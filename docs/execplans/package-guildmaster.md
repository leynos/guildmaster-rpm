# Package, test, document and publish guildmaster RPMs

This ExecPlan (execution plan) is a living document. The sections
`Constraints`, `Tolerances`, `Risks`, `Progress`, `Surprises & discoveries`,
`Decision log`, `Outcomes & retrospective`, `Conformance basis`, and
`Verification plan` must be kept up to date as work proceeds.

Status: IN PROGRESS

## Purpose / big picture

`guildmaster` is a small C daemon that exposes a machine-wide GNU Make
jobserver as the character device `/dev/guild`, using CUSE (Character Device
in Userspace, a kernel facility that lets an unprivileged process implement a
device node). `leynos/dev-env-rocky` needs it installed from an RPM on
development hosts that run several coding agents at once, with an explicit
token capacity (initially two).

After this work, an operator can download an x86_64 RPM for Rocky Linux 10 or
Fedora 43 from a tagged GitHub release of `leynos/guildmaster-rpm`, verify it
against `SHA256SUMS`, install it with `dnf install ./guildmaster-*.rpm`, set
the capacity in `/etc/sysconfig/guildmaster`, enable `guildmaster.service`,
and have members of the `guild` group acquire tokens from `/dev/guild`.
Success is observable as: `make release-check` passing locally, the tagged
release workflow finishing green, and the downloaded public RPMs passing the
fresh-guest CUSE acceptance plan.

## Constraints

- Do not install or activate guildmaster on the shared development host
  (`ibara`, Fedora 43 under WSL2). Do not change its device permissions,
  SELinux policy or cgroup settings. All package installation happens in
  disposable containers or virtual machines.
- No rootful Podman, `--privileged`, host cgroup bind mounts, host PID
  namespace, host systemd socket or blanket SELinux label disabling.
- Never pass the host's `/dev/cuse` or `/dev/guild` into a container or
  guest.
- Devices must not be world-writable. Upstream's udev rule
  (`MODE="0666"`) therefore cannot be shipped unchanged.
- The package must not enable or start the service on installation, and must
  not restart it on upgrade.
- No hosted DNF repository, COPR project or new signing key. RPMs are
  published unsigned and described as such.
- Out of scope: the consuming RFC's Cargo adapter, admission supervisor,
  agent configuration and Ansible roles.
- Gates run sequentially, with output captured through `tee` under
  `set -o pipefail`. Build trees live in ignored repository directories
  (`.build/`, `dist/`), not `/tmp`.
- Prose uses British English with Oxford spelling.
- Only invocation-owned resources are ever cleaned up.

## Tolerances (exception triggers)

- Host changes: any `sudo` package installation on the development host
  beyond the set approved with this plan requires escalation.
- Downstream patch: if the capacity patch exceeds roughly 80 changed lines
  in `guildmaster.c`, or needs to touch token-accounting logic, stop and
  escalate.
- Iterations: if a single gate still fails after five distinct fix
  attempts, stop and escalate with diagnostics.
- Environment: if the WSL2 host cannot run KVM guests through user-session
  libvirt, stop and escalate; do not fall back to software emulation or a
  rootful path.
- Security: if guildmaster cannot start under SELinux enforcing in a guest
  without new policy, stop and present the recorded AVC denials and options
  rather than shipping generated policy.
- Publication: a release is only tagged from a reviewed, merged commit with
  every `make release-check` gate passing. A merge that requires human
  approval is an expected stopping point.

## Risks

- Risk: WSL2 nested virtualization or user-session libvirt does not work on
  this host, blocking the CUSE tier locally.
  Severity: high. Likelihood: medium.
  Mitigation: prototype first (EP-M1). `/dev/kvm` exists with mode 0666 and
  the CPU exposes `vmx`. If it fails, escalate; hosted GitHub runners with
  KVM are the contingency.
- Risk: GitHub-hosted runners lack the cgroup delegation needed for rootless
  systemd containers, or usable KVM.
  Severity: high. Likelihood: medium.
  Mitigation: the preflight scripts report precisely; CI findings are
  recorded and, if hosted runners fail, escalate for a self-hosted runner
  decision rather than weakening the fixture.
