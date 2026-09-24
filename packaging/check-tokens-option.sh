#!/usr/bin/env bash
# Exercise guildmaster's downstream --tokens option without CUSE.
#
# Usage: check-tokens-option.sh <path-to-guildmaster>
#
# Invalid values must be rejected with exit status 2 and a diagnostic before
# the daemon touches /dev/cuse, so those cases are safe anywhere. Accepted
# values are only observable through the capacity line the daemon logs before
# it opens /dev/cuse; those cases run only where /dev/cuse cannot be opened,
# so this script can never bring up a real /dev/guild on a build host.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <path-to-guildmaster>" >&2
    exit 2
fi
gm=$1
failures=0

# fail <message>: report a check failure.
#
# Prints "FAIL: <message>" to stderr and increments the shared "failures"
# counter. Always returns 0.
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# expect_rejected <description> <args...>: assert guildmaster rejects <args>.
#
# Runs guildmaster with <args> and calls fail when it does not exit 2 with an
# "invalid --tokens value" diagnostic and no capacity line. Always returns 0.
expect_rejected() {
    local description=$1 status=0 output
    shift
    output=$("${gm}" "$@" 2>&1) || status=$?
    if [[ ${status} -ne 2 ]]; then
        fail "${description}: expected exit status 2, got ${status}: ${output}"
    elif [[ ${output} != *"invalid --tokens value"* ]]; then
        fail "${description}: no diagnostic in: ${output}"
    elif [[ ${output} == *"token pool capacity"* ]]; then
        fail "${description}: a capacity was selected: ${output}"
    else
        echo "ok: rejected ${description}"
    fi
}

# expect_capacity <description> <expected> <args...>: assert the selected
# token pool capacity.
#
# Runs guildmaster with <args> and calls fail unless it exits 1 (no
# /dev/cuse) with a "token pool capacity <expected>" line in its output.
# Always returns 0.
expect_capacity() {
    local description=$1 expected=$2 status=0 output
    shift 2
    output=$("${gm}" "$@" 2>&1) || status=$?
    if [[ ${status} -ne 1 ]]; then
        fail "${description}: expected exit status 1 without /dev/cuse, got ${status}: ${output}"
    elif [[ ${output}$'\n' != *"token pool capacity ${expected}"$'\n'* ]]; then
        fail "${description}: expected capacity ${expected} in: ${output}"
    else
        echo "ok: ${description} selects capacity ${expected}"
    fi
}

expect_rejected 'zero' --tokens=0
expect_rejected 'zero, separate argument' --tokens 0
expect_rejected 'negative' --tokens=-1
expect_rejected 'explicit plus sign' --tokens=+2
expect_rejected 'trailing characters' --tokens=2x
expect_rejected 'leading whitespace' '--tokens= 2'
expect_rejected 'empty' --tokens=
expect_rejected 'hexadecimal' --tokens=0x2
expect_rejected 'fraction' --tokens=2.5
expect_rejected 'one past unsigned long long' --tokens=18446744073709551616
expect_rejected 'far out of range' --tokens=99999999999999999999999
expect_rejected 'attached garbage' --tokensx
expect_rejected 'missing value' -f --tokens

if [[ -r /dev/cuse && -w /dev/cuse ]]; then
    echo 'skip: /dev/cuse is accessible here, so accepted values are not exercised'
else
    default_capacity=$(($(getconf _NPROCESSORS_ONLN) + 1))
    expect_capacity 'no option' "${default_capacity}"
    expect_capacity '--tokens=2' 2 --tokens=2
    expect_capacity '--tokens 2' 2 --tokens 2
    expect_capacity '--tokens=1' 1 --tokens=1
    expect_capacity 'largest value' 18446744073709551615 --tokens=18446744073709551615
    expect_capacity 'last occurrence wins' 6 --tokens=5 --tokens 6
    expect_capacity 'other options preserved' 4 -f --tokens 4 -s
fi

if [[ ${failures} -ne 0 ]]; then
    echo "${failures} check(s) failed" >&2
    exit 1
fi
echo 'all --tokens checks passed'
