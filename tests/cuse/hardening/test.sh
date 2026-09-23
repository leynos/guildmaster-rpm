#!/usr/bin/env bash
# A directive in the unit file is a request, not proof. This test claims only
# what the kernel reports for the live daemon process, plus prohibited
# operations attempted from inside the service's own namespaces and cgroup
# as the service's own user. Directives not covered here are configured but
# unverified, and the documentation says so.
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

pid=$(unit_property MainPID)
[[ ${pid} -gt 0 ]] || environment_error 'guildmaster is not running'
status_field() {
    sed -n "s/^$1:[[:space:]]*//p" "/proc/${pid}/status"
}

uid=$(id -u guildmaster)
check_equal 'real, effective, saved and filesystem UIDs are the service account' \
    "$(status_field Uid | tr -s '\t ' ' ')" "${uid} ${uid} ${uid} ${uid}"
check_equal 'NoNewPrivs' "$(status_field NoNewPrivs)" 1
check_equal 'seccomp filter mode' "$(status_field Seccomp)" 2
check_equal 'bounding capabilities' "$(status_field CapBnd)" 0000000000000000
check_equal 'effective capabilities' "$(status_field CapEff)" 0000000000000000
check_equal 'permitted capabilities' "$(status_field CapPrm)" 0000000000000000
check_equal 'ambient capabilities' "$(status_field CapAmb)" 0000000000000000
check 'the daemon has its own mount namespace' \
    sh -c "[ \"\$(readlink /proc/${pid}/ns/mnt)\" != \"\$(readlink /proc/1/ns/mnt)\" ]"
check 'the daemon has its own network namespace' \
    sh -c "[ \"\$(readlink /proc/${pid}/ns/net)\" != \"\$(readlink /proc/1/ns/net)\" ]"

# Attempt prohibited operations from the service's context: enter the
# daemon's mount and network namespaces and drop to its user.
in_service() {
    nsenter --target "${pid}" --mount --net -- \
        setpriv --reuid guildmaster --regid guildmaster --clear-groups --no-new-privs "$@"
}
check 'the probe really runs as the service account' \
    sh -c "[ \"\$(nsenter --target ${pid} --mount --net -- setpriv --reuid guildmaster --regid guildmaster --clear-groups id -un)\" = guildmaster ]"
# The file-system protections are probed as root inside the daemon's mount
# namespace, so that file permissions cannot be what makes them hold.
in_service_mounts() {
    nsenter --target "${pid}" --mount -- "$@"
}
check 'control: root can write to /etc in the host view' \
    sh -c 'touch /etc/gm-hardening-control && rm /etc/gm-hardening-control'
check_not 'ProtectSystem: /etc is read-only, even for root' \
    in_service_mounts touch /etc/gm-hardening-probe
check_not 'ProtectSystem: /usr is read-only, even for root' \
    in_service_mounts touch /usr/gm-hardening-probe
check 'control: the member home exists in the host view' test -d /home/gm-member
# Listing must succeed, so that an empty result means an empty directory
# and not an error.
if home_listing=$(in_service_mounts ls -A /home); then
    check_equal 'ProtectHome: /home appears empty, even to root' "${home_listing}" ''
else
    fail 'ProtectHome: root could not list /home in the service mount namespace'
fi
check_equal 'PrivateNetwork: only loopback exists' \
    "$(in_service ls /sys/class/net | paste -sd' ')" lo
check_not 'no probe file leaked into the host view' test -e /etc/gm-hardening-probe -o -e /usr/gm-hardening-probe

# DevicePolicy=closed is enforced by a BPF program on the service's cgroup,
# so the probe has to run inside that cgroup; a transient unit would not be.
# A short-lived root shell moves itself there and then opens the device.
cgroup=$(unit_property ControlGroup)
probe_device() {
    # Runs as root, so that file permissions cannot be what stops it.
    sh -c "echo \$\$ >/sys/fs/cgroup${cgroup}/cgroup.procs && exec head -c1 $1 >/dev/null"
}
if [[ -w /sys/fs/cgroup${cgroup}/cgroup.procs ]]; then
    check_not 'DevicePolicy: a process in the service cgroup cannot read /dev/kmsg' probe_device /dev/kmsg
    check 'DevicePolicy: the same probe may read /dev/null (control)' probe_device /dev/null
else
    fail "cannot enter the service cgroup ${cgroup} to test DevicePolicy"
fi
finish
