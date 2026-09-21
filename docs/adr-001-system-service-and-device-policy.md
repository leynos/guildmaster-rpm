# ADR 001: system service, device policy, test boundary and capacity patch

- Status: accepted
- Date: 2026-09-21
- Deciders: Payton McIntosh

## Context

`guildmaster` serves `/dev/guild`, a GNU Make jobserver shared by a whole
machine, through CUSE (Character Device in Userspace). The consumer of these
packages, `leynos/dev-env-rocky`, configures development hosts on which
several coding agents build at once, and needs a small, explicit number of
job tokens, initially two.

Upstream commit `463382b` ships a systemd unit that runs the daemon as root
with no options, a udev rule that makes `/dev/guild` world-writable
(`MODE="0666"`), and a token capacity fixed at the number of online
processors plus one. None of those suits a shared development host.

Four decisions follow. They are recorded together because each constrains
the others.

## Decision 1: a disabled system unit under an unprivileged account

In the context of a machine-wide device that every build on the host shares,
facing the choice between a system unit and per-user units, we decided for a
single system unit, `guildmaster.service`, to achieve exactly one token pool
per machine, accepting that an operator with root must activate it.

The daemon runs as the system account `guildmaster`, created by
`sysusers.d`. It needs no privilege beyond opening `/dev/cuse`: libfuse's
CUSE path uses the already opened descriptor and performs no mount. The unit
drops every capability, sets `NoNewPrivileges`, `ProtectSystem=strict`,
`PrivateNetwork`, a system-call filter and `DevicePolicy=closed` with
`/dev/cuse` as the only additional device. The daemon never executes builds;
compilers run as the users who invoke them.

Installing the package does not enable or start the service. The scriptlets
are the standard `%systemd_post` and `%systemd_preun`, so the distribution
preset decides, and both Fedora and Rocky Linux leave it disabled. Activation
is an explicit act by the operator or by Ansible.

Upgrades never restart the daemon: the spec uses `%systemd_postun`, not
`%systemd_postun_with_restart`. A restart destroys `/dev/guild` and creates a
new pool. Clients holding the old device keep dead handles and are not
counted against the new pool, so a restart in the middle of builds lets the
machine exceed its intended concurrency until those builds finish. The
supported procedure is therefore to drain and then restart, and it is the
operator's to perform. The package cannot know when the host is drained.

This is package lifecycle behaviour only. It does not provide the consuming
design's guarantees about compiler lifetimes; those belong to the future
admission supervisor in `dev-env-rocky`.

## Decision 2: two groups and package-owned udev rules

In the context of two devices with different audiences, facing upstream's
world-writable node and a root-only `/dev/cuse`, we decided for two groups
and one package-owned rules file, to achieve separation of daemon and client
permissions, accepting that the package changes the group of the shared
`/dev/cuse` node.

- `/dev/cuse` becomes `root:guildmaster`, mode `0660`. Only the daemon's
  account is in that group. Whoever can open `/dev/cuse` can create arbitrary
  character devices, so client users must never be added to it.
- `/dev/guild` becomes `root:guild`, mode `0660`. Membership of `guild` is
  the documented way to authorize a client. The daemon is not a member.
- Neither node is accessible to others. No world-writable mode is shipped.

The rule for `/dev/cuse` also tags the device for systemd. The unit
`Requires=` and orders itself after `dev-cuse.device`, which systemd only
announces once udev has processed that rule, so the daemon cannot start
before its permissions exist. The unit `Wants=modprobe@cuse.service`,
systemd's stock template, so that starting the service, by hand or at boot,
loads the module on demand. No `modules-load.d` file is shipped: a host that
leaves the service disabled never loads CUSE because of this package. An
earlier design that used `modules-load.d` could not start after installation
without a reboot, because that directory is only read at boot.

The package cannot depend on "the CUSE module for the running kernel". On
both distributions `cuse.ko` is in `kernel-modules-extra`, which minimal and
cloud installations omit. Installing it for the running kernel is an operator
prerequisite, documented in the users' guide. Without it the start job fails
on the `dev-cuse.device` dependency and the daemon is never executed.

No SELinux policy module is shipped, and none is needed: under enforcing
policy on both distributions the daemon runs as `unconfined_service_t` with
no denials. SELinux therefore does not confine the daemon; its confinement
comes from the unprivileged account and the unit's sandboxing. The package
never disables or weakens SELinux.

## Decision 3: containers for userspace, guests for CUSE

In the context of needing both fast package checks and proof of real
operation, facing the fact that a container shares its host's kernel and
devices, we decided for two test tiers with a strict boundary, to achieve
honest evidence, accepting a slower release gate.

Rootless Podman containers run each distribution's real systemd as PID 1.
They test installation, the manifest, accounts, the installed production
unit, upgrade and removal against distribution userspace. They have no CUSE,
so the only runtime claim they make is the documented failure to start
without the device. They never report guildmaster as operating, and the
production `ExecStart` is never replaced by a stand-in.

Fresh KVM guests, provisioned by tmt's virtual provisioner from
checksum-pinned cloud images through the user's libvirt session, supply
their own kernel, CUSE, udev and enforcing SELinux. Everything about real
operation is tested there, from the RPM's own files, with no repairs by the
harness. The host's `/dev/cuse` and `/dev/guild` are never passed anywhere.

Container runs on a host without SELinux are evidence about userspace only.
Confined-container coverage is claimed only for runs on an enforcing host,
and each run records which kind it was.

## Decision 4: a minimal downstream `--tokens` patch

In the context of a consumer that needs capacity two, facing an upstream
with a fixed capacity and no releases, we decided for one small patch adding
`--tokens N`, to achieve explicit capacity, accepting the cost of carrying
it until upstream offers an equivalent.

The patch parses the option with libfuse's own option parser before anything
else happens, so every other argument still reaches libfuse. It accepts only
a plain positive decimal integer that fits the pool's counter; zero, signs,
whitespace, trailing characters and out-of-range values are rejected with a
diagnostic and exit status 2 before `/dev/cuse` is opened. Without the option
behaviour is exactly upstream's. It touches no accounting code.

The package default keeps upstream's capacity. `/etc/sysconfig/guildmaster`
is a `%config(noreplace)` file that ships `GUILDMASTER_OPTS=""`; Ansible
selects a capacity by writing `GUILDMASTER_OPTS="--tokens=2"` there, without
replacing any vendor-owned file. Choosing two is a property of the consuming
deployment, not of the package.

A token count bounds how many cooperating jobserver clients run at once. It
is not a limit on processor threads or memory, and tools that ignore the
jobserver are not constrained at all.

## Consequences

- The package changes the group and mode of `/dev/cuse` while it is
  installed. Any other CUSE user on the host must run as root or join
  `guildmaster`; this is documented.
- After removal, the rules file is gone but an existing `/dev/cuse` node
  keeps its group until the module is reloaded or the host reboots. The
  accounts are left in place, as is distribution practice.
- With `Type=exec`, `systemctl start` succeeds once the daemon has been
  executed, so an invalid `--tokens` value shows up as a `failed` unit with
  `ExecMainStatus=2` immediately afterwards rather than as a failed start
  command. `RestartPreventExitStatus=2` prevents a restart loop.
- Upstream accounts for tokens per opening process, not per open file
  description as its README says. The guest tests pin the real behaviour
  down; the packaging does not change it.
- The patch must be re-examined at every upstream snapshot, and dropped when
  upstream can set its own capacity.
