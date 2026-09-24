#!/usr/bin/env bash
# Offline tests for scripts/build-upgrade-fixture.sh.
#
# No network and no real podman: PODMAN is a stub that records its
# invocation and writes a fake guildmaster-*.rpm into the bind-mounted /out
# staging directory it is given, without ever building anything. FLOCK is
# the real system flock, used both by the script under test and, for the
# lock-contention case, by this suite itself to hold the per-target lock
# from outside and prove the script waits for it — a FIFO handshake shows
# this deterministically, never a sleep.
#
# SCRIPT_UNDER_TEST points the whole suite at a script under test; it
# defaults to the real script, and is also used at the end of this file to
# run the whole suite again against deliberately broken mutant copies, to
# check that the suite actually catches their bugs.
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

stub_dir=${scratch}/stubs
mkdir -p "${stub_dir}"

# podman stub: parses the "-v <staging>:/out:z" bind mount out of its own
# argv, records the full command line, and writes a fake RPM into that
# directory in place of a real build.
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
# flock-announce: wraps the real flock. When invoked with "-x" — the only
# exclusive flock call build-upgrade-fixture.sh makes is on the per-target
# fixture lock — it announces the request on ${FLOCK_ANNOUNCE_FIFO} before
# executing the real flock, so the lock-contention test can prove the
# runner actually reached and requested that lock, rather than merely
# being slow to start.
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
}

# add_srpm <target> <content>: writes the target's only source RPM.
add_srpm() {
    local target=$1 content=$2
    rm -rf "${SCENARIO}/dist/${target}/srpm"
    mkdir -p "${SCENARIO}/dist/${target}/srpm"
    printf '%s\n' "${content}" >"${SCENARIO}/dist/${target}/srpm/guildmaster-${content}.src.rpm"
}

# run_upgrade: run build-upgrade-fixture.sh against the current scenario,
# using ${image:-fake-image} and ${target:-rocky-10}; output in
# ${SCENARIO}/stdout and .../stderr, status in $status.
run_upgrade() {
    status=0
    env PODMAN="${stub_dir}/podman" FLOCK=flock \
        CACHE_DIR="${SCENARIO}/cache" LOCK_DIR="${SCENARIO}/cache/locks" \
        DIST_DIR="${SCENARIO}/dist" \
        "${SCRIPT_UNDER_TEST}" "${image:-fake-image}" "${target:-rocky-10}" \
        >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
}

# out_dir_for <target>: the fixture output directory for <target> in the
# current scenario.
out_dir_for() {
    echo "${SCENARIO}/cache/upgrade-fixture/${1}"
}

# stray_staging <target>: any leftover staging entries for <target>'s
# fixture build.
stray_staging() {
    find "${SCENARIO}/cache/upgrade-fixture" -maxdepth 1 -name "${1}.*" 2>/dev/null
}

# --- reject: usage error (wrong argument count) -------------------------------

new_scenario upgrade_usage_error
status=0
env PODMAN="${stub_dir}/podman" FLOCK=flock CACHE_DIR="${SCENARIO}/cache" \
    LOCK_DIR="${SCENARIO}/cache/locks" DIST_DIR="${SCENARIO}/dist" \
    "${SCRIPT_UNDER_TEST}" only-one-argument \
    >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
assert_status "${status}" 2
assert_contains "${SCENARIO}/stderr" 'usage:' 'the wrong argument count is reported as a usage error'

# --- reject: unknown target ---------------------------------------------------

new_scenario upgrade_unknown_target
target=debian-13 run_upgrade
assert_status "${status}" 2
assert_contains "${SCENARIO}/stderr" 'unknown target debian-13' 'an unknown target is refused'

# --- reject: missing srpm directory --------------------------------------------

new_scenario upgrade_missing_srpm_dir
run_upgrade
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'expected exactly one source RPM' \
    'a missing srpm directory reaches the diagnostic rather than aborting on set -e'

# --- reject: two SRPMs present -------------------------------------------------

new_scenario upgrade_two_srpms
mkdir -p "${SCENARIO}/dist/rocky-10/srpm"
echo one >"${SCENARIO}/dist/rocky-10/srpm/guildmaster-one.src.rpm"
echo two >"${SCENARIO}/dist/rocky-10/srpm/guildmaster-two.src.rpm"
run_upgrade
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'expected exactly one source RPM' \
    'two source RPMs are refused with the same diagnostic'

