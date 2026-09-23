# Shared helpers for the tmt tests. Sourced, not executed.
#
# Tests count failures instead of stopping at the first one, so that one run
# reports everything that is wrong, and finish with `finish`.
# shellcheck shell=bash

failures=0

pass() {
    echo "ok: $*"
}

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# An unusable environment is an error, never a pass or a skip.
environment_error() {
    echo "ENVIRONMENT ERROR: $*" >&2
    exit 2
}

# check <description> <command...>: the command must succeed.
check() {
    local description=$1
    shift
    if "$@"; then
        pass "${description}"
    else
        fail "${description} (command: $*)"
    fi
}

# check_not <description> <command...>: the command must fail. A command that
# could not be run at all (126, 127) proves nothing, so that is a failure too.
check_not() {
    local description=$1 status=0
    shift
    "$@" || status=$?
    case ${status} in
    0) fail "${description} (unexpectedly succeeded: $*)" ;;
    126 | 127) fail "${description} (could not run: $*)" ;;
    *) pass "${description}" ;;
    esac
}

# True when a process with this exact command name exists. Reads /proc so
# that the fixtures need no procps.
process_exists() {
    grep -qsx "$1" /proc/[0-9]*/comm
}

# check_equal <description> <actual> <expected>
check_equal() {
    if [[ $2 == "$3" ]]; then
        pass "$1: $2"
    else
        fail "$1: expected '$3', got '$2'"
    fi
}

# wait_for <seconds> <command...>: bounded wait for a state, never a bare
# sleep. The pause between attempts is pacing only; the assertion is the
# command's success.
wait_for() {
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        ((SECONDS < deadline)) || return 1
        sleep 0.2
    done
}

# One machine-readable unit property; never parse `systemctl status`.
unit_property() {
    systemctl show "${2:-guildmaster.service}" --property "$1" --value
}

# The single binary package under test, selected by the harness.
rpm_under_test() {
    local dir=${GM_RPM_DIR:?GM_RPM_DIR is not set; run through the Makefile targets}
    local -a found=()
    local candidate
    for candidate in "${dir}"/guildmaster-[0-9]*."$(rpm --eval '%{_arch}')".rpm; do
        [[ -f ${candidate} ]] && found+=("${candidate}")
    done
    [[ ${#found[@]} -eq 1 ]] ||
        environment_error "expected exactly one guildmaster binary RPM in ${dir}, found ${#found[@]}"
    printf '%s\n' "${found[0]}"
}

# Dump what a reader needs when a service assertion fails.
dump_service_diagnostics() {
    echo '--- systemctl show guildmaster.service'
    systemctl show guildmaster.service \
        --property ActiveState,SubState,Result,ExecMainStatus,MainPID,User,Group || true
    echo '--- journal'
    journalctl --no-pager -b -u guildmaster.service -u modprobe@cuse.service | tail -n 50 || true
    echo '--- devices'
    ls -lZ /dev/cuse /dev/guild 2>&1 || true
    if command -v ausearch >/dev/null 2>&1; then
        echo '--- AVC records since boot'
        ausearch -m avc -ts boot 2>&1 | tail -n 40 || true
    fi
}

finish() {
    if [[ ${failures} -ne 0 ]]; then
        echo "${failures} check(s) failed" >&2
        dump_service_diagnostics
        exit 1
    fi
    echo 'all checks passed'
}
