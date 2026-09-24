#!/usr/bin/env bash
# Offline tests for scripts/virt-preflight.sh.
#
# No real tmt, libvirt or virtual provisioner: TMT, VIRSH, PYTHON and DF are
# stubs that answer from per-scenario control files. The disk-space-too-low
# case is still driven by setting MIN_FREE_MIB absurdly high instead of
# faking free space; the DF stub only intervenes to make df itself fail or
# print unparsable output. /dev/null stands in for /dev/kvm (it is a real,
# readable and writable character device) wherever a passing kvm_device
# check is wanted.
#
# SCRIPT_UNDER_TEST points the whole suite at a script under test; it
# defaults to the real script, and is also used at the end of this file to
# run the whole suite again against deliberately broken mutant copies, to
# check that the suite actually catches their bugs.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
: "${SCRIPT_UNDER_TEST:=${repo_root}/scripts/virt-preflight.sh}"

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

# assert_record <check> <status> [description]: a "preflight_event
# check=<check> status=<status>" line appears in stdout.
assert_record() {
    local check=$1 rec_status=$2
    local desc=${3:-"${check} reports ${rec_status}"}
    assert_contains "${SCENARIO}/stdout" "preflight_event check=${check} status=${rec_status}" "${desc}"
}

stub_dir=${scratch}/stubs
mkdir -p "${stub_dir}"

cat >"${stub_dir}/tmt" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == --version ]]; then
    [[ -f ${SCENARIO}/tmt_fails ]] && exit 1
    echo 'tmt version: 1.99.0'
    exit 0
fi
exit 0
STUB

cat >"${stub_dir}/python3" <<'STUB'
#!/usr/bin/env bash
set -u
case "$*" in
*'import testcloud, libvirt'*)
    [[ -f ${SCENARIO}/python_fails ]] && exit 1
    exit 0
    ;;
*'importlib.metadata'*)
    echo '1.2.3'
    exit 0
    ;;
esac
exit 0
STUB

cat >"${stub_dir}/virsh" <<'STUB'
#!/usr/bin/env bash
set -u
case "$*" in
*version)
    [[ -f ${SCENARIO}/virsh_unreachable ]] && exit 1
    cat <<'EOF'
Compiled against library: libvirt 10.0.0
Using library: libvirt 10.0.0
Using API: QEMU 10.0.0
Running hypervisor: QEMU 8.2.0
EOF
    ;;
*capabilities)
    [[ -f ${SCENARIO}/virsh_capabilities_fails ]] && exit 1
    if [[ -f ${SCENARIO}/no_kvm_domain ]]; then
        printf '<capabilities><guest><arch name="x86_64"><domain type="qemu"/></arch></guest></capabilities>\n'
    else
        printf "<capabilities><guest><arch name='x86_64'><domain type='kvm'/></arch></guest></capabilities>\n"
    fi
    ;;
esac
exit 0
STUB

cat >"${stub_dir}/df" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ -f ${SCENARIO}/df_fails ]]; then
    echo 'df: cannot read table of mounted filesystems' >&2
    exit 1
fi
if [[ -f ${SCENARIO}/df_garbage ]]; then
    echo 'not a number'
    exit 0
