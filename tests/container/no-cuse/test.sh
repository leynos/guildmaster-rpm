#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
# The container has no CUSE. The documented behaviour is that the start job
# fails on the dev-cuse.device dependency, after the device job's timeout,
# and that the daemon is never executed. This is the only runtime claim the
# container tier makes: it does not show guildmaster operating.
set -uo pipefail
. ../../lib/common.sh

[[ ! -e /dev/cuse ]] ||
    environment_error '/dev/cuse exists in the container fixture; it must not'

# Shorten the wait for a device that will never appear. This configures the
# device unit's job timeout only; guildmaster.service itself is untouched.
mkdir -p /run/systemd/system/dev-cuse.device.d
printf '[Unit]\nJobRunningTimeoutSec=10\n' >/run/systemd/system/dev-cuse.device.d/timeout.conf
systemctl daemon-reload

start_status=0
timeout 120 systemctl start guildmaster.service || start_status=$?
check 'systemctl start reports failure' test "${start_status}" -ne 0
check 'the start was not cut short by the test timeout' test "${start_status}" -ne 124
check_equal 'ActiveState' "$(unit_property ActiveState)" inactive
check_equal 'MainPID' "$(unit_property MainPID)" 0
check_equal 'the daemon was never executed' "$(unit_property ExecMainPID)" 0
check 'the journal records the dependency failure' \
    sh -c "journalctl -b --no-pager -u guildmaster.service | grep -q \"Job guildmaster.service/start failed with result 'dependency'\""
check_not 'no guildmaster process' process_exists guildmaster
check_not 'no /dev/guild' test -e /dev/guild
check_not 'the unit is not left in a failed state that needs resetting' \
    systemctl is-failed --quiet guildmaster.service

check_not 'gm-run fails without the device' gm-run true

rm -rf /run/systemd/system/dev-cuse.device.d
systemctl daemon-reload
finish
