#!/usr/bin/env bash
# The package promises that an enabled guildmaster.service comes up at boot,
# loading cuse on demand. After the reboot this test runs no modprobe and
# starts nothing.
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

if [[ ${TMT_REBOOT_COUNT:-0} -eq 0 ]]; then
    check_equal 'the service is enabled before the reboot' "$(systemctl is-enabled guildmaster.service)" enabled
    check_not 'nothing else is set to load cuse at boot' \
        grep -rqsw cuse /etc/modules-load.d /usr/lib/modules-load.d /run/modules-load.d
    [[ ${failures} -eq 0 ]] || finish
    uname -r >/var/tmp/gm-kernel-before-reboot
    tmt-reboot
fi

check_equal 'the same kernel is running' "$(uname -r)" "$(cat /var/tmp/gm-kernel-before-reboot)"
check_equal 'SELinux is enforcing' "$(getenforce)" Enforcing
check 'boot finished' timeout 180 systemctl is-system-running --wait
check_equal 'ActiveState' "$(unit_property ActiveState)" active
check_equal 'SubState' "$(unit_property SubState)" running
check_equal 'NRestarts' "$(unit_property NRestarts)" 0
check 'cuse was loaded during boot' grep -qw '^cuse' /proc/modules
check_equal '/dev/cuse' "$(stat -c '%U:%G %a' /dev/cuse)" 'root:guildmaster 660'
check_equal '/dev/guild' "$(stat -c '%U:%G %a' /dev/guild)" 'root:guild 660'
check_equal 'a member can run a command under the jobserver' \
    "$(runuser -u gm-member -- gm-run sh -c 'echo "$MAKEFLAGS"')" '--jobserver-auth=fifo:/dev/guild'
check_not 'an outsider still cannot' runuser -u gm-outsider -- gm-run true
denials=$(ausearch -m avc,user_avc -ts boot 2>/dev/null | grep -E 'guild|cuse' || true)
check_equal 'no AVC denials mention guildmaster or CUSE since boot' "${denials}" ''
finish
