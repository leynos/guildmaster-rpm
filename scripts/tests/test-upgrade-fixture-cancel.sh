#!/usr/bin/env bash
# Offline tests for the cancellation and recovery behaviour of
# scripts/build-upgrade-fixture.sh: restoring the previous fixture when the
# script is interrupted between moving it aside and promoting the new one,
# restoring a leftover ".old" at the start of a later run, and confirming the
# atomic exchange path never leaves out_dir absent at all.
#
# This suite lives apart from scripts/tests/test-upgrade-fixture.sh so the
# two can be developed concurrently; it borrows that suite's harness, FIFO
# handshake helpers, podman and flock-announce stubs verbatim, and borrows
# scripts/tests/test-build-rpm.sh's bounded fifo_read pattern and its
# "sigdfl" launcher for starting the script under test in its own process
# group.
#
# No network and no real podman or flock: PODMAN and FLOCK are stubs. A
# PUBLISH_MV stub stands in for the fallback promotion move so a test can
# hold the script between the move-aside and the promotion and then signal
# it, deterministically, with no timing sleeps used as assertions.
#
# SCRIPT_UNDER_TEST points the whole suite at a script under test; it
# defaults to the real script.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
: "${SCRIPT_UNDER_TEST:=${repo_root}/scripts/build-upgrade-fixture.sh}"

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

# --- FIFO handshake (bounded, never a sleep) ----------------------------------

: "${FIFO_TIMEOUT:=60}"

# fifo_read_kill <target>: terminate a stuck handshake's background job with
# TERM, then KILL if it is still alive after a short grace period. A target
# of "-<pid>" signals a whole process group, meaningful only for a job the
# suite started with setsid.
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

stub_dir=${scratch}/stubs
mkdir -p "${stub_dir}"

# podman stub: parses the "-v <staging>:/out:z" bind mount out of its own
# argv, records the full command line, and writes a fake RPM into that
# directory in place of a real build. Copied from test-upgrade-fixture.sh.
cat >"${stub_dir}/podman" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${SCENARIO}/podman.log"
echo call >>"${SCENARIO}/podman.count"
out_dir=
prev=
for arg in "$@"; do
    if [[ ${prev} == -v && ${arg} == *:/out:z ]]; then
        out_dir=${arg%:/out:z}
    fi
    prev=${arg}
done
if [[ -f ${SCENARIO}/podman_fails ]]; then
    echo 'podman: rpmbuild failed' >&2
    exit 1
fi
[[ -n ${out_dir} ]] || {
    echo 'podman stub: no /out bind mount found in argv' >&2
    exit 1
}
echo "fake rpm bytes ${RANDOM}" >"${out_dir}/guildmaster-0.1-1.upgradetest.x86_64.rpm"
STUB

# publish-mv stub: stands in for the fallback promotion move
# ("${PUBLISH_MV} -T <staging> <out_dir>") so that its start can be
# announced and it can be held open until a test releases it, letting a test
# hold the script between the move-aside and the promotion. Falls straight
# through to the real mv for the rollback move (source ending ".old") and
# whenever no announce FIFO is set, so it behaves exactly like mv otherwise.
#
#   PUBLISH_MV_ANNOUNCE_FIFO  announce that the promotion move has started,
#                             then block on PUBLISH_MV_WAIT_FIFO before
#                             moving anything
#   PUBLISH_MV_WAIT_FIFO      block the promotion move until the test writes
#                             to it
cat >"${stub_dir}/publish-mv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SCENARIO}/publish-mv.log"
args=("$@")
src=${args[-2]}
if [[ ${src} != *.old && -n ${PUBLISH_MV_ANNOUNCE_FIFO:-} ]]; then
    echo started >"${PUBLISH_MV_ANNOUNCE_FIFO}"
    [[ -z ${PUBLISH_MV_WAIT_FIFO:-} ]] || read -r _ <"${PUBLISH_MV_WAIT_FIFO}"
fi
exec mv "$@"
STUB

# flock-announce: wraps the real flock. When invoked with "-x" it announces
# the request on ${FLOCK_ANNOUNCE_FIFO} before executing the real flock.
# Copied from test-upgrade-fixture.sh; unused by the cases in this suite but
# kept so a case can be added later without re-deriving it.
cat >"${stub_dir}/flock-announce" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == -x && -n ${FLOCK_ANNOUNCE_FIFO:-} ]]; then
    exec {announce_fd}<>"${FLOCK_ANNOUNCE_FIFO}"
    printf 'requesting\n' >&"${announce_fd}"
    exec {announce_fd}>&-
fi
exec flock "$@"
STUB

# A non-interactive shell starts an asynchronous job with SIGINT and SIGQUIT
# ignored, and an ignored disposition is inherited across exec and cannot be
# trapped. A build launched with "&" would therefore be unable to install its
# own INT/TERM handlers, and the cancellation case would be testing the
# harness rather than the script. This launcher restores the default
# disposition before exec, matching a build started from a terminal. Copied
# from test-build-rpm.sh.
cat >"${stub_dir}/sigdfl" <<'STUB'
#!/usr/bin/env python3
"""Reset SIGINT and SIGQUIT to their default disposition, then exec argv[1:]."""