- Risk: the host has SELinux disabled, so container runs here give
  userspace evidence only, never confined-container evidence.
  Severity: medium. Likelihood: certain.
  Mitigation: report the boundary honestly. Guests run enforcing and supply
  the SELinux evidence for the daemon itself.
- Risk: an unprivileged service account cannot open `/dev/cuse` (root-only,
  mode 0600 by default), or SELinux denies CUSE to an unconfined service.
  Severity: high. Likelihood: medium.
  Mitigation: ship a package-owned udev rule granting the `guildmaster`
  group access to `/dev/cuse` only; verify in guests; escalate on AVCs.
- Risk: upstream accounts tokens per opening process identifier rather than
  per open file description, so inherited-handle semantics differ from the
  README.
  Severity: medium. Likelihood: high (seen in source).
  Mitigation: test and document actual behaviour; do not patch it.
- Risk: tmt's container provisioner cannot pass `--systemd=always`.
  Severity: medium. Likelihood: certain (confirmed in tmt 1.76 source).
  Mitigation: a small tested fixture adapter launches the container and tmt
  connects to it; see Decision log.

## Progress

- [x] (2026-09-21 17:00Z) Confirmed `leynos/guildmaster-rpm` exists with an
  empty initial commit; created branch `package-guildmaster`.
- [x] (2026-09-21 17:10Z) Confirmed baseline `ef8dcbd` and upstream
  `463382b` are still the heads; read upstream in full.
- [x] (2026-09-21 17:20Z) Host survey and rootless systemd prototype
  (Fedora fixture boots; state `degraded` from `systemd-resolved`).
- [x] (2026-09-21 17:30Z) Drafted this plan.
- [x] (2026-09-21 18:00Z) Plan approved by the user; the approval answered
  the host-tooling question with an instruction to proceed as planned.
- [x] (2026-09-21 18:50Z) EP-M1 virtualization prototype: host tooling
  installed; a disposable Rocky 10 guest booted through
  `tmt … provision --how virtual --connection session` with KVM under WSL2;
  the trial RPM's service started unprivileged under SELinux enforcing with
  no AVC denials, and group permissions and capacity two held.
- [x] (2026-09-21 20:00Z) EP-M2 capacity patch and spec, including the SRPM
  rebuild in every build and the version-ordering test.
- [x] (2026-09-21 20:00Z) EP-M3 build scripts, unit suite and model checks.
  Delegated to a journeyman. The real three-phase builds pass on both
  targets: dependencies with network, then `rpmbuild -ba` and a clean SRPM
  rebuild with `--network=none`, four packages each, temporary container
  and image removed. `make unit`: 52 build-script cases, 84 fixture checks,
  68 CUSE-script checks, 22 executed scenarios and 10408 abstract schedules
  in the bounded model, four seeded model faults rejected.
- [x] (2026-09-21 21:05Z) EP-M4 rootless systemd container tier: eight tests
  pass on both targets against real builds (host without SELinux, so
  userspace evidence only).
- [x] (2026-09-21 21:05Z) EP-M5 CUSE guest tier: thirteen tests pass in fresh
  guests on both targets against real builds, SELinux enforcing.
- [x] (2026-09-21 20:20Z) EP-M6 documentation and lint gates.
- [x] (2026-09-21 21:05Z) `make release-check` passed on a clean tree at
  `fb84046`; log and evidence kept in the session scratchpad.
- [x] (2026-09-23 15:00Z) CodeRabbit review: 13 findings, all actioned;
  `make release-check` passed again on a clean tree at `be97be6`, now with
  fourteen guest tests per target.
- [ ] EP-M7 CI, PR and review (completed: workflows, offline suites for
  every script and for the workflows themselves, PR #1, hosted CI green on
  every pushed head since run 35648908683 with the rootless systemd
  preflight passing on `ubuntu-24.04` and Podman 4.9.3, and three rounds
  of CodeRabbit and Codex review, each finding actioned or, for the
  metrics interface, declined by the maintainer; remaining: merge, and the
  hosted CUSE tier, which can only run once `acceptance.yml` is on
  `main`).
- [ ] EP-M8 release and post-publication verification.

## Surprises & discoveries

