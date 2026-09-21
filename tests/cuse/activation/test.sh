#!/usr/bin/env bash
# Follow the users' guide: set the capacity, enable and start the service.
# Nothing here repairs the package: no chmod, chown, mknod, modprobe, unit
# override, setenforce or policy module.
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

check_not 'cuse is not loaded before activation' grep -qw '^cuse' /proc/modules

# Operator action: choose capacity two.
cat >/etc/sysconfig/guildmaster <<'CONFIG'
GUILDMASTER_OPTS="--tokens=2"
CONFIG
# Operator action: activate.
check 'systemctl enable --now succeeds' systemctl enable --now guildmaster.service

check_equal 'ActiveState' "$(unit_property ActiveState)" active
check_equal 'SubState' "$(unit_property SubState)" running
check_equal 'Result' "$(unit_property Result)" success
check_equal 'NRestarts' "$(unit_property NRestarts)" 0
main_pid=$(unit_property MainPID)
check 'MainPID is set' test "${main_pid}" -gt 0
check_equal 'the daemon runs as its own account' \
    "$(stat -c '%U:%G' "/proc/${main_pid}")" guildmaster:guildmaster
check_equal 'the daemon was given the configured option' \
    "$(tr '\0' ' ' <"/proc/${main_pid}/cmdline")" '/usr/bin/guildmaster --tokens=2 '
check 'the daemon logged capacity two' \
    sh -c 'journalctl -b --no-pager -u guildmaster.service | grep -q "token pool capacity 2$"'

check 'starting the service loaded cuse on demand' grep -qw '^cuse' /proc/modules
udevadm settle --timeout=10
check_equal '/dev/cuse is restricted to the daemon group' \
    "$(stat -c '%U:%G %a %F' /dev/cuse)" 'root:guildmaster 660 character special file'
check_equal '/dev/guild is restricted to the client group' \
    "$(stat -c '%U:%G %a %F' /dev/guild)" 'root:guild 660 character special file'

# Recorded as evidence, not asserted: the package ships no SELinux policy, so
# the domain is whatever the distribution's policy gives an ordinary service.
{
    echo "daemon_selinux_context: $(tr -d '\0' <"/proc/${main_pid}/attr/current")"
    echo "dev_cuse_after_activation: $(stat -c '%U:%G %a %C' /dev/cuse)"
    echo "dev_guild_after_activation: $(stat -c '%U:%G %a %C' /dev/guild)"
} | tee -a "${GM_GUEST_FACTS:?}"
denials=$(ausearch -m avc,user_avc -ts boot 2>/dev/null | grep -E 'guild|cuse' || true)
check_equal 'no AVC denials mention guildmaster or CUSE' "${denials}" ''
check_equal 'SELinux is still enforcing' "$(getenforce)" Enforcing
finish
