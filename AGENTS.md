# Agent and contributor instructions

This repository packages guildmaster as RPMs. Read
[docs/developers-guide.md](docs/developers-guide.md) before changing
anything; it explains the build, the two test tiers and their boundary.

## Ground rules

- Never install or start guildmaster on the machine you are working on, and
  never change its device permissions, SELinux policy or cgroup settings to
  make a test pass. Packages are only ever installed in the disposable
  containers and guests the test targets create.
- Never use rootful or privileged containers, the host's `/dev/cuse` or
  `/dev/guild`, or software emulation in place of KVM. A missing prerequisite
  is a failure to report, not something to work around.
- Clean up only what your own invocation created. Containers, guests and run
  directories carry unique names for that reason.
- Tests must not repair the installed package. Operator actions that the
  users' guide documents are allowed and must be labelled as such.
- Prose is British English with Oxford spelling, wrapped at 80 columns.

## Gates

Run gates one at a time, never in parallel, and capture their output:

```bash
set -o pipefail
make lint 2>&1 | tee /tmp/guildmaster-rpm-lint.log
make unit 2>&1 | tee /tmp/guildmaster-rpm-unit.log
make test 2>&1 | tee /tmp/guildmaster-rpm-test.log
make test-cuse 2>&1 | tee /tmp/guildmaster-rpm-test-cuse.log
```

- `make lint` and `make unit` must pass before every commit.
- `make test` must pass before a commit that touches the spec, `packaging/`,
  `patches/`, the build scripts, the fixtures or the container tests.
- `make test-cuse` must pass before a commit that touches the unit, the udev
  rules, the patch or the guest tests.
- `make release-check` must pass on a clean tree before a release is tagged.

Commit small, coherent changes. Write commit messages in the imperative mood
without conventional-commit prefixes.

## Changing pins

The upstream commit, the container base images, the guest images and the
GitHub Actions are all pinned by immutable identifiers with recorded
checksums or digests. The developers' guide gives the procedure for moving
each pin. Never take a checksum from the bytes you have just downloaded.
