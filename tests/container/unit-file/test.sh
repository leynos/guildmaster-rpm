#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
# Verify the unit the RPM installed, not a copy from the source tree.
set -uo pipefail
. ../../lib/common.sh

unit=/usr/lib/systemd/system/guildmaster.service
check 'the unit is installed' test -f "${unit}"
verify_output=$(systemd-analyze --man=no --recursive-errors=yes verify "${unit}" 2>&1)
verify_status=$?
echo "${verify_output}"
check_equal 'systemd-analyze verify exit status' "${verify_status}" 0
check_not 'systemd-analyze verify has nothing to say about guildmaster.service' \
    grep -q 'guildmaster\.service' <<<"${verify_output}"

check_equal 'LoadState' "$(unit_property LoadState)" loaded
check_equal 'FragmentPath' "$(unit_property FragmentPath)" "${unit}"
check_equal 'Type' "$(unit_property Type)" exec
check_equal 'User' "$(unit_property User)" guildmaster
check_equal 'Group' "$(unit_property Group)" guildmaster
check_equal 'NoNewPrivileges' "$(unit_property NoNewPrivileges)" yes
check_equal 'CapabilityBoundingSet is empty' "$(unit_property CapabilityBoundingSet)" ''
check_equal 'DevicePolicy' "$(unit_property DevicePolicy)" closed
# ProtectClock=yes adds read-only access to the real-time clock by itself.
device_allow=$(unit_property DeviceAllow | LC_ALL=C sort | paste -sd, -)
check_equal 'DeviceAllow is /dev/cuse plus the read-only clock' \
    "${device_allow}" '/dev/cuse rw,char-rtc r'
check 'requires the CUSE device unit' \
    sh -c 'systemctl show guildmaster.service -p Requires --value | grep -qw dev-cuse.device'
check 'ordered after the CUSE device unit' \
    sh -c 'systemctl show guildmaster.service -p After --value | grep -qw dev-cuse.device'
check 'wants modprobe@cuse.service' \
    sh -c 'systemctl show guildmaster.service -p Wants --value | grep -qw modprobe@cuse.service'
check 'the modprobe@ template it relies on is shipped by systemd' \
    test -f /usr/lib/systemd/system/modprobe@.service
check_equal 'Restart' "$(unit_property Restart)" on-failure
check 'an invalid --tokens value does not cause a restart loop' \
    sh -c 'systemctl show guildmaster.service -p RestartPreventExitStatus --value | grep -qw 2'
check 'reads the operator configuration file, optionally' \
    sh -c 'systemctl show guildmaster.service -p EnvironmentFiles --value | grep -q "^/etc/sysconfig/guildmaster (ignore_errors=yes)"'

exec_path=$(systemctl show guildmaster.service -p ExecStart --value | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
check_equal 'ExecStart path' "${exec_path}" /usr/bin/guildmaster
check 'ExecStart path is executable and owned by the package' \
    sh -c "test -x '${exec_path}' && rpm -qf '${exec_path}' | grep -q '^guildmaster-'"
check 'ExecStart passes GUILDMASTER_OPTS' \
    grep -qx 'ExecStart=/usr/bin/guildmaster $GUILDMASTER_OPTS' "${unit}"

check 'udev rules restrict /dev/guild to the guild group' \
    grep -qx 'KERNEL=="guild", SUBSYSTEM=="cuse", GROUP="guild", MODE="0660"' \
    /usr/lib/udev/rules.d/70-guildmaster.rules
check_not 'no world-accessible device mode is shipped' \
    grep -E 'MODE="0?[0-7]{2}[1-7]"' /usr/lib/udev/rules.d/70-guildmaster.rules
finish
