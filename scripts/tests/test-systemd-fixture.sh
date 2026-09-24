#!/usr/bin/env bash
# Offline tests for scripts/systemd-fixture.sh and scripts/podman-preflight.sh.
#
# No container runtime, no tmt and no network: podman, tmt and the other
# seams are replaced by stubs that record how they were called and answer
# from files in a per-test scenario directory. These are executed script
# tests of the adapter's own logic. They say nothing about whether a real
# host can boot systemd in a container; podman-preflight.sh and the real
# "make test" run cover that.
#
# The one concurrency test (cancellation) uses FIFO barriers, not sleeps.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
fixture_script=${repo_root}/scripts/systemd-fixture.sh
preflight_script=${repo_root}/scripts/podman-preflight.sh

scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT

passed=0
failed=0
current=

# ok <message>: record a passing check for the current test.
ok() {
    passed=$((passed + 1))
    echo "ok: ${current}: $*"
}

# not_ok <message>: record a failing check for the current test.
not_ok() {
    failed=$((failed + 1))
    echo "FAIL: ${current}: $*" >&2
}

# assert_status <actual> <expected>: pass or fail on whether the two exit
# statuses match.
assert_status() {
    if [[ $1 -eq $2 ]]; then ok "exit status $2"; else not_ok "exit status $1, expected $2"; fi
}

# assert_contains <file> <needle> <message>: pass when <file> contains
# <needle>; otherwise fail and dump the file for diagnosis.
assert_contains() {
    if grep -qF -- "$2" "$1"; then ok "$3"; else
        not_ok "$3 (no '$2' in $1)"
        sed 's/^/    | /' "$1" >&2
    fi
}

# assert_lacks <file> <needle> <message>: pass when <file> does not contain
# <needle>.
assert_lacks() {
    if grep -qF -- "$2" "$1"; then
        not_ok "$3 (found '$2' in $1)"
    else ok "$3"; fi
}

# --- FIFO handshake (bounded, never a sleep) ----------------------------------

: "${FIFO_TIMEOUT:=60}"

# fifo_read_kill <pid>: terminate a stuck handshake's background job with
# TERM, then KILL if it is still alive after a short grace period.
fifo_read_kill() {
    local target=$1
    kill -TERM "${target}" 2>/dev/null || true
    sleep 0.2
    kill -0 "${target}" 2>/dev/null && kill -KILL "${target}" 2>/dev/null
    return 0
}

# fifo_read <fifo> <what> [kill targets...]: read one line from a FIFO
# handshake with a bounded wait. On timeout, records a failure naming
# <what>, terminates every given kill target (see fifo_read_kill) and
# returns non-zero.
fifo_read() {
    local fifo=$1 what=$2
    shift 2
    local fd
    exec {fd}<>"${fifo}"
    if read -r -t "${FIFO_TIMEOUT}" -u "${fd}" _; then
        exec {fd}<&-
        return 0
    fi
    exec {fd}<&-
    not_ok "timed out after ${FIFO_TIMEOUT}s waiting for ${what}"
    local target
    for target in "$@"; do
        fifo_read_kill "${target}"
    done
    return 1
}

# --- stubs -----------------------------------------------------------------

stub_dir=${scratch}/stubs
mkdir -p "${stub_dir}"

cat >"${stub_dir}/podman" <<'STUB'
#!/usr/bin/env bash
# Answers from files in ${SCENARIO}; records every call in ${SCENARIO}/podman.log.
set -u
printf '%s\n' "$*" >>"${SCENARIO}/podman.log"
answer() { [[ -f ${SCENARIO}/$1 ]] && cat "${SCENARIO}/$1"; }
case $1 in
--version) echo 'podman version 0.0.0-stub' ;;
info) answer info ;;
image) exit "$(answer image_exists_status || echo 0)" ;;
build) exit "$(answer build_status || echo 0)" ;;
run)
    if [[ -p ${SCENARIO}/run.started ]]; then
        # Cancellation during start-up: announce, then block until killed.
        echo started >"${SCENARIO}/run.started"
        read -r _ <"${SCENARIO}/run.never"
    fi
    exit "$(answer run_status || echo 0)"
    ;;
