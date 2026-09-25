#!/bin/sh
# Stand-in for /usr/bin/qemu-system-x86_64 on an ephemeral GitHub-hosted
# runner only; .github/actions/setup-cuse-tier installs it with dpkg-divert,
# and it must never be installed on a shared or developer machine.
#
# tmt builds testcloud's libvirt domain without a display adapter, and on
# the hosted runner's SeaBIOS the Rocky Linux 10 image's bootloader then
# hangs before the kernel starts. tmt offers no way to add a device, so this
# wrapper adds one VGA device when QEMU starts a tmt guest on a q35 machine,
# and otherwise runs the real QEMU with its arguments unchanged. libvirt's
# capability probes use "-machine none" and no tmt guest name, so they are
# never altered.
#
# QEMU_REAL is a seam for scripts/tests; libvirt clears the environment, so
# on the runner the default is always used.
: "${QEMU_REAL:=/usr/bin/qemu-system-x86_64.real}"

tmt_guest=no
q35=no
previous=
for arg in "$@"; do
    case ${previous}:${arg} in
    -name:guest=tmt-*) tmt_guest=yes ;;
    -machine:pc-q35-*) q35=yes ;;
    esac
    previous=${arg}
done

if [ "${tmt_guest}" = yes ] && [ "${q35}" = yes ]; then
    exec "${QEMU_REAL}" "$@" -device VGA,bus=pcie.0,addr=0x10
fi
exec "${QEMU_REAL}" "$@"