- Observation: the host is Fedora 43 under WSL2 with SELinux absent
  (`getenforce` missing, Podman reports `selinuxEnabled: false`).
  Evidence: `podman info`; empty `ProcessLabel` on the prototype container.
  Impact: confined-container coverage cannot be claimed from this host.
- Observation: libvirt, testcloud, `qemu-img`, `meson`, `rpmlint` and
  `shfmt` are not installed; `tmt` is 1.76.0 and Fedora offers
  `tmt+provision-virtual` 1.78.0. Passwordless `sudo` works.
  Impact: the CUSE tier needs host package installation (approval sought).
- Observation: tmt's Podman plugin hard-codes `podman run … -itd --user`
  with no hook for `--systemd=always` or `--cgroupns=private`.
  Evidence: `tmt/steps/provision/podman.py` lines 340–355.
  Impact: fixture adapter required.
- Observation: upstream's udev rule makes `/dev/guild` mode 0666, and its
  unit runs as root with no options.
  Impact: both are replaced by packaging-owned files.
- Observation: upstream keys clients by the opener's process identifier
  (`client_ref(ctx->pid)`), with a reference count per process.
  Impact: handle-semantics tests must describe this, not the README's
  "per open file description" wording.
- Observation: on Rocky Linux 10, `meson` 1.4.1 is in CRB, `fuse3-devel`
  3.16.2 in AppStream; `rpmlint` is not in BaseOS, AppStream or CRB;
  `cuse.ko.xz` is shipped for every 6.12.0-211 kernel (owning subpackage to
  be verified in the guest).
- Observation: the rootless Fedora systemd fixture reaches `degraded`
  because `systemd-resolved` fails (Podman manages `/etc/resolv.conf`).
  Impact: either mask-free fixture fix or a named documented exception.

- Observation: Rocky Linux 10's GenericCloud image installs only
  `kernel-modules-core`; `cuse.ko.xz` is in `kernel-modules-extra` (which
  pulls in `kernel-modules`), verified in the guest for kernel
  `6.12.0-211.16.1.el10_2.0.1.x86_64`. The matching package was installable
  without a kernel update or reboot on 2026-09-21; by 2026-09-23 it had
  left the repositories, and the preflight's kernel-update-and-reboot path
  ran instead (kernel `6.12.0-211.56.1.el10_2.0.1`). Guest kernels move
  with the repositories even though the base image is pinned; the evidence
  records each run's kernel.
- Observation: tmt copies an absolute-path image into its own cache,
  `/var/tmp/tmt/testcloud/images/<basename>`, and boots an overlay of that
  copy. The repository's verified image was unchanged after the run.
  Impact: INV-OVERLAY must hash tmt's cached copy as well as ours.
- Observation: under SELinux enforcing the daemon runs as
  `system_u:system_r:unconfined_service_t:s0` with no AVC denials. The
  package ships no SELinux policy, so SELinux does not confine the daemon;
  confinement comes from the unprivileged account and unit sandboxing.
- Observation: `%udev_rules_update` expands to nothing on both targets;
  systemd's file triggers reload udev rules.
- Observation: RPM file names contain `^`. GitHub may rewrite unusual
  characters in release asset names, which would break `SHA256SUMS`.
  Impact: verify in EP-M7 before relying on it; treat as a risk.
- Observation: piping `rpmbuild` into `head` kills the build with SIGPIPE.
  Impact: always log to a file and inspect afterwards.

- Observation: tmt copies the whole fmf root into every run and refuses a
  run directory inside it. Impact: run directories live under
  `/var/tmp/tmt/<unique id>`; the VM image cache lives per user under
  `~/.cache/guildmaster-rpm/images`, outside the repository.
- Observation: tmt's Podman plugin adopts an existing container with
  `provision --container NAME`, provided its run directory is bind-mounted
  at the same path. This is the adapter's hand-off; no SSH is needed.
- Observation: Fedora's weak dependencies pull `systemd-resolved` into the
  fixture, where it fails at step USER because `CAP_NET_RAW` is outside
  rootless Podman's bounding set. Without weak dependencies both fixtures
  boot to `running`, so there are no allowed failed units.
- Observation: tmt 1.78 saves a command-line `--hardware cpu.processors=N`
  as `{and: [{cpu.processors: ...}]}`, which `Hardware.from_spec` rejects
  with `KeyError: 'processors'` on any later invocation of the same run,
  including cleanup. The first guest run leaked its domain because of it
  (removed by name). Impact: resources go through tmt context into the
  plan's hardware block, and the wrapper has a by-name fallback cleanup.
