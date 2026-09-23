#!/usr/bin/env bash
# Environment preflight, run before the package is installed. It may reboot
# the guest once, through tmt, if the CUSE module is only available for a
# newer kernel than the image booted.
set -uo pipefail
. ../../lib/common.sh

facts=${GM_GUEST_FACTS:?}
kernel=$(uname -r)

[[ $(cat /proc/1/comm) == systemd ]] || environment_error 'PID 1 is not systemd'
[[ $(getenforce) == Enforcing ]] || environment_error "SELinux is $(getenforce), not Enforcing"

# The prepared state must not contain anything the package is meant to bring.
getent passwd guildmaster >/dev/null && environment_error 'account guildmaster already exists'
for group in guildmaster guild; do
    getent group "${group}" >/dev/null && environment_error "group ${group} already exists"
done
rpm -q guildmaster >/dev/null 2>&1 && environment_error 'guildmaster is already installed'
for path in /usr/lib/systemd/system/guildmaster.service /etc/systemd/system/guildmaster.service \
    /etc/systemd/system/guildmaster.service.d /etc/sysconfig/guildmaster /dev/guild; do
    [[ -e ${path} ]] && environment_error "${path} already exists"
done
grep -rqs guild /usr/lib/udev/rules.d /etc/udev/rules.d &&
    environment_error 'a udev rule mentioning guild already exists'
# Nothing but the package may be responsible for CUSE being loaded later.
grep -rqsw cuse /etc/modules-load.d /usr/lib/modules-load.d /run/modules-load.d &&
    environment_error 'a modules-load.d entry already loads cuse'
semodule -l 2>/dev/null | grep -qi guild &&
    environment_error 'an SELinux module mentioning guild is already loaded'

# The module must match the kernel that runs the tests. Discover which
# package ships it rather than assuming a name.
if ! modinfo cuse >/dev/null 2>&1; then
    provider=
    for candidate in kernel-modules-core kernel-modules kernel-modules-extra; do
        if dnf -q repoquery -l "${candidate}-${kernel}" 2>/dev/null | grep -q '/fs/fuse/cuse\.ko'; then
            provider=${candidate}
            break
        fi
    done
    if [[ -n ${provider} ]]; then
        dnf -y install "${provider}-${kernel}" ||
            environment_error "could not install ${provider}-${kernel}"
    elif [[ ${TMT_REBOOT_COUNT:-0} -eq 0 ]]; then
        # No package carries cuse.ko for the booted kernel any more. Move to
        # the current kernel and its modules, then reboot into it.
        dnf -y install kernel kernel-modules-extra ||
            environment_error 'could not install a current kernel with its extra modules'
        tmt-reboot
        # tmt-reboot does not return when the reboot is accepted.
        environment_error 'tmt-reboot returned without rebooting the guest'
    else
        environment_error "no cuse.ko for the running kernel ${kernel}, even after a kernel update and reboot"
    fi
fi
modinfo cuse >/dev/null 2>&1 || environment_error "cuse.ko is not available for ${kernel}"
module_package=$(rpm -qf "$(modinfo -n cuse)")

modprobe cuse || environment_error 'modprobe cuse failed'
udevadm settle --timeout=10
[[ -c /dev/cuse ]] || environment_error '/dev/cuse is not a character device after modprobe'

{
    echo "os: $(. /etc/os-release && echo "${PRETTY_NAME}")"
    echo "kernel: ${kernel}"
    echo "reboots_for_kernel: ${TMT_REBOOT_COUNT:-0}"
    echo "cuse_module_package: ${module_package}"
    echo "processors: $(nproc)"
    echo "memory_mib: $(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
    echo "selinux: $(getenforce)"
    echo "selinux_policy: $(rpm -q selinux-policy)"
    echo "systemd: $(rpm -q systemd)"
    echo "fuse3_libs_preinstalled: $(rpm -q fuse3-libs 2>/dev/null || echo no)"
    echo "dev_cuse_before_package: $(stat -c '%U:%G %a' /dev/cuse) $(stat -c '%C' /dev/cuse)"
} | tee "${facts}"

# Leave CUSE unloaded, so that loading it later is the package's doing.
modprobe -r cuse || environment_error 'could not unload cuse again'
check_not 'cuse is unloaded again' grep -qw '^cuse' /proc/modules
finish
