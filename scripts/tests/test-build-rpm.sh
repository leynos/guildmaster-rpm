#!/usr/bin/env bash
# Unit tests for scripts/build-rpm.sh and scripts/clean.sh.
#
# These run on the host with no network and no container runtime: the build
# script's curl and podman seams are pointed at stubs, and its tarball URL,
# checksum, cache, lock and staging directories at scratch paths. What is
# under test is the scripts' own orchestration, validation, publication and
# locking — argument and target checking, agreement between the pinned commit
# and the spec, when a cached tarball is reused versus re-fetched, that a bad
# download is never published, that the three container phases are invoked
# with the right isolation, that anything other than the exact expected
# package set is refused, that publication is all-or-nothing, that clean waits
# for in-flight builds and keeps the lock directory, and that
# failed or cancelled work leaves no staging directories, temporary files,
# containers, images or held locks behind.
#
# The podman stub models the three phases as podman does: phase A runs a named
# container that survives its own failure, phase B and phase C run throwaway
# containers from the committed image, and the container and image names live
# in a small state directory so that a test can plant a foreign name and check
# it is never touched.
#
# Concurrency is driven with FIFO handshakes, never with sleeps: the podman
# stub announces that it has reached the build phase and then blocks until the
# test releases it, so every interleaving below is deterministic.
#
# Usage: scripts/tests/test-build-rpm.sh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../.." && pwd)
under_test="${repo_root}/scripts/build-rpm.sh"
clean_under_test="${repo_root}/scripts/clean.sh"

# Must agree with the script's own pins; the spec is checked against these by
# the script itself, which is what the spec/commit case below exercises.
commit=463382ba5b47625a9355832cd792a164c54237f9
short_commit=${commit:0:7}
tarball="guildmaster-${commit}.tar.gz"
pkg_version="0.1^20251202git${short_commit}"
pkg_release=1.fc43
pkg_arch=x86_64

tests_run=0
tests_failed=0
current_test=

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

# --- harness ----------------------------------------------------------------

fail() {
    echo "  FAIL: $*" >&2
    tests_failed=$((tests_failed + 1))
}

start() {
    current_test=$1
    tests_run=$((tests_run + 1))
    echo "- ${current_test}"
}

assert_eq() {
    local expected=$1 actual=$2 what=$3
    [[ ${expected} == "${actual}" ]] ||
        fail "${what}: expected '${expected}', got '${actual}'"
}

assert_file() {
    [[ -f $1 ]] || fail "$2: expected file '$1' to exist"
}

assert_no_file() {
    [[ ! -e $1 ]] || fail "$2: expected '$1' not to exist"
}

assert_contains() {
    grep -qF -- "$2" "$1" || fail "$3: '$1' does not contain '$2'"
}

assert_not_contains() {
    grep -qF -- "$2" "$1" && fail "$3: '$1' unexpectedly contains '$2'"
    return 0
}

# --- FIFO handshakes ---------------------------------------------------------

# Default bound, in seconds, on a single FIFO handshake read. A stub or
# background build that never turns up must fail its own case rather than
# hang the whole suite; override with FIFO_TIMEOUT in a slower environment.
: "${FIFO_TIMEOUT:=60}"

# Terminate a stuck handshake's background job: TERM, then KILL if it is
# still alive after a short grace period. Pass a bare pid to signal one
# process, or "-<pid>" to signal a whole process group — only meaningful for
# a job the suite started with setsid, which makes the pid its group id too.
fifo_read_kill() {
    local target=$1
    kill -TERM "${target}" 2>/dev/null || true
    sleep 0.2
    kill -0 "${target}" 2>/dev/null && kill -KILL "${target}" 2>/dev/null
    return 0
}

# Read one line from a FIFO handshake with a bounded wait, in place of a
# plain blocking read. The FIFO is opened read-write on its own descriptor
# before the read, so opening it can never itself block on a writer turning
# up; only the read is bounded. On timeout this records a test failure
# naming the handshake, terminates every given kill target (see
# fifo_read_kill) and returns non-zero so the caller can bail out of the
# case instead of hanging it. The timeout is a hang guard only — it is never
# part of the deterministic barrier semantics the handshakes provide.
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
    fail "timed out after ${FIFO_TIMEOUT}s waiting for ${what}"
    local target
    for target in "$@"; do
        fifo_read_kill "${target}"
    done
    return 1
}

# --- fixtures ---------------------------------------------------------------

# Stand-in for the upstream archive. Its content is irrelevant; only its
# checksum matters to the script.
fixture="${workdir}/upstream-tarball"
printf 'not really a tarball, but a stable one\n' >"${fixture}"
fixture_sha256=$(sha256sum "${fixture}" | cut -d' ' -f1)

stub_bin="${workdir}/bin"
mkdir -p "${stub_bin}"

# curl stub: append the requested URL to a call log, then serve the fixture
# (or, when CURL_STUB_CORRUPT is set, deliberately wrong content) to the path
# given after -o.
cat >"${stub_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out=
url=
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
echo "${url}" >>"${CURL_STUB_LOG}"
if [[ -n ${CURL_STUB_FAIL:-} ]]; then
    echo "curl stub: simulated transfer failure" >&2
    exit 22
fi
if [[ -n ${CURL_STUB_CORRUPT:-} ]]; then
    printf 'truncated junk' >"${out}"
else
    cat "${CURL_STUB_FIXTURE}" >"${out}"
fi
STUB
chmod +x "${stub_bin}/curl"

# podman stub. One flattened line per invocation goes to PODMAN_STUB_LOG, so a
# test can assert the flags of each phase; container and image names are
# tracked as files under PODMAN_STUB_STATE, so a test can assert that only
# this invocation's names are ever removed.
#
#   PODMAN_STUB_TAG            content written into each package, so a test can
#                              tell one generation's set from another
#   PODMAN_STUB_SET            which package set phase B writes; see write_set
#   PODMAN_STUB_FAIL_PHASE     deps | commit | build | rebuild
#   PODMAN_STUB_STARTED_FIFO   announce that the build has reached phase B
#   PODMAN_STUB_WAIT_FIFO      block in phase B until the test writes to it
#   PODMAN_STUB_PARTIAL_BEFORE_WAIT
#                              write only the binary package before blocking,
#                              and the rest after being released
cat >"${stub_bin}/podman" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

line=
for a in "$@"; do line+=" ${a//$'\n'/ }"; done
printf '%s\n' "${line# }" >>"${PODMAN_STUB_LOG}"

state=${PODMAN_STUB_STATE}
mkdir -p "${state}/containers" "${state}/images"

slug() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
die_stub() { echo "podman stub: $*" >&2; exit 125; }

sub=$1
shift

case ${sub} in
    commit)
        [[ -e ${state}/containers/$(slug "$1") ]] ||
            die_stub "commit: no such container $1"
        if [[ ${PODMAN_STUB_FAIL_PHASE:-} == commit ]]; then
            echo "podman stub: simulated commit failure" >&2
            exit 1
        fi
        : >"${state}/images/$(slug "$2")"
        exit 0
        ;;
    rm | rmi)
        dir=containers
        if [[ ${sub} == rmi ]]; then
            dir=images
        fi
        rc=0
        for arg in "$@"; do
            [[ ${arg} == -* ]] && continue
            f="${state}/${dir}/$(slug "${arg}")"
            if [[ -e ${f} ]]; then rm -f "${f}"; else rc=1; fi
        done
        exit "${rc}"
        ;;
    run) ;;
    *) die_stub "unknown subcommand ${sub}" ;;
esac

