# guildmaster: a CUSE-based machine-wide GNU Make jobserver.
#
# Upstream has no release tags, so this packages a pinned commit as a
# post-release snapshot of the 0.1 version declared in upstream's
# meson.build. With the caret, 0.1^<date>git<commit> sorts after 0.1 and
# before any later upstream version such as 0.1.1 or 0.2, so no epoch is
# needed. See docs/developers-guide.md.
%global commit          463382ba5b47625a9355832cd792a164c54237f9
%global shortcommit     %(c=%{commit}; echo ${c:0:7})
%global snapshotdate    20251202
%global upstream_version 0.1

Name:           guildmaster
Version:        %{upstream_version}^%{snapshotdate}git%{shortcommit}
Release:        1%{?dist}
Summary:        Machine-wide GNU Make jobserver device using CUSE

License:        ISC
URL:            https://codeberg.org/amonakov/guildmaster
Source0:        %{url}/archive/%{commit}.tar.gz#/%{name}-%{commit}.tar.gz
Source1:        guildmaster.service
Source2:        guildmaster.sysconfig
Source3:        guildmaster.sysusers
Source4:        70-guildmaster.rules
Source5:        guildmaster.8
Source6:        gm-run.1
Source7:        check-tokens-option.sh

# Downstream: select the token pool capacity. Provenance, upstream base and
# removal condition are recorded in the patch header.
Patch1:         0001-add-tokens-option.patch

BuildRequires:  gcc
BuildRequires:  meson >= 1.3.0
BuildRequires:  pkgconfig(fuse3)
BuildRequires:  systemd-rpm-macros
# %%check runs check-tokens-option.sh.
BuildRequires:  bash

%{?systemd_requires}

%description
guildmaster serves /dev/guild, a FIFO-like GNU Make jobserver node
implemented with CUSE (character device in userspace), and accounts for the
tokens each client holds, so that tokens held by a client that dies are
returned to the pool. One jobserver can therefore be shared by every build
on a machine. gm-run runs a command under that jobserver.

This package runs the daemon as an unprivileged system service that is not
enabled by default, restricts /dev/guild to the guild group, and adds a
--tokens option for choosing the pool capacity.

%prep
%autosetup -n %{name} -p1

%build
# The packaged unit, udev rules and configuration replace upstream's: its
# unit runs as root and its udev rule makes /dev/guild world-writable.
%meson -Dopenrc=false -Dsystemd=false -Dudev=false
%meson_build

%install
%meson_install
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_unitdir}/guildmaster.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/sysconfig/guildmaster
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_sysusersdir}/guildmaster.conf
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_udevrulesdir}/70-guildmaster.rules
install -Dpm 0644 %{SOURCE5} %{buildroot}%{_mandir}/man8/guildmaster.8
install -Dpm 0644 %{SOURCE6} %{buildroot}%{_mandir}/man1/gm-run.1

%check
bash %{SOURCE7} %{buildroot}%{_bindir}/guildmaster

%post
# Applies the distribution preset, which leaves the service disabled. The
# service is never started here.
%systemd_post guildmaster.service

%preun
%systemd_preun guildmaster.service

%postun
# Deliberately not %%systemd_postun_with_restart: restarting replaces the
# token pool underneath running builds. The operator restarts after draining.
%systemd_postun guildmaster.service

%files
%license LICENSE
%doc README.md
%{_bindir}/guildmaster
%{_bindir}/gm-run
%{_unitdir}/guildmaster.service
%config(noreplace) %{_sysconfdir}/sysconfig/guildmaster
%{_sysusersdir}/guildmaster.conf
%{_udevrulesdir}/70-guildmaster.rules
%{_mandir}/man8/guildmaster.8*
%{_mandir}/man1/gm-run.1*

%changelog
* Mon Sep 21 2026 Payton McIntosh <pmcintosh@df12.net> - 0.1^20251202git463382b-1
- Initial package of upstream commit 463382b for Fedora 43 and Rocky Linux 10
- Add the downstream --tokens option