import os
import signal
import sys

for sig in (signal.SIGINT, signal.SIGQUIT):
    signal.signal(sig, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
STUB

chmod +x "${stub_dir}"/*

# new_scenario <name>: a scenario directory with the cache, locks and dist
# directories in place; tests then add SRPMs and break one thing.
new_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    export SCENARIO
    mkdir -p "${SCENARIO}/cache/locks" "${SCENARIO}/dist"
    : >"${SCENARIO}/podman.log"
    : >"${SCENARIO}/podman.count"
    : >"${SCENARIO}/publish-mv.log"
}

# add_srpm <target> <content>: writes the target's only source RPM.
add_srpm() {
    local target=$1 content=$2
    rm -rf "${SCENARIO}/dist/${target}/srpm"
    mkdir -p "${SCENARIO}/dist/${target}/srpm"
    printf '%s\n' "${content}" >"${SCENARIO}/dist/${target}/srpm/guildmaster-${content}.src.rpm"
}

# run_upgrade [env-assignments...]: run build-upgrade-fixture.sh against the
# current scenario, using ${image:-fake-image} and ${target:-rocky-10};
# output in ${SCENARIO}/stdout and .../stderr, status in $status.
run_upgrade() {
    status=0
    env PODMAN="${stub_dir}/podman" FLOCK=flock \
        CACHE_DIR="${SCENARIO}/cache" LOCK_DIR="${SCENARIO}/cache/locks" \
        DIST_DIR="${SCENARIO}/dist" "$@" \
        "${SCRIPT_UNDER_TEST}" "${image:-fake-image}" "${target:-rocky-10}" \
        >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
}

# The pid of the build started by start_upgrade_bg.
bg_pid=

# start_upgrade_bg <output> [env-assignments...]: start
# build-upgrade-fixture.sh in the background, in its own process group, so a
# test can signal the whole invocation. Sets bg_pid, which is also the
# process group id, because job control is off in a script and setsid execs
# in place rather than forking.
#
# This cannot echo the pid instead — a command substitution would make the
# job a child of the substitution's subshell, and `wait` in the test would
# not find it.
start_upgrade_bg() {
    local output=$1
    shift
    setsid "${stub_dir}/sigdfl" env PODMAN="${stub_dir}/podman" FLOCK=flock \
        CACHE_DIR="${SCENARIO}/cache" LOCK_DIR="${SCENARIO}/cache/locks" \
        DIST_DIR="${SCENARIO}/dist" "$@" \
        "${SCRIPT_UNDER_TEST}" "${image:-fake-image}" "${target:-rocky-10}" \
        >"${output}" 2>&1 &
    bg_pid=$!
}

# out_dir_for <target>: the fixture output directory for <target> in the
# current scenario.
out_dir_for() {
    echo "${SCENARIO}/cache/upgrade-fixture/${1}"
}

# stray_staging <target>: any leftover staging entries for <target>'s
# fixture build (excluding ".old", which is recovery data, not stray
# staging).
stray_staging() {
    find "${SCENARIO}/cache/upgrade-fixture" -maxdepth 1 -name "${1}.*" \
        ! -name "${1}.old" 2>/dev/null
}

# --- cancellation: SIGTERM between move-aside and promotion -------------------
#
# Forces the non-atomic fallback path with PUBLISH_EXCHANGE=never, primes a
# published fixture, then starts a second build whose promotion move is held
# open by the publish-mv stub. Once the stub confirms it has started the
# promotion move — meaning out_dir has already been moved aside to ".old" —
# SIGTERM is sent to the whole process group. The script must restore the
# previous fixture to out_dir and leave no staging directory behind.

new_scenario upgrade_cancel_mid_promotion
target=rocky-10
add_srpm rocky-10 first
run_upgrade PUBLISH_EXCHANGE=never
assert_status "${status}" 0
out_dir=$(out_dir_for rocky-10)
before_listing=$(find "${out_dir}" -type f -printf '%f\n' | LC_ALL=C sort)
before_sha=$(cat "${out_dir}/source.sha256")

add_srpm rocky-10 second
announce=${SCENARIO}/promote-announce.fifo
wait_fifo=${SCENARIO}/promote-wait.fifo
mkfifo "${announce}" "${wait_fifo}"

start_upgrade_bg "${SCENARIO}/cancelled.out" \
    PUBLISH_EXCHANGE=never \
    PUBLISH_MV="${stub_dir}/publish-mv" \
    PUBLISH_MV_ANNOUNCE_FIFO="${announce}" \
    PUBLISH_MV_WAIT_FIFO="${wait_fifo}"
build_pid=${bg_pid}

if fifo_read "${announce}" \
    'the build to announce it reached the fallback promotion move' \
    "-${build_pid}"; then
    # out_dir is briefly absent here; setsid gave the build its own process
    # group, so this signal reaches the blocked publish-mv stub too.
    if [[ ! -e ${out_dir} ]]; then
        ok 'out_dir is absent while the promotion move is held open'
    else not_ok 'out_dir was not moved aside before the promotion move started'; fi
    kill -TERM "-${build_pid}"
    rc=0
    wait "${build_pid}" || rc=$?
    assert_status "${rc}" 143

    after_listing=$(find "${out_dir}" -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    after_sha=$(cat "${out_dir}/source.sha256" 2>/dev/null || true)
    if [[ ${before_listing} == "${after_listing}" && ${before_sha} == "${after_sha}" ]]; then
        ok 'the previous fixture is restored to out_dir, unchanged'
    else not_ok 'the previous fixture at out_dir changed or is missing after cancellation'; fi
    if [[ -z $(stray_staging rocky-10) ]]; then
        ok 'no staging directory is left behind'
    else not_ok "stray staging directory left: $(stray_staging rocky-10)"; fi
    if [[ ! -e ${out_dir}.old ]]; then
        ok 'no ".old" recovery directory remains'
    else not_ok '".old" recovery directory was left behind'; fi
    assert_contains "${SCENARIO}/cancelled.out" \
        'restored the previous upgrade fixture' \
        'the script reports the restoration'
else
    wait "${build_pid}" 2>/dev/null || true
fi

# --- recovery: a leftover ".old" is restored at the next run's start ----------
#
# Simulates the on-disk state left by an interrupted run: out_dir absent,
# ".old" present with the previous fixture. The next run must restore it
# before doing anything else, rather than starting from "no fixture" and
# later deleting ".old" as clutter.

new_scenario upgrade_restore_leftover_old
target=rocky-10
add_srpm rocky-10 first
run_upgrade
assert_status "${status}" 0
out_dir=$(out_dir_for rocky-10)
before_listing=$(find "${out_dir}" -type f -printf '%f\n' | LC_ALL=C sort)
before_sha=$(cat "${out_dir}/source.sha256")

mv -T "${out_dir}" "${out_dir}.old"
[[ ! -e ${out_dir} ]] || not_ok 'setup: out_dir still present after moving it aside'

run_upgrade
assert_status "${status}" 0
after_listing=$(find "${out_dir}" -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
after_sha=$(cat "${out_dir}/source.sha256" 2>/dev/null || true)
if [[ ${before_listing} == "${after_listing}" && ${before_sha} == "${after_sha}" ]]; then
    ok 'the leftover fixture is restored and recognized as current'
else not_ok 'the leftover fixture was not restored correctly'; fi
if [[ ! -e ${out_dir}.old ]]; then
    ok 'the ".old" leftover is consumed by the restore'
else not_ok '".old" still present after the restoring run'; fi
assert_contains "${SCENARIO}/stdout" 'is current' \
    'the restored fixture is recognized without rebuilding'
if [[ $(wc -l <"${SCENARIO}/podman.count") -eq 1 ]]; then
    ok 'podman was not invoked again for the restored fixture'
else not_ok 'podman was invoked again despite the fixture being restored and current'; fi

# --- atomic exchange: out_dir is never absent, no move-aside occurs -----------
#
# On a host that supports "mv -T --exchange", the promotion swaps the two
# directories directly. The publish-mv stub — used only on the fallback
# path — must never be invoked, which is the suite's evidence that no
# move-aside to ".old" ever happened.

new_scenario upgrade_exchange_no_move_aside
target=rocky-10
add_srpm rocky-10 first
run_upgrade PUBLISH_MV="${stub_dir}/publish-mv"
assert_status "${status}" 0
out_dir=$(out_dir_for rocky-10)

add_srpm rocky-10 second
run_upgrade PUBLISH_MV="${stub_dir}/publish-mv"
assert_status "${status}" 0
if [[ ! -s ${SCENARIO}/publish-mv.log ]]; then
    ok 'the fallback promotion move is never invoked on the exchange path'
else not_ok "the fallback promotion move was invoked: $(cat "${SCENARIO}/publish-mv.log")"; fi
if [[ ! -e ${out_dir}.old ]]; then
    ok 'no ".old" directory is created by the exchange path'
else not_ok '".old" directory was created despite the exchange path succeeding'; fi
if [[ -z $(stray_staging rocky-10) ]]; then
    ok 'no staging directory is left behind by the exchange path'
else not_ok "stray staging directory left: $(stray_staging rocky-10)"; fi
new_sha=$(cat "${out_dir}/source.sha256")
srpm=$(find "${SCENARIO}/dist/rocky-10/srpm" -name '*.src.rpm')
expected_sha=$(sha256sum <"${srpm}" | cut -d' ' -f1)
if [[ ${new_sha} == "${expected_sha}" ]]; then
    ok 'the published fixture is the newly built one'
else not_ok 'the published fixture does not match the newly built SRPM'; fi

echo
echo "build-upgrade-fixture-cancel tests: ${passed} passed, ${failed} failed"
suite_status=0
[[ ${failed} -eq 0 ]] || suite_status=1
exit "${suite_status}"
