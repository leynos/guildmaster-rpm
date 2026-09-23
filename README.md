# guildmaster-rpm

*RPMs of guildmaster, the machine-wide jobserver that gets its tokens back.*

[guildmaster](https://codeberg.org/amonakov/guildmaster) serves `/dev/guild`,
a GNU Make jobserver shared by every build on a machine, and returns a
client's tokens to the pool when that client dies. This repository packages
it for Rocky Linux 10 and Fedora 43 (x86_64), as a hardened systemd service
with a configurable token capacity, and tests the result in real guests
before every release.

______________________________________________________________________

## Why guildmaster-rpm?

- **One pool per machine**: several coding agents building at once share one
  small set of job tokens, instead of each assuming it owns every core.
- **Safe by default**: the daemon runs unprivileged, `/dev/guild` is limited
  to the `guild` group, and nothing starts until an operator enables
  it.
- **Configurable without forking files**: set the capacity in
  `/etc/sysconfig/guildmaster`; upgrades keep it and never restart the
  daemon underneath running builds.
- **Tested where it matters**: CUSE needs a real kernel, so releases are
  accepted in fresh KVM guests under enforcing SELinux, not only in
  containers.

It is not a Cargo limiter by itself, and a token count is not a limit on
threads or memory. `leynos/dev-env-rocky` builds the transparent integration
on top; see the [users' guide](docs/users-guide.md) for the fine print.

______________________________________________________________________

## Quick start

### Installation

Releases are plain files on GitHub, not a DNF repository, and the packages
are unsigned. Download, verify the checksums, and install by path:

```bash
tag=v0.1-20251202git463382b-1
gh release download "$tag" --repo leynos/guildmaster-rpm --dir guildmaster-rpms
cd guildmaster-rpms
sha256sum --check SHA256SUMS

# guildmaster needs the cuse module for the running kernel
sudo dnf install "kernel-modules-extra-$(uname -r)"
sudo dnf install ./guildmaster-0.1.*.el10.x86_64.rpm    # or .fc43 on Fedora
```

### Basic usage

```bash
# Two tokens for the whole machine, then switch it on
echo 'GUILDMASTER_OPTS="--tokens=2"' | sudo tee /etc/sysconfig/guildmaster
sudo systemctl enable --now guildmaster.service

# Let a user take tokens (they need to log in again)
sudo usermod --append --groups guild "$USER"

# Build under the shared jobserver
gm-run make
```

______________________________________________________________________

## Features

- Binary, `debuginfo`, `debugsource` and source RPMs for `el10` and `fc43`,
  with a `SHA256SUMS` manifest.
- `guildmaster`, `gm-run`, manual pages, a vendor systemd unit, `sysusers.d`
  accounts and udev rules; one downstream patch adding `--tokens N`.
- The `cuse` kernel module is loaded on demand when the service starts.
- Builds run with no network after dependencies are installed, and every
  build proves a clean rebuild from its own source RPM.
- Output is published a whole generation at a time, under locks, with
  rollback; the machinery is covered by offline tests and a bounded model
  check.
- Two test tiers: rootless Podman containers running real systemd for
  packaging and the unit file, and disposable tmt/QEMU guests for CUSE,
  permissions, token accounting, upgrades, reboots and removal.

### Prerequisites for building and testing

Rootless Podman with cgroup v2 and the systemd cgroup manager, `tmt`, `make`
and the lint tools for `make test`; additionally tmt's virtual provisioner,
a libvirt user session and KVM for `make test-cuse`. The
[developers' guide](docs/developers-guide.md) has the details, and the
preflight scripts report precisely what is missing.

```bash
make rpms           # build both targets into dist/
make test           # offline tests, then both container tiers
make test-cuse      # fresh-guest CUSE acceptance, both distributions
make release-check  # everything a release must pass
```

______________________________________________________________________

## Learn more

- [Users' guide](docs/users-guide.md) — verification, installation,
  activation, permissions, capacity, upgrades, restarts and removal
- [Developers' guide](docs/developers-guide.md) — provenance, versioning, the
  patch, build and publication, test architecture, CI and releases
- [ADR 001](docs/adr-001-system-service-and-device-policy.md) — why it is a
  system unit, the device policy, the test boundary and the capacity patch
- [Changelog](CHANGELOG.md)

______________________________________________________________________

## Licence

guildmaster is © Alexander Monakov under the ISC licence, which the packages
install. The packaging in this repository is also under the ISC licence — see
[LICENSE](LICENSE) for details.

______________________________________________________________________

## Contributing

Contributions are welcome. Please read [AGENTS.md](AGENTS.md) for the gates a
change must pass, and the developers' guide for how the pieces fit together.