# --- accept: a successful build, per target ------------------------------------

for target_dist in 'rocky-10 .el10.upgradetest' 'fedora-43 .fc43.upgradetest'; do
    read -r target dist_flag <<<"${target_dist}"
    new_scenario "upgrade_build_${target}"
    add_srpm "${target}" first
    run_upgrade
    assert_status "${status}" 0
    out_dir=$(out_dir_for "${target}")
    if [[ -f ${out_dir}/source.sha256 ]]; then
        ok "${target}: source.sha256 is published"
    else not_ok "${target}: source.sha256 missing"; fi
    if [[ $(find "${out_dir}" -maxdepth 1 -name 'guildmaster-*.rpm' | wc -l) -ge 1 ]]; then
        ok "${target}: an RPM is published"
    else not_ok "${target}: no RPM published"; fi
    srpm=$(find "${SCENARIO}/dist/${target}/srpm" -name '*.src.rpm')
    expected_sha=$(sha256sum <"${srpm}" | cut -d' ' -f1)
    if [[ $(cat "${out_dir}/source.sha256") == "${expected_sha}" ]]; then
        ok "${target}: source.sha256 matches the built SRPM"
    else not_ok "${target}: source.sha256 does not match the SRPM"; fi
    assert_contains "${SCENARIO}/podman.log" "UPGRADE_DIST=${dist_flag}" \
        "${target}: the upgrade dist tag ${dist_flag} is passed to the container"
done
unset target dist_flag

# --- accept: a second run with the same SRPM reuses without invoking podman ---

new_scenario upgrade_reuse
add_srpm rocky-10 first
run_upgrade
assert_status "${status}" 0
calls_before=$(wc -l <"${SCENARIO}/podman.count")
run_upgrade
assert_status "${status}" 0
assert_contains "${SCENARIO}/stdout" 'is current' 'a second run against the same SRPM reports reuse'
calls_after=$(wc -l <"${SCENARIO}/podman.count")
if [[ ${calls_after} -eq ${calls_before} ]]; then
    ok 'podman is not invoked again'
else not_ok "podman was invoked again: ${calls_before} -> ${calls_after} calls"; fi

# --- accept: a changed SRPM rebuilds --------------------------------------------

new_scenario upgrade_changed_srpm_rebuilds
add_srpm rocky-10 first
run_upgrade
assert_status "${status}" 0
first_sha=$(cat "$(out_dir_for rocky-10)/source.sha256")
add_srpm rocky-10 second
run_upgrade
assert_status "${status}" 0
assert_contains "${SCENARIO}/stdout" 'guildmaster' 'the rebuild reports its output'
second_sha=$(cat "$(out_dir_for rocky-10)/source.sha256")
if [[ ${first_sha} != "${second_sha}" ]]; then
    ok 'source.sha256 is updated for the changed SRPM'
else not_ok 'source.sha256 unchanged despite a changed SRPM'; fi
if [[ $(wc -l <"${SCENARIO}/podman.count") -eq 2 ]]; then
    ok 'podman was invoked again for the changed SRPM'
else not_ok 'podman was not invoked again'; fi

# --- reject: a podman failure leaves the previous output intact -----------------

new_scenario upgrade_podman_failure_preserves_previous
add_srpm rocky-10 first
run_upgrade
assert_status "${status}" 0
out_dir=$(out_dir_for rocky-10)
before_listing=$(find "${out_dir}" -type f -printf '%f\n' | LC_ALL=C sort)
before_sha=$(cat "${out_dir}/source.sha256")
add_srpm rocky-10 second
touch "${SCENARIO}/podman_fails"
run_upgrade
assert_status "${status}" 1
after_listing=$(find "${out_dir}" -type f -printf '%f\n' | LC_ALL=C sort)
after_sha=$(cat "${out_dir}/source.sha256")
if [[ ${before_listing} == "${after_listing}" && ${before_sha} == "${after_sha}" ]]; then
    ok 'the previous output is left untouched by a failed build'
else not_ok 'the previous output changed despite the build failing'; fi
if [[ -z $(stray_staging rocky-10) ]]; then
    ok 'no staging directory is left behind'
