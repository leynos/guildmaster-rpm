#!/usr/bin/env bash
# Install the package on a host where the cuse module is already loaded and
# /dev/cuse already exists with the distribution's default ownership. The
# package's udev rule must reach that existing device at installation, with
# no reboot, module reload or manual udev trigger by the operator.
#
# This runs after tests/cuse/removal, so the package is absent.
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

rpm -q guildmaster >/dev/null 2>&1 && environment_error 'guildmaster is still installed'
[[ -e /usr/lib/udev/rules.d/70-guildmaster.rules ]] &&
    environment_error 'the package rule is still present'
# Recreate the state of a host that loaded cuse before the package existed.
# /dev/cuse is a static node that survives unloading the module, and the
# removed rule's static_node option has already given it the package's
# group, so reset it to the distribution default (root:root 0600) and
# replay udev without the rule, which drops the rule's systemd tag. This is
# scenario set-up: it takes away what the package did, it does not add
# anything the package should do.
udevadm control --reload
grep -qw '^cuse' /proc/modules || modprobe cuse || environment_error 'modprobe cuse failed'
chown root:root /dev/cuse
chmod 0600 /dev/cuse
udevadm trigger --action=change --name-match=/dev/cuse --settle
[[ $(stat -c '%U:%G %a' /dev/cuse) == 'root:root 600' ]] ||
    environment_error "/dev/cuse is $(stat -c '%U:%G %a' /dev/cuse), not the distribution default"
pass 'set-up: cuse is loaded and /dev/cuse has the distribution default root:root 600'

rpm_file=$(rpm_under_test) || exit 2
check 'dnf installs the package' dnf -y --setopt=tsflags= install "${rpm_file}"

check_equal '/dev/cuse takes the package rule at installation' \
    "$(stat -c '%U:%G %a' /dev/cuse)" 'root:guildmaster 660'
check 'the device is tagged for systemd' \
    wait_for 10 sh -c '[ "$(systemctl show dev-cuse.device -p ActiveState --value)" = active ]'

echo 'GUILDMASTER_OPTS="--tokens=2"' >/etc/sysconfig/guildmaster
check 'the service starts without a reboot' systemctl start guildmaster.service
check_equal 'ActiveState' "$(unit_property ActiveState)" active
check 'the daemon created /dev/guild' wait_for 10 test -c /dev/guild
check 'the service stops' systemctl stop guildmaster.service
check 'dnf removes the package again' dnf -y remove guildmaster
finish