- Observation: with `Type=exec`, `systemctl restart` succeeds even when the
  daemon then rejects `--tokens=0`; the unit is `failed` with
  `ExecMainStatus=2` immediately afterwards. Documented, and the test waits
  for the state instead of trusting the exit status.
- Observation: the Fedora 43 cloud image already contains `fuse3-libs`; the
  Rocky image and both container bases do not, so dependency installation
  is demonstrated there.
- Observation: the Fedora 43 GA image needed a kernel update and one reboot
  to obtain a matching `kernel-modules-extra` (kernel 7.2.5-100.fc43); the
  preflight test handles this through `tmt-reboot` and records the kernel.
- Observation: container base images set `tsflags=nodocs`; the install test
  overrides it so that manual pages and the licence are checked.

- Observation: GitHub rewrites `^` in a release asset name to `.`
  (verified with a draft release that was deleted afterwards). Impact:
  `scripts/assemble-release.sh` applies the same rename itself so that
  `SHA256SUMS` lists the names users download; tags use a hyphen for the
  caret, for example `v0.1-20251202git463382b-1`.
- Observation: under heavy I/O from other sessions on the shared host, a
  `dnf` transaction inside the build container spent about fifteen minutes
  in `wb_wait_for_completion`. It was slow, not hung; the same phase took
  65 seconds for the next target.
- Observation: a stale zero-byte `.git/index.lock` appeared during that
  stall with no git process alive; it was removed after checking.

- Observation: Rocky Linux 10's RPM (4.19) does not run systemd's reload
  file trigger when a package removes a unit file; a stock `irqbalance`
  behaves identically, in a container and in a guest. `systemctl` lists the
  removed unit as loaded and inactive until the next `daemon-reload`.
  Fedora 43 reloads by itself. Impact: recorded in the removal tests,
  asserted after the documented reload, and documented for operators.
- Observation: the journeyman's open questions for real builds were all
  answered by them: the committed dependency image works for the
  network-isolated phases, `dnf builddep` needs no `SOURCES` tree, CRB is
  enabled on Rocky, the debug package names and the `(none)` epoch are as
  validated, and the SRPM reports the build architecture.
- Observation: a test cannot extend a plan's `prepare` step through
  `adjust`; enabling EPEL for rpmlint on Rocky moved to the plan.
- Residual gap: phase B's in-container payload-path guard and manifest
  writer are exercised only by real builds, not by the offline suite. The
  host re-validates the manifest fully.

- Observation: CodeRabbit's first review of the whole branch (2026-09-23)
  reported 13 findings, none critical or high. All were actioned: the
  staged `GM_TOKENS_CHECK` was not consumed by any guest test (now
  `tests/cuse/capacity`, run as `nobody` so accepted values are exercised
  without the daemon reaching the device); the world-accessible mode check
  missed modes such as `0777`; the upgrade-fixture builder's Rocky
  detection and CRB spelling differed from `build-rpm.sh`; a returning
  `tmt-reboot` was not treated as an error; the release-script mutants
  relied on line numbers; the users' guide used second-person wording; the
  developers' guide had stale claims; and three model-check functions and
  the guest client exceeded complexity limits, now enforced by `ruff.toml`.

## Decision log

- Decision: CodeRabbit's pre-merge Observability warning, asking for a
  metrics interface in the daemon, is declined for this package. It would
  need a second downstream patch reading upstream's token-accounting state,
  which the brief's "smallest patch" requirement and this plan's patch
  tolerance rule out. The user chose, on 2026-09-23, to document the
  existing observability (journal and unit state) and record metrics as a
  proposal for upstream or `dev-env-rocky` instead.
  Date/Author: 2026-09-23, user.
- Decision: the repository's packaging is placed under the ISC licence, the
  same as upstream, with the owner as copyright holder. The baseline
  repository carries no licence file. This is the agent's choice on the
  owner's behalf and is flagged for confirmation in the pull request.
  Date/Author: 2026-09-21, Claude.
