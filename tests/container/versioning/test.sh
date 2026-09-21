#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
# Upstream has no tags; the package is 0.1^<date>git<commit>. Show with RPM's
# comparison that this needs no epoch: it is newer than plain 0.1, older than
# a later snapshot, a later packaging release and any future upstream
# version.
set -uo pipefail
. ../../lib/common.sh

vercmp() {
    rpm --eval "%{lua: print(rpm.vercmp('$1', '$2'))}"
}

snapshot='0.1^20251202git463382b'
check_equal 'same version' "$(vercmp "${snapshot}" "${snapshot}")" 0
check_equal 'newer than the 0.1 it follows' "$(vercmp "${snapshot}" 0.1)" 1
check_equal 'older than a later snapshot' "$(vercmp "${snapshot}" '0.1^20260301gitabcdef0')" -1
check_equal 'older than upstream 0.1.1' "$(vercmp "${snapshot}" 0.1.1)" -1
check_equal 'older than upstream 0.2' "$(vercmp "${snapshot}" 0.2)" -1
check_equal 'older than upstream 1.0' "$(vercmp "${snapshot}" 1.0)" -1
check_equal 'a tilde pre-release of 0.2 is still newer' "$(vercmp "${snapshot}" '0.2~rc1')" -1
check_equal 'packaging release 2 is newer than 1' "$(vercmp 2 1)" 1

installed_version=$(rpm -q --qf '%{VERSION}' guildmaster)
check_equal 'the installed package uses this scheme' "${installed_version}" "${snapshot}"
finish
