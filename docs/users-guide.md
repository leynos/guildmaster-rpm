# Users' guide

This guide covers downloading, verifying, installing, activating,
configuring, upgrading and removing the guildmaster RPMs on Rocky Linux 10
and Fedora 43 (x86_64). Operators replacing an install built from upstream's
sources should read [Adopting the 0.1 packages](migrations/0.1.md) first.

## What the package provides, and what it does not

`guildmaster` serves `/dev/guild`, one GNU Make jobserver for the whole
machine. A client reads a byte to take a job token and writes it back when
the job ends. Unlike a plain FIFO, guildmaster notices when a client goes
away and returns the tokens it still held to the pool. `gm-run` runs a
command under that jobserver.

Be clear about the limits before relying on it:

- Installing guildmaster does not constrain Cargo, or anything else, by
  itself. Only programs that speak the jobserver protocol and are told to
  use `/dev/guild` take part, for example GNU Make or Ninja started through
  `gm-run`. `leynos/dev-env-rocky` supplies the later, transparent
  integration for coding agents; it is not part of this package.
- A token count is not a limit on processor threads or memory. It bounds how
  many cooperating jobs run at once. One job may still use many threads and
  any amount of memory.
- The package does not establish guarantees about the lifetime of compilers
  across restarts. See [Restart precautions](#restart-precautions).

## Download and verify

Packages are attached to the
[GitHub releases](https://github.com/leynos/guildmaster-rpm/releases) of this
repository. A release is not a DNF repository: `dnf install guildmaster`
will not find it, and there are no automatic updates. Download the files and
install them by path.

Each release carries, for each distribution, the binary package, its
`debuginfo` and `debugsource` packages, the source RPM, and one `SHA256SUMS`
file. Rocky Linux 10 packages carry `.el10` in their names, Fedora 43
packages `.fc43`.

```bash
tag=v0.1-20251202git463382b-1
gh release download "$tag" --repo leynos/guildmaster-rpm --dir guildmaster-rpms
cd guildmaster-rpms
sha256sum --check SHA256SUMS
```

`SHA256SUMS` detects files that changed after the release was
published, for example a corrupted download. It comes from the same place as
the packages, so it is not an independent guarantee of authenticity, and it
is not an RPM signature. The packages are unsigned. DNF will therefore ask
for `--nogpgcheck` or report that the package is not signed, depending on
the local DNF configuration.

## Prerequisites

guildmaster needs the `cuse` kernel module for the kernel that is running.
On both distributions it is in `kernel-modules-extra`, which minimal and
cloud installations leave out. The RPM cannot depend on "the module for the
running kernel", so the operator installs it:

```bash
sudo dnf install "kernel-modules-extra-$(uname -r)"
```

If that exact version is no longer in the repositories, update the kernel
and its modules together and reboot into it:

```bash
sudo dnf install kernel kernel-modules-extra
sudo systemctl reboot
```

`modinfo cuse` confirms it is present. There is no need to load the module
or arrange for it to load at boot; starting the service does that.

## Install

```bash
# Rocky Linux 10
sudo dnf install ./guildmaster-0.1.20251202git463382b-1.el10.x86_64.rpm

# Fedora 43
sudo dnf install ./guildmaster-0.1.20251202git463382b-1.fc43.x86_64.rpm
```

The package version is `0.1^20251202git463382b`. GitHub does not accept a
caret in an asset name, so the released files carry a full stop in its
place; `SHA256SUMS` uses the same names. The file name is not part of an
RPM's identity: `rpm -q guildmaster` reports the real version. DNF installs
the one runtime dependency, `fuse3-libs`.

Installation creates the following and starts nothing.

| Path                                          | Purpose                                 |
| --------------------------------------------- | --------------------------------------- |
| `/usr/bin/guildmaster`                        | The daemon                              |
| `/usr/bin/gm-run`                             | Runs a command under `/dev/guild`       |
| `/usr/lib/systemd/system/guildmaster.service` | Vendor unit, disabled                   |
| `/etc/sysconfig/guildmaster`                  | Operator configuration, kept on upgrade |
| `/usr/lib/sysusers.d/guildmaster.conf`        | Account and groups                      |
| `/usr/lib/udev/rules.d/70-guildmaster.rules`  | Device permissions                      |
| `guildmaster(8)`, `gm-run(1)`                 | Manual pages                            |

_Table 1: What the package installs._

It also creates the system account `guildmaster` with its group, and the
empty group `guild`.

## Configure the capacity

The package default is upstream's: one token per online processor, plus one.
To choose a capacity, set `GUILDMASTER_OPTS` in `/etc/sysconfig/guildmaster`.
For two tokens:

```bash
echo 'GUILDMASTER_OPTS="--tokens=2"' | sudo tee /etc/sysconfig/guildmaster
```

This file belongs to the operator. Upgrades never replace it, and no
vendor-owned file needs editing; this is the interface Ansible should use. The
value takes effect the next time the service starts. `--tokens` accepts a
positive decimal integer only. With anything else the daemon refuses to run: the
unit ends up `failed` with exit status 2 and a message in the journal, and
systemd does not retry. Because the unit is `Type=exec`, `systemctl start`
itself may still report success in that case, so the unit's state must be
checked afterwards.

## Activate

```bash
sudo systemctl enable --now guildmaster.service
systemctl show guildmaster.service \
    --property ActiveState,SubState,Result,ExecMainStatus,MainPID
```

Starting the service loads the `cuse` module on demand, now and at every
boot. If the module is not installed, the start fails after a wait of up to
90 seconds with `Dependency failed for guildmaster.service` in the journal,
and the daemon is never run.

## Permissions

| Device       | Owner, group and mode      | Who may open it              |
| ------------ | -------------------------- | ---------------------------- |
| `/dev/cuse`  | `root:guildmaster`, `0660` | The daemon's account only    |
| `/dev/guild` | `root:guild`, `0660`       | Members of the `guild` group |

_Table 2: Device permissions while the package is installed._

Authorize a user to take tokens by adding them to `guild`; they must log in
again for it to take effect:

```bash
sudo usermod --append --groups guild alice
```

Never add client users to the `guildmaster` group. Access to `/dev/cuse`
allows the creation of arbitrary character devices. Note that the package
changes the group of `/dev/cuse` for the whole host; any other CUSE
program must run as root or under an account in `guildmaster`.

## Use

```bash
gm-run make
```

`gm-run` waits for one token, runs the command with
`--jobserver-auth=fifo:/dev/guild` appended to `MAKEFLAGS`, and returns the
token afterwards. Its exit status is the command's; 128 plus the signal
number if the command was killed by a signal; or 1 if `/dev/guild` could not
be opened or the command could not be run. Do not pass `-j` to a Make started
this way: Make takes its parallelism from the jobserver it is handed.

Tokens are accounted per process that opened the device. When that process's
last handle is closed, including when it is killed, the tokens it still holds
go back to the pool. A handle inherited by a child process keeps the account
open until the child closes it too.

## Status and logs

```bash
systemctl show guildmaster.service \
    --property ActiveState,SubState,Result,ExecMainStatus,NRestarts
journalctl --unit guildmaster.service --boot
sudo fuser --verbose /dev/guild   # who has the device open (psmisc)
```

The daemon logs its capacity once at start-up (`token pool capacity 2`), and
each connection, disconnection and final token balance.

If the daemon crashes, systemd restarts it after two seconds. Clients of the
crashed daemon see errors on their handles.

There is no metrics interface. The journal and `systemctl show` are the only
observability the package provides: the configured capacity at start-up,
each connection and disconnection with the process identifier, each final
token balance returned to the pool, each ignored unmatched return, and the
unit's state and restart count. How many tokens are free or held, and how
many clients are waiting, is not reported. A non-blocking read of
`/dev/guild` by a member of `guild` shows whether a token is free at that
moment, but it takes the token, which must then be written back.

## Upgrades

Install the newer package the same way, with `dnf install` or
`dnf upgrade ./…rpm`. An upgrade keeps `/etc/sysconfig/guildmaster`, keeps
the service's enabled state, and deliberately does not restart a running
daemon: the old process continues to serve its clients. The new executable
is only used after the next restart, whose timing is the operator's decision.

## Restart precautions

Restarting guildmaster removes `/dev/guild` and creates a new, full pool.
Programs that had the old device open keep dead handles: they can neither
take nor return tokens, and they are not counted against the new pool. A
restart while builds are running means those builds carry on outside the
limit until they finish.

The supported procedure is to drain first:

1. Stop starting new builds.
2. Wait until nothing has the device open:
   `sudo fuser --silent /dev/guild` exits non-zero when there are no users.
3. `sudo systemctl restart guildmaster.service`.
4. Check the state and the logged capacity as shown above.

The same procedure applies after changing the capacity and after an upgrade.
The package only provides the mechanism; it cannot know when a host is
drained, and it makes no promise about compilers that outlive a restart.
That is the business of the admission supervisor planned in
`dev-env-rocky`.

## Removal

```bash
sudo dnf remove guildmaster
```

Removal stops and disables the service and removes `/dev/guild`. A
configuration file that was edited is kept as `/etc/sysconfig/guildmaster.rpmsave`.
The `guildmaster` account and both groups are left in place, as is usual for
system accounts. `/dev/cuse` keeps its group until the module is reloaded or
the host reboots.

On Rocky Linux 10, RPM does not reload systemd when a package removes a unit
file; this is true of every package there. `systemctl` may therefore still
list `guildmaster.service` as loaded and inactive until
`sudo systemctl daemon-reload` is run or the host reboots. On Fedora 43 the
reload happens by itself.
