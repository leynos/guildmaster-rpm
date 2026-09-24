# Digest-pinned for reproducibility; this is fedora:43 as of 2026-07-26.
FEDORA_IMAGE := registry.fedoraproject.org/fedora@sha256:af06c24b2e90bef115bba80e428ac21466db8869ad544f3424b969513b67eeae
# quay.io rather than docker.io: Docker Hub rate-limits anonymous pulls,
# which bites on shared CI runner IPs. Digest-pinned for reproducibility;
# this is rockylinux:10 as of 2026-07-25.
ROCKY_IMAGE  := quay.io/rockylinux/rockylinux@sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834

.PHONY: all rpms rpm-fedora-43 rpm-rocky-10 unit clean \
	upgrade-fixture-fedora-43 upgrade-fixture-rocky-10 \
	test test-fedora-43 test-rocky-10 \
	test-cuse test-cuse-fedora-43 test-cuse-rocky-10 test-device \
	accept-cuse-fedora-43 accept-cuse-rocky-10 \
	lint lint-shell lint-python lint-fmf lint-workflows lint-docs lint-spec \
	check-fmt typecheck markdownlint \
	release-check

# Guest resources for the CUSE tier: starting allocations, not measured
# minimums. GUEST_IMAGE_<target> may name an absolute path to an image to use
# instead of the per-user cache entry; it must still match the checksum
# pinned in fixtures/cuse/images.tsv.
GUEST_MEMORY_MIB ?= 2048
GUEST_CPUS ?= 2
GUEST_IMAGE_fedora-43 ?=
GUEST_IMAGE_rocky-10 ?=
export GUEST_MEMORY_MIB GUEST_CPUS

# The build targets share podman resources, so keep them ordered within a
# single make process. Cross-process safety does not rely on this: the
# tarball cache is checksum-gated, output is published atomically under a
# per-target lock, and clean takes the activity lock exclusively.
.NOTPARALLEL:

all: test

rpms: rpm-fedora-43 rpm-rocky-10

rpm-fedora-43:
	scripts/build-rpm.sh $(FEDORA_IMAGE) dist/fedora-43

rpm-rocky-10:
	scripts/build-rpm.sh $(ROCKY_IMAGE) dist/rocky-10

# Host-side tests for the build and clean scripts. No network, no container
# runtime: their curl, podman and publication-move seams are pointed at
# stubs. The fixed cases come first, then the bounded state-space sweep.
unit:
	scripts/tests/test-build-rpm.sh
	scripts/tests/test-systemd-fixture.sh
	scripts/tests/test-cuse-scripts.sh
	scripts/tests/test-release-scripts.sh
	scripts/tests/test-verify-release.sh
	scripts/tests/test-virt-preflight.sh
	scripts/tests/test-upgrade-fixture.sh
	scripts/tests/test-upgrade-fixture-cancel.sh
	uv run --no-project --with pyyaml==6.0.2 python3 scripts/tests/test_workflows.py
	scripts/tests/model_check.py

# The higher-release rebuild that the upgrade tests install over the package
# under test. Test equipment: written under .build/, never published.
# It is rebuilt from the source RPM already in dist/<target>, so it has no
# rpm-<target> prerequisite; the targets that need fresh packages list
# rpm-<target> first, and .NOTPARALLEL keeps that order.
upgrade-fixture-fedora-43:
	scripts/build-upgrade-fixture.sh $(FEDORA_IMAGE) fedora-43

upgrade-fixture-rocky-10:
	scripts/build-upgrade-fixture.sh $(ROCKY_IMAGE) rocky-10

# The normal suite: offline tests, then for each target a build and the
# /plans/container tests in a rootless Podman container running the
# distribution's systemd as PID 1. Each target installs exactly the packages
# its own rpm-<target> prerequisite just published, checked against their
# manifest. No CUSE here; see test-cuse.
test: test-fedora-43 test-rocky-10

test-fedora-43: unit rpm-fedora-43 upgrade-fixture-fedora-43
	UPGRADE_RPM_DIR=$(CURDIR)/.build/upgrade-fixture/fedora-43 \
		scripts/systemd-fixture.sh fedora-43 $(FEDORA_IMAGE) dist/fedora-43

test-rocky-10: unit rpm-rocky-10 upgrade-fixture-rocky-10
	UPGRADE_RPM_DIR=$(CURDIR)/.build/upgrade-fixture/rocky-10 \
		scripts/systemd-fixture.sh rocky-10 $(ROCKY_IMAGE) dist/rocky-10

