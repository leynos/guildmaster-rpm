#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

# as_member <command...>: run a command as the unprivileged gm-member user.
as_member() {
    runuser -u gm-member -- "$@"
}

# pool_free: how many tokens can be taken right now, measured without
# blocking and handed straight back.
pool_free() {
    as_member python3 -c '
import os
fd = os.open("/dev/guild", os.O_RDWR | os.O_NONBLOCK)
taken = 0
try:
    while os.read(fd, 1):
        taken += 1
except BlockingIOError:
    pass
print(taken)
'
}

check_equal 'the pool is full beforehand' "$(pool_free)" 2

check_equal 'MAKEFLAGS names the jobserver' \
    "$(as_member gm-run sh -c 'echo "$MAKEFLAGS"')" '--jobserver-auth=fifo:/dev/guild'
check_equal 'existing MAKEFLAGS are kept' \
    "$(as_member env MAKEFLAGS=-k gm-run sh -c 'echo "$MAKEFLAGS"')" '-k --jobserver-auth=fifo:/dev/guild'
check_equal 'gm-run holds one token while the command runs' \
    "$(as_member gm-run python3 -c '
import os
fd = os.open("/dev/guild", os.O_RDWR | os.O_NONBLOCK)
taken = 0
try:
    while os.read(fd, 1):
        taken += 1
except BlockingIOError:
    pass
print(taken)
')" 1

status=0
as_member gm-run sh -c 'exit 7' || status=$?
check_equal 'the exit status of the command is passed through' "${status}" 7
status=0
as_member gm-run sh -c 'kill -TERM $$' || status=$?
check_equal 'death by signal is reported as 128 plus the signal' "${status}" 143
status=0
as_member gm-run /nonexistent/command 2>/dev/null || status=$?
check_equal 'a command that cannot be run gives 1' "${status}" 1
check_equal 'every token came back' "$(pool_free)" 2

# A real jobserver client: GNU Make accepts the jobserver it is handed and
# completes a parallel build through it.
workdir=$(mktemp -d)
chown gm-member "${workdir}"
cat >"${workdir}/Makefile" <<'MAKEFILE'
all: a b c d
a b c d:
	@+echo built $@
MAKEFILE
# No -j here: make takes its parallelism from the jobserver it is handed.
output=$(as_member gm-run make --no-print-directory -C "${workdir}" 2>&1)
echo "${output}"
check_equal 'make built every target under the jobserver' \
    "$(grep -c '^built ' <<<"${output}")" 4
check_not 'make did not reject the jobserver' grep -qi 'jobserver' <<<"${output}"
rm -rf "${workdir}"
check_equal 'the pool is full afterwards' "$(pool_free)" 2
finish
