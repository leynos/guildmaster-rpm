#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

# pool_free: how many tokens can be taken right now, measured without
# blocking and handed straight back.
pool_free() {
    runuser -u gm-member -- python3 -c '
import os
fd = os.open("/dev/guild", os.O_RDWR | os.O_NONBLOCK)
taken = 0
try:
    while os.read(fd, 1):
        taken += 1
except BlockingIOError:
    pass
print(taken)
'
}

# This test starts the unit more often than an operator would inside
# systemd's start-rate window (five starts in ten seconds). reset-failed
# clears that counter; it changes nothing about the unit.
systemctl reset-failed guildmaster.service 2>/dev/null || true

# --- stop and start
check 'systemctl stop succeeds' systemctl stop guildmaster.service
check_equal 'ActiveState after stop' "$(unit_property ActiveState)" inactive
check_equal 'Result after stop' "$(unit_property Result)" success
check 'the device node is removed with the daemon' wait_for 10 test ! -e /dev/guild
check_not 'clients fail cleanly while it is stopped' runuser -u gm-member -- gm-run true
check 'systemctl start succeeds' systemctl start guildmaster.service
check 'the device node returns' wait_for 10 test -c /dev/guild
udevadm settle --timeout=10
check_equal '/dev/guild permissions are reapplied' "$(stat -c '%U:%G %a' /dev/guild)" 'root:guild 660'
check_equal 'a fresh pool has full capacity' "$(pool_free)" 2

# --- the documented drain and restart procedure
# A long-running client, holding the device open with one token.
coproc HOLDER { runuser -u gm-member -- python3 ../accounting/gmclient.py; }
echo open >&"${HOLDER[1]}"
read -r -t 20 -u "${HOLDER[0]}" answer
check_equal 'holder opened the device' "${answer}" 'opened 1'
echo 'take 1' >&"${HOLDER[1]}"
read -r -t 20 -u "${HOLDER[0]}" answer
check_equal 'holder took a token' "${answer}" token

# Step 1 of the procedure: look for open handles before restarting.
check 'fuser reports the open handle' fuser --silent /dev/guild
old_pid=$(unit_property MainPID)

# What the procedure protects against: restarting anyway.
check 'restart succeeds' systemctl restart guildmaster.service
check 'the device node returns' wait_for 10 test -c /dev/guild
check 'the daemon is a new process' test "$(unit_property MainPID)" -ne "${old_pid}"
check_equal 'the new pool is full: the old holder is not counted against it' "$(pool_free)" 2
echo 'give 1' >&"${HOLDER[1]}"
read -r -t 20 -u "${HOLDER[0]}" answer
check 'the old handle is dead, so its holder cannot take part in the new pool' \
    sh -c "case '${answer}' in error*) exit 0 ;; *) exit 1 ;; esac"
echo "stale handle answered: ${answer}"
echo exit >&"${HOLDER[1]}"
wait "${HOLDER_PID}" 2>/dev/null || true

# Drained: no handles, so a restart disturbs nobody.
check_not 'fuser reports no open handles once clients have finished' fuser --silent /dev/guild

# --- crash recovery
systemctl reset-failed guildmaster.service 2>/dev/null || true
old_pid=$(unit_property MainPID)
kill -KILL "${old_pid}"
check 'systemd restarts the daemon after a crash' \
    wait_for 30 sh -c '[ "$(systemctl show guildmaster.service -p ActiveState --value)" = active ] && [ "$(systemctl show guildmaster.service -p MainPID --value)" -ne '"${old_pid}"' ]'
check_equal 'NRestarts counts the recovery' "$(unit_property NRestarts)" 1
check 'the device node returns' wait_for 10 test -c /dev/guild
check_equal 'the recovered pool is full' "$(pool_free)" 2

# --- invalid configuration
cp /etc/sysconfig/guildmaster /etc/sysconfig/guildmaster.good
echo 'GUILDMASTER_OPTS="--tokens=0"' >/etc/sysconfig/guildmaster
systemctl reset-failed guildmaster.service 2>/dev/null || true
# With Type=exec the start job succeeds as soon as the daemon has been
# executed; the rejection of the value follows immediately afterwards. So the
# assertion is on the unit's state, not on systemctl's exit status.
systemctl restart guildmaster.service || true
check 'the unit fails with an invalid capacity' \
    wait_for 20 systemctl is-failed --quiet guildmaster.service
check_equal 'ActiveState with invalid capacity' "$(unit_property ActiveState)" failed
check_equal 'Result' "$(unit_property Result)" exit-code
check_equal 'ExecMainStatus is the documented 2' "$(unit_property ExecMainStatus)" 2
check_equal 'no restart loop' "$(unit_property NRestarts)" 0
check 'the journal carries the diagnostic' \
    sh -c 'journalctl -b --no-pager -u guildmaster.service | grep -q "invalid --tokens value .0."'
check_not 'no device node' test -e /dev/guild
mv /etc/sysconfig/guildmaster.good /etc/sysconfig/guildmaster
systemctl reset-failed guildmaster.service
check 'the service starts again with the good configuration' systemctl restart guildmaster.service
check 'the device node returns' wait_for 10 test -c /dev/guild
check_equal 'capacity is two again' "$(pool_free)" 2
finish