# --- podman run ---
args=("$@")
name=
network=
out=
out_mode=
i=0
while [[ ${i} -lt ${#args[@]} ]]; do
    case ${args[i]} in
        --name) name=${args[i + 1]}; i=$((i + 2)) ;;
        --network=*) network=${args[i]#--network=}; i=$((i + 1)) ;;
        --rm) i=$((i + 1)) ;;
        -v)
            case ${args[i + 1]} in
                *:/out:z) out=${args[i + 1]%%:/out:z}; out_mode=rw ;;
                *:/out:ro,z) out=${args[i + 1]%%:/out:ro,z}; out_mode=ro ;;
            esac
            i=$((i + 2))
            ;;
        *) break ;;
    esac
done
image=${args[i]:-}
[[ -n ${image} ]] || die_stub "run: no image in argv"

V=${STUB_VERSION:-0.1^20251202git463382b}
R=${STUB_RELEASE:-1.fc43}
A=${STUB_ARCH:-x86_64}
tag=${PODMAN_STUB_TAG:-generation}

if [[ -n ${name} ]]; then
    # Phase A. A named container survives even when its command fails, which
    # is exactly why the build script has to remove it by name afterwards.
    [[ ${out_mode} == '' ]] || die_stub "phase A must not mount /out"
    [[ -e ${state}/containers/$(slug "${name}") ]] &&
        die_stub "container name ${name} is already in use"
    : >"${state}/containers/$(slug "${name}")"
    if [[ ${PODMAN_STUB_FAIL_PHASE:-} == deps ]]; then
        echo "podman stub: simulated dependency failure" >&2
        exit 1
    fi
    exit 0
fi

[[ -e ${state}/images/$(slug "${image}") ]] ||
    die_stub "run: no such image ${image}"
[[ -n ${out} ]] || die_stub "run: no /out mount in argv"

if [[ ${out_mode} == ro ]]; then
    # Phase C, the SRPM rebuild. A real rpmbuild --rebuild would also object
    # to a malformed staging directory, but the stub stays quiet about that so
    # that the validation cases below reach validate_staging, which is what
    # they are about.
    if [[ ${PODMAN_STUB_FAIL_PHASE:-} == rebuild ]]; then
        echo "podman stub: simulated SRPM rebuild failure" >&2
        exit 1
    fi
    exit 0
fi

# Phase B.
case ${PODMAN_STUB_SET:-complete} in
    noarch) A=noarch ;;
    wrong-arch) A=aarch64 ;;
    wrong-dist) R=1.el9 ;;
    wrong-commit) V='0.1^20251202gitdeadbee' ;;
esac
base="guildmaster-${V}-${R}.${A}.rpm"
debuginfo="guildmaster-debuginfo-${V}-${R}.${A}.rpm"
debugsource="guildmaster-debugsource-${V}-${R}.${A}.rpm"
srpm="srpm/guildmaster-${V}-${R}.src.rpm"

put() {
    mkdir -p "$(dirname "${out}/$1")"
    printf '%s\n' "${tag}" >"${out}/$1"
}

