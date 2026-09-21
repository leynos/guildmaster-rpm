#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

check_equal 'the service is running beforehand' "$(unit_property ActiveState)" active
check 'dnf removes the package' dnf -y remove guildmaster

check_not 'the package is gone' rpm -q guildmaster
check_not 'no guildmaster process remains' process_exists guildmaster
check_not '/dev/guild is gone' test -e /dev/guild
check_equal 'systemd no longer knows the unit' "$(unit_property LoadState)" not-found
check_not 'no enablement symlink is left behind' \
    test -e /etc/systemd/system/multi-user.target.wants/guildmaster.service
for path in /usr/bin/guildmaster /usr/bin/gm-run /usr/lib/udev/rules.d/70-guildmaster.rules; do
    check_not "${path} removed" test -e "${path}"
done
check 'edited configuration is kept as .rpmsave' \
    grep -qx 'GUILDMASTER_OPTS="--tokens=2"' /etc/sysconfig/guildmaster.rpmsave
check 'accounts are left in place' sh -c 'getent passwd guildmaster && getent group guild'
echo "/dev/cuse after removal: $(stat -c '%U:%G %a' /dev/cuse 2>&1)"
finish
