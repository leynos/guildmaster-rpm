# Digest-pinned for reproducibility; this is fedora:43 as of 2026-07-26.
FEDORA_IMAGE := registry.fedoraproject.org/fedora@sha256:af06c24b2e90bef115bba80e428ac21466db8869ad544f3424b969513b67eeae
# quay.io rather than docker.io: Docker Hub rate-limits anonymous pulls,
# which bites on shared CI runner IPs. Digest-pinned for reproducibility;
# this is rockylinux:10 as of 2026-07-25.
ROCKY_IMAGE  := quay.io/rockylinux/rockylinux@sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834

.PHONY: all rpms rpm-fedora-43 rpm-rocky-10 unit clean

# The build targets share podman resources, so keep them ordered within a
# single make process. Cross-process safety does not rely on this: the
# tarball cache is checksum-gated, output is published atomically under a
# per-target lock, and clean takes the activity lock exclusively.
.NOTPARALLEL:

# The container and guest test tiers replace this with `test` once they land;
# until then the offline checks are the whole default gate.
all: unit

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
	scripts/tests/model_check.py

# ---------------------------------------------------------------------------
# EP-M4 onwards add test, test-fedora-43, test-rocky-10, test-cuse, lint and
# release-check here. `all` becomes `all: test` at that point.
# ---------------------------------------------------------------------------

# Serialized against builds via .build/locks/activity.lock; keeps that lock
# directory so a waiting build cannot end up locking an unlinked inode, and
# keeps .build/images/ unless CLEAN_IMAGES=1.
clean:
	scripts/clean.sh