# Describe whatever is in /out, the way phase B's rpm -qp loop would. The
# fields are recovered from the file name, which is the same information rpm
# would report for these packages.
write_manifest() {
    local epoch=${1:-'(none)'}
    local f rel stem arch name_ver name version release sum
    : >"${out}/manifest.tsv"
    for f in "${out}"/*.rpm "${out}"/srpm/*.src.rpm; do
        [[ -e ${f} ]] || continue
        rel=${f#"${out}/"}
        stem=$(basename "${rel}")
        stem=${stem%.rpm}
        arch=${stem##*.}
        if [[ ${arch} == src ]]; then arch=${A}; fi
        stem=${stem%.*}
        release=${stem##*-}
        name_ver=${stem%-*}
        version=${name_ver##*-}
        name=${name_ver%-*}
        sum=$(sha256sum "${f}" | cut -d' ' -f1)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${rel}" "${name}" "${epoch}" "${version}" "${release}" \
            "${arch}" "${sum}" >>"${out}/manifest.tsv"
    done
}

write_complete() {
    put "${base}"
    put "${debuginfo}"
    put "${debugsource}"
    put "${srpm}"
}

if [[ -n ${PODMAN_STUB_PARTIAL_BEFORE_WAIT:-} ]]; then
    mkdir -p "${out}/srpm"
    put "${base}"
fi
if [[ -n ${PODMAN_STUB_STARTED_FIFO:-} ]]; then
    echo started >"${PODMAN_STUB_STARTED_FIFO}"
fi
if [[ -n ${PODMAN_STUB_WAIT_FIFO:-} ]]; then
    read -r _ <"${PODMAN_STUB_WAIT_FIFO}"
fi
if [[ ${PODMAN_STUB_FAIL_PHASE:-} == build ]]; then
    echo "podman stub: simulated build failure" >&2
    exit 1
fi

case ${PODMAN_STUB_SET:-complete} in
    empty) ;;
    partial) put "${base}" ;;
    missing-base)
        put "${debuginfo}"; put "${debugsource}"; put "${srpm}"
        write_manifest
        ;;
    missing-debuginfo)
        put "${base}"; put "${debugsource}"; put "${srpm}"
        write_manifest
        ;;
    missing-debugsource)
        put "${base}"; put "${debuginfo}"; put "${srpm}"
        write_manifest
        ;;
    missing-srpm)
        put "${base}"; put "${debuginfo}"; put "${debugsource}"
        mkdir -p "${out}/srpm"
        write_manifest
        ;;
    missing-manifest)
        write_complete
        ;;
    extra-file)
        write_complete
        write_manifest
        printf 'stray\n' >"${out}/build.log"
        ;;
    extra-dir)
        write_complete
        write_manifest
        mkdir -p "${out}/logs"
        ;;
    devel)
        write_complete
        put "guildmaster-devel-${V}-${R}.${A}.rpm"
        write_manifest
        ;;
    duplicate)
        write_complete
        put "guildmaster-0.1^20251201gitc0ffee1-${R}.${A}.rpm"
        write_manifest
        ;;
    manifest-extra-line)
        write_complete
        write_manifest
        printf 'guildmaster-ghost.rpm\tguildmaster-ghost\t(none)\t1\t1.fc43\t%s\t%s\n' \
            "${A}" "$(printf '0%.0s' {1..64})" >>"${out}/manifest.tsv"
        ;;
    manifest-missing-line)
        write_complete
        write_manifest
        grep -v '^srpm/' "${out}/manifest.tsv" >"${out}/manifest.new"
        mv "${out}/manifest.new" "${out}/manifest.tsv"
        ;;
    manifest-epoch)
        write_complete
        write_manifest 1
        ;;
    manifest-sha)
        write_complete
        write_manifest
        awk -F'\t' -v OFS='\t' 'NR==1 { $7 = "0000000000000000000000000000000000000000000000000000000000000000" } { print }' \
            "${out}/manifest.tsv" >"${out}/manifest.new"
        mv "${out}/manifest.new" "${out}/manifest.tsv"
        ;;
    manifest-short-line)
        write_complete
        write_manifest
        printf 'guildmaster-ghost.rpm\tguildmaster\t(none)\n' >>"${out}/manifest.tsv"
        ;;
    manifest-long-line)
        write_complete
        write_manifest
        printf 'x\tx\t(none)\tx\tx\tx\tx\tsurplus\n' >>"${out}/manifest.tsv"
        ;;
    manifest-wrong-name)
        write_complete
        write_manifest
        awk -F'\t' -v OFS='\t' 'NR==1 { $2 = "guildmaster-other" } { print }' \
            "${out}/manifest.tsv" >"${out}/manifest.new"
        mv "${out}/manifest.new" "${out}/manifest.tsv"
        ;;
    *)
        write_complete
        write_manifest
        ;;
esac
STUB
chmod +x "${stub_bin}/podman"

# publish-mv stub: stands in for the two publication moves on the fallback
# path so that promotion and rollback failures can be injected. It fails only
# for the move it is told to fail, and otherwise behaves exactly like mv. The
# promotion move's source is the staging directory; the rollback move's
# source is that directory's .previous sibling.
cat >"${stub_bin}/publish-mv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
src=${args[-2]}
if [[ ${src} == *.previous ]]; then
    if [[ -n ${PUBLISH_MV_FAIL_ROLLBACK:-} ]]; then
        echo "publish-mv stub: refusing to roll back ${src}" >&2
        exit 1
    fi
elif [[ -n ${PUBLISH_MV_FAIL_PROMOTION:-} ]]; then
    echo "publish-mv stub: refusing to promote ${src}" >&2
    exit 1
fi
exec mv "$@"
STUB
chmod +x "${stub_bin}/publish-mv"

# A non-interactive shell starts an asynchronous job with SIGINT and SIGQUIT
# ignored, and an ignored disposition is inherited across exec and cannot be
# trapped. A build launched with "&" would therefore be unable to install its
# own INT handler, and the cancellation cases would be testing the harness
# rather than the script. This launcher restores the default disposition
# before exec, which is the state a build started from a terminal has.
cat >"${stub_bin}/sigdfl" <<'STUB'
#!/usr/bin/env python3
"""Reset SIGINT and SIGQUIT to their default disposition, then exec argv[1:]."""

import os
import signal
import sys

for sig in (signal.SIGINT, signal.SIGQUIT):
    signal.signal(sig, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
STUB
chmod +x "${stub_bin}/sigdfl"

# First value of <key> on the first build_event record for <event>.
log_field() {
    local file=$1 event=$2 key=$3
    grep -m1 -E "^build_event event=${event}( |\$)" "${file}" 2>/dev/null |
        tr ' ' '\n' | sed -n "s/^${key}=//p" | head -1
}

has_event() {
    grep -qE "^build_event event=$2( |\$)" "$1"
}

# --- case plumbing ----------------------------------------------------------

target=fedora-43

out_dir() {
    echo "$1/${target}"
}

# Environment shared by every invocation of the script under test for a case.
case_env() {
    local case_dir=$1
    echo \
        "CURL=${stub_bin}/curl" \
        "PODMAN=${stub_bin}/podman" \
        "CURL_STUB_LOG=${case_dir}/curl.log" \
        "PODMAN_STUB_LOG=${case_dir}/podman.log" \
        "PODMAN_STUB_STATE=${case_dir}/podman-state" \
        "CURL_STUB_FIXTURE=${fixture}" \
        "TARBALL_URL=https://example.invalid/${tarball}" \
        "TARBALL_SHA256=${fixture_sha256}" \
        "CACHE_DIR=${case_dir}/cache" \
        "LOCK_DIR=${case_dir}/cache/locks" \
        "STAGING_ROOT=${case_dir}/.staging"
}

prepare_case() {
    local case_dir=$1
    mkdir -p "${case_dir}" "${case_dir}/podman-state/containers" \
        "${case_dir}/podman-state/images"
    : >"${case_dir}/curl.log"
    : >"${case_dir}/podman.log"
}

# Run the script under test for a case. Extra VAR=value arguments are added to
# its environment. Echoes the exit status; output lands in ${case_dir}/output.
run_build() {
    local case_dir=$1
    shift
    prepare_case "${case_dir}"
    local rc=0
    # shellcheck disable=SC2046  # deliberate word splitting of the env list
    env $(case_env "${case_dir}") "$@" \
        "${under_test}" fake-image "$(out_dir "${case_dir}")" \
        >"${case_dir}/output" 2>&1 || rc=$?
    echo "${rc}"
}

# As run_build, but publishing to a differently named target directory.
run_build_to() {
    local case_dir=$1 outdir=$2
    shift 2
    prepare_case "${case_dir}"
    local rc=0
    # shellcheck disable=SC2046  # deliberate word splitting of the env list
    env $(case_env "${case_dir}") "$@" \
        "${under_test}" fake-image "${outdir}" \
        >"${case_dir}/output" 2>&1 || rc=$?
    echo "${rc}"
}

# Start the script under test in the background, in its own process group so
# a test can signal the whole build. Sets bg_pid, which is also the process
# group id: job control is off in a script, so the background job is not a
# group leader and setsid execs in place rather than forking.
#
# This cannot echo the pid instead — a command substitution would make the
# job a child of the substitution's subshell, and `wait` in the test would
# not find it.
bg_pid=
start_build_bg() {
    local case_dir=$1 output=$2
    shift 2
    # shellcheck disable=SC2046  # deliberate word splitting of the env list
    setsid "${stub_bin}/sigdfl" env $(case_env "${case_dir}") "$@" \
        "${under_test}" fake-image "$(out_dir "${case_dir}")" \
        >"${output}" 2>&1 &
    bg_pid=$!
}

curl_calls() {
    grep -c . "$1/curl.log" || true
}

# The Nth podman invocation, as a single line.
podman_call() {
    sed -n "$2p" "$1/podman.log"
}

podman_calls() {
    grep -c . "$1/podman.log" || true
}

stray_temps() {
    find "$1/cache" -maxdepth 1 -name "${tarball}.??????" \
        -printf '%f\n' 2>/dev/null || true
}

# Any staging directory at all, whether this invocation's or a leftover.
stray_staging() {
    find "$1/.staging" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true
}

# Container and image names the stub still knows about.
live_containers() {
    find "$1/podman-state/containers" -mindepth 1 -printf '%f\n' 2>/dev/null |
        LC_ALL=C sort || true
}

live_images() {
    find "$1/podman-state/images" -mindepth 1 -printf '%f\n' 2>/dev/null |
        LC_ALL=C sort || true
}

cached_tarball() {
    echo "$1/cache/${tarball}"
}

# The package set held in a directory, as "<file>:<tag>" lines, sorted.
# Empty when the directory is absent.
set_in_dir() {
    local dir=$1
    [[ -d ${dir} ]] || return 0
    (
        cd "${dir}" || return 0
        find . -type f -name '*.rpm' -printf '%P\n' | LC_ALL=C sort |
            while read -r f; do
                echo "${f}:$(cat "${f}")"
            done
    )
}

published_set() {
    set_in_dir "$(out_dir "$1")"
}

# Staging entries that are recovery data, and those that are not.
previous_dirs() {
    find "$1/.staging" -mindepth 1 -maxdepth 1 -name '*.previous' \
        -printf '%f\n' 2>/dev/null || true
}

staging_excluding_previous() {
    find "$1/.staging" -mindepth 1 -maxdepth 1 ! -name '*.previous' \
        -printf '%f\n' 2>/dev/null || true
}

complete_set_for() {
    local tag=$1
    printf '%s\n' \
        "guildmaster-${pkg_version}-${pkg_release}.${pkg_arch}.rpm:${tag}" \
        "guildmaster-debuginfo-${pkg_version}-${pkg_release}.${pkg_arch}.rpm:${tag}" \
        "guildmaster-debugsource-${pkg_version}-${pkg_release}.${pkg_arch}.rpm:${tag}" \
        "srpm/guildmaster-${pkg_version}-${pkg_release}.src.rpm:${tag}" |
        LC_ALL=C sort
}

assert_published_set() {
    local case_dir=$1 tag=$2 what=$3
    local actual expected
    actual=$(published_set "${case_dir}")
    expected=$(complete_set_for "${tag}")
    [[ ${actual} == "${expected}" ]] ||
        fail "${what}: published set is not the complete '${tag}' set:
    expected: $(echo "${expected}" | tr '\n' ' ')
    actual:   $(echo "${actual}" | tr '\n' ' ')"
}

# True when the published directory holds exactly one complete generation of
# one of the named tags.
published_is_one_complete_generation() {
    local case_dir=$1 actual tag
    shift
    [[ -d "$(out_dir "${case_dir}")" ]] || return 1
    actual=$(published_set "${case_dir}")
    for tag in "$@"; do
        [[ ${actual} == "$(complete_set_for "${tag}")" ]] && return 0
    done
    return 1
}

# Does this host support the atomic directory swap? That needs coreutils
# 9.5 or newer and a filesystem implementing renameat2(RENAME_EXCHANGE).
# GitHub's ubuntu-24.04 runners ship coreutils 9.4 and take the documented
# fallback, so the publication mode a default build reports is
# host-dependent and cannot be asserted as a constant.
exchange_supported() {
    local probe="${workdir}/exchange-probe" rc=0
    rm -rf "${probe}"
    mkdir -p "${probe}/a" "${probe}/b"
    mv -T --exchange "${probe}/a" "${probe}/b" 2>/dev/null || rc=1
    rm -rf "${probe}"
    return "${rc}"
}

if exchange_supported; then
    default_publish_mode=exchange
else
    default_publish_mode=fallback
fi

# Both locks must be free once everything has finished.
assert_locks_free() {
    local case_dir=$1 what=$2
    local lock
    for lock in "${case_dir}/cache/locks/activity.lock" \
        "${case_dir}/cache/locks/publish-${target}.lock"; do
        [[ -e ${lock} ]] || continue
        flock -n -x "${lock}" true ||
            fail "${what}: lock '${lock}' is still held"
    done
}

# Nothing of this invocation's may survive, and nothing of anybody else's may
# have been removed.
assert_no_stray_containers() {
    local case_dir=$1 what=$2
    assert_eq '' "$(live_containers "${case_dir}")" "${what}: containers left behind"
    assert_eq '' "$(live_images "${case_dir}")" "${what}: images left behind"
}

# --- cases: argument, target and commit checking ----------------------------

start 'rejects a wrong argument count'
rc=0
"${under_test}" >"${workdir}/usage.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" 'exit status for no arguments'
assert_contains "${workdir}/usage.out" 'usage:' 'usage message'
rc=0
"${under_test}" only-one >"${workdir}/usage1.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" 'exit status for one argument'

start 'refuses an unrecognized target unless the dist tag is given'
c="${workdir}/unknown-target"
rc=$(run_build_to "${c}" "${c}/mystery-9")
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for an unknown target'
assert_contains "${c}/output" "unknown target 'mystery-9'" 'unknown target message'
assert_eq 0 "$(curl_calls "${c}")" 'curl invocations for an unknown target'
assert_eq 0 "$(podman_calls "${c}")" 'podman invocations for an unknown target'

rc=$(run_build_to "${c}" "${c}/mystery-9" EXPECTED_DIST=fc43)
assert_eq 0 "${rc}" 'exit status with EXPECTED_DIST supplied'
assert_eq fc43 "$(log_field "${c}/output" target_resolved dist)" 'resolved dist tag'

start 'maps each known target to its dist tag'
c="${workdir}/rocky-target"
rc=$(run_build_to "${c}" "${c}/rocky-10" STUB_RELEASE=1.el10)
assert_eq 0 "${rc}" 'exit status for the rocky-10 target'
assert_eq el10 "$(log_field "${c}/output" target_resolved dist)" 'rocky dist tag'
assert_file "${c}/rocky-10/guildmaster-${pkg_version}-1.el10.${pkg_arch}.rpm" \
    'published rocky package'

start 'refuses to build when the spec packages a different commit'
c="${workdir}/spec-drift"
other_spec="${c}/other.spec"
mkdir -p "${c}"
printf '%%global commit          %s\nName: guildmaster\n' \
    0000000000000000000000000000000000000000 >"${other_spec}"
rc=$(run_build "${c}" "SPEC_FILE=${other_spec}")
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a spec/commit mismatch'
assert_contains "${c}/output" 'update both together' 'spec drift message'
assert_contains "${c}/output" "${commit}" 'the pinned commit is named'
assert_eq 0 "$(curl_calls "${c}")" 'curl invocations after a spec mismatch'
assert_eq 0 "$(podman_calls "${c}")" 'podman invocations after a spec mismatch'

start 'refuses a spec with no commit to compare'
c="${workdir}/spec-nocommit"
mkdir -p "${c}"
printf 'Name: guildmaster\n' >"${c}/nocommit.spec"
rc=$(run_build "${c}" "SPEC_FILE=${c}/nocommit.spec")
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a spec with no commit'
assert_contains "${c}/output" "could not read '%global commit'" 'missing commit message'

start 'agrees with the commit the checked-in spec packages'
c="${workdir}/spec-agrees"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status against the real spec'
assert_eq "${short_commit}" "$(log_field "${c}/output" spec_commit_ok commit)" \
    'reported short commit'

# --- cases: the tarball cache -----------------------------------------------

start 'downloads, builds and publishes on a cold cache'
c="${workdir}/cold"
rc=$(run_build "${c}" PODMAN_STUB_TAG=first)
assert_eq 0 "${rc}" 'exit status'
assert_eq 1 "$(curl_calls "${c}")" 'curl invocations'
assert_file "$(cached_tarball "${c}")" 'cached tarball'
assert_eq "${fixture_sha256}" \
    "$(sha256sum "$(cached_tarball "${c}")" | cut -d' ' -f1)" \
    'cached tarball checksum'
assert_published_set "${c}" first 'first publication'
assert_file "$(out_dir "${c}")/manifest.tsv" 'published manifest'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files'
assert_eq '' "$(stray_staging "${c}")" 'staging directories left behind'
assert_no_stray_containers "${c}" 'after a successful build'

start 'reuses a cached tarball without downloading again'
rc=$(run_build "${c}" PODMAN_STUB_TAG=second)
assert_eq 0 "${rc}" 'exit status on second run'
assert_eq 0 "$(curl_calls "${c}")" 'curl invocations on a warm cache'
assert_published_set "${c}" second 'second publication replaced the first'

start 're-fetches when the cached tarball fails its checksum'
c="${workdir}/corrupt"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status priming the cache'
printf 'clobbered by an interrupted run' >"$(cached_tarball "${c}")"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status with a corrupt cache'
assert_eq 1 "$(curl_calls "${c}")" 'curl invocations after corruption'
assert_eq "${fixture_sha256}" \
    "$(sha256sum "$(cached_tarball "${c}")" | cut -d' ' -f1)" \
    'repaired tarball checksum'

start 'never publishes a download that fails its checksum'
c="${workdir}/badsum"
rc=$(run_build "${c}" CURL_STUB_CORRUPT=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a bad download'
assert_contains "${c}/output" 'checksum mismatch' 'checksum failure message'
assert_no_file "$(cached_tarball "${c}")" 'cache file after a bad download'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files after failure'
assert_eq 0 "$(podman_calls "${c}")" 'container invocations after a failed download'

start 'leaves nothing behind when the transfer itself fails'
c="${workdir}/transfer"
rc=$(run_build "${c}" CURL_STUB_FAIL=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a failed transfer'
assert_no_file "$(cached_tarball "${c}")" 'cache file after a failed transfer'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files after failure'

# --- cases: the three container phases --------------------------------------

start 'runs three phases with the network only in the first'
c="${workdir}/phases"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status'
assert_eq 6 "$(podman_calls "${c}")" 'podman invocations'

phase_a=$(podman_call "${c}" 1)
phase_commit=$(podman_call "${c}" 2)
phase_b=$(podman_call "${c}" 3)
phase_c=$(podman_call "${c}" 4)
remove_container=$(podman_call "${c}" 5)
remove_image=$(podman_call "${c}" 6)

printf '%s\n' "${phase_a}" >"${c}/phase-a"
printf '%s\n' "${phase_commit}" >"${c}/phase-commit"
printf '%s\n' "${phase_b}" >"${c}/phase-b"
printf '%s\n' "${phase_c}" >"${c}/phase-c"
printf '%s\n' "${remove_container}" >"${c}/remove-container"
printf '%s\n' "${remove_image}" >"${c}/remove-image"

assert_contains "${c}/phase-a" 'run --name guildmaster-build-' 'phase A is a named run'
assert_not_contains "${c}/phase-a" '--network=none' 'phase A may reach the network'
assert_not_contains "${c}/phase-a" ':/out:' 'phase A must not mount the output'
assert_contains "${c}/phase-a" "${repo_root}/guildmaster.spec:/work/guildmaster.spec:ro,z" \
    'spec mount'
assert_contains "${c}/phase-a" "${repo_root}/packaging:/work/packaging:ro,z" \
    'packaging mount'
assert_contains "${c}/phase-a" "${repo_root}/patches:/work/patches:ro,z" \
    'patches mount'
assert_contains "${c}/phase-a" "$(cached_tarball "${c}"):/work/${tarball}:ro,z" \
    'tarball mount'
assert_contains "${c}/phase-a" 'dnf -y builddep' 'build dependency installation'
assert_contains "${c}/phase-a" 'set-enabled crb' 'CRB is enabled on Rocky'

assert_contains "${c}/phase-commit" 'commit guildmaster-build-' 'the deps phase is committed'
assert_contains "${c}/phase-commit" 'localhost/guildmaster-build:' 'temporary image name'

assert_contains "${c}/phase-b" '--network=none' 'phase B has no network'
assert_contains "${c}/phase-b" '--rm' 'phase B container is removed'
assert_contains "${c}/phase-b" "${c}/.staging/" 'a staging directory is mounted at /out'
# shellcheck disable=SC2016  # matching the literal, unexpanded container script
assert_contains "${c}/phase-b" 'rpmbuild --define "_topdir ${topdir}" -ba /work/guildmaster.spec' \
    'rpmbuild invocation'
assert_contains "${c}/phase-b" 'manifest.tsv' 'the manifest is written in the container'
# rpmbuild's output goes to a file, never down a pipe: piping it into head
# kills the build with SIGPIPE.
# shellcheck disable=SC2016  # matching the literal, unexpanded container script
assert_contains "${c}/phase-b" '>"${topdir}/rpmbuild.log"' 'rpmbuild logs to a file'
grep -qF -- "$(out_dir "${c}"):/out" "${c}/podman.log" &&
    fail 'the published directory must not be mounted as the output directory'

assert_contains "${c}/phase-c" '--network=none' 'phase C has no network'
assert_contains "${c}/phase-c" ':/out:ro,z' 'phase C mounts the output read-only'
assert_contains "${c}/phase-c" '--rebuild' 'phase C rebuilds the SRPM'

assert_contains "${c}/remove-container" 'rm -f guildmaster-build-' 'the container is removed'
assert_contains "${c}/remove-image" 'rmi -f localhost/guildmaster-build:' 'the image is removed'

start 'names its container and image after the invocation'
c="${workdir}/names"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status'
build_id=$(log_field "${c}/output" activity_lock_acquired build_id)
[[ -n ${build_id} ]] || fail 'build_id field is empty'
assert_contains "${c}/podman.log" "guildmaster-build-${build_id}" \
    'container name carries the build id'
assert_contains "${c}/podman.log" "localhost/guildmaster-build:${build_id}" \
    'image name carries the build id'

# --- cases: a failure in each phase -----------------------------------------

phase_failure_case() {
    local phase=$1 marker=$2
    local c="${workdir}/fail-${phase}"
    local rc
    rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
    assert_eq 0 "${rc}" "exit status priming a good publication (${phase})"

    # A foreign container and image that this build must never touch.
    : >"${c}/podman-state/containers/someone-elses-build"
    : >"${c}/podman-state/images/localhost_someone-elses-image_1"

    rc=$(run_build "${c}" PODMAN_STUB_TAG=doomed "PODMAN_STUB_FAIL_PHASE=${phase}")
    [[ ${rc} -ne 0 ]] || fail "expected a non-zero exit status for a ${phase} failure"
    assert_contains "${c}/output" "${marker}" "${phase} failure message"
    assert_published_set "${c}" good "the previous complete set survives a ${phase} failure"
    assert_eq '' "$(stray_staging "${c}")" "staging directories after a ${phase} failure"
    assert_eq 'someone-elses-build' "$(live_containers "${c}")" \
        "containers after a ${phase} failure"
    assert_eq 'localhost_someone-elses-image_1' "$(live_images "${c}")" \
        "images after a ${phase} failure"
    assert_not_contains "${c}/podman.log" 'someone-elses' \
        "a ${phase} failure named a foreign resource"
    assert_locks_free "${c}" "after a ${phase} failure"
}

start 'a dependency-phase failure leaves the previous output and no scratch'
phase_failure_case deps 'installing build dependencies'

start 'a commit failure leaves the previous output and no scratch'
phase_failure_case commit 'committing the build environment'

start 'a build-phase failure leaves the previous output and no scratch'
phase_failure_case build 'the container build'

start 'an SRPM rebuild failure leaves the previous output and no scratch'
phase_failure_case rebuild 'the SRPM rebuild'

# --- cases: validation before publication -----------------------------------

# Every way the staged set can be wrong, and the diagnostic that must name it.
# Each case first primes a good publication, so the assertion is both that the
# build fails and that the previous complete set is untouched.
validation_rejection_case() {
    local set_name=$1 marker=$2
    local c="${workdir}/reject-${set_name}"
    local rc
    rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
    assert_eq 0 "${rc}" "exit status priming a good publication (${set_name})"
    rc=$(run_build "${c}" PODMAN_STUB_TAG=bad "PODMAN_STUB_SET=${set_name}")
    [[ ${rc} -ne 0 ]] ||
        fail "expected a non-zero exit status for the '${set_name}' set"
    assert_contains "${c}/output" "${marker}" "${set_name} diagnostic"
    has_event "${c}/output" validation_failed ||
        fail "no validation_failed record for '${set_name}'"
    assert_published_set "${c}" good "the previous set survives '${set_name}'"
    assert_eq '' "$(stray_staging "${c}")" "staging after '${set_name}'"
    assert_no_stray_containers "${c}" "after '${set_name}'"
    assert_locks_free "${c}" "after '${set_name}'"
}

start 'refuses to publish an empty staging directory'
validation_rejection_case empty 'produced no output'

start 'refuses to publish without the binary package'
validation_rejection_case missing-base 'produced no binary package'

start 'refuses to publish without the debuginfo package'
validation_rejection_case missing-debuginfo "missing: guildmaster-debuginfo-"

start 'refuses to publish without the debugsource package'
validation_rejection_case missing-debugsource "missing: guildmaster-debugsource-"

start 'refuses to publish without the source RPM'
validation_rejection_case missing-srpm 'missing: srpm/guildmaster-'

start 'refuses to publish without the manifest'
validation_rejection_case missing-manifest 'missing: manifest.tsv'

start 'refuses to publish with an unexpected extra file'
validation_rejection_case extra-file 'unexpected: build.log'

start 'refuses to publish with an unexpected extra directory'
validation_rejection_case extra-dir 'unexpected: logs'

start 'refuses to publish a -devel subpackage'
validation_rejection_case devel 'produced a -devel subpackage'

start 'refuses to publish a noarch package'
validation_rejection_case noarch 'produced a noarch package'

start 'refuses to publish a foreign architecture'
validation_rejection_case wrong-arch 'expected x86_64'

start 'refuses to publish the wrong dist tag'
validation_rejection_case wrong-dist 'expected .fc43'

start 'refuses to publish a version that names another commit'
validation_rejection_case wrong-commit "does not name commit ${short_commit}"

start 'refuses to publish two versions of the binary package'
validation_rejection_case duplicate 'more than one binary package'

start 'refuses a manifest naming a package that was not built'
validation_rejection_case manifest-extra-line 'which the build did not produce'

start 'refuses a manifest that omits a package'
validation_rejection_case manifest-missing-line 'does not describe every package'

start 'refuses a manifest recording an epoch'
validation_rejection_case manifest-epoch "records epoch '1'"

start 'refuses a manifest whose checksum does not match'
validation_rejection_case manifest-sha 'does not match'

start 'refuses a manifest line with too few fields'
validation_rejection_case manifest-short-line 'fewer than seven fields'

start 'refuses a manifest line with too many fields'
validation_rejection_case manifest-long-line 'more than seven fields'

start 'refuses a manifest whose metadata contradicts the file name'
validation_rejection_case manifest-wrong-name 'but names'

start 'refuses to publish an incomplete build'
c="${workdir}/incomplete"
rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
assert_eq 0 "${rc}" 'exit status priming a good publication'
rc=$(run_build "${c}" PODMAN_STUB_TAG=bad PODMAN_STUB_SET=partial)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for an incomplete build'
assert_contains "${c}/output" 'incomplete or unexpected build' 'incomplete build message'
assert_published_set "${c}" good 'the previous complete set survives'
assert_eq '' "$(stray_staging "${c}")" 'staging directories left behind'
assert_locks_free "${c}" 'after an incomplete build'

# --- cases: diagnostics and secret handling ---------------------------------

start 'keeps a secret-bearing tarball URL out of the build log'
c="${workdir}/redaction"
rc=$(run_build "${c}" \
    "TARBALL_URL=https://ci-bot:s3cr3tpassw0rd@example.invalid/private/${tarball}?token=hunter2token")
assert_eq 0 "${rc}" 'exit status'
assert_contains "${c}/output" "${tarball}" \
    'the tarball filename identifies the download'
for secret in 's3cr3tpassw0rd' 'hunter2token' 'ci-bot:' 'token=' 'example.invalid'; do
    if grep -qF -- "${secret}" "${c}/output"; then
        fail "the build log discloses '${secret}'"
    fi
done

start 'keeps a secret-bearing URL out of a transfer failure diagnostic'
c="${workdir}/redaction-failure"
rc=$(run_build "${c}" CURL_STUB_FAIL=1 \
    "TARBALL_URL=https://ci-bot:s3cr3tpassw0rd@example.invalid/private/${tarball}?token=hunter2token")
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a failed transfer'
for secret in 's3cr3tpassw0rd' 'hunter2token' 'ci-bot:'; do
    if grep -qF -- "${secret}" "${c}/output"; then
        fail "the failure diagnostic discloses '${secret}'"
    fi
done

start 'emits structured diagnostics for the build lifecycle'
c="${workdir}/diagnostics"
rc=$(run_build "${c}" PODMAN_STUB_TAG=first)
assert_eq 0 "${rc}" 'exit status on a cold cache'
log="${c}/output"
for event in target_resolved spec_commit_ok activity_lock_acquired cache_miss \
    download_start cache_published staging_created phase_deps_start \
    phase_deps_ok phase_build_start phase_build_ok phase_rebuild_start \
    phase_rebuild_ok containers_removed validation_ok \
    publication_lock_acquired published build_complete; do
    has_event "${log}" "${event}" || fail "no '${event}' record was logged"
done
assert_eq "${target}" "$(log_field "${log}" activity_lock_acquired target)" \
    'target field'
[[ -n $(log_field "${log}" activity_lock_acquired build_id) ]] ||
    fail 'build_id field is empty'
[[ -n $(log_field "${log}" activity_lock_acquired elapsed_seconds) ]] ||
    fail 'elapsed_seconds field is empty'
assert_eq "${pkg_version}" "$(log_field "${log}" validation_ok version)" \
    'validated version'
assert_eq "${pkg_release}" "$(log_field "${log}" validation_ok release)" \
    'validated release'
assert_eq "${pkg_arch}" "$(log_field "${log}" validation_ok arch)" 'validated arch'
assert_eq 4 "$(log_field "${log}" validation_ok packages)" 'validated package count'
assert_eq first "$(log_field "${log}" published mode)" 'first publication mode'

rc=$(run_build "${c}" PODMAN_STUB_TAG=second)
assert_eq 0 "${rc}" 'exit status on a warm cache'
has_event "${c}/output" cache_hit || fail 'no cache_hit record on a warm cache'
assert_eq "${default_publish_mode}" "$(log_field "${c}/output" published mode)" \
    'second publication mode'
if [[ ${default_publish_mode} == fallback ]]; then
    assert_eq exchange_unsupported \
        "$(log_field "${c}/output" published fallback_reason)" \
        'fallback reason on a host without RENAME_EXCHANGE'
fi

rc=$(run_build "${c}" PODMAN_STUB_TAG=third PUBLISH_EXCHANGE=never)
assert_eq 0 "${rc}" 'exit status on the fallback path'
assert_eq fallback "$(log_field "${c}/output" published mode)" \
    'fallback publication mode'
assert_eq exchange_disabled \
    "$(log_field "${c}/output" published fallback_reason)" 'fallback reason'

rc=$(run_build "${c}" PODMAN_STUB_TAG=broken PODMAN_STUB_SET=partial)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a partial build'
has_event "${c}/output" validation_failed || fail 'no validation_failed record'

rc=$(run_build "${c}" PODMAN_STUB_FAIL_PHASE=build)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a failed build'
has_event "${c}/output" phase_build_failed || fail 'no phase_build_failed record'
has_event "${c}/output" cleanup || fail 'no cleanup record'
assert_eq yes "$(log_field "${c}/output" cleanup removed_container)" \
    'cleanup reports removing the container'
assert_eq yes "$(log_field "${c}/output" cleanup removed_image)" \
    'cleanup reports removing the image'

# --- cases: atomic publication ----------------------------------------------

# A second build is held inside phase B with a partial set already staged.
# Until it is released, the published directory must still be exactly the
# previous complete set — never empty, never a mixture.
publication_case() {
    local c=$1 exchange=$2
    prepare_case "${c}"
    local started="${c}/started.fifo" waiting="${c}/wait.fifo"
    mkfifo "${started}" "${waiting}"

    local rc
    rc=$(run_build "${c}" PODMAN_STUB_TAG=previous PUBLISH_EXCHANGE="${exchange}")
    assert_eq 0 "${rc}" "exit status priming the previous set (${exchange})"

    prepare_case "${c}"
    start_build_bg "${c}" "${c}/second.out" \
        PODMAN_STUB_TAG=next \
        PUBLISH_EXCHANGE="${exchange}" \
        PODMAN_STUB_PARTIAL_BEFORE_WAIT=1 \
        PODMAN_STUB_STARTED_FIFO="${started}" \
        PODMAN_STUB_WAIT_FIFO="${waiting}"
    local pid=${bg_pid}

    fifo_read "${started}" \
        "second build to announce it reached phase B (${exchange})" "-${pid}" ||
        return 1
    # The second build is now blocked with a half-written staging directory.
    assert_published_set "${c}" previous \
        "while a second build is mid-flight (${exchange})"

    echo go >"${waiting}"
    wait "${pid}" || fail "second build failed (${exchange}): $(cat "${c}/second.out")"
    assert_published_set "${c}" next "after the second build published (${exchange})"
    assert_eq '' "$(stray_staging "${c}")" "staging left behind (${exchange})"
    assert_no_stray_containers "${c}" "after publication (${exchange})"
    assert_locks_free "${c}" "after publication (${exchange})"
}

start 'publication is all-or-nothing (host default path)'
publication_case "${workdir}/publish-atomic" auto

start 'publication is all-or-nothing (fallback path)'
publication_case "${workdir}/publish-fallback" never

# Two builds of the same target, held together at the pre-publication barrier
# and then released into the publication lock at once. Neither the staged
# output of either build nor any mixture of the two may ever be visible: the
# published directory must hold one complete generation at every moment, and
# one complete generation at the end. Which of the two wins the lock is
# deliberately not asserted — that is the point of the lock, not a property
# of it.
concurrent_publish_case() {
    local c="${workdir}/concurrent-publish"
    prepare_case "${c}"
    local announce_a="${c}/announce-a.fifo" wait_a="${c}/wait-a.fifo"
    local announce_b="${c}/announce-b.fifo" wait_b="${c}/wait-b.fifo"
    mkfifo "${announce_a}" "${wait_a}" "${announce_b}" "${wait_b}"

    local rc
    rc=$(run_build "${c}" PODMAN_STUB_TAG=previous)
    assert_eq 0 "${rc}" 'exit status priming the previous set'

    prepare_case "${c}"
    start_build_bg "${c}" "${c}/a.out" \
        PODMAN_STUB_TAG=build-a \
        PREPUBLISH_ANNOUNCE_FIFO="${announce_a}" \
        PREPUBLISH_WAIT_FIFO="${wait_a}"
    local pid_a=${bg_pid}
    start_build_bg "${c}" "${c}/b.out" \
        PODMAN_STUB_TAG=build-b \
        PREPUBLISH_ANNOUNCE_FIFO="${announce_b}" \
        PREPUBLISH_WAIT_FIFO="${wait_b}"
    local pid_b=${bg_pid}

    fifo_read "${announce_a}" 'build A to announce the pre-publication barrier' \
        "-${pid_a}" "-${pid_b}" || return 1
    fifo_read "${announce_b}" 'build B to announce the pre-publication barrier' \
        "-${pid_a}" "-${pid_b}" || return 1

    # Both builds now hold the activity lock with a complete, validated set
    # staged and unpublished.
    assert_published_set "${c}" previous 'while both builds wait to publish'
    assert_eq 2 "$(stray_staging "${c}" | grep -c .)" \
        'staging directories in flight'

    # Take the publication lock from outside, so that releasing both builds
    # cannot publish anything. This is what makes the next assertion a
    # statement about the lock rather than about timing: neither build can
    # get past publish_staging's flock while this holder owns it, however
    # long they run.
    local holder_ready="${c}/holder-ready.fifo"
    local holder_release="${c}/holder-release.fifo"
    mkfifo "${holder_ready}" "${holder_release}"
    flock -x "${c}/cache/locks/publish-${target}.lock" \
        -c "echo held >'${holder_ready}'; read -r _ <'${holder_release}'" &
    local holder_pid=$!
    fifo_read "${holder_ready}" 'external lock holder to take the publication lock' \
        "${holder_pid}" "-${pid_a}" "-${pid_b}" || return 1

    # Release both builds into the publication lock at once.
    echo go >"${wait_a}" &
    echo go >"${wait_b}" &

    # Both are now past the barrier and blocked on the lock this test holds,
    # so the published directory must still be exactly the previous
    # generation, and neither build can have exited.
    assert_published_set "${c}" previous 'while the publication lock is held'
    kill -0 "${pid_a}" 2>/dev/null || fail 'build A exited without the publication lock'
    kill -0 "${pid_b}" 2>/dev/null || fail 'build B exited without the publication lock'

    echo go >"${holder_release}"
    wait "${holder_pid}"
    wait "${pid_a}" || fail "build A failed: $(cat "${c}/a.out")"
    wait "${pid_b}" || fail "build B failed: $(cat "${c}/b.out")"

    # Which build won the lock is deliberately not asserted; that it
    # published alone, and whole, is.
    published_is_one_complete_generation "${c}" build-a build-b ||
        fail "final published set is not one complete generation: [$(published_set "${c}")]"
    assert_eq '' "$(stray_staging "${c}")" 'staging directories after the race'
    assert_eq '' "$(stray_temps "${c}")" 'temporary files after the race'
    assert_no_stray_containers "${c}" 'after two concurrent builds'
    assert_locks_free "${c}" 'after two concurrent builds'
}

start 'two concurrent builds never expose a partial or mixed generation'
concurrent_publish_case

# --- cases: fallback rollback -----------------------------------------------

# The fallback path moves the previous output aside before promoting staging.
# If that promotion fails, the previous output must come back.
start 'rolls back the previous output when fallback promotion fails'
c="${workdir}/rollback-ok"
rc=$(run_build "${c}" PODMAN_STUB_TAG=previous)
assert_eq 0 "${rc}" 'exit status priming the previous set'
rc=$(run_build "${c}" \
    PODMAN_STUB_TAG=doomed \
    PUBLISH_EXCHANGE=never \
    PUBLISH_MV="${stub_bin}/publish-mv" \
    PUBLISH_MV_FAIL_PROMOTION=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status when promotion fails'
assert_published_set "${c}" previous 'the previous set is restored by rollback'
has_event "${c}/output" publish_fallback_failed ||
    fail 'no publish_fallback_failed record'
has_event "${c}/output" rollback_start || fail 'no rollback_start record'
has_event "${c}/output" rollback_ok || fail 'no rollback_ok record'
assert_eq '' "$(previous_dirs "${c}")" '.previous after a successful rollback'
assert_eq '' "$(staging_excluding_previous "${c}")" \
    'staging directories after a successful rollback'
assert_eq '' "$(stray_temps "${c}")" 'temporary files after a rollback'
assert_locks_free "${c}" 'after a successful rollback'

# If the rollback also fails, the previous output must survive as recovery
# data rather than being cleaned up with the invocation's own scratch.
start 'preserves the previous output when rollback itself fails'
c="${workdir}/rollback-failed"
rc=$(run_build "${c}" PODMAN_STUB_TAG=previous)
assert_eq 0 "${rc}" 'exit status priming the previous set'
rc=$(run_build "${c}" \
    PODMAN_STUB_TAG=doomed \
    PUBLISH_EXCHANGE=never \
    PUBLISH_MV="${stub_bin}/publish-mv" \
    PUBLISH_MV_FAIL_PROMOTION=1 \
    PUBLISH_MV_FAIL_ROLLBACK=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status when rollback fails'
has_event "${c}/output" rollback_failed || fail 'no rollback_failed record'
assert_contains "${c}/output" 'preserved at' 'the recoverable path is reported'
if has_event "${c}/output" build_complete; then
    fail 'a failed publication was reported as a completed build'
fi
grep -qF 'RPMs written to' "${c}/output" &&
    fail 'a failed publication claimed the RPMs were written'

# The recoverable copy is the complete previous generation, and it is the
# only staging entry left.
recoverable=$(previous_dirs "${c}")
[[ -n ${recoverable} ]] || fail 'the recoverable .previous directory was removed'
assert_eq "$(complete_set_for previous)" \
    "$(set_in_dir "${c}/.staging/${recoverable}")" \
    'the preserved .previous directory holds the complete previous set'
assert_eq '' "$(staging_excluding_previous "${c}")" \
    'invocation-owned staging after a failed rollback'
assert_eq '' "$(stray_temps "${c}")" 'temporary files after a failed rollback'
assert_locks_free "${c}" 'after a failed rollback'

# --- cases: clean ------------------------------------------------------------

clean_race_case() {
    local c="${workdir}/clean-race"
    prepare_case "${c}"
    local started="${c}/started.fifo" waiting="${c}/wait.fifo"
    local clean_ready="${c}/clean.fifo"
    mkfifo "${started}" "${waiting}" "${clean_ready}"

    local rc
    rc=$(run_build "${c}" PODMAN_STUB_TAG=published)
    assert_eq 0 "${rc}" 'exit status priming the published set'

    prepare_case "${c}"
    start_build_bg "${c}" "${c}/build.out" \
        PODMAN_STUB_TAG=later \
        PODMAN_STUB_STARTED_FIFO="${started}" \
        PODMAN_STUB_WAIT_FIFO="${waiting}"
    local build_pid=${bg_pid}
    fifo_read "${started}" 'build to announce it reached phase B' "-${build_pid}" ||
        return 1

    # Announce-then-block: once the hook has fired, clean can only be waiting
    # on the activity lock, which the running build holds shared.
    cat >"${c}/prelock-hook" <<HOOK
#!/usr/bin/env bash
echo waiting >"${clean_ready}"
HOOK
    chmod +x "${c}/prelock-hook"

    env FLOCK=flock \
        CACHE_DIR="${c}/cache" \
        LOCK_DIR="${c}/cache/locks" \
        DIST_DIR="$(out_dir "${c}")" \
        CLEAN_PRELOCK_HOOK="${c}/prelock-hook" \
        "${clean_under_test}" >"${c}/clean.out" 2>&1 &
    local clean_pid=$!
    fifo_read "${clean_ready}" 'clean to reach the activity lock' \
        "${clean_pid}" "-${build_pid}" || return 1

    assert_published_set "${c}" published 'clean must not touch output while a build runs'
    assert_file "$(cached_tarball "${c}")" 'clean must not remove the cache yet'

    echo go >"${waiting}"
    wait "${build_pid}" || fail "build failed: $(cat "${c}/build.out")"
    wait "${clean_pid}" || fail "clean failed: $(cat "${c}/clean.out")"

    assert_no_file "$(out_dir "${c}")" 'output directory after clean'
    assert_no_file "$(cached_tarball "${c}")" 'cached tarball after clean'
    [[ -d "${c}/cache/locks" ]] || fail 'clean removed the lock directory'
    assert_locks_free "${c}" 'after clean'
}

start 'clean waits for an in-flight build and keeps the lock directory'
clean_race_case

start 'clean empties the cache but keeps the lock directory'
c="${workdir}/clean-cache"
prepare_case "${c}"
rc=$(run_build "${c}" PODMAN_STUB_TAG=published)
assert_eq 0 "${rc}" 'exit status priming the published set'
# Scratch a build left in the cache, nested so that the removal has to
# recurse rather than unlink a single file.
mkdir -p "${c}/cache/scratch/deeper"
printf 'left over\n' >"${c}/cache/scratch/deeper/leftover"

env CACHE_DIR="${c}/cache" LOCK_DIR="${c}/cache/locks" \
    DIST_DIR="$(out_dir "${c}")" \
    "${clean_under_test}" >"${c}/clean.out" 2>&1 ||
    fail "clean failed: $(cat "${c}/clean.out")"
assert_no_file "$(out_dir "${c}")" 'output directory after clean'
assert_no_file "$(cached_tarball "${c}")" 'cached tarball after clean'
assert_no_file "${c}/cache/scratch" 'cache scratch after clean'
[[ -d "${c}/cache/locks" ]] || fail 'clean removed the lock directory'
assert_contains "${c}/clean.out" 'kept' 'clean reports what it kept'
assert_locks_free "${c}" 'after clean'

# --- cases: failure and cancellation ----------------------------------------

start 'a failed build leaves no staging, temporaries or held locks'
c="${workdir}/build-failure"
rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
assert_eq 0 "${rc}" 'exit status priming a good publication'
rc=$(run_build "${c}" PODMAN_STUB_FAIL_PHASE=build)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a failed build'
assert_published_set "${c}" good 'the previous complete set survives a failure'
assert_eq '' "$(stray_staging "${c}")" 'staging directories after a failure'
assert_eq '' "$(stray_temps "${c}")" 'temporary files after a failure'
assert_no_stray_containers "${c}" 'after a failed build'
assert_locks_free "${c}" 'after a failed build'

# Cancellation must clean up exactly this invocation's scratch, container and
# image — and never the recovery data a previous failed rollback left behind.
cancellation_case() {
    local signal=$1
    local c="${workdir}/build-cancel-${signal}"
    prepare_case "${c}"
    local started="${c}/started.fifo" waiting="${c}/wait.fifo"
    mkfifo "${started}" "${waiting}"
    local rc
    rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
    assert_eq 0 "${rc}" "exit status priming a good publication (${signal})"

    # Recovery data from an earlier failed rollback, and a foreign container.
    mkdir -p "${c}/.staging/${target}.zzzzzz.previous"
    printf 'recovery\n' >"${c}/.staging/${target}.zzzzzz.previous/keep-me"
    : >"${c}/podman-state/containers/someone-elses-build"

    prepare_case "${c}"
    start_build_bg "${c}" "${c}/cancelled.out" \
        PODMAN_STUB_TAG=doomed \
        PODMAN_STUB_PARTIAL_BEFORE_WAIT=1 \
        PODMAN_STUB_STARTED_FIFO="${started}" \
        PODMAN_STUB_WAIT_FIFO="${waiting}"
    local build_pid=${bg_pid}
    fifo_read "${started}" \
        "build to announce it reached phase B (${signal})" "-${build_pid}" ||
        return 1
    # setsid gave the build its own process group, so this reaches the stub too.
    kill "-${signal}" -"${build_pid}"
    wait "${build_pid}" 2>/dev/null || true

    assert_published_set "${c}" good \
        "the previous complete set survives cancellation (${signal})"
    assert_eq "${target}.zzzzzz.previous" "$(previous_dirs "${c}")" \
        "recovery data after cancellation (${signal})"
    assert_file "${c}/.staging/${target}.zzzzzz.previous/keep-me" \
        "recovery contents after cancellation (${signal})"
    assert_eq '' "$(staging_excluding_previous "${c}")" \
        "staging directories after cancellation (${signal})"
    assert_eq '' "$(stray_temps "${c}")" "temporary files after cancellation (${signal})"
    assert_eq 'someone-elses-build' "$(live_containers "${c}")" \
        "containers after cancellation (${signal})"
    assert_eq '' "$(live_images "${c}")" "images after cancellation (${signal})"
    assert_locks_free "${c}" "after cancellation (${signal})"
}

start 'a TERM-cancelled build cleans up only what it owns'
cancellation_case TERM

start 'an INT-cancelled build cleans up only what it owns'
cancellation_case INT

# --- summary ----------------------------------------------------------------

echo
if [[ ${tests_failed} -gt 0 ]]; then
    echo "BUILD-RPM UNIT TESTS FAILED (${tests_failed} of ${tests_run} cases)" >&2
    exit 1
fi
echo "BUILD-RPM UNIT TESTS OK (${tests_run} cases)"
