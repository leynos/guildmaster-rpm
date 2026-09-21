#!/usr/bin/env bash
# Run the CUSE acceptance plan in a fresh, disposable KVM guest.
#
# Usage: scripts/cuse-guest.sh <target> <rpm-dir>
#   <target>   fedora-43 or rocky-10. It selects the pinned image, the tmt
#              distro context and the packages together, so that they cannot
#              disagree.
#   <rpm-dir>  a published build-rpm.sh output directory (with manifest.tsv),
#              or a directory of downloaded release assets prepared by
#              scripts/verify-release.sh.
#
# The guest is provisioned by tmt's own virtual provisioner (testcloud, QEMU
# and KVM) through the invoking user's libvirt session. Nothing from this
# host's /dev is passed in: the guest has its own kernel, CUSE, udev, systemd
# and SELinux policy.
#
# Fresh by construction
#   Every invocation provisions a new guest on a new copy-on-write overlay of
#   the checksum-verified base image and destroys it afterwards. The base
#   image is read-only, and its SHA-256 is checked before and after the run.
#   The overlay's backing file is checked to be that image. Guests are never
#   reused here; for development reuse, see docs/developers-guide.md.
#
# Two tmt invocations share one run id. The first provisions the guest. The
# packages under test are then placed in the plan's data directory, which the
# second invocation's prepare step pushes to the guest. That is how exactly
# the selected, checksum-verified files, and no others, reach the guest.
#
# Ownership
#   The run id gm-cuse-<target>-<pid>-<random> names everything this
#   invocation owns: the tmt run directory, and through it the libvirt
#   domain, overlay and SSH key that tmt created for it. Cleanup asks tmt to
#   clean up that run id and nothing else. The run directory is kept when the
#   run fails, or with KEEP_WORKDIR=1; the guest never is.
#
# TMT, SHA256SUM, QEMU_IMG and the helper-script variables are seams for
# scripts/tests.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <target> <rpm-dir>" >&2
    exit 2
fi
target=$1
rpm_dir=$2

