#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
# Run the same option checks as %check, against the installed executable.
# Without /dev/cuse the daemon can only get as far as choosing its capacity,
# which is all that is asserted here.
set -uo pipefail
. ../../lib/common.sh

[[ ! -e /dev/cuse ]] ||
    environment_error '/dev/cuse exists in the container fixture; it must not'
check 'option checks pass against /usr/bin/guildmaster' \
    bash ../../../packaging/check-tokens-option.sh /usr/bin/guildmaster

default_config=$(grep -v '^#' /etc/sysconfig/guildmaster)
check_equal 'the shipped configuration selects no explicit capacity' \
    "${default_config}" 'GUILDMASTER_OPTS=""'
finish
