#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
# Upgrade to the higher-release rebuild made by
# scripts/build-upgrade-fixture.sh. Whether an upgrade leaves a *running*
# daemon alone can only be shown with CUSE; see tests/cuse. Here: the
# operator's configuration and enablement survive, and nothing is started.
set -uo pipefail
. ../../lib/common.sh

upgrade_dir=${GM_UPGRADE_RPM_DIR:?}
upgrade_rpm=$(find "${upgrade_dir}" -maxdepth 1 -name "guildmaster-[0-9]*.$(rpm --eval '%{_arch}').rpm")
[[ -f ${upgrade_rpm} ]] || environment_error "no upgrade fixture package in ${upgrade_dir}"

before=$(rpm -q guildmaster)
cat >/etc/sysconfig/guildmaster <<'CONFIG'
# Written by the upgrade test, standing in for Ansible.
GUILDMASTER_OPTS="--tokens=2"
CONFIG
config_sum=$(sha256sum </etc/sysconfig/guildmaster)
# A documented operator action, so that the upgrade has a state to preserve.
check 'the operator enables the service' systemctl enable guildmaster.service

check 'dnf upgrades the package' dnf -y upgrade "${upgrade_rpm}"
after=$(rpm -q guildmaster)
check 'the installed release changed' test "${before}" != "${after}"
check 'only one guildmaster is installed' sh -c '[ "$(rpm -q guildmaster | wc -l)" -eq 1 ]'

check_equal 'operator configuration is byte-identical' \
    "$(sha256sum </etc/sysconfig/guildmaster)" "${config_sum}"
check_not 'no .rpmsave: the operator file was not displaced' test -e /etc/sysconfig/guildmaster.rpmsave
check_equal 'enablement survives' "$(systemctl is-enabled guildmaster.service)" enabled
check_equal 'the upgrade started nothing' "$(unit_property ActiveState)" inactive
check_equal 'accounts are unchanged' "$(id -un guildmaster):$(getent group guild | cut -d: -f1)" guildmaster:guild
check 'rpm -V reports only the edited configuration' \
    sh -c 'out=$(rpm -V guildmaster | grep -v " c /etc/sysconfig/guildmaster$"); [ -z "$out" ]'
finish