container) exit "$(answer container_exists_status || echo 1)" ;;
rm | logs) exit 0 ;;
inspect)
    case $* in
    *SystemdMode*) answer settings ;;
    *ProcessLabel*) answer label ;;
    *) echo '[]' ;;
    esac
    ;;
exec)
    case $* in
    *'is-system-running --wait'*)
        answer wait_state
        [[ $(answer wait_state) == running ]]
        ;;
    *is-system-running*)
        answer state
        [[ $(answer state) == running ]]
        ;;
    *'/proc/1/comm'*) answer pid1 ;;
    *'list-units --failed'*) answer failed_units ;;
    *) exit 0 ;;
    esac
    ;;
esac
STUB

cat >"${stub_dir}/tmt" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ $1 == --version ]]; then
    echo 'tmt version: 0.0.0-stub'
    exit 0
fi
printf '%s\n' "$*" >>"${SCENARIO}/tmt.log"
printf '%s\n' "${TMT_WORKDIR_ROOT:-unset}" >"${SCENARIO}/tmt.workdir_root"
if [[ -p ${SCENARIO}/tmt.started ]]; then
    # Cancellation test: announce, then block until killed.
    echo started >"${SCENARIO}/tmt.started"
    read -r _ <"${SCENARIO}/tmt.never"
fi
exit "$(cat "${SCENARIO}/tmt_status" 2>/dev/null || echo 0)"
STUB
chmod +x "${stub_dir}/podman" "${stub_dir}/tmt"

pinned='registry.example/fedora@sha256:0000000000000000000000000000000000000000000000000000000000000000'

# new_scenario <name>: a healthy host, a bootable fixture, a passing plan and
# a valid package directory. Tests then break one thing.
new_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    export SCENARIO
    mkdir -p "${SCENARIO}/rpms/srpm" "${SCENARIO}/work" "${SCENARIO}/cache"
    echo running >"${SCENARIO}/state"
    echo running >"${SCENARIO}/wait_state"
    echo systemd >"${SCENARIO}/pid1"
    echo 'true private false private 0' >"${SCENARIO}/settings"
    : >"${SCENARIO}/label"
    : >"${SCENARIO}/failed_units"
    echo 0 >"${SCENARIO}/image_exists_status"
    : >"${SCENARIO}/podman.log"
    : >"${SCENARIO}/tmt.log"

    local file
    : >"${SCENARIO}/rpms/manifest.tsv"
    for file in 'guildmaster-0.1^1-1.fc43.x86_64.rpm' 'srpm/guildmaster-0.1^1-1.fc43.src.rpm'; do
        echo "payload of ${file}" >"${SCENARIO}/rpms/${file}"
        printf '%s\tguildmaster\t(none)\t0.1^1\t1.fc43\tx86_64\t%s\n' "${file}" \
            "$(sha256sum <"${SCENARIO}/rpms/${file}" | cut -d' ' -f1)" \
            >>"${SCENARIO}/rpms/manifest.tsv"
    done
}

# run_fixture [extra env assignments...]: run the adapter against the current
# scenario; output in ${SCENARIO}/out, status in $status.
run_fixture() {
    status=0
    env PODMAN="${stub_dir}/podman" TMT="${stub_dir}/tmt" PREFLIGHT=true \
        CACHE_DIR="${SCENARIO}/cache" WORK_ROOT="${SCENARIO}/work" \
        EXEC_TIMEOUT=1 BOOT_TIMEOUT=1 "$@" \
        "${fixture_script}" fedora-43 "${base_image:-${pinned}}" "${SCENARIO}/rpms" \
        >"${SCENARIO}/out" 2>&1 || status=$?
}

