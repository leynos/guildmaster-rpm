#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
# Install the package under test into a fixture that must not already contain
# any part of it, then check what was installed.
set -uo pipefail
. ../../lib/common.sh

rpm_file=$(rpm_under_test) || exit 2
arch=$(rpm --eval '%{_arch}')
dist=$(rpm --eval '%{?dist}')

# The fixture must not hide a broken package.
check_not 'guildmaster is not installed beforehand' rpm -q guildmaster
check_not 'no guildmaster account beforehand' getent passwd guildmaster
check_not 'no guildmaster group beforehand' getent group guildmaster
check_not 'no guild group beforehand' getent group guild
for path in /usr/lib/systemd/system/guildmaster.service /etc/sysconfig/guildmaster \
    /usr/lib/udev/rules.d/70-guildmaster.rules /dev/guild; do
    check_not "${path} absent beforehand" test -e "${path}"
done
[[ ${failures} -eq 0 ]] || environment_error 'the fixture already contains guildmaster state'

echo "package under test: $(sha256sum "${rpm_file}")"
# Container base images set tsflags=nodocs, which would leave out the manual
# pages, licence and README that this test is here to check.
check 'dnf installs the package' dnf -y --setopt=tsflags= install "${rpm_file}"

check_equal 'name' "$(rpm -q --qf '%{NAME}' guildmaster)" guildmaster
check_equal 'epoch' "$(rpm -q --qf '%{EPOCH}' guildmaster)" '(none)'
check_equal 'version' "$(rpm -q --qf '%{VERSION}' guildmaster)" '0.1^20251202git463382b'
check_equal 'release carries the dist tag' "$(rpm -q --qf '%{RELEASE}' guildmaster)" "1${dist}"
check_equal 'architecture is native' "$(rpm -q --qf '%{ARCH}' guildmaster)" "${arch}"
check_equal 'licence' "$(rpm -q --qf '%{LICENSE}' guildmaster)" ISC
case ${GM_TARGET:-} in
fedora-43) check_equal 'dist tag for the target' "${dist}" .fc43 ;;
rocky-10) check_equal 'dist tag for the target' "${dist}" .el10 ;;
*) fail "unknown GM_TARGET '${GM_TARGET:-}'" ;;
esac

# The payload, exactly. Build-id links vary with the build and are checked
# by location only.
expected=$(
    cat <<'LIST'
/etc/sysconfig/guildmaster
/usr/bin/gm-run
/usr/bin/guildmaster
/usr/lib/systemd/system/guildmaster.service
/usr/lib/sysusers.d/guildmaster.conf
/usr/lib/udev/rules.d/70-guildmaster.rules
/usr/share/doc/guildmaster
/usr/share/doc/guildmaster/README.md
/usr/share/licenses/guildmaster
/usr/share/licenses/guildmaster/LICENSE
/usr/share/man/man1/gm-run.1.gz
/usr/share/man/man8/guildmaster.8.gz
LIST
)
actual=$(rpm -ql guildmaster | grep -v '^/usr/lib/\.build-id' | LC_ALL=C sort)
check_equal 'payload' "${actual}" "${expected}"
check_not 'nothing from a build tree or /usr/local' \
    sh -c "rpm -ql guildmaster | grep -E 'BUILD|/usr/local|/builddir|/root|/tmp'"

# path mode owner group
while read -r path mode owner group; do
    check_equal "mode of ${path}" "$(stat -c '%a %U %G' "${path}")" "${mode} ${owner} ${group}"
done <<'MODES'
/etc/sysconfig/guildmaster 644 root root
/usr/bin/gm-run 755 root root
/usr/bin/guildmaster 755 root root
/usr/lib/systemd/system/guildmaster.service 644 root root
/usr/lib/sysusers.d/guildmaster.conf 644 root root
/usr/lib/udev/rules.d/70-guildmaster.rules 644 root root
MODES
check 'rpm -V reports nothing' sh -c '[ -z "$(rpm -V guildmaster)" ]'
check_equal 'the sysconfig file is the only config file' \
    "$(rpm -qc guildmaster)" /etc/sysconfig/guildmaster
check 'licence is marked as such' sh -c 'rpm -qL guildmaster | grep -qx /usr/share/licenses/guildmaster/LICENSE'

requires=$(rpm -qR guildmaster)
check 'requires libfuse3' grep -q '^libfuse3\.so\.3' <<<"${requires}"
check 'scriptlets require systemd' grep -q '^systemd' <<<"${requires}"
check_not 'does not require a -devel package' grep -q -- '-devel' <<<"${requires}"
check 'libfuse3 was installed as a dependency' rpm -q fuse3-libs

# Accounts, from sysusers.d.
check_equal 'daemon account' \
    "$(getent passwd guildmaster | cut -d: -f1,5,6,7)" \
    'guildmaster:Guildmaster jobserver daemon:/:/usr/sbin/nologin'
check 'daemon account is a system account' \
    sh -c '[ "$(id -u guildmaster)" -lt 1000 ]'
check_equal 'daemon primary group' "$(id -gn guildmaster)" guildmaster
check 'client group exists' getent group guild
check_equal 'client group starts empty' "$(getent group guild | cut -d: -f4)" ''
check_not 'daemon is not a client-group member' sh -c 'id -nG guildmaster | grep -qw guild'

# Installing must not activate anything.
check_equal 'unit file state' "$(systemctl is-enabled guildmaster.service)" disabled
check_equal 'ActiveState' "$(unit_property ActiveState)" inactive
check_equal 'MainPID' "$(unit_property MainPID)" 0
check_not 'no /dev/guild' test -e /dev/guild

check 'gm-run is on PATH' command -v gm-run
check 'man pages are installed' sh -c 'test -s /usr/share/man/man8/guildmaster.8.gz && test -s /usr/share/man/man1/gm-run.1.gz'
finish