- Decision: no prepared guest base image is cached. Preparation (the
  matching `kernel-modules-extra`, with a kernel update and reboot if
  needed) happens inside each fresh guest, which keeps the prohibited
  pre-installed state trivially absent at the cost of a few minutes a run.
  Date/Author: 2026-09-21, Claude.
- Decision (supersedes the modules-load.d decision below): the unit pulls in
  systemd's stock `modprobe@cuse.service` (`Wants=` and `After=`) and
  requires `dev-cuse.device`, which udev only announces after
  `70-guildmaster.rules` has applied the group and the `systemd` tag. The
  module is therefore loaded on demand when the service starts, at boot or
  by hand, and never on hosts that leave the service disabled. No
  `modules-load.d` file is shipped. The prototype showed the first design
  could not start after installation without a reboot, because
  `modules-load.d` is only read at boot.
  Date/Author: 2026-09-21, Claude.
- Decision (refines the capacity decision below): the sysconfig variable is
  `GUILDMASTER_OPTS`, matching upstream's OpenRC `conf.d` name, so that
  Ansible writes `GUILDMASTER_OPTS="--tokens=2"`. A dedicated token variable
  would need shell logic in the unit to omit the option when unset.
  Date/Author: 2026-09-21, Claude.

- Decision: snapshot versioning `0.1^YYYYMMDDgit<short>` with `Release:
  N%{?dist}`, no epoch. Upstream declares version `0.1` in `meson.build` but
  has no tags. RPM's caret sorts a snapshot after `0.1` and before `0.1.1`
  or `0.2`; ordering is demonstrated with `rpmdev-vercmp`/`rpm --eval
  '%{lua:…rpm.vercmp…}'` in a test.
  Date/Author: 2026-09-21, Claude.
- Decision (superseded in part by the `GUILDMASTER_OPTS` refinement
  above): capacity is configured through `/etc/sysconfig/guildmaster`
  (`%config(noreplace)`), read by the vendor unit as
  `EnvironmentFile=-/etc/sysconfig/guildmaster`. As implemented, the file
  supplies `GUILDMASTER_OPTS`, which ships empty to preserve upstream's
  processors-plus-one capacity; Ansible writes
  `GUILDMASTER_OPTS="--tokens=2"`. The originally planned
  `GUILDMASTER_TOKENS` variable was not implemented. Systemd drop-ins
  remain available but are not the documented interface.
  Date/Author: 2026-09-21, Claude.
