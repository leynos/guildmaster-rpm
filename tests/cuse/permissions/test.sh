#!/usr/bin/env bash
# Each prohibited access is attempted and must fail with EACCES; each
# permitted access must succeed.
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

# Operator actions from the users' guide: an authorized client is a member of
# the guild group. gm-outsider is an ordinary user who is not.
check 'create the authorized test user' useradd --groups guild gm-member
check 'create the unauthorized test user' useradd gm-outsider

# try_open <user> <device>: prints "ok" or the errno name.
try_open() {
    runuser -u "$1" -- python3 -c '
import errno, os, sys
try:
    os.close(os.open(sys.argv[1], os.O_RDWR))
    print("ok")
except OSError as error:
    print(errno.errorcode[error.errno])
' "$2"
}

# others_access <device>: the permission digit for others, or "unreadable"
# when stat fails, so a missing device can never pass for a closed one.
others_access() {
    local mode
    mode=$(stat -c %a "$1" 2>/dev/null) || {
        echo unreadable
        return
    }
    echo "${mode: -1}"
}

check_equal 'a guild member can open /dev/guild' "$(try_open gm-member /dev/guild)" ok
check_equal 'an outsider cannot open /dev/guild' "$(try_open gm-outsider /dev/guild)" EACCES
check_equal 'a guild member cannot open /dev/cuse' "$(try_open gm-member /dev/cuse)" EACCES
check_equal 'an outsider cannot open /dev/cuse' "$(try_open gm-outsider /dev/cuse)" EACCES
check_not 'the daemon account is not a client-group member' \
    sh -c 'id -nG guildmaster | grep -qw guild'
check_not 'the client is not a daemon-group member' \
    sh -c 'id -nG gm-member | grep -qw guildmaster'
check_equal '/dev/cuse grants others no access' "$(others_access /dev/cuse)" 0
check_equal '/dev/guild grants others no access' "$(others_access /dev/guild)" 0
check_not 'an outsider cannot run builds through gm-run' runuser -u gm-outsider -- gm-run true
finish