repo_root=$(cd "$(dirname "$0")/.." && pwd)
[[ ${rpm_dir} == /* ]] || rpm_dir=${repo_root}/${rpm_dir}

: "${TMT:=tmt}"
: "${FLOCK:=flock}"
: "${SHA256SUM:=sha256sum}"
: "${QEMU_IMG:=qemu-img}"
: "${VIRSH:=virsh}"
: "${PREFLIGHT:=${repo_root}/scripts/virt-preflight.sh}"
: "${IMAGE_SCRIPT:=${repo_root}/scripts/cuse-image.sh}"
: "${CACHE_DIR:=${repo_root}/.build}"
: "${LOCK_DIR:=${CACHE_DIR}/locks}"
: "${EVIDENCE_DIR:=${CACHE_DIR}/evidence}"
: "${WORK_ROOT:=${TMT_WORKDIR_ROOT:-/var/tmp/tmt}}"
: "${PLAN:=/plans/cuse}"
: "${UPGRADE_RPM_DIR:=}"
# Starting allocations, not measured minimums.
: "${GUEST_MEMORY_MIB:=2048}"
: "${GUEST_CPUS:=2}"
# Absolute path to an image to use instead of the pinned cache entry. It must
# still match the pinned checksum: this relocates the bytes, it does not
# change which bytes are accepted.
: "${GUEST_IMAGE:=}"
: "${KEEP_WORKDIR:=0}"
# "release" when the packages are downloaded release assets; recorded in the
# evidence so that candidate and post-publication runs cannot be confused.
: "${EVIDENCE_KIND:=candidate}"

run_id="gm-cuse-${target}-$$-${RANDOM}"
run_dir=${WORK_ROOT}/${run_id}
provisioned=no
succeeded=no

log_event() {
    local event=$1
    shift
    printf 'guest_event event=%s target=%s run=%s elapsed_seconds=%s' \
        "${event}" "${target}" "${run_id}" "${SECONDS}"
    local field
    for field in "$@"; do
        printf ' %s' "${field}"
    done
    printf '\n'
}

die() {
    log_event guest_failed "detail=\"$*\""
    echo "$0: $*" >&2
    exit 1
}

# The guest's memory and processors reach the plan as tmt context, which the
# plan substitutes into its hardware block. They are not given as
# "provision --hardware" options: tmt 1.78 saves a command-line
# cpu.processors constraint in a form it cannot load again, which breaks
# every later invocation on the same run, including cleanup.
tmt_run() {
    TMT_WORKDIR_ROOT=${WORK_ROOT} "${TMT}" --root "${repo_root}" \
        --context "distro=${target}" \
        --context "guest_memory_mib=${GUEST_MEMORY_MIB}" \
        --context "guest_cpus=${GUEST_CPUS}" \
        run --id "${run_id}" "$@"
}

# Last resort when tmt cannot clean up its own run: remove the one libvirt
# domain and testcloud instance directory that tmt recorded for this run id.
destroy_own_guest() {
    local instance
    instance=$(sed -n 's/^ *instance-name: *//p' \
        "${run_dir}/plans${PLAN#/plans}/provision/guests.yaml" 2>/dev/null | head -n 1)
    [[ ${instance} == tmt-* ]] || return 1
    "${VIRSH}" --connect qemu:///session destroy "${instance}" >/dev/null 2>&1 || true
    "${VIRSH}" --connect qemu:///session undefine "${instance}" --nvram >/dev/null 2>&1 ||
        "${VIRSH}" --connect qemu:///session undefine "${instance}" >/dev/null 2>&1 || true
    rm -rf "${WORK_ROOT:?}/testcloud/instances/${instance}"
    ! "${VIRSH}" --connect qemu:///session dominfo "${instance}" >/dev/null 2>&1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ ${provisioned} == yes ]]; then
        # tmt pulled the test logs during execute and report; whatever a
        # failing test dumped (journal, AVC records, device labels) is
        # already in the run directory. Now destroy this run's guest.
        if tmt_run cleanup >"${run_dir}.cleanup.log" 2>&1; then
            log_event guest_destroyed
            rm -f "${run_dir}.cleanup.log"
        elif destroy_own_guest; then
            log_event guest_destroyed 'method=fallback' "log=${run_dir}.cleanup.log"
        else
            log_event guest_cleanup_failed "log=${run_dir}.cleanup.log"
            echo "$0: could not remove the guest of run ${run_id}; see ${run_dir}.cleanup.log" >&2
            [[ ${status} -ne 0 ]] || status=1
        fi
    fi
    if [[ -d ${run_dir} ]]; then
        if [[ ${succeeded} == yes && ${KEEP_WORKDIR} != 1 ]]; then
            rm -rf "${run_dir}"
        else
            log_event workdir_retained "path=${run_dir}"
        fi
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

checksum_of() {
    "${SHA256SUM}" <"$1" | cut -d' ' -f1
}

# Copy the packages into the plan's data directory, checking each against
# the manifest, as systemd-fixture.sh does.
stage_rpms() {
    local manifest=${rpm_dir}/manifest.tsv data_dir=$1
    [[ -f ${manifest} ]] ||
        die "no manifest.tsv in ${rpm_dir}; build the packages first (make rpm-${target})"
    mkdir -p "${data_dir}/rpms"
    local filename sha256 rest
    while IFS=$'\t' read -r filename rest; do
        sha256=${rest##*$'\t'}
        [[ -f ${rpm_dir}/${filename} ]] || die "manifest lists ${filename}, which is missing"
        mkdir -p "$(dirname "${data_dir}/rpms/${filename}")"
        cp "${rpm_dir}/${filename}" "${data_dir}/rpms/${filename}"
        [[ $(checksum_of "${data_dir}/rpms/${filename}") == "${sha256}" ]] ||
            die "${filename} does not match the checksum in manifest.tsv"
        log_event rpm_selected "file=${filename}" "sha256=${sha256}"
    done <"${manifest}"
    cp "${manifest}" "${data_dir}/rpms/manifest.tsv"
    cp "${repo_root}/packaging/check-tokens-option.sh" "${data_dir}/"

    if [[ -n ${UPGRADE_RPM_DIR} ]]; then
        mkdir -p "${data_dir}/upgrade"
        cp "${UPGRADE_RPM_DIR}"/*.rpm "${data_dir}/upgrade/"
    fi
}

# Show, rather than assume, that the guest's disk is an overlay whose backing
# file is the verified image. testcloud keeps each instance's disk in its
# store under the instance name tmt recorded for this run.
verify_overlay() {
    local instance disk backing
    instance=$(sed -n 's/^ *instance-name: *//p' \
        "${run_dir}/plans${PLAN#/plans}/provision/guests.yaml" | head -n 1)
    [[ -n ${instance} ]] || die 'tmt recorded no testcloud instance name for this run'
    disk=$(find "${WORK_ROOT}/testcloud/instances/${instance}" -maxdepth 1 \
        -name '*.qcow2' 2>/dev/null | head -n 1)
    [[ -n ${disk} ]] || die "no disk found for testcloud instance ${instance}"
    backing=$("${QEMU_IMG}" info --force-share --output=json "${disk}" |
        sed -n 's/^ *"full-backing-filename": *"\(.*\)",\{0,1\}$/\1/p' | head -n 1)
    [[ -n ${backing} ]] || die "the guest disk ${disk} has no backing file; it is not an overlay"
    [[ $(readlink -f "${backing}") == "$(readlink -f "${image}")" ]] ||
        die "the guest disk is backed by ${backing}, not by the verified image ${image}"
    log_event overlay_verified "instance=${instance}" "backing=${image}"
}

write_evidence() {
    mkdir -p "${EVIDENCE_DIR}"
    local evidence=${EVIDENCE_DIR}/cuse-${target}-${EVIDENCE_KIND}.txt
    {
        echo "tier: fresh-guest CUSE acceptance"
        echo "kind: ${EVIDENCE_KIND}"
        echo "target: ${target}"
        echo "plan: ${PLAN}"
        echo "result: passed"
        echo "source_commit: $(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "source_tree_dirty: $(git -C "${repo_root}" status --porcelain 2>/dev/null | grep -q . && echo yes || echo no)"
        echo "image: $(basename "${image}")"
        echo "image_sha256: ${image_sha256}"
        echo "image_unchanged_after_run: yes"
        echo "guest_memory_mib: ${GUEST_MEMORY_MIB}"
        echo "guest_cpus: ${GUEST_CPUS}"
        echo "tmt_version: $("${TMT}" --version 2>&1 | head -n 1)"
        "${PREFLIGHT}" | sed -n 's/^preflight_event check=\(virtual_provisioner\|libvirt_session\) status=ok /host_\1: /p'
        echo "rpms:"
        cut -f1,7 "${rpm_dir}/manifest.tsv" | sed 's/^/  /'
        echo "guest_facts:"
        sed 's/^/  /' "${data_dir}/guest-facts.txt"
    } >"${evidence}"
    log_event evidence_written "path=${evidence}"
}

"${PREFLIGHT}"

mkdir -p "${LOCK_DIR}"
exec {activity_fd}>"${LOCK_DIR}/activity.lock"
"${FLOCK}" -s "${activity_fd}"

if [[ -n ${GUEST_IMAGE} ]]; then
    [[ ${GUEST_IMAGE} == /* ]] || die 'GUEST_IMAGE must be an absolute path'
    image=${GUEST_IMAGE}
else
    image=$("${IMAGE_SCRIPT}" "${target}")
fi
image_sha256=$(awk -F'\t' -v target="${target}" -v arch="$(uname -m)" \
    '$0 !~ /^#/ && $1 == target && $2 == arch { print $4 }' \
    "${repo_root}/fixtures/cuse/images.tsv")
[[ $(checksum_of "${image}") == "${image_sha256}" ]] ||
    die "${image} does not match the SHA-256 pinned for ${target}"
log_event image_verified "image=$(basename "${image}")" "sha256=${image_sha256}"

mkdir -p "${WORK_ROOT}"
provisioned=yes
tmt_run -v \
    discover \
    provision --how virtual --connection session \
    --image "${image}" \
    plan --name "^${PLAN}\$" ||
    die "provisioning the ${target} guest failed; logs are under ${run_dir}"
verify_overlay

data_dir=${run_dir}/plans${PLAN#/plans}/data
stage_rpms "${data_dir}"

tmt_run -v \
    --environment "GM_RPM_DIR=${data_dir}/rpms" \
    --environment "GM_UPGRADE_RPM_DIR=${data_dir}/upgrade" \
    --environment "GM_TOKENS_CHECK=${data_dir}/check-tokens-option.sh" \
    --environment "GM_GUEST_FACTS=${data_dir}/guest-facts.txt" \
    --environment "GM_TARGET=${target}" \
    prepare execute report finish ||
    die "the ${PLAN} plan failed for ${target}; logs are under ${run_dir}"

[[ $(checksum_of "${image}") == "${image_sha256}" ]] ||
    die "the base image ${image} changed during the run"
[[ -s ${data_dir}/guest-facts.txt ]] ||
    die 'the guest recorded no facts; the environment preflight test did not run'

succeeded=yes
write_evidence
log_event guest_complete