# container_name: the fixture container name the adapter logged for the
# current scenario, read back from its output.
container_name() {
    sed -n 's/.*fixture=\(gm-fx-[^ ]*\).*/\1/p' "${SCENARIO}/out" | head -n 1
}

# Every "rm" the adapter issued must name its own container and nothing else.
assert_only_own_container_removed() {
    local own others
    own=$(container_name)
    others=$(grep '^rm ' "${SCENARIO}/podman.log" | grep -vF -- "${own}" || true)
    if [[ -n ${own} && -z ${others} ]] && grep -q "^rm .*${own}" "${SCENARIO}/podman.log"; then
        ok 'removed its own container and no other'
    else
        not_ok "unexpected removals: own=${own} others=${others}"
    fi
}

# --- systemd-fixture.sh ------------------------------------------------------

new_scenario happy_path
run_fixture
assert_status "${status}" 0
for option in '--systemd=always' '--cgroupns=private' '--user=0' '--detach'; do
    assert_contains "${SCENARIO}/podman.log" "${option}" "podman run is given ${option}"
done
for forbidden in '--privileged' '--pid=host' '/sys/fs/cgroup' 'label=disable' '/run/systemd'; do
    assert_lacks "${SCENARIO}/podman.log" "${forbidden}" "podman is never given ${forbidden}"
done
assert_contains "${SCENARIO}/tmt.log" "--container $(container_name)" 'tmt adopts the adapter container'
assert_contains "${SCENARIO}/tmt.log" '--context distro=fedora-43' 'tmt is given the matching distro context'
assert_contains "${SCENARIO}/tmt.log" 'GM_TARGET=fedora-43' 'tests are told the target'
assert_lacks "${SCENARIO}/tmt.log" ' cleanup' 'tmt is not asked to remove the container'
assert_contains "${SCENARIO}/out" 'event=rpm_selected' 'selected packages are logged with checksums'
assert_contains "${SCENARIO}/cache/evidence/container-fedora-43.txt" 'container_coverage: userspace_only' \
    'evidence records the coverage without SELinux'
assert_contains "${SCENARIO}/cache/evidence/container-fedora-43.txt" 'guildmaster-0.1^1-1.fc43.x86_64.rpm' \
    'evidence records the packages'
assert_only_own_container_removed
if [[ -z $(ls -A "${SCENARIO}/work") ]]; then ok 'work directory removed on success'; else not_ok 'work directory left behind'; fi
assert_lacks "${SCENARIO}/podman.log" 'build ' 'a cached fixture image is not rebuilt'

new_scenario image_not_cached
echo 1 >"${SCENARIO}/image_exists_status"
run_fixture
assert_status "${status}" 0
assert_contains "${SCENARIO}/podman.log" "build --build-arg BASE=${pinned}" 'a missing fixture image is built from the pinned base'

new_scenario image_key_tracks_inputs
run_fixture
first=$(sed -n 's/.*image=\([^ ]*\).*/\1/p' "${SCENARIO}/out" | head -n 1)
cp "${repo_root}/fixtures/systemd/Containerfile" "${SCENARIO}/Containerfile"
echo '# changed' >>"${SCENARIO}/Containerfile"
run_fixture CONTAINERFILE="${SCENARIO}/Containerfile"
second=$(sed -n 's/.*image=\([^ ]*\).*/\1/p' "${SCENARIO}/out" | head -n 1)
if [[ -n ${first} && ${first} != "${second}" ]]; then ok 'image tag changes with the Containerfile'; else not_ok "tags: ${first} ${second}"; fi

new_scenario unpinned_base
base_image='registry.example/fedora:43' run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'must be pinned by digest' 'an unpinned base image is refused'
assert_lacks "${SCENARIO}/podman.log" 'run ' 'no container is started'

new_scenario missing_manifest
rm "${SCENARIO}/rpms/manifest.tsv"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'no manifest.tsv' 'a package directory without a manifest is refused'
assert_lacks "${SCENARIO}/podman.log" 'run ' 'no container is started'

