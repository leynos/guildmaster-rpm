# Changelog

This project follows [Common Changelog](https://common-changelog.org/).
Versions are the RPM version and release; tags replace the caret, which Git
does not allow, with a hyphen.

## [0.1^20251202git463382b-1] - 2026-09-21

_Initial release._

### Added

- RPMs of guildmaster at upstream commit `463382b` for Rocky Linux 10 and
  Fedora 43 on x86_64, with `debuginfo`, `debugsource` and source packages
- Downstream `--tokens N` option for choosing the token pool capacity
- `guildmaster.service`, disabled by default, running as the unprivileged
  `guildmaster` account and loading the `cuse` module on demand
- `guild` group for clients of `/dev/guild`, and udev rules restricting
  `/dev/cuse` and `/dev/guild`
- `/etc/sysconfig/guildmaster` for operator configuration, preserved across
  upgrades
- Manual pages `guildmaster(8)` and `gm-run(1)`

[0.1^20251202git463382b-1]: https://github.com/leynos/guildmaster-rpm/releases/tag/v0.1-20251202git463382b-1