# CUSE acceptance: one fresh, disposable KVM guest per distribution, run
# sequentially. The target name selects the image, the distro context and the
# packages together. Run on their own, these targets build the packages
# first. Within one make invocation each rpm-<target> runs once, so the
# container tier and the guest tier of a release-check exercise the same
# bytes; scripts/release-evidence.sh then checks that they did.
test-cuse: test-cuse-rocky-10 test-cuse-fedora-43

test-cuse-rocky-10: rpm-rocky-10 accept-cuse-rocky-10

test-cuse-fedora-43: rpm-fedora-43 accept-cuse-fedora-43

# The guest tier against the packages that are already in dist/<target>,
# without building. The release workflow uses these on the artefacts its
# build job produced, so that what is accepted is what is published.
accept-cuse-rocky-10: upgrade-fixture-rocky-10
	UPGRADE_RPM_DIR=$(CURDIR)/.build/upgrade-fixture/rocky-10 \
	GUEST_IMAGE=$(GUEST_IMAGE_rocky-10) \
		scripts/cuse-guest.sh rocky-10 dist/rocky-10

accept-cuse-fedora-43: upgrade-fixture-fedora-43
	UPGRADE_RPM_DIR=$(CURDIR)/.build/upgrade-fixture/fedora-43 \
	GUEST_IMAGE=$(GUEST_IMAGE_fedora-43) \
		scripts/cuse-guest.sh fedora-43 dist/fedora-43

test-device: test-cuse

SHELL_SOURCES := $(wildcard scripts/*.sh scripts/tests/*.sh scripts/tests/stubs/*.sh packaging/*.sh \
	tests/lib/*.sh tests/*/*/test.sh)
PYTHON_SOURCES := scripts/tests tests/cuse/accounting

lint: lint-shell lint-python typecheck lint-fmf lint-workflows lint-docs lint-spec

# Estate-standard gate names.
check-fmt:
	shfmt -d -i 4 $(SHELL_SOURCES)
	uvx ruff format --check $(PYTHON_SOURCES)

typecheck:
	uvx ty check $(PYTHON_SOURCES)

markdownlint: lint-docs

lint-shell:
	shellcheck -x -P SCRIPTDIR $(SHELL_SOURCES)
	shfmt -d -i 4 $(SHELL_SOURCES)

lint-python:
	@# ruff's EXE001 cannot see the executable bit on every filesystem (WSL
	@# mounts, for one), so check scripts with a shebang explicitly.
	@status=0; for f in $$(git ls-files '*.py'); do \
		if [ "$$(head -c 2 "$$f")" = '#!' ] && [ "$$(git ls-files -s "$$f" | cut -c1-6)" != 100755 ]; then \
			echo "$$f has a shebang but is not executable in git" >&2; status=1; \
		fi; \
	done; exit $$status
	uvx ruff check $(PYTHON_SOURCES)
	uvx ruff format --check $(PYTHON_SOURCES)

# The CUSE plan takes its guest resources from context, so lint needs them.
lint-fmf:
	tmt -c distro=fedora-43 -c guest_cpus=2 -c guest_memory_mib=2048 lint \
		--failed-only --enforce-check C001

lint-workflows:
	actionlint

lint-docs:
	markdownlint-cli2 '**/*.md' '#.build' '#dist'
	@if grep -rqs --include='*.md' --exclude-dir=.build --exclude-dir=dist '^[`]\{3\}mermaid' . ; then \
		nixie --no-sandbox $$(git ls-files '*.md'); \
	else \
		echo 'no Mermaid diagrams to validate'; \
	fi

# rpmlint of the built packages runs inside the container tier, against the
# distributions' own rpmlint configuration; this checks the spec on the host
# where rpmlint is installed.
lint-spec:
	@if command -v rpmlint >/dev/null 2>&1; then \
		rpmlint --config packaging/rpmlint.toml guildmaster.spec; \
	else \
		echo 'rpmlint is not installed; the spec is linted in the container tier'; \
	fi

# Everything a release candidate must pass, in order. A
# missing virtualization prerequisite fails test-cuse and therefore this
# target: container results never stand in for the guest tier.
release-check: lint test test-cuse
	scripts/release-evidence.sh

# Serialized against builds via .build/locks/activity.lock; keeps that lock
# directory so a waiting build cannot end up locking an unlinked inode.
clean:
	scripts/clean.sh