new_scenario changed_package
echo tampered >>"${SCENARIO}/rpms/guildmaster-0.1^1-1.fc43.x86_64.rpm"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'does not match the checksum' 'a package that differs from the manifest is refused'
assert_lacks "${SCENARIO}/podman.log" 'run ' 'no container is started'

new_scenario never_answers
: >"${SCENARIO}/state"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'systemd did not answer within 1s' 'the first readiness wait is bounded'
assert_contains "${SCENARIO}/out" 'event=diagnostics_captured' 'diagnostics are captured before removal'
assert_only_own_container_removed
assert_lacks "${SCENARIO}/tmt.log" 'run' 'the plan is not run on an unready fixture'

new_scenario boot_times_out
echo starting >"${SCENARIO}/state"
echo starting >"${SCENARIO}/wait_state"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'did not finish booting' 'a boot that does not complete is a failure'
assert_lacks "${SCENARIO}/tmt.log" 'run' 'the plan is not run'

new_scenario degraded_unexpected
echo degraded >"${SCENARIO}/state"
echo degraded >"${SCENARIO}/wait_state"
echo 'surprise.service loaded failed failed' >"${SCENARIO}/failed_units"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'unexpected failed unit: surprise.service' 'degraded is not treated as running'
assert_lacks "${SCENARIO}/tmt.log" 'run' 'the plan is not run'

new_scenario degraded_named_exception
echo degraded >"${SCENARIO}/state"
echo degraded >"${SCENARIO}/wait_state"
echo 'known.service loaded failed failed' >"${SCENARIO}/failed_units"
run_fixture ALLOWED_FAILED_UNITS='other.service known.service'
assert_status "${status}" 0
assert_contains "${SCENARIO}/out" 'event=allowed_failed_unit' 'a named exception is logged, not hidden'

new_scenario pid1_not_systemd
echo bash >"${SCENARIO}/pid1"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'PID 1 is bash' 'an application container is refused'

new_scenario privileged_container
echo 'true private true private 0' >"${SCENARIO}/settings"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'unexpected container settings' 'settings Podman reports are verified'

new_scenario selinux_confined
echo 'system_u:system_r:container_init_t:s0:c1,c2' >"${SCENARIO}/label"
run_fixture
assert_status "${status}" 0
assert_contains "${SCENARIO}/cache/evidence/container-fedora-43.txt" 'container_coverage: confined' \
    'an enforcing host with the expected domain is recorded as confined'

new_scenario selinux_wrong_domain
echo 'system_u:system_r:spc_t:s0' >"${SCENARIO}/label"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'expected the container_init_t domain' 'an unconfined domain is refused'

new_scenario plan_fails
echo 1 >"${SCENARIO}/tmt_status"
run_fixture
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'event=workdir_retained' 'logs are kept when the plan fails'
assert_contains "${SCENARIO}/out" 'event=diagnostics_captured' 'diagnostics are captured'
assert_only_own_container_removed
if [[ ! -e ${SCENARIO}/cache/evidence/container-fedora-43.txt ]]; then ok 'no evidence is written for a failed run'; else not_ok 'evidence written for a failed run'; fi

new_scenario upgrade_rpms_recorded
mkdir -p "${SCENARIO}/upgrade"
echo 'upgrade rpm bytes' >"${SCENARIO}/upgrade/guildmaster-0.1^1-2.fc43.upgradetest.x86_64.rpm"
upgrade_sha=$(sha256sum <"${SCENARIO}/upgrade/guildmaster-0.1^1-2.fc43.upgradetest.x86_64.rpm" | cut -d' ' -f1)
run_fixture UPGRADE_RPM_DIR="${SCENARIO}/upgrade"
assert_status "${status}" 0
assert_contains "${SCENARIO}/out" 'event=upgrade_rpm_selected' 'the upgrade package is logged'
assert_contains "${SCENARIO}/out" 'file=guildmaster-0.1^1-2.fc43.upgradetest.x86_64.rpm' \
    'the upgrade log names the upgrade package'
