#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

upgrade_rpm=$(find "${GM_UPGRADE_RPM_DIR:?}" -maxdepth 1 -name "guildmaster-[0-9]*.$(rpm --eval '%{_arch}').rpm")
[[ -f ${upgrade_rpm} ]] || environment_error "no upgrade fixture package in ${GM_UPGRADE_RPM_DIR}"

# See service-lifecycle: keep this test's restarts out of the start-rate window.
systemctl reset-failed guildmaster.service 2>/dev/null || true

coproc HOLDER { runuser -u gm-member -- python3 ../accounting/gmclient.py; }
say() {
    echo "$1" >&"${HOLDER[1]}"
    read -r -t 20 -u "${HOLDER[0]}" answer
}
say open
say 'take 1'
check_equal 'a client holds a token before the upgrade' "${answer}" token

pid_before=$(unit_property MainPID)
config_sum=$(sha256sum </etc/sysconfig/guildmaster)
before=$(rpm -q guildmaster)
check 'dnf upgrades the package' dnf -y upgrade "${upgrade_rpm}"
check 'the installed release changed' test "$(rpm -q guildmaster)" != "${before}"

check_equal 'the daemon was not restarted' "$(unit_property MainPID)" "${pid_before}"
check_equal 'ActiveState' "$(unit_property ActiveState)" active
check_equal 'operator configuration is byte-identical' "$(sha256sum </etc/sysconfig/guildmaster)" "${config_sum}"
check_equal 'enablement survives' "$(systemctl is-enabled guildmaster.service)" enabled
say 'try 1'
check_equal 'the client can still take the second token' "${answer}" token
say 'try 1'
check_equal 'and the pool is then empty: accounting was not reset' "${answer}" empty
say 'give 1'
say 'give 1'
check_equal 'the client can return its tokens' "${answer}" gave
echo exit >&"${HOLDER[1]}"
wait "${HOLDER_PID}" 2>/dev/null || true

# The running process is still the old executable; the documented procedure
# after an upgrade is to drain and restart.
check 'the old executable is still what is running' \
    sh -c "readlink /proc/${pid_before}/exe | grep -q '(deleted)'"
check_not 'drained: no open handles' fuser --silent /dev/guild
check 'restart after draining' systemctl restart guildmaster.service
new_pid=$(unit_property MainPID)
check_equal 'the new executable is now running' "$(readlink "/proc/${new_pid}/exe")" /usr/bin/guildmaster
check 'the daemon still logs capacity two' \
    sh -c "journalctl -b --no-pager _PID=${new_pid} | grep -q 'token pool capacity 2\$'"
finish