else not_ok "stray staging directory left: $(stray_staging rocky-10)"; fi

# --- locking: the per-target lock is held across a build ------------------------

new_scenario upgrade_lock_contention
add_srpm rocky-10 first
lockfile=${SCENARIO}/cache/locks/upgrade-fixture-rocky-10.lock
: >"${lockfile}"
holder_ready=${SCENARIO}/holder-ready.fifo
holder_release=${SCENARIO}/holder-release.fifo
announce_fifo=${SCENARIO}/flock-announce.fifo
mkfifo "${holder_ready}" "${holder_release}" "${announce_fifo}"
flock -x "${lockfile}" -c "echo held >'${holder_ready}'; read -r _ <'${holder_release}'" &
holder_pid=$!
fifo_read "${holder_ready}" 'the external lock holder to take the per-target lock' "${holder_pid}"

env PODMAN="${stub_dir}/podman" FLOCK="${stub_dir}/flock-announce" \
    FLOCK_ANNOUNCE_FIFO="${announce_fifo}" CACHE_DIR="${SCENARIO}/cache" \
    LOCK_DIR="${SCENARIO}/cache/locks" DIST_DIR="${SCENARIO}/dist" \
    "${SCRIPT_UNDER_TEST}" fake-image rocky-10 \
    >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" &
runner_pid=$!

# Wait for the runner to actually request the per-target lock before
# asserting it is blocked: a copy of the script missing the "flock -x" call
# would otherwise pass these assertions vacuously, simply by being slow to
# start.
if fifo_read "${announce_fifo}" 'the runner to request the per-target lock' "${runner_pid}" "${holder_pid}"; then
    if kill -0 "${runner_pid}" 2>/dev/null; then
        ok 'the invocation is still running while the external holder keeps the lock'
    else not_ok 'the invocation exited before the lock was released'; fi
    if [[ ! -s ${SCENARIO}/podman.log ]]; then
        ok 'podman has not been invoked while blocked on the per-target lock'
    else not_ok 'podman was invoked before the lock was available'; fi

    echo go >"${holder_release}"
    wait "${holder_pid}"
    status=0
    wait "${runner_pid}" || status=$?
    assert_status "${status}" 0
    if [[ -s ${SCENARIO}/podman.log ]]; then
        ok 'podman is invoked once the lock becomes available'
    else not_ok 'podman was never invoked after the lock was released'; fi
else
    wait "${runner_pid}" 2>/dev/null || true
    wait "${holder_pid}" 2>/dev/null || true
fi

echo
echo "build-upgrade-fixture tests: ${passed} passed, ${failed} failed"
suite_status=0
[[ ${failed} -eq 0 ]] || suite_status=1