assert_contains "${SCENARIO}/out" "sha256=${upgrade_sha}" 'the upgrade log carries its real checksum'
assert_contains "${SCENARIO}/cache/evidence/container-fedora-43.txt" 'upgrade_rpms:' \
    'evidence records an upgrade_rpms block'
assert_contains "${SCENARIO}/cache/evidence/container-fedora-43.txt" \
    "guildmaster-0.1^1-2.fc43.upgradetest.x86_64.rpm	${upgrade_sha}" \
    'evidence records the upgrade package with its real checksum'

new_scenario upgrade_dir_empty_refused
mkdir -p "${SCENARIO}/upgrade"
run_fixture UPGRADE_RPM_DIR="${SCENARIO}/upgrade"
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'holds no RPMs' 'an empty upgrade directory is refused'
assert_lacks "${SCENARIO}/podman.log" 'run ' 'no container is started when the upgrade directory is empty'

new_scenario container_start_fails
echo 125 >"${SCENARIO}/run_status"
run_fixture
assert_status "${status}" 1
assert_lacks "${SCENARIO}/podman.log" 'rm ' 'nothing is removed when nothing was started'

# A failed start that nonetheless created the container still owns it: the
# container is removed by this invocation's name.
new_scenario container_start_fails_after_create
echo 125 >"${SCENARIO}/run_status"
echo 0 >"${SCENARIO}/container_exists_status"
run_fixture
assert_status "${status}" 1
assert_only_own_container_removed

# Cancellation while Podman is still starting the container: bash runs the
# TERM trap only once "podman run" returns, so the container this invocation
# may have created must already be marked as its own, and removed.
new_scenario cancelled_during_start
mkfifo "${SCENARIO}/run.started" "${SCENARIO}/run.never"
exec {never_fd}<>"${SCENARIO}/run.never"
setsid env PODMAN="${stub_dir}/podman" TMT="${stub_dir}/tmt" PREFLIGHT=true \
    CACHE_DIR="${SCENARIO}/cache" WORK_ROOT="${SCENARIO}/work" \
    "${fixture_script}" fedora-43 "${pinned}" "${SCENARIO}/rpms" \
    >"${SCENARIO}/out" 2>&1 &
fixture_pid=$!
if fifo_read "${SCENARIO}/run.started" 'podman run to announce it started' "-${fixture_pid}"; then
    kill -TERM -- "-${fixture_pid}"
    status=0
    wait "${fixture_pid}" || status=$?
    assert_status "${status}" 143
    assert_only_own_container_removed
else
    wait "${fixture_pid}" 2>/dev/null || true
fi
exec {never_fd}>&-

# Cancellation: hold the run inside tmt, deliver TERM to the process group as
# a terminal or CI runner would, and check that the container is removed.
new_scenario cancelled
mkfifo "${SCENARIO}/tmt.started" "${SCENARIO}/tmt.never"
exec {never_fd}<>"${SCENARIO}/tmt.never"
setsid env PODMAN="${stub_dir}/podman" TMT="${stub_dir}/tmt" PREFLIGHT=true \
    CACHE_DIR="${SCENARIO}/cache" WORK_ROOT="${SCENARIO}/work" \
    "${fixture_script}" fedora-43 "${pinned}" "${SCENARIO}/rpms" \
    >"${SCENARIO}/out" 2>&1 &
fixture_pid=$!
if fifo_read "${SCENARIO}/tmt.started" 'tmt to announce it started' "-${fixture_pid}"; then
    kill -TERM -- "-${fixture_pid}"
    status=0
    wait "${fixture_pid}" || status=$?
    assert_status "${status}" 143
    assert_only_own_container_removed
    assert_contains "${SCENARIO}/out" 'event=workdir_retained' 'the work directory is kept after cancellation'
else
    wait "${fixture_pid}" 2>/dev/null || true
fi
exec {never_fd}>&-

# --- podman-preflight.sh -----------------------------------------------------

