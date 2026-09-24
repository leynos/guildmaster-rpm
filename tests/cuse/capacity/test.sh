#!/usr/bin/env bash
# Run the %check option test against the installed daemon in the guest, as
# an ordinary user. That user cannot open /dev/cuse, so the script runs its
# accepted-value cases as well as the rejections, and the daemon can never
# get as far as serving a device. The script is the copy that
# scripts/cuse-guest.sh staged beside the packages.
set -uo pipefail
. ../../lib/common.sh

script=${GM_TOKENS_CHECK:?GM_TOKENS_CHECK is not set; run through scripts/cuse-guest.sh}
[[ -f ${script} ]] || environment_error "no staged option test at ${script}"
rpm -q guildmaster >/dev/null || environment_error 'guildmaster is not installed'

# The staged copy may sit in a directory the unprivileged user cannot read.
copy=$(mktemp /var/tmp/gm-check-tokens.XXXXXX)
install -m 0755 "${script}" "${copy}"
check_not 'nobody cannot open /dev/cuse' runuser -u nobody -- test -w /dev/cuse
check 'option checks pass against /usr/bin/guildmaster as nobody' \
    runuser -u nobody -- bash "${copy}" /usr/bin/guildmaster
rm -f "${copy}"
check_not 'the checks left no daemon behind' process_exists guildmaster
check_not 'and no /dev/guild' test -e /dev/guild
finish
