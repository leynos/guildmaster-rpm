#!/usr/bin/env bash
# Check that this host can run the rootless systemd container fixtures.
#
# Usage: scripts/podman-preflight.sh
#
# Requires rootless Podman on cgroup v2 with the systemd cgroup manager, a
# functioning systemd user manager, subordinate UID and GID ranges for the
# invoking user, and a user manager that has been delegated at least the pids
# controller. Anything missing is reported by name and the script exits
# non-zero: an unusable fixture host is a failure, never a pass, and nothing
# here falls back to rootful or privileged containers.
#
# The SELinux state is reported, not required. Only a run on an enforcing
# host exercises the container's SELinux confinement; elsewhere the results
# are evidence about distribution userspace only.
#
# Output is one "preflight_event" key=value record per check, then a summary
# record. PODMAN, SYSTEMCTL, GETENFORCE, SUBUID_FILE, SUBGID_FILE,
# CGROUP_ROOT and PREFLIGHT_USER are seams for scripts/tests.
set -euo pipefail

: "${PODMAN:=podman}"
: "${SYSTEMCTL:=systemctl}"
: "${GETENFORCE:=getenforce}"
: "${SUBUID_FILE:=/etc/subuid}"
: "${SUBGID_FILE:=/etc/subgid}"
: "${CGROUP_ROOT:=/sys/fs/cgroup}"
: "${PREFLIGHT_USER:=$(id -un)}"
: "${PREFLIGHT_UID:=$(id -u)}"

failures=0

record() {
    local check=$1 status=$2
    shift 2
    printf 'preflight_event check=%s status=%s' "${check}" "${status}"
    local field
    for field in "$@"; do
        printf ' %s' "${field}"
    done
    printf '\n'
    if [[ ${status} == fail ]]; then
        failures=$((failures + 1))
    fi
}

# expect <check> <actual> <wanted>
expect() {
    if [[ $2 == "$3" ]]; then
        record "$1" ok "value=$2"
    else
        record "$1" fail "value=${2:-unknown}" "required=$3"
    fi
}

info=$("${PODMAN}" info --format \
    '{{.Host.Security.Rootless}} {{.Host.CgroupsVersion}} {{.Host.CgroupManager}} {{.Host.OCIRuntime.Name}} {{.Version.Version}}' \
    2>/dev/null) || info=
if [[ -z ${info} ]]; then
    record podman_info fail 'detail="podman info failed; is Podman installed and usable by this user?"'
else
    read -r rootless cgroups manager runtime version <<<"${info}"
    record podman_info ok "version=${version}" "runtime=${runtime}"
    expect rootless "${rootless}" true
    expect cgroup_version "${cgroups}" v2
    expect cgroup_manager "${manager}" systemd
fi

if "${SYSTEMCTL}" --user show-environment >/dev/null 2>&1; then
    record user_manager ok
else
    record user_manager fail 'detail="systemctl --user cannot reach the user manager; enable lingering or log in through a full session"'
fi

subordinate_range() {
    local file=$1 kind=$2
    if [[ -r ${file} ]] &&
        grep -Eq "^(${PREFLIGHT_USER}|${PREFLIGHT_UID}):[0-9]+:[0-9]+$" "${file}"; then
        record "${kind}" ok
    else
        record "${kind}" fail "detail=\"no entry for ${PREFLIGHT_USER} in ${file}\""
    fi
}
subordinate_range "${SUBUID_FILE}" subuid
subordinate_range "${SUBGID_FILE}" subgid

# systemd inside the container needs a delegated subtree; the pids controller
# is the one the fixtures rely on. The others are reported so that tests of
# resource limits can tell whether they are able to run.
controllers_file="${CGROUP_ROOT}/user.slice/user-${PREFLIGHT_UID}.slice/user@${PREFLIGHT_UID}.service/cgroup.controllers"
if [[ -r ${controllers_file} ]]; then
    controllers=$(tr ' ' ',' <"${controllers_file}")
    if [[ ,${controllers}, == *,pids,* ]]; then
        record delegation ok "controllers=${controllers}"
    else
        record delegation fail "controllers=${controllers:-none}" 'required=pids'
    fi
else
    record delegation fail "detail=\"cannot read ${controllers_file}; the user manager has no delegated cgroup\""
fi

selinux=$("${GETENFORCE}" 2>/dev/null | tr '[:upper:]' '[:lower:]') || selinux=
selinux=${selinux:-absent}
if [[ ${selinux} == enforcing ]]; then
    coverage=confined
else
    coverage=userspace_only
fi
record selinux ok "state=${selinux}" "container_coverage=${coverage}"

if [[ ${failures} -ne 0 ]]; then
    record summary fail "failures=${failures}"
    echo "$0: this host cannot run the rootless systemd fixtures; see the failed checks above" >&2
    exit 1
fi
record summary ok "container_coverage=${coverage}"