# run_preflight: a healthy host unless the scenario's files say otherwise.
run_preflight() {
    status=0
    env PODMAN="${stub_dir}/podman" SYSTEMCTL="${SCENARIO}/systemctl" \
        GETENFORCE="${SCENARIO}/getenforce" \
        SUBUID_FILE="${SCENARIO}/subuid" SUBGID_FILE="${SCENARIO}/subgid" \
        CGROUP_ROOT="${SCENARIO}/cgroup" PREFLIGHT_USER=tester PREFLIGHT_UID=1234 \
        "${preflight_script}" >"${SCENARIO}/out" 2>&1 || status=$?
}

# new_preflight_scenario <name>: a healthy host scenario for
# podman-preflight.sh; tests then break one check.
new_preflight_scenario() {
    new_scenario "$1"
    echo 'true v2 systemd crun 5.8.0' >"${SCENARIO}/info"
    printf '#!/bin/sh\nexit 0\n' >"${SCENARIO}/systemctl"
    printf '#!/bin/sh\necho Disabled\n' >"${SCENARIO}/getenforce"
    chmod +x "${SCENARIO}/systemctl" "${SCENARIO}/getenforce"
    echo 'tester:100000:65536' >"${SCENARIO}/subuid"
    echo 'tester:100000:65536' >"${SCENARIO}/subgid"
    mkdir -p "${SCENARIO}/cgroup/user.slice/user-1234.slice/user@1234.service"
    echo 'cpu memory pids' >"${SCENARIO}/cgroup/user.slice/user-1234.slice/user@1234.service/cgroup.controllers"
}

new_preflight_scenario preflight_healthy
run_preflight
assert_status "${status}" 0
assert_contains "${SCENARIO}/out" 'check=summary status=ok container_coverage=userspace_only' 'a healthy host passes'

new_preflight_scenario preflight_enforcing
printf '#!/bin/sh\necho Enforcing\n' >"${SCENARIO}/getenforce"
run_preflight
assert_status "${status}" 0
assert_contains "${SCENARIO}/out" 'container_coverage=confined' 'an enforcing host is reported as confined coverage'

new_preflight_scenario preflight_rootful
echo 'false v2 systemd crun 5.8.0' >"${SCENARIO}/info"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=rootless status=fail' 'rootful Podman is refused'

new_preflight_scenario preflight_cgroup_v1
echo 'true v1 systemd crun 5.8.0' >"${SCENARIO}/info"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=cgroup_version status=fail value=v1 required=v2' 'cgroup v1 is refused'

new_preflight_scenario preflight_cgroupfs
echo 'true v2 cgroupfs crun 5.8.0' >"${SCENARIO}/info"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=cgroup_manager status=fail' 'the cgroupfs manager is refused'

new_preflight_scenario preflight_no_podman
rm "${SCENARIO}/info"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=podman_info status=fail' 'an unusable Podman is reported'

new_preflight_scenario preflight_no_user_manager
printf '#!/bin/sh\nexit 1\n' >"${SCENARIO}/systemctl"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=user_manager status=fail' 'a missing user manager is reported'

new_preflight_scenario preflight_no_subuid
echo 'someone-else:100000:65536' >"${SCENARIO}/subuid"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=subuid status=fail' 'a missing subordinate UID range is reported'
assert_contains "${SCENARIO}/out" 'check=subgid status=ok' 'and only that range'

new_preflight_scenario preflight_no_delegation
echo 'cpu memory' >"${SCENARIO}/cgroup/user.slice/user-1234.slice/user@1234.service/cgroup.controllers"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=delegation status=fail controllers=cpu,memory required=pids' \
    'missing pids delegation is reported precisely'

new_preflight_scenario preflight_reports_every_failure
echo 'false v1 cgroupfs crun 5.8.0' >"${SCENARIO}/info"
run_preflight
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=summary status=fail failures=3' 'all failures are reported, not only the first'

echo
echo "systemd fixture tests: ${passed} passed, ${failed} failed"
[[ ${failed} -eq 0 ]]
