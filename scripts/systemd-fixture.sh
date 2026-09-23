#!/usr/bin/env bash
# Run a tmt plan inside a rootless Podman container whose PID 1 is the
# distribution's real systemd.
#
# Usage: scripts/systemd-fixture.sh <target> <base-image> <rpm-dir>
#   <target>      fedora-43 or rocky-10; selects the tmt distro context
#   <base-image>  digest-pinned base image the fixture is built from
#   <rpm-dir>     a published build-rpm.sh output directory, with manifest.tsv
#
# Why an adapter
#   tmt's container provisioner builds its own "podman run" command line and
#   offers no way to add --systemd=always or --cgroupns=private. It can,
#   however, adopt an existing container (provision --container NAME), and it
#   only needs its working directory to be visible at the same path inside.
#   So this script starts the fixture with exactly the options below, proves
#   that systemd booted, and then hands the container to tmt.
#
# What is never used: rootful Podman, --privileged, a host cgroup bind mount,
# the host PID namespace, the host systemd socket, or SELinux label disabling.
# A host that cannot run the fixture fails podman-preflight.sh; there is no
# fallback.
#
# Ownership
#   Everything this invocation creates carries its unique name: the container
#   gm-fx-<target>-<pid>-<random> and the directory /var/tmp/tmt/<that name>.
#   Cleanup removes that container and nothing else. The directory is kept
#   when the run fails, or when KEEP_WORKDIR=1, because it holds the tmt logs
#   and the diagnostics captured below. The fixture image is a shared cache
#   keyed on its inputs and is never removed here.
#
# The activity lock is held shared for the whole run, so "make clean" waits
# instead of deleting packages or an upgrade fixture that are being copied.
#
# Every external command is a seam (PODMAN, TMT, FLOCK, SHA256SUM) so that
# scripts/tests/test-systemd-fixture.sh can drive this script offline.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <target> <base-image> <rpm-dir>" >&2
    exit 2
fi
target=$1
base_image=$2
rpm_dir=$3