fi
exec /bin/df "$@"
STUB
chmod +x "${stub_dir}"/*

# new_scenario <name>: a scenario directory with the cache and work root in
# place; tests then set control files and break one thing.
new_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    export SCENARIO
    mkdir -p "${SCENARIO}/cache" "${SCENARIO}/workdir"
}

# run_preflight [extra env assignments...]: run virt-preflight.sh against
# the current scenario; output in ${SCENARIO}/stdout and .../stderr, status
# in $status.
run_preflight() {
    status=0
    env TMT="${stub_dir}/tmt" VIRSH="${stub_dir}/virsh" PYTHON="${stub_dir}/python3" \
        DF="${stub_dir}/df" \
        KVM_DEVICE=/dev/null IMAGE_CACHE_DIR="${SCENARIO}/cache" \
        TMT_WORKDIR_ROOT="${SCENARIO}/workdir" MIN_FREE_MIB=1 "$@" \
        "${SCRIPT_UNDER_TEST}" >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
}

# --- accept: everything passes -----------------------------------------------

new_scenario preflight_all_pass
run_preflight
assert_status "${status}" 0
assert_record tmt ok
assert_record virtual_provisioner ok
assert_record libvirt_session ok
assert_record kvm_device ok
assert_record kvm_domains ok
if [[ $(grep -c '^preflight_event check=disk_space status=ok' "${SCENARIO}/stdout") -eq 2 ]]; then
    ok 'disk_space is reported ok for both the image cache and the tmt work root'
else not_ok 'disk_space ok records missing for one of the two directories'; fi
assert_record summary ok 'a final summary record is written'
assert_contains "${SCENARIO}/stdout" "check=kvm_device status=ok device=/dev/null" \
    'the record format carries the named field after check and status'
assert_contains "${SCENARIO}/stdout" 'check=disk_space status=ok path=' \
    'disk_space records carry a path field'
assert_contains "${SCENARIO}/stdout" 'free_mib=' 'disk_space records carry a free_mib field'

# --- reject: tmt missing -------------------------------------------------------

new_scenario preflight_tmt_missing
run_preflight TMT="${scratch}/no-such-tmt"
assert_status "${status}" 1
assert_record tmt fail
assert_record virtual_provisioner ok 'other checks still run after tmt fails'
assert_contains "${SCENARIO}/stderr" 'cannot run the CUSE acceptance guests' 'the overall failure is reported'

# --- reject: python imports failing --------------------------------------------

new_scenario preflight_python_broken
touch "${SCENARIO}/python_fails"
run_preflight
assert_status "${status}" 1
assert_record virtual_provisioner fail
assert_contains "${SCENARIO}/stdout" 'testcloud or libvirt Python bindings are missing' \
    'the missing-bindings detail is reported'

# --- reject: libvirt session unreachable ---------------------------------------

new_scenario preflight_libvirt_unreachable
touch "${SCENARIO}/virsh_unreachable"
run_preflight
assert_status "${status}" 1
assert_record libvirt_session fail
assert_contains "${SCENARIO}/stdout" 'cannot connect to qemu:///session' 'the connection detail is reported'

# --- reject: KVM device missing -------------------------------------------------

new_scenario preflight_kvm_device_missing
run_preflight KVM_DEVICE="${SCENARIO}/no-such-device"
assert_status "${status}" 1
assert_record kvm_device fail
assert_contains "${SCENARIO}/stdout" 'is missing or not accessible' 'the missing-device detail is reported'

# --- reject: KVM device present but not a character device ---------------------

new_scenario preflight_kvm_device_not_char
touch "${SCENARIO}/not-a-device"
run_preflight KVM_DEVICE="${SCENARIO}/not-a-device"
assert_status "${status}" 1
assert_record kvm_device fail
assert_contains "${SCENARIO}/stdout" 'is missing or not accessible' \
    'a regular file in place of the device is refused'

# --- reject: capabilities without a KVM domain ----------------------------------

new_scenario preflight_no_kvm_domain
touch "${SCENARIO}/no_kvm_domain"
run_preflight
assert_status "${status}" 1
assert_record libvirt_session ok 'the session itself is reachable'
assert_record kvm_domains fail
assert_contains "${SCENARIO}/stdout" 'only emulation is available' 'the emulation-only detail is reported'

# --- reject: virsh capabilities failing outright --------------------------------

new_scenario preflight_capabilities_fails
touch "${SCENARIO}/virsh_capabilities_fails"
run_preflight
assert_status "${status}" 1
assert_record kvm_domains fail 'a capabilities command that itself fails is treated as no KVM domains'

# --- reject: disk space below the minimum ---------------------------------------

new_scenario preflight_disk_space_low
run_preflight MIN_FREE_MIB=9999999999
assert_status "${status}" 1
if [[ $(grep -c '^preflight_event check=disk_space status=fail' "${SCENARIO}/stdout") -eq 2 ]]; then
    ok 'disk_space fails for both directories under an absurd minimum'
else not_ok 'disk_space fail records missing for one of the two directories'; fi
assert_contains "${SCENARIO}/stdout" 'required_mib=9999999999' 'the required minimum is reported'

# --- reject: df itself fails -----------------------------------------------------

new_scenario preflight_df_fails
touch "${SCENARIO}/df_fails"
run_preflight
assert_status "${status}" 1
if [[ $(grep -c '^preflight_event check=disk_space status=fail' "${SCENARIO}/stdout") -eq 2 ]]; then
    ok 'disk_space fails for both directories when df itself fails'
else not_ok 'disk_space fail records missing for one of the two directories'; fi
assert_record tmt ok 'other checks still run after df fails'
assert_record kvm_domains ok 'other checks still run after df fails'
assert_contains "${SCENARIO}/stdout" 'df failed or produced unparsable output' \
    'the df-failure detail is reported'

# --- reject: df prints unparsable output ------------------------------------------

new_scenario preflight_df_garbage
touch "${SCENARIO}/df_garbage"
run_preflight
assert_status "${status}" 1
if [[ $(grep -c '^preflight_event check=disk_space status=fail' "${SCENARIO}/stdout") -eq 2 ]]; then
    ok 'disk_space fails for both directories when df prints unparsable output'
else not_ok 'disk_space fail records missing for one of the two directories'; fi
assert_record tmt ok 'other checks still run after df prints garbage'
assert_record kvm_domains ok 'other checks still run after df prints garbage'
assert_contains "${SCENARIO}/stdout" 'df failed or produced unparsable output' \
    'the unparsable-output detail is reported'

# --- reject: everything fails ---------------------------------------------------

new_scenario preflight_all_fail
touch "${SCENARIO}/tmt_fails" "${SCENARIO}/python_fails" "${SCENARIO}/virsh_unreachable" \
    "${SCENARIO}/virsh_capabilities_fails"
run_preflight KVM_DEVICE="${SCENARIO}/no-such-device" MIN_FREE_MIB=9999999999
assert_status "${status}" 1
assert_record tmt fail
assert_record virtual_provisioner fail
assert_record libvirt_session fail
assert_record kvm_device fail
assert_record kvm_domains fail
assert_contains "${SCENARIO}/stdout" 'preflight_event check=summary status=fail failures=7' \
    'the summary reports every one of the 7 failing checks'

echo
echo "virt-preflight tests: ${passed} passed, ${failed} failed"
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
    # the one line containing <fixed-string> with "if true; then" (keeping
    # the mutant syntactically valid while always taking the "ok" branch).
    # The pattern is single-quoted on purpose: it is literal source text.
    # Fails loudly when the pattern matches no line or more than one, or a
    # line that is not an "if ... then" condition, so a later edit to the
    # script cannot silently turn a mutant into a copy of the original.
    make_mutant() {
        local source=$1 pattern=$2 output=$3 matches line
        matches=$(grep -nF -- "${pattern}" "${source}" | cut -d: -f1)
        if [[ $(grep -c . <<<"${matches}") -ne 1 ]]; then
            echo "FAIL: mutant pattern '${pattern}' matches $(grep -c . <<<"${matches}") lines of ${source}" >&2
            exit 1
        fi
        line=${matches}
        sed -n "${line}p" "${source}" | grep -q '^if \[\[.*\]\]; then$' || {
            echo "FAIL: mutant pattern '${pattern}' in ${source} is not an 'if [[ ... ]]; then' line" >&2
            exit 1
        }
        sed "${line}s/.*/if true; then/" "${source}" >"${output}"
        chmod +x "${output}"
    }

    # Mutant 1: virt-preflight.sh no longer checks that libvirt actually
    # offers KVM domains, so a device-node-only host would pass.
    # shellcheck disable=SC2016
    make_mutant "${repo_root}/scripts/virt-preflight.sh" \
        "if [[ \${capabilities} == *\"<domain type='kvm'\"* ]]; then" \
        "${mutant_dir}/no-kvm-domains-check.sh"

    # Mutant 2: virt-preflight.sh no longer checks the KVM device is a
    # readable, writable character device.
    # shellcheck disable=SC2016
    make_mutant "${repo_root}/scripts/virt-preflight.sh" \
        'if [[ -c ${KVM_DEVICE} && -r ${KVM_DEVICE} && -w ${KVM_DEVICE} ]]; then' \
        "${mutant_dir}/no-kvm-device-check.sh"

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
        summary=$(grep '^virt-preflight tests:' "${out}" | tail -n 1) || true
        if [[ ${summary} =~ ^virt-preflight\ tests:\ ([0-9]+)\ passed,\ ([0-9]+)\ failed$ ]]; then
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

    check_mutant no-kvm-domains-check SCRIPT_UNDER_TEST="${mutant_dir}/no-kvm-domains-check.sh"
    check_mutant no-kvm-device-check SCRIPT_UNDER_TEST="${mutant_dir}/no-kvm-device-check.sh"

    [[ ${mutant_status} -eq 0 ]] || suite_status=1
fi

exit "${suite_status}"