- Decision: two groups. `guildmaster` (the daemon's account and group)
  gains access to `/dev/cuse`; `guild` (clients) gains access to
  `/dev/guild` at mode 0660. The daemon is not a member of `guild`'s
  clients' privileges and clients cannot open `/dev/cuse`. Accounts are
  created with `sysusers.d`.
  Date/Author: 2026-09-21, Claude.
- Decision: CUSE module loading is a package promise, delivered by
  `/usr/lib/modules-load.d/guildmaster.conf`, and tested by the reboot
  scenario without harness `modprobe`. The kernel module package itself
  (`kernel-modules-extra` on Fedora) is an operator prerequisite because an
  RPM cannot depend on "the module for the running kernel".
  Date/Author: 2026-09-21, Claude.
- Decision: container tier uses a repository-owned fixture adapter
  (`scripts/systemd-fixture.sh`) that runs Podman with exactly the required
  options, performs readiness checks, and then hands the running container
  to tmt. The hand-off mechanism (tmt `connect` over a loopback SSH port
  versus a thin `podman exec` runner) is settled by prototype in EP-M4.
  Date/Author: 2026-09-21, Claude.
- Decision: debuginfo and debugsource packages are built, validated as part
  of the expected set, and published.
  Date/Author: 2026-09-21, Claude.

- Decision: the user approved the plan on 2026-09-21 in reply to the
  host-tooling question, and chose GitHub-hosted KVM runners (gated by the
  preflight scripts, never exposed to fork pull requests) for CI
  acceptance. The user also requires a scrutineer-run `coderabbit review
  --agent` pass after each major milestone, with deterministic gates green
  first and all concerns cleared before moving on; on rate limiting, wait
  45–90 minutes with `vsleep` before retrying.
  Date/Author: 2026-09-21, user.

## Outcomes & retrospective

Not yet started.

## Context and orientation

The working tree is `/data/leynos/Projects/guildmaster-rpm`, remote
`git@github.com:leynos/guildmaster-rpm`, currently one empty commit on
`main`. Work happens on `package-guildmaster`.

The baseline, `leynos/bash-completions-rpm` at `ef8dcbd`, provides:
`scripts/build-rpm.sh` (checksum-gated source cache, per-invocation staging,
shared activity lock, per-target publication lock, atomic exchange with a
documented non-atomic fallback and rollback, structured `build_event` logs
with redaction, injectable `CURL`/`PODMAN`/`FLOCK`/`SHA256SUM`/`PUBLISH_MV`
seams); `scripts/clean.sh`; `scripts/tests/test-build-rpm.sh` (offline unit
suite); `scripts/tests/model_check.py` (bounded state-space model); tmt
plans and tests; CI and release workflows. These are adapted, not copied
blindly: the package is native (not `noarch`), has no epoch, no `-devel`
subpackage, and gains debug packages.

Upstream `codeberg.org/amonakov/guildmaster` at `463382b` builds
`guildmaster` (links `fuse3`) and `gm-run` with Meson ≥ 1.3, and installs a
udev rule, OpenRC files and a minimal systemd unit. Capacity is fixed at
online processors plus one. Licence: ISC.

## Conformance basis

No Terms of Reference or technical design document exists. The governing
artefacts are the task brief given to the agent on 2026-09-21 and the
consuming RFC (`leynos/dev-env-rocky`, branch `concurrent-build-limits`,
`docs/rfc-concurrent-build-limits.md`, PR 224). Traced items:

```plaintext
REQ-RPM      spec, SRPM rebuild, manifest
             -> EP-M2, EP-M3
             -> tests/container/install, tests/container/versioning,
                tests/container/rpmlint, scripts/tests/test-build-rpm.sh
                (package-set validation, manifest), scripts/build-rpm.sh
                phase C (clean SRPM rebuild in every build)
REQ-CAP      --tokens N patch, sysconfig
             -> EP-M2
             -> packaging/check-tokens-option.sh (%check),
                tests/container/capacity, tests/cuse/capacity,
                tests/cuse/activation, tests/cuse/accounting,
                tests/cuse/service-lifecycle (invalid value)
REQ-BUILD    locking and publication
             -> EP-M3
             -> scripts/tests/test-build-rpm.sh, scripts/tests/model_check.py
REQ-SYSTEMD  unit, accounts, no activation, upgrade, removal
             -> EP-M4, EP-M5
             -> tests/container/install, tests/container/unit-file,
                tests/container/no-cuse, tests/container/upgrade,
                tests/container/removal, tests/cuse/activation,
                tests/cuse/permissions, tests/cuse/hardening,
                tests/cuse/service-lifecycle, tests/cuse/upgrade-running,
                tests/cuse/reboot, tests/cuse/removal
REQ-CONT     rootless systemd fixtures
             -> EP-M4
             -> scripts/tests/test-systemd-fixture.sh, make test
REQ-CUSE     fresh-guest acceptance
             -> EP-M5
             -> scripts/tests/test-cuse-scripts.sh,
                scripts/tests/test-virt-preflight.sh, make test-cuse
REQ-DOCS     README, guides, ADR
             -> EP-M6
             -> make lint (markdownlint), docs/adr-001-system-service-and-device-policy.md
REQ-CI       pinned least-privilege CI
             -> EP-M7
             -> make lint (actionlint), hosted workflow runs on PR #1
REQ-PUBLISH  verified public release
             -> EP-M7, EP-M8
             -> scripts/tests/test-release-scripts.sh,
                scripts/tests/test-verify-release.sh,
                scripts/tests/test-upgrade-fixture.sh,
                post-publication guest run
```

## Verification plan

Axioms: libfuse 3's `fuse_opt_parse` and `cuse_lowlevel_new` behave as
documented; `flock(1)`, `renameat2` and `mv --exchange` behave as
documented; tmt/testcloud create a fresh copy-on-write overlay per run
(this one is checked, not assumed — see INV-OVERLAY).

- Obligation INV-TOKENS: `--tokens N` and `--tokens=N` accept exactly the
  decimal integers `1..=ULLONG_MAX`, reject every other value, including
  larger ones and a trailing `--tokens` with no value, with a diagnostic and
  exit status 2 before opening `/dev/cuse`, and leave behaviour unchanged
  when omitted.
  Method: parameterized test over the boundary partition (`0`, `-1`, `1`,
  `2`, `ULLONG_MAX` = `18446744073709551615`, `ULLONG_MAX+1`, a far
  out-of-range value, `2x`, empty, missing, `+2`, hexadecimal, a fraction and
  a value with leading whitespace), run in `%check`, in the container tier
  and, as an unprivileged user, in the guest tier.
  Non-vacuity: parsing happens before the device is opened, so the test
  distinguishes "rejected: bad value" from "failed: no /dev/cuse" by
  message; a seeded fault (accepting `0`) must fail the test.
- Obligation INV-CAPACITY: with capacity two, two holders are admitted, a
  third blocks until a token returns; closure and abrupt death restore
  capacity; unmatched writes never raise capacity above two.
  Method: deterministic guest test using a small helper that signals state
  over pipes/FIFOs, with non-blocking reads (`EAGAIN`) as the positive
  witness that the pool is empty rather than sleeps.
  Non-vacuity: the same test first proves a third non-blocking read fails
  and, after release, succeeds.
- Obligation INV-PUBLISH (retained from baseline): readers of `dist/<target>`
  see a complete previous or complete new generation, except the documented
  absent window on the fallback path; failed promotion restores the previous
  generation; failed rollback retains it at `<staging>.previous`.
  Method: executed script tests with stub commands and FIFO barriers, plus
  the bounded model in `scripts/tests/model_check.py` adapted to the new
  package set. The model is an abstraction and bounded; it is reported as
  such, not as a proof.
  Non-vacuity: the model checker asserts reachability of contention,
  fallback and rollback-failure states; unit tests include negative
  controls (corrupt cache, missing debuginfo, unexpected extra package).
- Obligation INV-PKGSET: publication is refused unless staging holds exactly
  the expected set (binary, debuginfo, debugsource, SRPM), each native
  `x86_64` with the expected dist tag, and nothing else.
  Method: parameterized unit tests over missing/extra/duplicate/`noarch`
  cases.
- Obligation INV-OVERLAY: an acceptance run never mutates the verified base
  image.
  Method: record the base image SHA-256 before and after each run and
  compare.
- Obligation INV-PERM: unauthorized users cannot open `/dev/guild`; the
  client group cannot open `/dev/cuse`.
  Method: guest tests attempting the prohibited `open` from each identity
  and asserting `EACCES`.

## Plan of work

Stage A (no repository code): EP-M1 prototype of user-session libvirt under
WSL2 with a Rocky 10 cloud image, confirming KVM, SSH reachability, SELinux
enforcing, `modprobe cuse` and the owning kernel subpackage.

Stage B/C proceed milestone by milestone below, each test-first where a
framework exists (shell unit suite, tmt tests). Stage D is documentation,
lint gates, CI, review and release.

## Milestones and plateaus

- EP-M1 (prototype): a disposable Rocky 10 and Fedora 43 guest boot via
  `tmt … provision --how virtual --connection session`; CUSE facts recorded
  in this plan. Recovery: `tmt clean` for the named run identifiers only.
- EP-M2: `guildmaster.spec`, `patches/0001-add-tokens-option.patch`,
  `packaging/` (unit, sysusers, udev rules, sysconfig, manual pages, option
  test, rpmlint configuration), `LICENSE`. No `modules-load.d` or tmpfiles
  file is shipped; see the Decision log. Acceptance: `make rpm-fedora-43` and
  `make rpm-rocky-10` produce the four-package set; `%check` runs the option
  tests; SRPM rebuild succeeds in a clean container with networking disabled
  (`--network=none`) after dependencies are installed.
- EP-M3: `scripts/build-rpm.sh`, `scripts/clean.sh`, adapted unit suite and
  model check. Acceptance: `make unit` passes offline; each new negative
  control observed failing first.
- EP-M4: `fixtures/systemd/Containerfile`, `scripts/podman-preflight.sh`,
  `scripts/systemd-fixture.sh`, `scripts/build-upgrade-fixture.sh`,
  `plans/container.fmf`, and tests under `tests/container/` (`install`,
  `unit-file`, `capacity`, `no-cuse`, `rpmlint`, `versioning`, `upgrade`,
  `removal`). The clean SRPM rebuild runs in every build (EP-M3), not as a
  separate test. Acceptance: `make test` passes on both targets; the
  production unit's missing-device failure is asserted via `systemctl
  show`, never reported as successful operation.
- EP-M5: `scripts/cuse-image.sh` (pinned QCOW2 cache with checksum
  verification and atomic publication), `scripts/virt-preflight.sh`,
  `scripts/cuse-guest.sh`, `fixtures/cuse/images.tsv`, `plans/cuse.fmf`,
  and tests under `tests/cuse/` (`preflight`, `capacity`, `activation`,
  `permissions`, `accounting` with the Python client `gmclient.py`,
  `gm-run`, `hardening`, `service-lifecycle`, `upgrade-running`, `reboot`,
  `removal`), which also run the shared `tests/container/install`,
  `unit-file` and `versioning` tests. Acceptance: `make test-cuse` passes from fresh
  overlays on both distributions, including the reboot/module-autoload
  scenario and upgrade/drain/removal.
- EP-M6: `README.md`, `docs/users-guide.md`, `docs/developers-guide.md`,
  `docs/adr-001-system-service-and-device-policy.md`, `CHANGELOG.md`,
  `AGENTS.md`; `make lint` covering shellcheck, shfmt, actionlint, `tmt
  lint`, markdownlint, nixie, ruff/ty for Python, rpmlint where available.
- EP-M7: `.github/workflows/ci.yml`, `acceptance.yml`, `release.yml`,
  `.github/actions/setup-*-tier/`, `scripts/assemble-release.sh`,
  `scripts/release-evidence.sh`, `scripts/verify-release.sh` and their
  offline suites; PR #1; review workflow; fixes.
- EP-M8: tag `v0.1-20251202git463382b-1` (the RPM version with a hyphen for
  the caret, validated against the spec by `scripts/assemble-release.sh`),
  wait for the workflow, download assets, verify, and rerun the essential
  guest tests against the downloaded RPMs.

Compatibility decision for every milestone: none. Nothing is released yet.

## Concrete steps

Filled in as milestones execute. All commands run from the repository root.
Gate invocations take the form:

```bash
set -o pipefail; make unit 2>&1 | tee /tmp/guildmaster-rpm-unit.log
```

## Validation and acceptance

Done means `make release-check` passes locally (unit and model tests, both
container targets, both fresh-guest CUSE targets, lint), hosted CI is green
on the final commit, the release workflow has published assets, and the
downloaded assets pass checksum, metadata and fresh-guest tests. Evidence
records candidate RPM SHA-256 values, source commit, target and image
identity together.

## Idempotence and recovery

Builds publish whole generations and can be rerun. Fixture and guest names
include an invocation identifier; cleanup removes only those. The QCOW2
cache verifies bytes before reuse, so an interrupted download is refetched.
The release workflow refuses to replace assets of an existing release.

## Artefacts and notes

Prototype evidence, 2026-09-21, host `ibara`:

```plaintext
podman 5.8.0, rootless=true, cgroup v2, manager systemd, runtime crun
delegated controllers: cpu memory pids
fixture (Fedora 43 digest af06c24b…): PID 1 = systemd, state degraded
failed: systemd-resolved.service and its two varlink sockets
```

## Interfaces and dependencies

Package interface promised to `dev-env-rocky`:

```plaintext
/usr/bin/guildmaster  [--tokens N] [FUSE options]
/usr/bin/gm-run <command> [args…]
/usr/lib/systemd/system/guildmaster.service      (disabled by preset)
/etc/sysconfig/guildmaster                       (config, noreplace): GUILDMASTER_OPTS=
/usr/lib/sysusers.d/guildmaster.conf         user guildmaster; group guild
/usr/lib/udev/rules.d/70-guildmaster.rules   /dev/cuse, /dev/guild group rules
```

Host tooling to install with approval: `tmt+provision-virtual`, libvirt
client and QEMU driver packages it pulls in, `qemu-img`, `rpmlint`,
`shfmt`. `meson` is only needed inside build containers.

## Revision note

2026-09-21: initial draft from research and host prototypes.