repo_root=$(cd "$(dirname "$0")/.." && pwd)
[[ ${rpm_dir} == /* ]] || rpm_dir=${repo_root}/${rpm_dir}

: "${PODMAN:=podman}"
: "${TMT:=tmt}"
: "${FLOCK:=flock}"
: "${SHA256SUM:=sha256sum}"
: "${PREFLIGHT:=${repo_root}/scripts/podman-preflight.sh}"
: "${CACHE_DIR:=${repo_root}/.build}"
: "${LOCK_DIR:=${CACHE_DIR}/locks}"
# tmt refuses a run directory inside the fmf root, which is this repository,
# so run directories live where tmt keeps its own.
: "${WORK_ROOT:=${TMT_WORKDIR_ROOT:-/var/tmp/tmt}}"
: "${EVIDENCE_DIR:=${CACHE_DIR}/evidence}"
: "${CONTAINERFILE:=${repo_root}/fixtures/systemd/Containerfile}"
: "${PLAN:=/plans/container}"
# Optional directory holding the higher-release package used by the upgrade
# test; see scripts/build-upgrade-fixture.sh.
: "${UPGRADE_RPM_DIR:=}"
# Seconds allowed for the container to answer at all, and then for systemd to
# finish booting.
: "${EXEC_TIMEOUT:=60}"
: "${BOOT_TIMEOUT:=120}"
# Space-separated units that may be failed after boot. Empty: the fixtures
# boot to "running" on both distributions. Any entry added here must be named
# and justified in docs/developers-guide.md.
: "${ALLOWED_FAILED_UNITS:=}"
: "${KEEP_WORKDIR:=0}"

name="gm-fx-${target}-$$-${RANDOM}"
work_dir=${WORK_ROOT}/${name}
container_started=no
succeeded=no

# log_event <event> [field...]: print a structured "fixture_event" log
# line.
#
# Writes "fixture_event event=<event> target=<target> fixture=<name>
# elapsed_seconds=<SECONDS>" followed by each extra field (already
# "key=value" formatted) space-separated. Always returns 0.
log_event() {
    local event=$1
    shift
    printf 'fixture_event event=%s target=%s fixture=%s elapsed_seconds=%s' \
        "${event}" "${target}" "${name}" "${SECONDS}"
    local field
    for field in "$@"; do
        printf ' %s' "${field}"
    done
    printf '\n'
}

# die <message>: log a failure and abort the script.
#
# Logs a fixture_failed event with <message> as its detail, prints
# "$0: <message>" to stderr, then exits the script with status 1.
die() {
    log_event fixture_failed "detail=\"$*\""
    echo "$0: $*" >&2
    exit 1
}

# Best-effort capture of what a reader needs to diagnose a failed run. Runs
# before the container is removed. None of it contains credentials: it is the
# fixture's own journal and unit state.
#
# capture_diagnostics: dump the fixture's journal and unit state.
#
# Writes the container's journal, failed units, guildmaster.service state,
# inspect output and console log under work_dir/diagnostics. Every capture
# is best-effort; failures are ignored. Always returns 0.
capture_diagnostics() {
    local out=${work_dir}/diagnostics
    mkdir -p "${out}"
    "${PODMAN}" exec "${name}" journalctl -b --no-pager >"${out}/journal.txt" 2>&1 || true
    "${PODMAN}" exec "${name}" systemctl list-units --failed --no-legend --plain \
        >"${out}/failed-units.txt" 2>&1 || true
    "${PODMAN}" exec "${name}" systemctl show guildmaster.service \
        >"${out}/guildmaster-show.txt" 2>&1 || true
    "${PODMAN}" inspect "${name}" >"${out}/inspect.json" 2>&1 || true
    "${PODMAN}" logs "${name}" >"${out}/console.txt" 2>&1 || true
    log_event diagnostics_captured "path=${out}"
}

# cleanup: remove this run's container and reclaim its working directory.
#
# Invoked from the EXIT, INT and TERM traps. Captures diagnostics before
# removing the container when the run did not succeed, then force-removes
# the container. Removes work_dir unless the run failed or KEEP_WORKDIR is
# set. Exits the script with the original status.
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ ${container_started} == yes ]]; then
        if [[ ${succeeded} != yes ]]; then
            capture_diagnostics
        fi
        # Only ever this invocation's container.
        "${PODMAN}" rm --force --time 10 "${name}" >/dev/null 2>&1 || true
        log_event container_removed
    fi
    if [[ -d ${work_dir} ]]; then
        if [[ ${succeeded} == yes && ${KEEP_WORKDIR} != 1 ]]; then
            rm -rf "${work_dir}"
        else
            log_event workdir_retained "path=${work_dir}"
        fi
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# acquire_activity_lock: take the shared activity lock.
#
# Creates LOCK_DIR if needed and blocks until a shared lock on
# activity.lock is held, so that "make clean" waits for this run. Always
# returns 0.
acquire_activity_lock() {
    mkdir -p "${LOCK_DIR}"
    exec {activity_fd}>"${LOCK_DIR}/activity.lock"
    "${FLOCK}" -s "${activity_fd}"
}

# Copy the packages under test into the working directory and check every one
# against the manifest the build wrote, so that the run installs exactly the
# bytes that were built and records which bytes those were.
#
# select_rpms: stage the packages under test into the working directory.
#
# Copies every file listed in rpm_dir/manifest.tsv into work_dir/rpms,
# verifying each against its manifest checksum, and copies the manifest
# alongside them. Also stages the upgrade fixture, through
# stage_upgrade_rpms, when UPGRADE_RPM_DIR is set. Calls die, which exits the
# script, on any missing file or checksum mismatch.
select_rpms() {
    local manifest=${rpm_dir}/manifest.tsv
    [[ -f ${manifest} ]] ||
        die "no manifest.tsv in ${rpm_dir}; build the packages first (make rpm-${target})"
    mkdir -p "${work_dir}/rpms"
    local filename sha256 _rest
    while IFS=$'\t' read -r filename _rest; do
        sha256=${_rest##*$'\t'}
        [[ -f ${rpm_dir}/${filename} ]] || die "manifest lists ${filename}, which is missing"
        mkdir -p "$(dirname "${work_dir}/rpms/${filename}")"
        cp "${rpm_dir}/${filename}" "${work_dir}/rpms/${filename}"
        echo "${sha256}  ${work_dir}/rpms/${filename}" |
            "${SHA256SUM}" -c --status - ||
            die "${filename} does not match the checksum in manifest.tsv"
        log_event rpm_selected "file=${filename}" "sha256=${sha256}"
    done <"${manifest}"
    cp "${manifest}" "${work_dir}/rpms/manifest.tsv"

    if [[ -n ${UPGRADE_RPM_DIR} ]]; then
        stage_upgrade_rpms
    fi
}

# stage_upgrade_rpms: copy the upgrade fixture into work_dir/upgrade.
#
# The same rules as scripts/cuse-guest.sh: a relative UPGRADE_RPM_DIR is
# resolved against the repository, an empty directory is refused, each copy is
# checked against the file it was copied from, and its checksum is logged and
# written to work_dir/upgrade.sha256 for the evidence. Calls die, which exits
# the script, on any failure.
stage_upgrade_rpms() {
    local source_dir=${UPGRADE_RPM_DIR} package staged sha256
    [[ ${source_dir} == /* ]] || source_dir=${repo_root}/${source_dir}
    local -a packages=()
    for package in "${source_dir}"/*.rpm; do
        [[ -f ${package} ]] && packages+=("${package}")
    done
    [[ ${#packages[@]} -gt 0 ]] ||
        die "UPGRADE_RPM_DIR ${source_dir} holds no RPMs; run make upgrade-fixture-${target}"
    mkdir -p "${work_dir}/upgrade"
    : >"${work_dir}/upgrade.sha256"
    for package in "${packages[@]}"; do
        staged=${work_dir}/upgrade/$(basename "${package}")
        cp "${package}" "${staged}"
        sha256=$("${SHA256SUM}" <"${staged}" | cut -d' ' -f1)
        [[ ${sha256} == "$("${SHA256SUM}" <"${package}" | cut -d' ' -f1)" ]] ||
            die "the staged copy of $(basename "${package}") differs from its source"
        printf '%s\t%s\n' "$(basename "${package}")" "${sha256}" >>"${work_dir}/upgrade.sha256"
        log_event upgrade_rpm_selected "file=$(basename "${package}")" "sha256=${sha256}"
    done
}

# Build the fixture image unless one with the same inputs already exists. The
# tag is keyed on the base image reference, which carries its digest, and on
# the Containerfile's bytes.
#
# ensure_fixture_image: build or reuse the fixture image, setting
# fixture_image.
#
# Sets the "fixture_image" global to a tag keyed on base_image and the
# Containerfile's bytes, building it with Podman when no image with that
# tag exists. Calls die, which exits the script, when base_image is not
# pinned by digest or the build fails.
ensure_fixture_image() {
    [[ ${base_image} == *@sha256:* ]] ||
        die "the base image must be pinned by digest, got ${base_image}"
    local key lock_fd
    key=$({
        printf '%s\n' "${base_image}"
        cat "${CONTAINERFILE}"
    } | "${SHA256SUM}" | cut -c1-16)
    fixture_image="localhost/guildmaster-rpm-fixture-${target}:${key}"

    exec {lock_fd}>"${LOCK_DIR}/fixture-${target}.lock"
    "${FLOCK}" -x "${lock_fd}"
    if "${PODMAN}" image exists "${fixture_image}"; then
        log_event fixture_image_cached "image=${fixture_image}"
    else
        log_event fixture_image_build_start "image=${fixture_image}"
        "${PODMAN}" build --build-arg "BASE=${base_image}" \
            --tag "${fixture_image}" \
            --file "${CONTAINERFILE}" "$(dirname "${CONTAINERFILE}")" ||
            die "building the fixture image for ${target} failed"
        log_event fixture_image_built "image=${fixture_image}"
    fi
    exec {lock_fd}>&-
}

# start_container: launch the fixture container as a private systemd.
#
# Starts the fixture_image container, detached, with --systemd=always,
# --cgroupns=private and --user=0, bind-mounting work_dir at the same
# path, and sets container_started=yes. Calls die, which exits the
# script, if Podman cannot start it.
start_container() {
    "${PODMAN}" run --detach \
        --name "${name}" \
        --systemd=always \
        --cgroupns=private \
        --user=0 \
        --volume "${work_dir}:${work_dir}:z" \
        "${fixture_image}" >/dev/null ||
        die "could not start the fixture container"
    container_started=yes
    log_event container_started "image=${fixture_image}"
}

# Two bounded waits. First until the container will run a command at all and
# systemd's manager answers; only then ask systemd to wait for boot to
# finish. "running" is required. "degraded" is accepted only if every failed
# unit is a named exception; anything else is a failure, as is a timeout.
#
# wait_for_boot: wait for the container's systemd to finish booting.
#
# Polls until systemd answers within EXEC_TIMEOUT seconds, confirms PID 1
# is systemd, then waits up to BOOT_TIMEOUT seconds for it to reach
# "running" (or "degraded" with only allow-listed failed units). Calls
# die, which exits the script, on any other outcome or timeout.
wait_for_boot() {
    local deadline=$((SECONDS + EXEC_TIMEOUT)) state
    while :; do
        # is-system-running exits non-zero for every state but "running", so
        # its status says nothing about whether the manager answered.
        state=$("${PODMAN}" exec "${name}" systemctl is-system-running 2>/dev/null) || true
        case ${state} in
        '' | offline | unknown) ;;
        *) break ;;
        esac
        if ((SECONDS >= deadline)); then
            die "systemd did not answer within ${EXEC_TIMEOUT}s (last state: ${state:-none})"
        fi
        # Pacing between polls only; the assertion is the state, not the time.
        sleep 1
    done

    local pid1
    pid1=$("${PODMAN}" exec "${name}" cat /proc/1/comm) || die "cannot read PID 1's name"
    [[ ${pid1} == systemd ]] || die "PID 1 is ${pid1}, not systemd"

    state=$("${PODMAN}" exec "${name}" \
        timeout "${BOOT_TIMEOUT}" systemctl is-system-running --wait 2>/dev/null) || true
    log_event boot_state "state=${state:-timeout}"
    case ${state} in
    running) ;;
    degraded)
        local failed unit
        failed=$("${PODMAN}" exec "${name}" systemctl list-units --failed \
            --no-legend --plain | awk '{print $1}')
        for unit in ${failed}; do
            [[ " ${ALLOWED_FAILED_UNITS} " == *" ${unit} "* ]] ||
                die "the fixture booted degraded; unexpected failed unit: ${unit}"
            log_event allowed_failed_unit "unit=${unit}"
        done
        ;;
    *) die "the fixture did not finish booting within ${BOOT_TIMEOUT}s (state: ${state:-timeout})" ;;
    esac
}

# Show that Podman applied what was asked for, and record the confinement the
# run actually had.
#
# verify_container: confirm the container's settings and record its
# SELinux confinement.
#
# Checks the container's systemd mode, cgroup namespace, privilege, PID
# namespace and user match what start_container requested, then writes
# "confined" or "userspace_only" to work_dir/container-coverage depending
# on whether it has an SELinux process label. Calls die, which exits the
# script, on a mismatch or an unexpected process label domain.
verify_container() {
    local settings
    settings=$("${PODMAN}" inspect "${name}" --format \
        '{{.Config.SystemdMode}} {{.HostConfig.CgroupMode}} {{.HostConfig.Privileged}} {{.HostConfig.PidMode}} {{.Config.User}}') ||
        die "cannot inspect the fixture container"
    [[ ${settings} == 'true private false private 0' ]] ||
        die "unexpected container settings (systemd cgroupns privileged pidns user): ${settings}"

    local label coverage
    label=$("${PODMAN}" inspect "${name}" --format '{{.ProcessLabel}}')
    if [[ -n ${label} ]]; then
        [[ ${label} == *:container_init_t:* ]] ||
            die "the fixture runs as ${label}, expected the container_init_t domain"
        coverage=confined
    else
        coverage=userspace_only
    fi
    log_event container_verified "settings=\"${settings}\"" \
        "process_label=${label:-none}" "container_coverage=${coverage}"
    printf '%s\n' "${coverage}" >"${work_dir}/container-coverage"
}

# run_plan: run the container plan against the started fixture.
#
# Runs tmt's discover, provision (adopting the started container), prepare,
# execute and report steps for PLAN, passing the staged RPM directories and
# target as environment variables. Finish and cleanup are left out; this
# script owns the container. Returns tmt's exit status.
run_plan() {
    local -a environment=(
        --environment "GM_RPM_DIR=${work_dir}/rpms"
        --environment "GM_UPGRADE_RPM_DIR=${work_dir}/upgrade"
        --environment "GM_TARGET=${target}"
    )
    # finish and cleanup are left out on purpose: this script owns the
    # container, and removes it after capturing diagnostics.
    TMT_WORKDIR_ROOT=${work_dir} "${TMT}" --root "${repo_root}" \
        --context "distro=${target}" \
        run --id "${name}" -v "${environment[@]}" \
        discover \
        provision --how container --container "${name}" \
        prepare execute report \
        plan --name "^${PLAN}\$"
}

# write_evidence: record the acceptance evidence for a successful run.
#
# Writes EVIDENCE_DIR/container-<target>.txt, summarising the tier, base
# and fixture images, SELinux coverage and tested packages. Always
# returns 0.
write_evidence() {
    mkdir -p "${EVIDENCE_DIR}"
    local evidence=${EVIDENCE_DIR}/container-${target}.txt
    {
        echo "tier: rootless systemd container"
        echo "target: ${target}"
        echo "plan: ${PLAN}"
        echo "result: passed"
        echo "source_commit: $(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "source_tree_dirty: $(git -C "${repo_root}" status --porcelain 2>/dev/null | grep -q . && echo yes || echo no)"
        echo "base_image: ${base_image}"
        echo "fixture_image: ${fixture_image}"
        echo "host_kernel: $(uname -r)"
        echo "container_coverage: $(cat "${work_dir}/container-coverage")"
        echo "podman_version: $("${PODMAN}" --version)"
        echo "tmt_version: $("${TMT}" --version 2>&1 | head -n 1)"
        echo "rpms:"
        cut -f1,7 "${work_dir}/rpms/manifest.tsv" | sed 's/^/  /'
        if [[ -s ${work_dir}/upgrade.sha256 ]]; then
            echo "upgrade_rpms:"
            sed 's/^/  /' "${work_dir}/upgrade.sha256"
        fi
    } >"${evidence}"
    log_event evidence_written "path=${evidence}"
}

"${PREFLIGHT}"
acquire_activity_lock
mkdir -p "${work_dir}"
select_rpms
ensure_fixture_image
start_container
wait_for_boot
verify_container
run_plan || die "the ${PLAN} plan failed for ${target}; logs are under ${work_dir}"
succeeded=yes
write_evidence
log_event fixture_complete
