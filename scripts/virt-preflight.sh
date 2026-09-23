#!/usr/bin/env bash
# Check that this host can run the CUSE acceptance guests.
#
# Usage: scripts/virt-preflight.sh
#
# Requires tmt's virtual provisioner (testcloud), a reachable libvirt user
# session (qemu:///session), hardware virtualization through /dev/kvm that
# libvirt itself reports as usable, and enough free disk for the image cache
# and the per-run overlays. If this host is itself a virtual machine, that
# means nested virtualization must be exposed to it.
#
# Anything missing is reported by name and the script exits non-zero. There is
# no fallback: not to the system libvirt connection, not to rootful or
# privileged execution, and not to software emulation (TCG), whose timing and
# coverage are not what the acceptance tier claims.
#
# Output is one "preflight_event" record per check and a summary. TMT, VIRSH,
# PYTHON, KVM_DEVICE, DF and the *_DIR variables are seams for scripts/tests.
set -euo pipefail

: "${TMT:=tmt}"
: "${VIRSH:=virsh}"
: "${PYTHON:=python3}"
: "${KVM_DEVICE:=/dev/kvm}"
: "${IMAGE_CACHE_DIR:=${XDG_CACHE_HOME:-${HOME}/.cache}/guildmaster-rpm/images}"
: "${TMT_WORKDIR_ROOT:=/var/tmp/tmt}"
# Two ~600 MiB base images, plus overlays and tmt run directories.
: "${MIN_FREE_MIB:=4096}"

failures=0

# record <check> <status> [field...]: print a "preflight_event" log line.
#
# Writes "preflight_event check=<check> status=<status>" followed by each
# extra field (already "key=value" formatted) space-separated, and
# increments the shared "failures" counter when <status> is "fail".
# Always returns 0.
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

if version=$("${TMT}" --version 2>/dev/null | head -n 1); then
    record tmt ok "version=\"${version#tmt version: }\""
else
    record tmt fail 'detail="tmt is not installed"'
fi

# tmt lists a provision method only when its plugin imported successfully.
if "${PYTHON}" -c 'import testcloud, libvirt' 2>/dev/null; then
    record virtual_provisioner ok \
        "testcloud=$("${PYTHON}" -c 'import importlib.metadata as m; print(m.version("testcloud"))' 2>/dev/null || echo unknown)"
else
    record virtual_provisioner fail \
        'detail="testcloud or libvirt Python bindings are missing; on Fedora install tmt+provision-virtual"'
fi

if libvirt_version=$("${VIRSH}" --connect qemu:///session version 2>/dev/null); then
    record libvirt_session ok \
        "libvirt=$(sed -n 's/^Using library: libvirt //p' <<<"${libvirt_version}")" \
        "qemu=$(sed -n 's/^Running hypervisor: QEMU //p' <<<"${libvirt_version}")"
else
    record libvirt_session fail \
        'detail="cannot connect to qemu:///session as this user; install the libvirt QEMU driver and client"'
fi

if [[ -c ${KVM_DEVICE} && -r ${KVM_DEVICE} && -w ${KVM_DEVICE} ]]; then
    record kvm_device ok "device=${KVM_DEVICE}"
else
    record kvm_device fail \
        "detail=\"${KVM_DEVICE} is missing or not accessible to this user; if this host is a VM, nested virtualization must be enabled for it\""
fi

# The device node existing is not enough: ask libvirt whether it can create
# KVM domains for this architecture.
# Captured first: grep -q exiting early would make a pipeline fail with
# SIGPIPE under pipefail.
capabilities=$("${VIRSH}" --connect qemu:///session capabilities 2>/dev/null) || capabilities=
if [[ ${capabilities} == *"<domain type='kvm'"* ]]; then
    record kvm_domains ok
else
    record kvm_domains fail 'detail="libvirt does not offer KVM domains in this session; only emulation is available"'
fi

# free_mib <path>: print the free space in MiB on <path>'s filesystem.
#
# Walks up from <path> to the nearest existing ancestor directory and
# prints df's available space, in mebibytes, for it.
free_mib() {
    local dir=$1
    while [[ ! -d ${dir} ]]; do dir=$(dirname "${dir}"); done
    df --output=avail -m "${dir}" | tail -n 1 | tr -d ' '
}
for dir in "${IMAGE_CACHE_DIR}" "${TMT_WORKDIR_ROOT}"; do
    available=$(free_mib "${dir}")
    if ((available >= MIN_FREE_MIB)); then
        record disk_space ok "path=${dir}" "free_mib=${available}"
    else
        record disk_space fail "path=${dir}" "free_mib=${available}" "required_mib=${MIN_FREE_MIB}"
    fi
done

if [[ ${failures} -ne 0 ]]; then
    record summary fail "failures=${failures}"
    echo "$0: this host cannot run the CUSE acceptance guests; see the failed checks above" >&2
    exit 1
fi
record summary ok
