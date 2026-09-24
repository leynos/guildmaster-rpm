# Developers' guide

This guide covers the packaging, build, test and publication machinery
for `guildmaster-rpm`. It is written for people changing the packaging
itself, not for operators installing the built RPMs (Red Hat Package
Manager files).

______________________________________________________________________

## 1. Provenance

The build, test and publication machinery in this repository is
adapted from `leynos/bash-completions-rpm` at commit
`ef8dcbde13411c90861d244e77602d2a3f12be2e`. That baseline supplied
the shape of `scripts/build-rpm.sh`, `scripts/clean.sh`, the offline
unit suite, the bounded model check, and the locking and
atomic-publication design described in
[Build and publication](#7-build-and-publication) below.

What was kept from the baseline:

- checksum-gated source caching, per-invocation staging, a shared
  activity lock and a per-target publication lock;
- atomic publication by directory exchange, with a documented
  non-atomic fallback and rollback;
- structured `build_event` diagnostics with secret redaction;
- injectable command seams (`CURL`, `PODMAN`, `FLOCK`, `SHA256SUM`,
  `PUBLISH_MV`, and others) so the unit suite and model check can
  drive the real scripts offline.

What was deliberately changed for guildmaster:

- the package is native `x86_64`, not `noarch` (`bash-completion` is
  architecture-independent; guildmaster links `libfuse3`);
- there is no epoch, matching the snapshot versioning scheme in
  [RPM versioning](#4-rpm-versioning);
- there is no `-devel` subpackage: guildmaster ships no headers or
  pkg-config file for other packages to build against;
- `debuginfo` and `debugsource` subpackages are built, validated as
  part of the expected package set, and published (the baseline did
  not carry these obligations into its own validation);
- the build runs in three phases, with the two phases that produce
  and reproduce the RPMs run with `--network=none`, whereas the
  baseline built with network access throughout;
- `manifest.tsv`, a machine-readable description of every published
  file and its checksum, is new (see
  [Build and publication](#7-build-and-publication));
- the completion-specific test tiers (`syntax`, `functional`, the
  `bash_completion` loader checks) are removed entirely and replaced
  by the container and CUSE (Character Device in Userspace) tiers
  described in [Test architecture](#8-test-architecture).

Upstream is `codeberg.org/amonakov/guildmaster`, commit
`463382ba5b47625a9355832cd792a164c54237f9`. Upstream carries no tags,
so this repository pins a commit rather than a release; see
[Source pinning](#3-source-pinning). Upstream's licence is ISC. The
baseline repository, `bash-completions-rpm`, carries no licence file
of its own; the packaging in this repository is by the same owner as
that baseline.

______________________________________________________________________

## 2. Repository layout

_Table 1: top-level repository paths and their role._

| Path | Role |
| --- | --- |
| `guildmaster.spec` | The RPM spec file. |
| `patches/` | The downstream `--tokens` patch (see [§5](#5-the-downstream-patch)). |
| `packaging/` | Sources installed by the spec: unit, sysconfig, sysusers.d, udev rules, man pages, the `%check` script and `rpmlint.toml`. |
| `scripts/` | Build, clean, fixture, preflight and evidence scripts run from the `Makefile`. |
| `scripts/tests/` | Offline, host-side unit tests and the bounded model check for the scripts above. |
| `fixtures/systemd/` | `Containerfile` for the rootless systemd container fixture. |
| `fixtures/cuse/` | `images.tsv`, the pinned guest image manifest. |
| `plans/` | `tmt` (Test Management Tool) plans: `container.fmf` and `cuse.fmf`. |
| `tests/lib/` | `common.sh`, helpers shared by every `tmt` test. |
| `tests/container/` | Tests run in the rootless systemd container tier. |
| `tests/cuse/` | Tests run in the fresh-guest CUSE acceptance tier. |
| `docs/` | This guide, the users' guide, the ADR (Architecture Decision Record) and the ExecPlan. |
| `Makefile` | Wires the scripts above into `make` targets; see throughout. |
| `.build/` | Ignored. Tarball and image caches, locks and evidence; see [§7](#7-build-and-publication) and [§15](#15-evidence-files). |
| `dist/` | Ignored. Published build output, one directory per target. |

______________________________________________________________________

## 3. Source pinning

Upstream has no release tags, so this repository packages a pinned
commit as a post-release snapshot. The pin has three parts, and they
must always move together:

- the commit, `463382ba5b47625a9355832cd792a164c54237f9`, recorded as
  `%global commit` in `guildmaster.spec` and as `COMMIT` (with the
  same default) in `scripts/build-rpm.sh`;
- the archive URL,
  `https://codeberg.org/amonakov/guildmaster/archive/<commit>.tar.gz`,
  built from the commit in both the spec's `Source0` and the script's
  `TARBALL_URL`;
- the SHA-256 checksum of that archive,
  `825b1a2c5748eb89d57fe6ef1435c1bf8d33656a696f9f5ca6b87b0965ccbfcb`,
  pinned as `TARBALL_SHA256` in `scripts/build-rpm.sh`.

`scripts/build-rpm.sh` enforces agreement between the first two: its
`check_spec_commit` function reads `%global commit` out of the spec
file with `sed` and refuses to run unless it equals the script's own
`COMMIT`. This runs before anything is downloaded, so a spec and
script that have drifted apart fail loudly rather than producing a
package whose version claims one snapshot while its sources are
another.

The checksum is enforced differently: `fetch_tarball` never trusts a
cached file's mere presence, only a checksum match against
`TARBALL_SHA256` (see [§7](#7-build-and-publication)). A freshly
downloaded tarball that fails this check is rejected outright; the
build never proceeds with unverified bytes.

### Moving the pin

1. Choose the new upstream commit and compute its short form (the
   first seven hex digits).
2. Download the archive at
   `https://codeberg.org/amonakov/guildmaster/archive/<commit>.tar.gz`
   and compute its SHA-256.
3. Update, together, in one commit:
   - `%global commit` and `%global snapshotdate` in
     `guildmaster.spec`;
   - `COMMIT` (the default) and `TARBALL_SHA256` in
     `scripts/build-rpm.sh`;
   - the pinned commit, version and release strings duplicated in
     `scripts/tests/test-build-rpm.sh` and
     `scripts/tests/modelcheck/common.py` (`COMMIT`, `VERSION` and
     `RELEASE`), which assert against the same
     values so that the offline suite continues to exercise the real
     pin;
   - `Release` back to `1%{?dist}` (see
     [RPM versioning](#4-rpm-versioning)).
4. Rebuild and let `check_spec_commit` and the checksum gate confirm
   agreement; run `make unit` before anything else, since it checks
   this machinery offline.

A forge can regenerate the bytes of a source archive for the same
commit (for example, by repackaging with a different tar or gzip
version), which changes the SHA-256 without changing the commit. The
checksum gate turns that into a loud, immediate build failure rather
than a silent change to what is packaged — moving the pin always
requires deliberately re-verifying and re-recording the checksum, not
just the commit.

______________________________________________________________________

## 4. RPM versioning

The package version is `0.1^20251202git463382b`, with `Release:
N%{?dist}` and no epoch. `%global upstream_version` is `0.1` (the
version `meson.build` declares upstream has), `%global snapshotdate`
is `20251202`, and `%global shortcommit` is derived from `%global
commit`.

RPM's caret (`^`) sorts a version _after_ the plain version it
follows and _before_ any later version, which is exactly the ordering
a snapshot needs: newer than `0.1`, but not mistaken for a real
`0.1.1` or `0.2` release that upstream might one day tag. No epoch is
needed because the caret alone is enough to establish this ordering
against every version upstream is expected to publish next.

`tests/container/versioning/test.sh` demonstrates the ordering with
RPM's own comparison function,
`rpm --eval "%{lua: print(rpm.vercmp(...))}"`, rather than a lexical
sort. A lexical sort gets it wrong: because `.` sorts before `^`, it
would place `0.1.1` before `0.1^20251202git463382b`, although `0.1.1`
is the newer version. The concrete comparisons it asserts:

```plaintext
0.1^20251202git463382b  vs  0.1^20251202git463382b   -> equal (0)
0.1^20251202git463382b  vs  0.1                       -> newer (1)
0.1^20251202git463382b  vs  0.1^20260301gitabcdef0     -> older (-1)
0.1^20251202git463382b  vs  0.1.1                      -> older (-1)
0.1^20251202git463382b  vs  0.2                        -> older (-1)
0.1^20251202git463382b  vs  1.0                        -> older (-1)
0.1^20251202git463382b  vs  0.2~rc1                    -> older (-1)
2                       vs  1 (as Release values)       -> newer (1)
```

The same test also confirms that the installed package really carries
this version string, so the scheme is checked against the built
artefact, not only against the abstract strings above.

### Bumping the version

- **A packaging-only change** (for example, editing the unit file or
  a udev rule, with no change to the pinned commit): increment
  `Release` only, for example `1%{?dist}` to `2%{?dist}`.
- **A new upstream snapshot at the same nominal upstream version**:
  follow [Moving the pin](#moving-the-pin) above — update `%global
  commit`, `%global snapshotdate` and reset `Release` to `1%{?dist}`.
- **A future upstream release** (upstream tags, say, `0.2`): update
  `%global upstream_version` to `0.2`, drop the caret and snapshot
  suffix from `Version` (it becomes a plain `0.2`), update the
  pinned commit to the tagged commit, and reset `Release` to
  `1%{?dist}`. This is the point at which the snapshot scheme in this
  section stops applying.

______________________________________________________________________

## 5. The downstream patch

`patches/0001-add-tokens-option.patch` adds a `--tokens N` /
`--tokens=N` option to `guildmaster.c`, letting the operator choose
the token pool's capacity instead of accepting upstream's fixed
"online processors plus one". The patch header records its own
provenance, upstream base commit, behaviour and removal condition, so
it is reproduced only briefly here:

- it is carried downstream, not (at the time of writing) submitted
  upstream;
- `--tokens` is parsed with libfuse's own `fuse_opt_parse`, before any
  other argument handling, so every other argument still reaches
  libfuse untouched;
- only a plain positive decimal integer that fits in `unsigned long
  long` is accepted; zero, a sign, whitespace, trailing characters,
  an empty value and anything out of range are rejected with a
  diagnostic and exit status 2, before `/dev/cuse` is opened;
- without the option, behaviour is upstream's unchanged default;
- the selected capacity is logged once at start-up (`token pool
  capacity N`), which is how the tests observe an accepted value
  without needing a working `/dev/cuse`;
- removal condition: drop the patch, and adapt the packaged unit and
  documentation, once upstream offers an equivalent way to set the
  capacity.

### `packaging/check-tokens-option.sh`

This script exercises the option directly against a built
`guildmaster` binary, and is the test named in the spec's `%check`
(`bash %{SOURCE7} %{buildroot}%{_bindir}/guildmaster`). It is reused,
unmodified, by `tests/container/capacity/test.sh` against the
installed binary, and copied into the guest's data directory by
`scripts/cuse-guest.sh`, which passes its path as `GM_TOKENS_CHECK` to
`tests/cuse/capacity`.

It always exercises the _rejected_ cases — every invalid value must
fail with exit status 2 and the diagnostic text `invalid --tokens
value`, and must never print `token pool capacity`, proving rejection
happens before capacity selection. It only exercises the _accepted_
cases — where a real capacity is chosen and logged — when `/dev/cuse`
is **not** accessible to the process running the check:

```bash
if [[ -r /dev/cuse && -w /dev/cuse ]]; then
    echo 'skip: /dev/cuse is accessible; accepted values not run'
else
    ...
fi
```

This is a safety guard, not an oversight: if `/dev/cuse` were
accessible, running an accepted `--tokens` value would let
`guildmaster` actually open the device and start serving `/dev/guild`
on whatever host or fixture is running the check. On a build host,
in `%check`, that is never wanted. The accepted-value assertions
therefore only run where they are safe: in the spec's `%check` and in
the container tier, `/dev/cuse` never exists at all (see
[Container fixture](#9-container-fixture)), so the full set of checks
runs there. In a CUSE guest, where `/dev/cuse` _is_ real,
`tests/cuse/capacity` runs the script against the installed daemon as
the unprivileged user `nobody`, which the package's udev rule does not
admit to `/dev/cuse`. The accepted-value cases therefore run there too,
and the daemon still cannot open the device.

______________________________________________________________________

## 6. Service integration design (brief)

The rationale for every decision in this section is recorded in the
ADR (Architecture Decision Record) at
`docs/adr-001-system-service-and-device-policy.md`; this section only
summarizes the mechanism.

- **Accounts.** `packaging/guildmaster.sysusers` creates the daemon's
  system account, `guildmaster`, and a separate group, `guild`,
  through `sysusers.d`. The daemon is not a member of `guild`.
- **Two groups, two devices.** `packaging/70-guildmaster.rules` gives
  the `guildmaster` group access to `/dev/cuse` (mode `0660`) and the
  `guild` group access to the `/dev/guild` node the daemon creates
  (mode `0660`). Neither device is accessible to anyone else, and
  neither group's members can reach the other device.
- **Module loading.** The unit `Wants=modprobe@cuse.service` and
  `After=modprobe@cuse.service`, systemd's own template unit, so the
  `cuse` kernel module is loaded on demand only when the service
  actually starts, by hand or at boot. The unit also `Requires=
  dev-cuse.device` and orders itself `After=dev-cuse.device`, which
  systemd only announces once `70-guildmaster.rules` has applied the
  `guildmaster` group and the `systemd` tag to it — so the daemon can
  never start before its own device permissions exist. No
  `modules-load.d` file is shipped: on a host that leaves the service
  disabled, nothing in this package loads `cuse`.
- **Configuration.** `/etc/sysconfig/guildmaster`
  (`packaging/guildmaster.sysconfig`) is installed
  `%config(noreplace)` and ships `GUILDMASTER_OPTS=""`. The unit reads
  it with `EnvironmentFile=-/etc/sysconfig/guildmaster` (the leading
  `-` makes a missing file harmless) and passes
  `$GUILDMASTER_OPTS` on `ExecStart`. An operator, or Ansible, sets an
  explicit capacity by writing `GUILDMASTER_OPTS="--tokens=2"` there.
- **Scriptlets.** `%post` runs `%systemd_post
  guildmaster.service`, which applies the distribution's preset —
  both Fedora and Rocky Linux leave new services disabled, so
  installing the package never starts or enables anything. If
  `/dev/cuse` already exists, because the module was loaded before
  installation, `%post` also reloads udev's rules and replays a change
  event for that one device, so it takes the package's group, mode and
  `systemd` tag at once; without that the service could not start until
  a reboot. `tests/cuse/preloaded` covers this, and failed before the
  change. udev resolves `GROUP=` when it parses its rules, so `%post`
  first runs `systemd-sysusers` for the package's file and reloads only
  once the group resolves: Rocky Linux 10's rpm creates sysusers.d
  accounts only at the end of the transaction, and a reload before that
  left the rule without its group, as the Rocky activation test showed. `%preun`
  runs `%systemd_preun guildmaster.service`. `%postun` runs plain
  `%systemd_postun guildmaster.service`, **never**
  `%systemd_postun_with_restart`: restarting the daemon destroys
  `/dev/guild` and creates a fresh token pool, and clients holding
  handles to the old device are left with dead handles that are not
  counted against the new pool. An automatic restart on upgrade could
  therefore silently let the host exceed its intended concurrency
  until those builds finish. The documented procedure is for the
  operator to drain running builds and then restart by hand; see
  `tests/cuse/service-lifecycle/test.sh` and
  `tests/cuse/upgrade-running/test.sh` for exactly what is verified
  about that procedure.

______________________________________________________________________

## 7. Build and publication

`scripts/build-rpm.sh <image> <outdir>` builds the RPMs for one
target and publishes them atomically. Its top-level flow, in order,
is: `resolve_expected_dist`, `check_spec_commit`,
`acquire_activity_lock`, `fetch_tarball`, `build_in_container`,
`validate_staging`, `prepublish_barrier` (a test-only seam, inert in
real use) and `publish_staging`.

### The three container phases

1. **Phase A (network, deps).** A named container (never `--rm`)
   installs `rpm-build`, `dnf-plugins-core` and, via `dnf builddep`,
   the spec's declared build dependencies — enabling the `crb`
   (CodeReady Builder) repository on Rocky Linux first, since `meson`
   lives there. This is the _only_ phase with network access. The
   container is then committed to a temporary image,
   `localhost/guildmaster-build:<build_id>`.
2. **Phase B (`--network=none`, build).** That image runs `rpmbuild
   -ba` against the spec, offline. It then copies the built binary,
   debuginfo and debugsource RPMs to `/out` and the SRPM (Source RPM)
   to `/out/srpm`, refuses any binary package that owns a payload path
   outside `/usr` or `/etc` (a build-tree leak or a `/usr/local` path
   is a packaging defect, not something to publish), and writes
   `/out/manifest.tsv` describing exactly what was produced.
3. **Phase C (`--network=none`, SRPM rebuild).** The same image
   rebuilds the SRPM from scratch with `rpmbuild --rebuild`, again
   offline, and fails unless the rebuild produces the same set of
   package file names as phase B. A source RPM that cannot reproduce
   its own binaries offline is not considered publishable.

The container and image names both carry this invocation's
`build_id` (`$$-${RANDOM}`), so cleanup on exit, interruption or
cancellation only ever removes resources this invocation created.

### `manifest.tsv`

Tab-separated, one row per published file, written by phase B and
re-validated by `validate_staging` before publication:

```plaintext
<relative path>  <name>  <epoch>  <version>  <release>  <arch>  <sha256>
```

`validate_manifest` checks, for every row: the field count is exactly
seven; the epoch field reads `(none)` (this package has no epoch);
the named file exists in staging; the file's basename matches the
name/version/release/arch fields it claims (source RPMs are checked
against the `.src.rpm` naming, binaries against
`<name>-<version>-<release>.<arch>.rpm`); and the row's SHA-256
matches the file's actual bytes. It then checks that the set of
listed files has no duplicates and is exactly the expected set — no
more, no fewer.

### Package-set validation

`validate_staging` refuses to publish anything but exactly: one base
binary package, one `-debuginfo` package, one `-debugsource` package,
and one SRPM under `srpm/` — every one of them `%{EXPECTED_ARCH}`
(`x86_64` by default), with the dist tag the target expects (`fc43`
for `fedora-43`, `el10` for `rocky-10`), and the version naming the
pinned short commit. It explicitly rejects: no output at all; any
`-devel` subpackage (this package ships none); zero or more than one
base binary package; a `noarch` package; a package carrying the wrong
architecture or dist tag; and anything not part of that expected set.
Every rejection is logged through the same `validation_failed` event
and then reported as a build failure — a build that produced only
some of its packages, or something extra, leaves the previously
published output completely untouched.

### Locking

- `.build/locks/activity.lock` is held **shared** by `build-rpm.sh`
  for the whole run. `scripts/clean.sh` takes the same lock
  **exclusive**, so a build in progress blocks `clean`, and a `clean`
  in progress blocks new builds from starting. This is what stops
  `clean` from deleting output or cache a build is using.
- `.build/locks/publish-<target>.lock` is held **exclusive** across
  `publish_staging`, so two concurrent builds of the same target
  cannot interleave their publication swaps.

### Atomic publication, fallback and rollback

`publish_staging` replaces the published `<outdir>` with the staged
directory. On first publication (`<outdir>` does not yet exist), a
plain `mv -T` rename is atomic. Otherwise it tries `mv -T --exchange`
(the `renameat2` `RENAME_EXCHANGE` call), which swaps the two
directories in a single atomic step: a reader of `<outdir>` always
sees either the whole previous set or the whole new one, never a
mixture.

Hosts without `RENAME_EXCHANGE` — coreutils older than 9.5, or a
filesystem that does not implement the call — take a fallback path,
selected automatically (`PUBLISH_EXCHANGE=auto`, the default) or
forced (`PUBLISH_EXCHANGE=never`, used by the unit tests to exercise
this path on any host). The fallback moves the previous output aside
to `<staging>.previous`, then moves the new staging directory into
`<outdir>`. **This path is not atomic**: `<outdir>` is briefly absent
between the two moves of a normal swap, though no partial or mixed
set is ever visible on either path.

If the fallback's second move (promoting staging into place) fails,
the script attempts to roll back by moving `<staging>.previous` back
into `<outdir>` and then fails the build. If that rollback also
succeeds, the previous complete output is restored and the failure is
reported as recoverable. If the rollback itself fails, the build
still exits non-zero, `<outdir>` is left absent, and the previous
complete output is preserved at `<staging>.previous` — which
`cleanup` **deliberately never removes**, since it is the only
remaining copy of the last known-good output. The failure message
names that path explicitly.

Both of the fallback's moves go through a `PUBLISH_MV` seam
(defaulting to `mv`), scoped narrowly to exactly these two moves, so
a test stub can inject a failure into promotion or rollback alone
without disturbing any other rename the script performs.

### Cancellation and cleanup

An `EXIT`/`INT`/`TERM` trap runs `cleanup`, which removes only this
invocation's own scratch: a part-downloaded tarball, the invocation's
staging directory, and the container and image it created (identified
by `build_id`). It is idempotent, since the `INT` and `TERM` handlers
fall through to the `EXIT` handler. `<staging>.previous` is never
touched by `cleanup` for the reason given above. `scripts/clean.sh`
similarly keeps `.build/locks/` on every run — removing a lock file
while a process holds a lock on it would let a waiting process
acquire a lock on the now-unlinked inode and proceed as though it had
exclusive access. The guest image cache is outside the repository (see
[§11](#11-cuse-guest-tier)), so `make clean` never touches it.

### Injectable seams and diagnostics

Every external command the script calls (`CURL`, `SHA256SUM`,
`PODMAN`, `FLOCK`, and, narrowly, `PUBLISH_MV`) and every pinned or
configurable input (`COMMIT`, `TARBALL_URL`, `TARBALL_SHA256`,
`SPEC_FILE`, `PACKAGING_DIR`, `PATCHES_DIR`, `CACHE_DIR`, `LOCK_DIR`,
`STAGING_ROOT`, `PUBLISH_EXCHANGE`, `EXPECTED_ARCH`, `EXPECTED_DIST`)
is overridable from the environment via a `: "${NAME:=default}"`
seam. Real builds override none of them; the seams exist purely so
`scripts/tests/test-build-rpm.sh` and `scripts/tests/model_check.py`
can drive the real script against stub commands and local fixtures,
with no network and no container runtime.

Every lifecycle step emits one `build_event` line to stdout, carrying
`event`, `target`, `build_id` and `elapsed_seconds`, with any
free-form `detail="..."` field always last — safe to grep or parse
from a CI log. `TARBALL_URL` is overridable and may carry userinfo or
a query token, so it is never logged in any form: downloads are
identified by tarball filename only, and any diagnostic text captured
from `curl` passes through a `redact_secrets` helper (stripping URL
userinfo and query strings) before being logged.

______________________________________________________________________

## 8. Test architecture

_Table 2: test tiers, what they run, and what they cover._

| Tier | Entry point | Covers |
| --- | --- | --- |
| Offline script tests | `make unit` (`test-build-rpm.sh`, `test-systemd-fixture.sh`, `test-cuse-scripts.sh`, `test-release-scripts.sh`, `test-verify-release.sh`, `test-virt-preflight.sh`, `test-upgrade-fixture.sh`, `test-upgrade-fixture-cancel.sh`) | Every repository script's own orchestration, validation and locking, against stub commands — no network, no container runtime, no `tmt`. |
| Guest-test helpers | `make unit` (`test_accounting_waits.py`) | The bounded-wait helper of the guest accounting test, against a fake clock. |
| Workflow contract | `make unit` (`test_workflows.py`, through `uv` with PyYAML 6.0.2) | The CI, acceptance and release workflows and the composite actions, parsed and checked against the release contract, with mutations. |
| Bounded model check | `make unit` (`model_check.py`) | A breadth sweep, executed and abstract, over the same build/publish/clean state space; see below. |
| Rootless systemd container tier | `make test` | Distribution userspace: packaging, the installed unit, accounts, upgrade and removal, and the documented CUSE-missing failure. Runs against the _host_ kernel. |
| Fresh-guest CUSE tier | `make test-cuse` | Real operation: activation, permissions, token accounting, `gm-run`, hardening, lifecycle, upgrade-while-running, reboot and removal, all with a real kernel, CUSE, udev and enforcing SELinux. |
| Release check | `make release-check` | Lint, both test tiers on both targets, then `scripts/release-evidence.sh`. |

### Offline script tests

`scripts/tests/test-build-rpm.sh` drives `build-rpm.sh` and
`clean.sh` through stub `curl`, `podman`, `flock` and `sha256sum`
commands and a local fixture, asserting the scripts' own logic:
argument checking, agreement between the pinned commit and the spec,
cache reuse versus re-fetch, checksum enforcement, the three
container phases being invoked with the right isolation, package-set
validation, atomic publication on both the exchange and fallback
paths, refusal to publish an incomplete set, two concurrent builds of
one target, `clean` waiting for an in-flight build, and that failed
or cancelled runs leave no staging directories, temporary files,
containers, images or held locks behind. Its concurrency cases use
FIFO handshakes rather than timing sleeps, so they are deterministic.

`scripts/tests/test-systemd-fixture.sh` and
`scripts/tests/test-cuse-scripts.sh` are the analogous offline suites
for `scripts/systemd-fixture.sh` / `scripts/podman-preflight.sh`, and
for `scripts/cuse-image.sh` / `scripts/cuse-guest.sh` respectively:
stub `podman`, `tmt`, `curl`, `virsh` and `qemu-img` commands record
their calls and answer from files in a per-test scenario directory,
so the wrappers' own cache safety, input selection and verification,
and cleanup ownership are tested without a real container runtime,
`tmt`, network or libvirt. `scripts/tests/test-release-scripts.sh`
does the same for `scripts/assemble-release.sh` and
`scripts/release-evidence.sh`: complete and incomplete package sets,
tag and spec agreement, checksums, duplicate asset names and the
evidence cross-check.

Three further suites complete the set. `test-verify-release.sh` stubs
`gh`, `rpm` and `sha256sum` to exercise `scripts/verify-release.sh` on
complete, tampered and incomplete releases, including four files that
are not the four packages. `test-virt-preflight.sh` stubs `tmt`, `virsh`,
the Python interpreter and `df` to make each virtualization prerequisite
fail in turn. `test-upgrade-fixture.sh` and
`test-upgrade-fixture-cancel.sh` stub `podman` and wrap `flock` to cover
`scripts/build-upgrade-fixture.sh`: argument checks, source reuse and
rebuilds, failed builds, per-target lock contention and cancellation
during publication. Each of these suites also builds deliberately
broken copies of its script and requires the suite to fail against each,
counting a copy as caught only when the suite reports failed
assertions, never on a crash.

`scripts/tests/test_workflows.py` (with its `scripts/tests/workflowcheck/`
package) parses the workflows and composite actions and checks the
release contract: triggers (no pull request can reach the KVM or
release workflows), target matrices, the release job graph, least
privilege, concurrency, pinned actions, checkout settings, artefact
names and hidden-file uploads, the candidate-to-publish order, tag
handling, and that every job running a `make` target that needs `uv`
installs it. Mutations of the workflow text must each be caught. It
needs PyYAML, so `make unit` runs it with
`uv run --no-project --with pyyaml==6.0.2`; `uv` must be on `PATH`, and
the CI jobs install it with `astral-sh/setup-uv`.

The guest accounting test takes its clock as a parameter for its polling
waits: each goes through one `wait_until` helper with an injectable `Clock`,
and a timeout fails the scenario. `scripts/tests/test_accounting_waits.py`
checks that helper offline against a fake clock that advances only when slept
on, so no real time passes. Waits that block in the kernel instead of polling,
`select` on a client's output and `Popen.wait` when stopping a client, keep
their own real timeouts and are not covered by the fake clock. Every one of
them has a timeout, including the wait after `SIGKILL` in `Client.finish`, which
fails the check if the client survives it; the same offline suite drives
`finish` with a stand-in process that never exits.

None of these offline suites says anything about whether a real
host can boot the fixtures — `podman-preflight.sh`,
`virt-preflight.sh` and the real `make test` / `make test-cuse` runs
cover that.

### Bounded state-space check

`scripts/tests/model_check.py` is **a bounded check, not a proof**.
It samples a finite, seeded set of scenarios and interleavings, so a
pass demonstrates the absence of a violation across whatever it
sampled — nothing more. It has two layers:

- an **executed** layer that drives the real `build-rpm.sh` and
  `clean.sh` through stub commands and FIFOs, over generated
  combinations of cache state, container-phase outcome, publication
  mode and clean position — this checks the shell code as written;
- an **abstract** layer that models the same algorithm as a small
  transition system and samples interleavings of up to two concurrent
  builds and a clean — covering interleavings that cannot be driven
  directly against the real script. This layer checks the algorithm
  as documented, and can in principle disagree with the shell.

Both layers assert the same four invariants (stated in the module's
own docstring): a published output is never partial or mixed; `clean`
never removes output or cache while an activity lock is held; a
successful rollback restores the prior complete output, and a failed
one retains it as recovery data; and a failed or cancelled invocation
leaves no invocation-owned staging directory, temporary tarball,
container, image or held lock.

Non-vacuity is checked two ways. First, the abstract layer must
actually reach publication contention, the fallback's absent window
and a retained-recovery state during its sampled run — a run that
never reaches them proves nothing and fails outright. Second, a
self-test runs a set of deliberately broken models (seeded faults)
through the same checker and asserts that every one of them is
rejected, so the checker itself is shown to be capable of catching a
violation, not merely silent by construction. The seed and case
counts are reproducible and overridable
(`--seed`/`MODEL_CHECK_SEED`, `--executed-cases`/
`MODEL_CHECK_EXECUTED`, `--schedules`/`MODEL_CHECK_SCHEDULES`); the
seed is always printed and repeated alongside any failing case.

The fixed FIFO cases in `test-build-rpm.sh` remain regression tests
for specific defects; the model check is a breadth sweep over their
state space, not a replacement for them.

The ExecPlan's own progress notes additionally record that, during
development, the container-tier adapter's offline suite reached 84
checks with three deliberately seeded faults confirmed caught before
the suite was accepted — reported here as the plan's own claim, not
independently re-run for this guide.

### Coverage boundary between the two runtime tiers

This boundary is exact, and worth stating precisely because it is
easy to overclaim: **containers test distribution userspace against
the host's own kernel and have no CUSE device at all.** They cover
packaging, unit verification, and the single documented
missing-device failure mode (`tests/container/no-cuse`) — they never
report guildmaster as operating, and the production `ExecStart` is
never replaced by a stand-in to make it appear to run. Only the
fresh-guest CUSE tier shows guildmaster actually serving `/dev/guild`,
the SELinux behaviour of the running daemon, udev's device rules
taking effect, and token accounting against the real device.

A successful unit start in a guest is likewise not proof that every
hardening directive in the unit is enforced. `tests/cuse/hardening`
enumerates exactly which `systemd` sandboxing directives are checked
against the kernel's own view of the live process (UID/GID sets,
`NoNewPrivs`, the seccomp filter mode, the capability sets, namespace
isolation, `ProtectSystem`, `ProtectHome`, `PrivateNetwork`, and
`DevicePolicy` via a probe run inside the service's own cgroup).
Every other directive in `packaging/guildmaster.service` is
configured but unverified by this test suite, and the test's own
comment says so.

______________________________________________________________________

## 9. Container fixture

`fixtures/systemd/Containerfile` builds an image, from a
digest-pinned base, that installs `systemd` and `dbus` with weak
dependencies disabled (`--setopt=install_weak_deps=False`) and clears
the baked-in machine ID so that each boot generates its own. Its
`CMD` is `/usr/lib/systemd/systemd`, so the container's PID 1 is the
distribution's real systemd, not a shell or supervisor stand-in.

Weak dependencies are excluded deliberately: on Fedora they would
pull in `systemd-resolved`, which cannot start in a rootless
container — it requests `CAP_NET_RAW` as an ambient capability, which
is outside rootless Podman's bounding set, so the unit fails at step
`USER` and the whole fixture boots to `degraded` for a reason that
has nothing to do with the package under test. With weak dependencies
excluded, both fixtures boot to `running`, so
`ALLOWED_FAILED_UNITS` is empty by default in
`scripts/systemd-fixture.sh`; any unit ever added to that list must
be named and justified in this guide.

The image tag is keyed on the base image's own digest-bearing
reference plus a hash of the Containerfile's bytes
(`ensure_fixture_image` in `scripts/systemd-fixture.sh`), so a
changed base or a changed Containerfile always produces a new image
rather than silently reusing a stale one; an unchanged pair reuses
the cached image under a per-target build lock.

### Podman options

`scripts/systemd-fixture.sh` starts the fixture with exactly:

```bash
podman run --detach \
    --name "${name}" \
    --systemd=always \
    --cgroupns=private \
    --user=0 \
    --volume "${work_dir}:${work_dir}:z" \
    "${fixture_image}"
```

`verify_container` then inspects the running container and asserts
these settings really took effect
(`Config.SystemdMode`, `HostConfig.CgroupMode`,
`HostConfig.Privileged`, `HostConfig.PidMode`, `Config.User` must
read `true private false private 0`), rather than assuming the
command line was honoured.

**Never used:** rootful Podman, `--privileged`, a host cgroup bind
mount, the host PID namespace, the host systemd socket, or SELinux
label disabling. A host that cannot support the options above fails
`scripts/podman-preflight.sh` (see
[§10](#10-host-preflight-for-containers)); there is no fallback to
any of them.

### Why an adapter exists

`tmt`'s own container provisioner builds its `podman run` command
line internally and offers no hook to add `--systemd=always` or
`--cgroupns=private`. It can, however, _adopt_ an already-running
container, via `provision --how container --container NAME`,
provided the container's own working directory is bind-mounted at
the same path inside it. `scripts/systemd-fixture.sh` is exactly that
adapter: it starts the fixture with the options above, proves systemd
booted, then hands the running container to `tmt` through that
adoption mechanism — no SSH connection is needed.

### Readiness

`wait_for_boot` uses two bounded waits, not one. First it polls
`systemctl is-system-running` until the container will run a command
at all and the systemd manager answers (`is-system-running` exits
non-zero for every state but `running`, so its exit status alone says
nothing about whether the manager is even reachable yet — the state
string itself is what is checked). Only once that is established does
it ask systemd to wait for boot to actually finish, bounded by
`BOOT_TIMEOUT`. `running` is accepted outright. `degraded` is
accepted only if every currently failed unit is named in
`ALLOWED_FAILED_UNITS` (empty by default, as above); any other failed
unit, or a timeout, is a hard failure.

### Verification and the SELinux process label

`verify_container` also reads the container's `ProcessLabel`. When
SELinux labelling is present, the label must include
`:container_init_t:`, and coverage is recorded as `confined`.
When no label is present at all — the case on a host with SELinux
disabled — coverage is recorded as `userspace_only`, and this value
is written to `${work_dir}/container-coverage` and echoed into the
tier's evidence file (see [§15](#15-evidence-files)). Confined
coverage is a property of the _host_, not something the fixture can
force.

### Diagnostics and cleanup

On any failure, `capture_diagnostics` runs before the container is
removed: `journalctl -b`, the list of failed units,
`systemctl show guildmaster.service`, `podman inspect` and `podman
logs`, all captured to `${work_dir}/diagnostics/`. None of this
contains credentials — it is the fixture's own journal and unit
state. `cleanup` then removes only this invocation's own container
(named `gm-fx-<target>-<pid>-<random>`); the work directory is kept
on failure, or with `KEEP_WORKDIR=1`, and removed otherwise.

### Run directories under `/var/tmp/tmt`

`tmt` copies the entire fmf (Flexible Metadata Format) tree into
every run and refuses a run directory located inside that tree — and
the fmf root here is the whole repository. Run directories therefore
live under `/var/tmp/tmt/<name>` (`WORK_ROOT`, overridable, defaulting
to `TMT_WORKDIR_ROOT` or `/var/tmp/tmt`), entirely outside the
repository.

______________________________________________________________________

## 10. Host preflight for containers

`scripts/podman-preflight.sh` checks, in order, that this host can
run the rootless systemd container fixtures, and exits non-zero
naming whatever is missing — there is no fallback to rootful or
privileged execution for any of these:

_Table 3: container preflight checks and what a failure means._

| Check | Failure means |
| --- | --- |
| `podman_info` | `podman info` could not be read; Podman is missing or unusable by this user. |
| `rootless` | Podman is not running rootless. |
| `cgroup_version` | The host is not on cgroup v2. |
| `cgroup_manager` | Podman's cgroup manager is not `systemd`. |
| `user_manager` | `systemctl --user` cannot reach a user manager (no lingering session). |
| `subuid` / `subgid` | No subordinate UID/GID range is configured for this user in `/etc/subuid` / `/etc/subgid`. |
| `delegation` | The user's systemd manager has not been delegated the `pids` cgroup controller, read from `.../user@<uid>.service/cgroup.controllers`. |
| `selinux` | Not a failure by itself: reports the host's `getenforce` state and records `container_coverage` as `confined` only when `enforcing`, else `userspace_only`. |

The correct Podman field for the cgroup version is
`.Host.CgroupsVersion` (queried with `podman info --format`); this is
the field the script reads and is worth calling out because it is
easy to confuse with the unrelated `.Host.CgroupManager` field
alongside it.

______________________________________________________________________

## 11. CUSE guest tier

### Host prerequisites

On a Fedora runner, installing `tmt+provision-virtual` pulls in
`testcloud` and libvirt's QEMU driver, which together provide `tmt`'s
virtual provisioner:

```bash
sudo dnf install tmt+provision-virtual
```

`qemu-img` is also required, for `verify_overlay` in
`scripts/cuse-guest.sh` (see below), and is not pulled in by the
package above.

Guests are provisioned through the invoking user's own **user-session
libvirt** connection, `qemu:///session` — never the system
connection, and never a rootful or privileged path. This needs
hardware virtualization: `/dev/kvm` must exist and be accessible to
this user, and if the host running the tests is itself a virtual
machine, nested virtualization must be exposed to it.

`scripts/virt-preflight.sh` checks all of this before a guest is ever
provisioned, and exits non-zero naming whatever is missing, with
**no fallback** to software emulation (TCG), a rootful connection, or
the system libvirt connection:

_Table 4: CUSE preflight checks and what a failure means._

| Check | Failure means |
| --- | --- |
| `tmt` | `tmt` is not installed. |
| `virtual_provisioner` | `testcloud`/`libvirt` Python bindings are missing (install `tmt+provision-virtual`). |
| `libvirt_session` | `qemu:///session` is not reachable as this user. |
| `kvm_device` | `/dev/kvm` is missing or inaccessible; if this host is itself a VM, nested virtualization is not enabled for it. |
| `kvm_domains` | libvirt's session connection reports no KVM domain capability — only emulation is available. |
| `disk_space` | Fewer than `MIN_FREE_MIB` (4096 by default) free under the image cache or the `tmt` work root. |

### Pinned guest images

`fixtures/cuse/images.tsv` pins, per target and architecture, an
image file name, a SHA-256 checksum and a download URL. The
checksums are recorded (as of 2026-09-21) from the distributions' own
signed checksum files:

- Rocky Linux 10:
  `Rocky-10-GenericCloud-Base-10.2-20260525.0.x86_64.qcow2.CHECKSUM`,
  published beside the image with a detached
  signature (`.CHECKSUM.asc`) from the Rocky Linux 10 release key;
- Fedora 43: `Fedora-Cloud-43-1.6-x86_64-CHECKSUM`, the clear-signed
  checksum file published beside the image.

To move a pin, take the new file name and SHA-256 **from the
distribution's own signed checksum file, never from a downloaded
image directly**.

`scripts/cuse-image.sh <target>` makes the pinned image available and
prints its path. The cache is **per user, not per repository**:
`${XDG_CACHE_HOME:-~/.cache}/guildmaster-rpm/images`
(`IMAGE_CACHE_DIR`), outside the repository, because `tmt` copies the
entire fmf tree into every run — a cache inside the repository would
be copied, and potentially left stale, on every invocation.

Cached files are named `<first 16 hex digits of the SHA-256>-<file
name>`: `tmt` links images into its own store by base name alone, so
prefixing the content's identity into the name is what keeps two
checkouts pinned to different bytes for the same target from
colliding there.

The same cache-safety rules as the source tarball apply: a cached
file is reused only if its bytes match the pinned SHA-256, checked on
every use (not merely on first download); a download lands in a
per-invocation temporary file and is published by a single rename
once verified, so concurrent invocations can neither observe nor
produce a partial image; and the published file is made read-only
(`chmod 0444`) once cached.

Guests never write to the cached file directly: `tmt`'s virtual
provisioner boots a throw-away copy-on-write overlay of it per run.
`scripts/cuse-guest.sh` additionally checks the base image's own
SHA-256 both before provisioning and again after the run finishes, so
an unexpected mutation of the cached file itself — as opposed to the
overlay — would be caught.

### Fresh overlays, verified

`verify_overlay` in `scripts/cuse-guest.sh` does not merely assume
`tmt` gave the guest a fresh overlay; it checks. It reads the
`instance-name` `tmt` recorded for this run from
`<run>/plans/cuse/provision/guests.yaml`, locates that instance's
`.qcow2` disk under `${WORK_ROOT}/testcloud/instances/<instance>`,
and reads its backing file with `qemu-img info --force-share
--output=json`. The backing file must resolve (`readlink -f`) to
exactly the verified, cached image; anything else fails the run. This
is what proves a fresh guest was really booted from the pinned bytes,
rather than from some other or stale disk.

No prepared or cached _base_ image with the package pre-installed is
ever used. Every run prepares the guest from scratch, inside
`tests/cuse/preflight`, which runs first (`order: 5`) and, before
touching the package, positively asserts the guest arrives in a
clean state: no `guildmaster` account, no `guildmaster` or `guild`
group, the package not already installed, none of the unit,
sysconfig, `/dev/guild`, udev rule or `modules-load.d` entries
already present, and no SELinux module mentioning `guild` already
loaded. Any of these being true is treated as an _environment_ error,
not a test failure — the fixture itself would be untrustworthy.

### Kernel and module matching, and the reboot path

`tests/cuse/preflight/test.sh` discovers, rather than assumes, which
package (if any) ships `cuse.ko` for the _running_ kernel, checking
`kernel-modules-core`, `kernel-modules` and `kernel-modules-extra` in
turn via `dnf repoquery -l`. If a match is found, it is installed. If
none is found and the guest has not yet rebooted in this test
(`TMT_REBOOT_COUNT == 0`), it installs a current `kernel` package plus
`kernel-modules-extra` and calls `tmt-reboot`, which reboots the guest
and re-runs this same test with `TMT_REBOOT_COUNT` incremented. If
still no match is found after that reboot, the test fails outright —
there is no third attempt.

Verified providers, as recorded in the ExecPlan:

- **Rocky Linux 10.2** image: `cuse.ko` is provided by
  `kernel-modules-extra` (which pulls in `kernel-modules`). On
  2026-09-21 it was still available for the image's own kernel,
  `6.12.0-211.16.1.el10_2.0.1`, and no reboot was needed; by 2026-09-23
  it no longer was, and runs updated to `6.12.0-211.56.1.el10_2.0.1` and
  rebooted once.
- **Fedora 43 GA** image: the shipped kernel always needs a kernel
  update plus one reboot; the kernel that then ran was `7.2.5-100.fc43`
  on 2026-09-21 and `7.2.6-100.fc43` on 2026-09-23, again with
  `kernel-modules-extra`.

These are the values that were true for the pinned images at the
time they were recorded; the evidence file for each real run records
the actual values observed for that run (see
[§15](#15-evidence-files)), since a later image update could shift
them.

### Two tmt invocations, one run id

`scripts/cuse-guest.sh` runs `tmt` **twice** against the same `--id`.
The first invocation provisions the guest and runs `discover`. The
script then copies the selected, checksum-verified packages (plus
`check-tokens-option.sh`) into that run's plan data directory,
`<run>/plans/cuse/data/`. The second invocation runs `prepare
execute report finish`, whose `prepare` step is what actually pushes
the data directory's contents to the guest. This two-step shape is
what lets the script guarantee that only the exact files it verified
(and no others) ever reach the guest — a single `discover ...
execute` invocation would have no point at which to inject them
between provisioning and preparing.

### The `--hardware cpu.processors` reload bug

`tmt` 1.78 saves a command-line `--hardware cpu.processors=N`
constraint in a form (`{and: [{cpu.processors: ...}]}`) that its own
`Hardware.from_spec` cannot load back on a _later_ invocation of the
same run — including cleanup — raising `KeyError: 'processors'`. This
was observed to leak a guest's libvirt domain on the very first
attempt at driving this tier, because cleanup itself failed with that
error.

The workaround is to never pass processor or memory counts as
`--hardware` command-line options at all. Instead, `plans/cuse.fmf`
takes them from `tmt` **context** and substitutes them into the
plan's own `hardware` block:

```yaml
provision:
    how: virtual
    connection: session
    hardware:
        memory: $@{guest_memory_mib} MB
        cpu:
            processors: $@{guest_cpus}
```

`scripts/cuse-guest.sh` supplies that context on every invocation
(`--context guest_memory_mib=... --context guest_cpus=...`), which
`tmt` can reload safely on every subsequent invocation of the same
run, cleanup included.

As a last-resort fallback, in case even this cannot clean up a run's
guest, `destroy_own_guest` in `scripts/cuse-guest.sh` reads the
`instance-name` `tmt` recorded for the run and destroys that one
libvirt domain, and only that one, by name — `virsh destroy` /
`undefine`, followed by removing its `testcloud` instance directory.

### Resource variables

`GUEST_MEMORY_MIB` (default `2048`) and `GUEST_CPUS` (default `2`)
are **starting allocations, not measured minimums** — they have not
been tuned down to a proven-sufficient floor. `GUEST_IMAGE_fedora-43`
and `GUEST_IMAGE_rocky-10` (both empty by default) may each name an
absolute path to an image to use instead of the per-user cache entry;
whatever is supplied must still match the checksum pinned in
`fixtures/cuse/images.tsv` — this relocates the bytes, it does not
change which bytes are accepted.

______________________________________________________________________

## 12. Development versus acceptance

`make test-cuse-<target>` always provisions a fresh, disposable guest
and destroys it afterwards; that disposability is exactly what makes
its result acceptance evidence. For iterating on a test or a package
change, running `tmt` by hand against a guest kept alive between
invocations gives much faster feedback, but such a reused guest is
**never acceptance evidence** — only a freshly provisioned one is.

Such a run always takes an explicit, unique `--id`; `--last` is never used on a
host that other agents or CI may also be using.

Provision a guest by hand:

```bash
tmt -c distro=rocky-10 -c guest_cpus=2 -c guest_memory_mib=2048 \
    run --id my-dev-guest \
    provision --how virtual --connection session \
    --image "$(scripts/cuse-image.sh rocky-10)"
```

Then, once the packages have been copied into the plan's data directory by hand
(see the environment variables below; `scripts/cuse-guest.sh` normally performs
this set-up), a test iteration is:

```bash
data=/var/tmp/tmt/my-dev-guest/plans/cuse/data
tmt -c distro=rocky-10 -c guest_cpus=2 -c guest_memory_mib=2048 \
    run --id my-dev-guest \
    --environment "GM_RPM_DIR=${data}/rpms" \
    --environment "GM_UPGRADE_RPM_DIR=${data}/upgrade" \
    --environment "GM_TOKENS_CHECK=${data}/check-tokens-option.sh" \
    --environment "GM_GUEST_FACTS=${data}/guest-facts.txt" \
    --environment GM_TARGET=rocky-10 \
    discover --force prepare --force execute --force
```

`prepare --force` is what pushes the staged plan data, and with it the
packages, to the guest; without it the guest keeps whatever it received
last. `--environment` belongs to `run`, as in `scripts/cuse-guest.sh`.

The guest is destroyed afterwards with `tmt run --id my-dev-guest cleanup`, or,
as a fallback, by removing the named libvirt domain directly, as
`destroy_own_guest` does in `scripts/cuse-guest.sh`.

### Environment variables the CUSE tests read

_Table 5: environment variables read by the `tests/cuse/*` scripts._

| Variable | Read by | Purpose |
| --- | --- | --- |
| `GM_RPM_DIR` | `tests/lib/common.sh` (`rpm_under_test`), most `tests/cuse/*` | Directory holding the built RPMs and `manifest.tsv`. |
| `GM_UPGRADE_RPM_DIR` | `tests/cuse/upgrade-running`, `tests/container/upgrade` | The higher-release rebuild from `scripts/build-upgrade-fixture.sh`. |
| `GM_TOKENS_CHECK` | `tests/cuse/capacity/test.sh` | Path to the copied `check-tokens-option.sh`. |
| `GM_GUEST_FACTS` | `tests/cuse/preflight/test.sh`, `tests/cuse/activation/test.sh` | Where to write the recorded guest facts file. |
| `GM_TARGET` | `tests/container/install/test.sh` | Which target's dist tag to expect (`fedora-43` / `rocky-10`). |
| `GM_MEMBER` | `tests/cuse/accounting/test_accounting.py` | The authorized test user to run clients as (defaults to `gm-member`). |

When `tmt` is driven by hand, these must be supplied as `run` options, as in
the iteration command above, and the packages must be staged in
`<run>/plans/cuse/data/rpms/` by hand, exactly as the `stage_rpms` function in
`scripts/cuse-guest.sh` does.

______________________________________________________________________

## 13. Token-accounting semantics

`tests/cuse/accounting/test_accounting.py` and its docstring record
what upstream's daemon actually does, which differs from upstream's
own README: **tokens are accounted per _opening process_, not per
open file description.** `guildmaster` keys its client accounts on
the process ID that called `open()`, not on the file description that
call returned.

The consequences this pins down, each backed by a scenario in that
test:

- **Multiple handles, one process.** If one process opens `/dev/guild`
  twice, both handles share one account. A token taken through the
  first handle can be returned through the second
  (`scenario_multiple_handles`). Closing one of several handles does
  **not** return that process's outstanding tokens — only closing its
  _last_ handle does.
- **Inherited handles.** A forked child inherits the parent's open
  file description for a handle the parent opened before forking.
  Because the kernel's own file description is shared and only
  released once every copy is closed, the _parent_ dying alone does
  **not** return a token taken through that handle while the child
  still holds its inherited copy open
  (`scenario_inherited_handles`) — the account is tied to the
  process that opened it, but the underlying description outlives
  that process as long as any copy of it is open elsewhere.
- **Abrupt death.** When a process dies, for example by `SIGKILL`, the
  tokens it still held return to the pool once no copy of its open file
  descriptions remains open (`scenario_abrupt_death`). If a child has
  inherited a handle, the tokens stay held until the child closes it too,
  as in the inherited-handle case above; a killed holder alone does not
  free them.
- **Unmatched or excess writes never inflate the pool.** Writing
  without a matching prior read, or writing back more than was taken,
  never raises the pool above its configured capacity
  (`scenario_unmatched_writes`).

The test observes all of this without relying on elapsed time as
evidence: "the pool is empty" is a non-blocking read answering
`EAGAIN`; "a client is waiting" is the kernel positively reporting
that process asleep inside `read(2)` (via `/proc/<pid>/syscall`),
combined with no answer yet on its control pipe; "a client was
admitted" is its answer arriving, awaited with a bound. This is
upstream's real, observed behaviour; the packaging does not attempt
to change it.

______________________________________________________________________

## 14. Quality gates

`make lint` runs, in order: `lint-shell`, `lint-python`, `typecheck`,
`lint-fmf`, `lint-workflows`, `lint-docs`, `lint-spec`. The estate's
standard gate names are also provided: `make check-fmt` (`shfmt` and
`ruff format --check`), `make typecheck` and `make markdownlint`.

_Table 6: lint sub-targets and the tools they require._

| Target | Tool(s) | Notes |
| --- | --- | --- |
| `lint-shell` | `shellcheck -x -P SCRIPTDIR`, `shfmt -d -i 4` | Runs over every script in `scripts/`, `scripts/tests/`, `packaging/`, `tests/lib/` and every `tests/*/*/test.sh`. |
| `lint-python` | `uvx ruff check`, `uvx ruff format --check` | Runs over `scripts/tests` and `tests/cuse/accounting`. |
| `typecheck` | `uvx ty check` | Type-checks the same Python sources. |
| `lint-fmf` | `tmt lint --failed-only --enforce-check C001` | Needs `distro`, `guest_cpus` and `guest_memory_mib` context, since `plans/cuse.fmf` substitutes them; the `Makefile` supplies example values. |
| `lint-workflows` | `actionlint` | Lints `.github/workflows/`. |
| `lint-docs` | `markdownlint-cli2`, `nixie` | Markdown style over every `.md` file outside `.build` and `dist`. `nixie` validates Mermaid diagrams and is only required, and only run, when a document contains one. |
| `lint-spec` | `rpmlint` (host, if installed) | See below; the container tier also runs `rpmlint` against the built packages, using the distributions' own configuration. |

`shfmt` is invoked with `-i 4` (four-space indentation), matching the
indentation already used throughout the shell scripts in this
repository.

### `rpmlint` availability

`rpmlint` is present on Fedora, but is **not** available in Rocky
Linux 10's BaseOS, AppStream or CRB repositories; EPEL (Extra
Packages for Enterprise Linux) 10 provides it. `lint-spec` therefore
degrades gracefully on the host: if `rpmlint` is not installed, it
prints a message explaining that the spec is linted in the container
tier instead of failing outright.

`tests/container/rpmlint` is the tier that actually runs it against
the built packages on both distributions. Its `main.fmf` declares
`require: [rpmlint]`, and carries an `adjust` rule that installs
`epel-release` first when `distro == rocky-10` — explicitly scoped as
a harness-only test dependency, not something the package itself ever
requires.

### `packaging/rpmlint.toml`

Both the host-side and container-tier `rpmlint` runs use this
configuration. Every filter names the specific check it silences and
why:

- spelling-error filters for `jobserver`, `CUSE`, `userspace`, `gm`
  and `dev` (as in `/dev` from `/dev/guild`) — words `rpmlint`'s
  dictionary does not recognize;
- a `no-documentation` filter for the `-debuginfo` and `-debugsource`
  subpackages, which legitimately ship none.

Anything else `rpmlint` reports is treated as a real failure.

______________________________________________________________________

## 15. Evidence files

Every passing run of the container tier or the CUSE tier writes an
evidence file under `.build/evidence/`:

- `container-<target>.txt`, written by `scripts/systemd-fixture.sh`'s
  `write_evidence`;
- `cuse-<target>-<kind>.txt`, written by `scripts/cuse-guest.sh`'s
  `write_evidence`, where `<kind>` is `candidate` by default
  (`EVIDENCE_KIND`), or `release` when run against downloaded release
  assets rather than a fresh local build.

Each file records, among other fields: the tier and plan name; a
`result: passed` line (only ever written on success); the source
commit and whether the working tree was clean
(`source_tree_dirty: yes|no`); the exact package checksums built,
taken from `manifest.tsv` (`file<TAB>sha256`); and tier-specific
facts — the fixture or base image identity and Podman/`tmt` versions
for the container tier; the guest image identity, checksum,
confirmation that it was unchanged after the run, guest resource
allocations and the recorded guest facts for the CUSE tier.

`scripts/release-evidence.sh` is the last step of `make
release-check`. It runs no test itself; it only cross-checks, for
every target in `TARGETS` (`rocky-10 fedora-43` by default):

- that both the container-tier and CUSE-tier (`candidate`) evidence
  files exist and record `result: passed`;
- that both name the **current** source commit
  (`git rev-parse HEAD`) and record `source_tree_dirty: no`;
- that both list **exactly** the package checksums currently in
  `dist/<target>/manifest.tsv`.

If any of these checks fails, it reports every problem it found and
exits non-zero **without** writing a release-candidate record — a
stale pass, a pass against different bytes, or a missing tier can
never be mistaken for release evidence this way. On success it writes
`.build/evidence/release-candidate.txt`, combining the checksums and
every contributing tier's evidence file into one record, which the
release procedure attaches to the release.

______________________________________________________________________

## 16. Continuous integration and releases

Three workflows live in `.github/workflows/`. Every action is pinned by
full commit SHA, the default token permission is `contents: read`, and every
checkout sets `persist-credentials: false`.

_Table 7: workflows, their triggers and what they may do._

| Workflow | Trigger | Jobs | Writes? |
| --- | --- | --- | --- |
| `ci.yml` | pull requests, pushes to `main` | lint and offline tests; build plus container tier per target | No |
| `acceptance.yml` | pushes to `main`, manual dispatch | fresh-guest CUSE tier per target | No |
| `release.yml` | tags matching `v*` | lint and offline tests; build plus container tier; CUSE tier on those artefacts; publish | Only the publish job |

`ci.yml` cancels superseded runs of the same ref. `release.yml` has its own
concurrency group per tag and is never cancelled, so a publication in
progress is not interrupted.

The CUSE tier needs KVM. It is never triggered by `pull_request`, so code
from a fork cannot reach a virtualization-capable runner; ordinary pull
request validation is the read-only `ci.yml`. The workflows currently use
GitHub-hosted `ubuntu-24.04` runners, which are ephemeral. The composite
actions in `.github/actions/` install the prerequisites and then run the
same preflight scripts as a developer would. A runner that cannot satisfy a
preflight fails the job; nothing falls back to privileged containers, the
system libvirt connection or emulation. On the hosted runner only, the
set-up step opens `/dev/kvm` to the runner user with a udev rule, which is
GitHub's documented method for an ephemeral machine and must not be copied
to a shared host.

Verified guest images are cached with `actions/cache`, keyed on
`fixtures/cuse/images.tsv`. `scripts/cuse-image.sh` still checks the bytes on
every use, so a bad cache entry is replaced rather than booted. Overlays are
per run and are never cached.

On failure, jobs upload their `make` log and the retained tmt run
directories. These contain test output, journals and unit state. The build
scripts never log the source URL, and the per-run SSH keys that tmt generates
for a guest are excluded from the upload; the guests they belonged to have
been destroyed by then.

### Release procedure

1. Land the change on `main` through a reviewed pull request, with
   `make release-check` passing on a clean tree.
2. If the package changed, bump `Release:` (or the snapshot) in
   `guildmaster.spec`, add a `%changelog` entry and update `CHANGELOG.md`.
3. Tag the merged commit. The tag is `v`, the RPM version with the caret
   replaced by a hyphen (Git does not allow a caret in a ref), a hyphen and
   the release number, for example `v0.1-20251202git463382b-1`. Push the tag.
4. `release.yml` builds each target once and runs the container tier. It
   uploads `dist/<target>` as the candidate. The CUSE jobs download that
   candidate and run `make accept-cuse-<target>`, which tests what is in
   `dist/` and builds no packages. The publish job needs every other job,
   for every target: a failed or skipped guest job blocks the release.
5. The publish job builds nothing. It runs `scripts/release-evidence.sh` to
   confirm that both tiers passed for this commit on exactly the candidate
   bytes, then `scripts/assemble-release.sh`, which checks the tag against
   the spec, requires exactly the expected four packages per target with the
   right dist tag, architecture and checksums, rejects anything missing,
   extra or duplicated, and writes the assets, `SHA256SUMS` and the release
   notes.
6. The release is created as a draft, the assets are uploaded, and only then
   is it made public.
7. Afterwards, download the public assets, run `sha256sum --check
   SHA256SUMS`, and repeat the guest tier on the downloaded packages, as
   described below.

GitHub replaces a caret in an asset name with a full stop. The assembly
script performs that rename itself, so `SHA256SUMS` lists the names users
will actually download, using release-relative file names.

The RPMs are unsigned. There is no approved signing infrastructure for this
repository, and none is invented here. `SHA256SUMS` detects changed bytes; it
is not an RPM signature and, coming from the same place as the packages, not
an independent guarantee of authenticity.

### Re-running a release

Re-running `release.yml` for a tag is safe. If a public release already
exists for the tag, the publish job compares its `SHA256SUMS` with the newly
assembled one: identical means there is nothing to do, and any difference
fails the job. Published packages are never replaced under the same tag; a
changed package needs a new `Release:` and a new tag. A draft left behind by
an interrupted run was never public and is deleted and recreated.

### Verifying a published release

`scripts/verify-release.sh <tag> <directory>` downloads the public assets,
checks them against `SHA256SUMS`, checks the RPM metadata against the tag,
and lays them out per target with a manifest so that the guest tier can be
run on them:

```bash
scripts/verify-release.sh v0.1-20251202git463382b-1 .build/release-check
EVIDENCE_KIND=release scripts/cuse-guest.sh rocky-10 \
    .build/release-check/rocky-10
EVIDENCE_KIND=release scripts/cuse-guest.sh fedora-43 \
    .build/release-check/fedora-43
```

Evidence from these runs is written as `cuse-<target>-release.txt`, apart
from the candidate evidence.
