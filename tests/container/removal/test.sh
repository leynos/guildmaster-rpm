#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

check 'the package is installed and enabled from the upgrade test' \
    sh -c 'rpm -q guildmaster && [ "$(systemctl is-enabled guildmaster.service)" = enabled ]'
check 'dnf removes the package' dnf -y remove guildmaster

check_not 'the package is gone' rpm -q guildmaster
for path in /usr/bin/guildmaster /usr/bin/gm-run \
    /usr/lib/systemd/system/guildmaster.service \
    /usr/lib/udev/rules.d/70-guildmaster.rules \
    /usr/lib/sysusers.d/guildmaster.conf; do
    check_not "${path} removed" test -e "${path}"
done
check_not 'no enablement symlink is left behind' \
    test -e /etc/systemd/system/multi-user.target.wants/guildmaster.service
check_equal 'systemd no longer knows the unit' "$(unit_property LoadState)" not-found
# RPM keeps a modified %config(noreplace) file as .rpmsave.
check 'edited configuration is kept as .rpmsave' test -f /etc/sysconfig/guildmaster.rpmsave
check 'and still holds the operator setting' \
    grep -qx 'GUILDMASTER_OPTS="--tokens=2"' /etc/sysconfig/guildmaster.rpmsave
# Distribution practice: accounts are not deleted on removal, so that any
# files they own never become owned by a recycled UID.
check 'the service account is left in place' getent passwd guildmaster
finish