# --- non-vacuity: mutants must make this suite fail --------------------------
#
# Only run once, from the top-level invocation, and only once the suite has
# actually passed against the real script: a mutant is expected to break at
# least one of the assertions above, and there is no reason to trust that
# signal if the suite was not clean to start with.
if [[ ${MUTATION_CHECK:-0} -eq 0 && ${suite_status} -eq 0 ]]; then
    echo
    echo "non-vacuity: checking that mutants make this suite fail"
    mutant_dir=${scratch}/mutants
    mkdir -p "${mutant_dir}"

    # make_mutant <source> <fixed-string> <output>: copy <source>, replacing
    # the one line containing <fixed-string> with "if false; then" (keeping
    # the mutant syntactically valid while always skipping that branch). The
    # pattern is single-quoted on purpose: it is literal source text. Fails
    # loudly when the pattern matches no line, more than one, or a line that
    # is not an "if ... then" condition, so a later edit to the script
    # cannot silently turn a mutant into a copy of the original.
    make_mutant() {
        local source=$1 pattern=$2 output=$3 matches line
        matches=$(grep -nF -- "${pattern}" "${source}" | cut -d: -f1)
        if [[ $(grep -c . <<<"${matches}") -ne 1 ]]; then
            echo "FAIL: mutant pattern '${pattern}' matches $(grep -c . <<<"${matches}") lines of ${source}" >&2
            exit 1
        fi
        line=${matches}
        sed -n "${line}p" "${source}" | grep -q '; then$' || {
            echo "FAIL: mutant pattern '${pattern}' in ${source} is not an 'if ...; then' line" >&2
            exit 1
        }
        sed "${line}s/.*/if false; then/" "${source}" >"${output}"
        chmod +x "${output}"
    }

    # Mutant: build-upgrade-fixture.sh no longer reuses a fixture built from
    # the same source RPM, so it always rebuilds.
    # shellcheck disable=SC2016
    make_mutant "${repo_root}/scripts/build-upgrade-fixture.sh" \
        'if [[ -f ${out_dir}/source.sha256 && $(cat "${out_dir}/source.sha256") == "${srpm_sum}" ]]; then' \
        "${mutant_dir}/no-reuse-check.sh"

    # make_line_removal_mutant <source> <pattern> <output>: copy <source>
    # without the one line matching <pattern> (a fixed string). Fails
    # loudly when the pattern matches zero or more than one line, so a
    # later edit to the script cannot silently turn the mutant into a copy
    # of the original.
    make_line_removal_mutant() {
        local source=$1 pattern=$2 output=$3 matches line
        matches=$(grep -nF -- "${pattern}" "${source}" | cut -d: -f1)
        if [[ $(grep -c . <<<"${matches}") -ne 1 ]]; then
            echo "FAIL: mutant pattern '${pattern}' matches $(grep -c . <<<"${matches}") lines of ${source}" >&2
            exit 1
        fi
        line=${matches}
        sed "${line}d" "${source}" >"${output}"
        chmod +x "${output}"
    }

    # Mutant: build-upgrade-fixture.sh no longer takes the per-target
    # exclusive lock before reusing or rebuilding, so concurrent
    # invocations for the same target race each other.
    # shellcheck disable=SC2016
    make_line_removal_mutant "${repo_root}/scripts/build-upgrade-fixture.sh" \
        '"${FLOCK}" -x "${fixture_fd}"' "${mutant_dir}/no-fixture-lock.sh"

    mutant_status=0

    # check_mutant <label> [extra env assignments...]: rerun this suite
    # against a mutant script and record whether it failed as expected.
    #
    # Invoked via "bash", not "$0" alone: a mutant copy is chmod +x by
    # make_mutant, but running it bare would still let a harness crash or a
    # non-executable $0 (exit 126) masquerade as "mutant caught" purely from
    # a nonzero exit. The rerun's own summary line is parsed instead, and is
    # only accepted as a genuine catch when it reports at least one passed
    # and at least one failed assertion; a missing summary line (the rerun
    # never got that far) is itself a mutant-check failure, not a pass.
    check_mutant() {
        local label=$1
        shift
        local out=${mutant_dir}/${label}.out
        local rc=0
        env MUTATION_CHECK=1 "$@" bash "$0" >"${out}" 2>&1 || rc=$?
        local summary mpassed mfailed
        summary=$(grep '^build-upgrade-fixture tests:' "${out}" | tail -n 1) || true
        if [[ ${summary} =~ ^build-upgrade-fixture\ tests:\ ([0-9]+)\ passed,\ ([0-9]+)\ failed$ ]]; then
            mpassed=${BASH_REMATCH[1]}
            mfailed=${BASH_REMATCH[2]}
        else
            echo "FAIL: mutant ${label}: no summary line was produced (exit ${rc})" >&2
            mutant_status=1
            return
        fi
        if [[ ${mfailed} -ge 1 && ${mpassed} -ge 1 ]]; then
            echo "ok: mutant ${label}: suite caught it (${summary}), exit ${rc}"
        else
            echo "FAIL: mutant ${label}: suite reported no failed assertions (${summary}), exit ${rc}" >&2
            mutant_status=1
        fi
    }

    check_mutant no-reuse-check SCRIPT_UNDER_TEST="${mutant_dir}/no-reuse-check.sh"
    # A short FIFO_TIMEOUT keeps this bounded: without the per-target lock
    # call, "flock-announce" never fires, so the lock-contention case's
    # fifo_read is expected to time out and fail rather than hang for the
    # suite's default 60s.
    check_mutant no-fixture-lock SCRIPT_UNDER_TEST="${mutant_dir}/no-fixture-lock.sh" FIFO_TIMEOUT=5

    [[ ${mutant_status} -eq 0 ]] || suite_status=1
fi

exit "${suite_status}"
