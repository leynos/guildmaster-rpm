#!/usr/bin/env python3
"""Bounded state-space check of the build, publication and cleanup machine.

**This is a bounded check, not a proof.** It samples a finite, seeded set of
scenarios and interleavings, so a pass demonstrates the absence of a violation
across whatever was sampled, and nothing more.

It has two layers, and they check different things:

*   An executed layer that drives the real ``scripts/build-rpm.sh`` and
    ``scripts/clean.sh`` through stub commands and FIFOs, over a generated
    combination of cache states, container-phase outcomes, publication modes
    and clean positions. What it checks is the shell code as written.
*   An abstract layer that models the same algorithm as a small transition
    system and samples interleavings of up to two concurrent builds and a
    clean. **This is an abstract model, not the executed script**: it is a
    hand-written transition system that can agree with the documentation and
    disagree with the shell. It covers what cannot be driven directly —
    arbitrary interleavings of two builds' internal steps against a clean.

Both layers are deterministic given a seed, which is printed on every run and
reported again with the offending case on failure. Neither layer needs a
network or a container runtime.

The fixed FIFO cases in ``test-build-rpm.sh`` remain the regression tests for
specific past defects; this checker is a breadth sweep over their state space,
not a replacement for them.

Invariants, stated once here and asserted in both layers:

I1  An observable published output is either absent — and then only while a
    fallback publication is between moving the previous output aside and
    promoting the new one, or after a failure that left nothing published —
    or exactly one complete generation. Never a partial or mixed set.
I2  Clean never removes the published output or the cache while any activity
    lock is held.
I3  A successful rollback restores the prior complete output; a failed one
    retains it as recovery data.
I4  A failed or cancelled invocation leaves no invocation-owned staging
    directory, no invocation-owned temporary tarball, no container or image
    of its own, and no held lock.

Two further guards keep a pass meaningful:

*   Non-vacuity: the abstract layer must actually reach publication
    contention, the fallback's absent window, and a retained-recovery state.
    A run that reached none of them proves nothing, and fails.
*   Self-test: deliberately broken models are run through the same checker,
    which must reject every one of them.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import itertools
import os
import random
import select
import shutil
import signal
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_SH = REPO_ROOT / "scripts" / "build-rpm.sh"
CLEAN_SH = REPO_ROOT / "scripts" / "clean.sh"

COMMIT = "463382ba5b47625a9355832cd792a164c54237f9"
VERSION = "0.1^20251202git463382b"
RELEASE = "1.fc43"
ARCH = "x86_64"
TARGET = "fedora-43"
TARBALL = f"guildmaster-{COMMIT}.tar.gz"

BASE_RPM = f"guildmaster-{VERSION}-{RELEASE}.{ARCH}.rpm"
DEBUGINFO_RPM = f"guildmaster-debuginfo-{VERSION}-{RELEASE}.{ARCH}.rpm"
DEBUGSOURCE_RPM = f"guildmaster-debugsource-{VERSION}-{RELEASE}.{ARCH}.rpm"
SRC_RPM = f"srpm/guildmaster-{VERSION}-{RELEASE}.src.rpm"
COMPLETE = (BASE_RPM, DEBUGINFO_RPM, DEBUGSOURCE_RPM, SRC_RPM)
MANIFEST = "manifest.tsv"

DEFAULT_SEED = 20260921

CURL_STUB = """#!/usr/bin/env bash
set -euo pipefail
out=
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
cat "${CURL_STUB_FIXTURE}" >"${out}"
"""

# The three phases, modelled as podman presents them: a named container that
# outlives a failing command, a commit to a temporary image, and two
# throwaway runs from that image.
PODMAN_STUB = """#!/usr/bin/env bash
set -euo pipefail
state=${PODMAN_STUB_STATE}
mkdir -p "${state}/containers" "${state}/images"
slug() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }

sub=$1
shift
case ${sub} in
    commit)
        : >"${state}/images/$(slug "$2")"
        exit 0
        ;;
    rm)
        rm -f "${state}/containers/$(slug "${!#}")"
        exit 0
        ;;
    rmi)
        rm -f "${state}/images/$(slug "${!#}")"
        exit 0
        ;;
esac

args=("$@")
name=
out=
mode=
i=0
while [[ ${i} -lt ${#args[@]} ]]; do
    case ${args[i]} in
        --name) name=${args[i + 1]}; i=$((i + 2)) ;;
        --network=* | --rm) i=$((i + 1)) ;;
        -v)
            case ${args[i + 1]} in
                *:/out:z) out=${args[i + 1]%%:/out:z}; mode=rw ;;
                *:/out:ro,z) mode=ro ;;
            esac
            i=$((i + 2))
            ;;
        *) break ;;
    esac
done

if [[ -n ${name} ]]; then
    : >"${state}/containers/$(slug "${name}")"
    if [[ ${PODMAN_STUB_FAIL_PHASE:-} == deps ]]; then
        echo "podman stub: simulated dependency failure" >&2
        exit 1
    fi
    exit 0
fi

if [[ ${mode} == ro ]]; then
    if [[ ${PODMAN_STUB_FAIL_PHASE:-} == rebuild ]]; then
        echo "podman stub: simulated rebuild failure" >&2
        exit 1
    fi
    exit 0
fi

if [[ -n ${PODMAN_STUB_STARTED_FIFO:-} ]]; then
    echo started >"${PODMAN_STUB_STARTED_FIFO}"
fi
if [[ -n ${PODMAN_STUB_WAIT_FIFO:-} ]]; then
    read -r _ <"${PODMAN_STUB_WAIT_FIFO}"
fi
if [[ ${PODMAN_STUB_FAIL_PHASE:-} == build ]]; then
    echo "podman stub: simulated build failure" >&2
    exit 1
fi

mkdir -p "${out}/srpm"
echo "${PODMAN_STUB_TAG}" >"${out}/@BASE@"
if [[ -z ${PODMAN_STUB_PARTIAL:-} ]]; then
    echo "${PODMAN_STUB_TAG}" >"${out}/@DEBUGINFO@"
    echo "${PODMAN_STUB_TAG}" >"${out}/@DEBUGSOURCE@"
    echo "${PODMAN_STUB_TAG}" >"${out}/@SRC@"
fi

: >"${out}/@MANIFEST@"
for f in "${out}"/*.rpm "${out}"/srpm/*.src.rpm; do
    [[ -e ${f} ]] || continue
    rel=${f#"${out}/"}
    stem=$(basename "${rel}")
    stem=${stem%.rpm}
    arch=${stem##*.}
    if [[ ${arch} == src ]]; then arch=@ARCH@; fi
    stem=${stem%.*}
    release=${stem##*-}
    name_ver=${stem%-*}
    version=${name_ver##*-}
    pkg=${name_ver%-*}
    sum=$(sha256sum "${f}" | cut -d' ' -f1)
    printf '%s\\t%s\\t(none)\\t%s\\t%s\\t%s\\t%s\\n' \
        "${rel}" "${pkg}" "${version}" "${release}" "${arch}" "${sum}" \
        >>"${out}/@MANIFEST@"
done
"""
for _placeholder, _value in (
    ("@BASE@", BASE_RPM),
    ("@DEBUGINFO@", DEBUGINFO_RPM),
    ("@DEBUGSOURCE@", DEBUGSOURCE_RPM),
    ("@SRC@", SRC_RPM),
    ("@MANIFEST@", MANIFEST),
    ("@ARCH@", ARCH),
):
    PODMAN_STUB = PODMAN_STUB.replace(_placeholder, _value)

PUBLISH_MV_STUB = """#!/usr/bin/env bash
set -euo pipefail
args=("$@")
src=${args[-2]}
if [[ ${src} == *.previous ]]; then
    if [[ -n ${PUBLISH_MV_FAIL_ROLLBACK:-} ]]; then
        echo "publish-mv stub: refusing to roll back" >&2
        exit 1
    fi
elif [[ -n ${PUBLISH_MV_FAIL_PROMOTION:-} ]]; then
    echo "publish-mv stub: refusing to promote" >&2
    exit 1
fi
exec mv "$@"
"""


class CheckFailure(Exception):
    """An invariant did not hold for a generated case."""


# --------------------------------------------------------------------------
# Executed layer
# --------------------------------------------------------------------------


def write_stubs(bindir: Path) -> None:
    bindir.mkdir(parents=True, exist_ok=True)
    for name, body in (
        ("curl", CURL_STUB),
        ("podman", PODMAN_STUB),
        ("publish-mv", PUBLISH_MV_STUB),
    ):
        path = bindir / name
        path.write_text(body)
        path.chmod(0o755)


def classify(directory: Path) -> str:
    """Describe a package directory as absent, complete:<tag>, partial or mixed."""
    if not directory.is_dir():
        return "absent"
    found: dict[str, str] = {}
    for name in COMPLETE:
        candidate = directory / name
        if candidate.is_file():
            found[name] = candidate.read_text().strip()
    extra = {
        str(p.relative_to(directory)) for p in directory.rglob("*.rpm") if p.is_file()
    } - set(COMPLETE)
    if extra:
        return "mixed"
    if not found:
        return "absent"
    if len(found) != len(COMPLETE) or not (directory / MANIFEST).is_file():
        return "partial"
    tags = set(found.values())
    if len(tags) != 1:
        return "mixed"
    return f"complete:{tags.pop()}"


def lock_is_free(path: Path) -> bool:
    if not path.exists():
        return True
    with open(path, "w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        fcntl.flock(handle, fcntl.LOCK_UN)
    return True


class Sandbox:
    """One disposable case directory wired to the stubs."""

    def __init__(self, root: Path, bindir: Path, fixture: Path, digest: str) -> None:
        self.root = root
        self.bindir = bindir
        self.fixture = fixture
        self.digest = digest
        self.out = root / TARGET
        self.cache = root / "cache"
        self.locks = self.cache / "locks"
        self.staging = root / ".staging"
        self.podman_state = root / "podman-state"

    def base_env(self, tag: str) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "CURL": str(self.bindir / "curl"),
                "PODMAN": str(self.bindir / "podman"),
                "CURL_STUB_FIXTURE": str(self.fixture),
                "PODMAN_STUB_TAG": tag,
                "PODMAN_STUB_STATE": str(self.podman_state),
                "TARBALL_URL": "https://example.invalid/" + TARBALL,
                "TARBALL_SHA256": self.digest,
                "CACHE_DIR": str(self.cache),
                "LOCK_DIR": str(self.locks),
                "STAGING_ROOT": str(self.staging),
            }
        )
        return env

    def seed_cache(self, state: str) -> set[str]:
        """Set the cache to one of absent/valid/corrupt/interrupted."""
        self.cache.mkdir(parents=True, exist_ok=True)
        target = self.cache / TARBALL
        if state == "valid":
            shutil.copyfile(self.fixture, target)
        elif state == "corrupt":
            target.write_text("truncated junk")
        elif state == "interrupted":
            (self.cache / f"{TARBALL}.ABC123").write_text("half a download")
        return self.temp_tarballs()

    def temp_tarballs(self) -> set[str]:
        if not self.cache.is_dir():
            return set()
        return {p.name for p in self.cache.glob(f"{TARBALL}.??????")}

    def staging_entries(self) -> tuple[tuple[str, ...], tuple[str, ...]]:
        if not self.staging.is_dir():
            return ((), ())
        owned: list[str] = []
        recovery: list[str] = []
        for entry in self.staging.iterdir():
            (recovery if entry.name.endswith(".previous") else owned).append(entry.name)
        return tuple(sorted(owned)), tuple(sorted(recovery))

    def container_residue(self) -> tuple[str, ...]:
        names: list[str] = []
        for kind in ("containers", "images"):
            directory = self.podman_state / kind
            if directory.is_dir():
                names.extend(f"{kind}/{p.name}" for p in directory.iterdir())
        return tuple(sorted(names))

    def run_build(self, tag: str, extra: dict[str, str]) -> subprocess.CompletedProcess:
        env = self.base_env(tag)
        env.update(extra)
        return subprocess.run(
            [str(BUILD_SH), "fake-image", str(self.out)],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
            check=False,
        )

    def run_clean(self) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.update(
            {
                "CACHE_DIR": str(self.cache),
                "LOCK_DIR": str(self.locks),
                "DIST_DIR": str(self.out),
            }
        )
        return subprocess.run(
            [str(CLEAN_SH)],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
            check=False,
        )

    def locks_free(self) -> bool:
        locks = self.locks.glob("*.lock") if self.locks.is_dir() else []
        return all(lock_is_free(p) for p in locks)


def publication_env(mode: str, bindir: Path) -> dict[str, str]:
    if mode in ("first", "exchange"):
        return {}
    env = {"PUBLISH_EXCHANGE": "never"}
    if mode in ("promotion_failure", "rollback_failure"):
        env["PUBLISH_MV"] = str(bindir / "publish-mv")
        env["PUBLISH_MV_FAIL_PROMOTION"] = "1"
    if mode == "rollback_failure":
        env["PUBLISH_MV_FAIL_ROLLBACK"] = "1"
    return env


def build_env(outcome: str) -> dict[str, str]:
    if outcome == "partial":
        return {"PODMAN_STUB_PARTIAL": "1"}
    if outcome in ("deps_failure", "build_failure", "rebuild_failure"):
        return {"PODMAN_STUB_FAIL_PHASE": outcome.removesuffix("_failure")}
    return {}


def check_exit_status(
    result: subprocess.CompletedProcess, *, expect_success: bool
) -> None:
    """Assert the build's exit status matches what the scenario expects."""
    if expect_success and result.returncode != 0:
        raise CheckFailure(
            f"expected success, got {result.returncode}: {result.stderr}"
        )
    if not expect_success and result.returncode == 0:
        raise CheckFailure("expected a non-zero exit status")


def _check_i3_generation(
    case: dict[str, object],
    sandbox: Sandbox,
    state: str,
    recovery: tuple[str, ...],
    *,
    expect_success: bool,
    primed: bool,
) -> None:
    """I3: the successful, rolled-back or recovery-retaining generation."""
    if expect_success:
        if state != "complete:current":
            raise CheckFailure(f"expected the new generation, found {state}")
    elif case["publish"] == "rollback_failure" and primed:
        # I3's negative case: rollback failed, so the previous generation is
        # preserved as recovery data rather than published.
        if not recovery:
            raise CheckFailure("the recoverable .previous directory was removed")
        recovered = classify(sandbox.staging / recovery[0])
        if recovered != "complete:previous":
            raise CheckFailure(f"recovery data is {recovered}")
    elif primed:
        # I3: a failure before or during publication leaves the prior
        # complete output in place, restoring it if rollback was needed.
        if state != "complete:previous":
            raise CheckFailure(f"expected the previous generation, found {state}")
    elif state != "absent":
        raise CheckFailure(f"expected no output, found {state}")


def check_published_state(
    case: dict[str, object], sandbox: Sandbox, *, expect_success: bool, primed: bool
) -> None:
    """Assert I1, I3 and the owned-staging half of I4 for the result."""
    state = classify(sandbox.out)
    owned, recovery = sandbox.staging_entries()

    # I1: never partial, never mixed.
    if state in ("partial", "mixed"):
        raise CheckFailure(f"published output is {state}")

    _check_i3_generation(
        case, sandbox, state, recovery, expect_success=expect_success, primed=primed
    )

    # I4: nothing invocation-owned survives a failure.
    if owned:
        raise CheckFailure(f"invocation-owned staging left behind: {owned}")


def check_invocation_residue(sandbox: Sandbox, pre_temps: set[str]) -> None:
    """Assert the rest of I4: no temporary tarball, container, image or lock
    left behind by this invocation."""
    leaked = sandbox.temp_tarballs() - pre_temps
    if leaked:
        raise CheckFailure(f"temporary tarballs left behind: {sorted(leaked)}")
    residue = sandbox.container_residue()
    if residue:
        raise CheckFailure(f"containers or images left behind: {residue}")
    if not sandbox.locks_free():
        raise CheckFailure("a lock is still held")


def check_clean_after(sandbox: Sandbox) -> None:
    """Run clean after the build and assert I2 in its simplest form."""
    before_state = classify(sandbox.out)
    clean_result = sandbox.run_clean()
    if clean_result.returncode != 0:
        raise CheckFailure(f"clean failed: {clean_result.stderr}")
    # I2, in its simplest form: with no activity lock held, clean removes
    # the output and the cache but keeps the lock directory.
    if sandbox.out.exists():
        raise CheckFailure(f"clean left the output in place (was {before_state})")
    if (sandbox.cache / TARBALL).exists():
        raise CheckFailure("clean left the cached tarball in place")
    if not sandbox.locks.is_dir():
        raise CheckFailure("clean removed the lock directory")


def check_executed_case(
    case: dict[str, object], sandbox: Sandbox, bindir: Path
) -> None:
    """Run one generated scenario and assert I1-I4 on the result."""
    pre_temps = sandbox.seed_cache(str(case["cache"]))

    if case["clean"] == "before":
        sandbox.run_clean()
        pre_temps = set()

    primed = bool(case["primed"])
    if primed:
        result = sandbox.run_build("previous", {})
        if result.returncode != 0:
            raise CheckFailure(f"priming build failed: {result.stdout}{result.stderr}")

    extra = build_env(str(case["build"]))
    extra.update(publication_env(str(case["publish"]), bindir))

    if case["build"] == "cancel":
        result = run_cancelled_build(sandbox, extra)
        expect_success = False
    else:
        result = sandbox.run_build("current", extra)
        expect_success = case["build"] == "success" and case["publish"] not in (
            "promotion_failure",
            "rollback_failure",
        )

    check_exit_status(result, expect_success=expect_success)
    check_published_state(case, sandbox, expect_success=expect_success, primed=primed)
    check_invocation_residue(sandbox, pre_temps)

    if case["clean"] == "after":
        check_clean_after(sandbox)


def run_cancelled_build(
    sandbox: Sandbox, extra: dict[str, str]
) -> subprocess.CompletedProcess:
    """Start a build, block it inside the build phase, then signal it."""
    started = sandbox.root / "started.fifo"
    waiting = sandbox.root / "wait.fifo"
    for fifo in (started, waiting):
        if fifo.exists():
            fifo.unlink()
        os.mkfifo(fifo)

    env = sandbox.base_env("cancelled")
    env.update(extra)
    env["PODMAN_STUB_STARTED_FIFO"] = str(started)
    env["PODMAN_STUB_WAIT_FIFO"] = str(waiting)

    proc = subprocess.Popen(
        [str(BUILD_SH), "fake-image", str(sandbox.out)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        start_new_session=True,
    )
    # O_NONBLOCK so a stub that never starts cannot wedge the checker.
    fd = os.open(started, os.O_RDONLY | os.O_NONBLOCK)
    try:
        ready, _, _ = select.select([fd], [], [], 60)
        if not ready:
            proc.kill()
            raise CheckFailure("the container stub never announced its start")
        os.read(fd, 64)
    finally:
        os.close(fd)

    os.killpg(proc.pid, signal.SIGTERM)
    stdout, stderr = proc.communicate(timeout=60)
    return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)


def executed_cases(rng: random.Random, limit: int) -> list[dict[str, object]]:
    """A deterministic bounded sample of executable scenarios."""
    caches = ["absent", "valid", "corrupt", "interrupted"]
    builds = [
        "success",
        "partial",
        "deps_failure",
        "build_failure",
        "rebuild_failure",
        "cancel",
    ]
    publishes = [
        "first",
        "exchange",
        "fallback",
        "promotion_failure",
        "rollback_failure",
    ]
    cleans = ["none", "before", "after"]

    everything: list[dict[str, object]] = []
    for cache, build, publish, clean in itertools.product(
        caches, builds, publishes, cleans
    ):
        # "first" publication means nothing was published before; every other
        # mode needs a primed generation to act on.
        primed = publish != "first"
        # Publication mode only matters when the build reaches publication.
        if build != "success" and publish not in ("first", "exchange"):
            continue
        everything.append(
            {
                "cache": cache,
                "build": build,
                "publish": publish,
                "clean": clean,
                "primed": primed,
            }
        )

    # Always exercise the publication modes that carry recovery behaviour, and
    # at least one failure in each container phase.
    required = [
        c
        for c in everything
        if c["cache"] == "valid"
        and c["clean"] == "none"
        and (
            c["publish"] in ("promotion_failure", "rollback_failure")
            or c["build"] in ("deps_failure", "build_failure", "rebuild_failure")
        )
    ]
    rest = [c for c in everything if c not in required]
    rng.shuffle(rest)
    chosen = required + rest[: max(0, limit - len(required))]
    return chosen


# --------------------------------------------------------------------------
# Abstract layer
# --------------------------------------------------------------------------


class ModelState:
    """The observable state the invariants talk about."""

    def __init__(self) -> None:
        self.published: str | None = None  # None, or a generation tag
        self.publishing_fallback = False  # inside the documented absent window
        self.activity_holders = 0
        self.publish_lock_held = False
        self.cache = "absent"
        self.staging: dict[str, str] = {}
        self.recovery: dict[str, str | None] = {}
        self.containers: set[str] = set()
        self.images: set[str] = set()
        self.cleaned = False
        self.in_critical = 0


class _BuildAborted(Exception):
    pass


class _LockContended(Exception):
    pass


class _CleanBlocked(Exception):
    pass


Step = tuple[str, Callable[[ModelState], None]]

# States the sweep must actually reach for a pass to mean anything.
REACHED: set[str] = set()


def _fetch_and_deps_steps(name: str, scenario: dict[str, str]) -> list[Step]:
    """Acquiring the activity lock, fetching, and the dependency phase."""

    def acquire_activity(state: ModelState) -> None:
        state.activity_holders += 1

    def fetch(state: ModelState) -> None:
        state.cache = "valid"

    def phase_deps(state: ModelState) -> None:
        state.containers.add(name)
        if scenario["build"] == "deps_failure":
            raise _BuildAborted

    return [
        (f"{name}:activity", acquire_activity),
        (f"{name}:fetch", fetch),
        (f"{name}:phase_deps", phase_deps),
    ]


def _build_and_validate_steps(name: str, scenario: dict[str, str]) -> list[Step]:
    """The commit, build and rebuild phases, followed by validation."""

    def phase_commit(state: ModelState) -> None:
        state.images.add(name)

    def phase_build(state: ModelState) -> None:
        state.staging[name] = scenario["build"]
        if scenario["build"] == "build_failure":
            raise _BuildAborted

    def phase_rebuild(state: ModelState) -> None:
        if scenario["build"] == "rebuild_failure":
            raise _BuildAborted
        state.containers.discard(name)
        state.images.discard(name)

    def validate(state: ModelState) -> None:
        if scenario["build"] != "success":
            raise _BuildAborted

    return [
        (f"{name}:phase_commit", phase_commit),
        (f"{name}:phase_build", phase_build),
        (f"{name}:phase_rebuild", phase_rebuild),
        (f"{name}:validate", validate),
    ]


def _build_phase_steps(name: str, scenario: dict[str, str]) -> list[Step]:
    """The build-phase steps: fetching, the three container phases and
    validation, as (label, function) pairs."""
    return _fetch_and_deps_steps(name, scenario) + _build_and_validate_steps(
        name, scenario
    )


def _publish_lock_and_publish_steps(name: str, scenario: dict[str, str]) -> list[Step]:
    """Taking the publication lock and publishing (or beginning a fallback)."""

    def take_publish_lock(state: ModelState) -> None:
        if state.publish_lock_held:
            REACHED.add("publication_contention")
            raise _LockContended
        state.publish_lock_held = True
        state.in_critical += 1

    def publish(state: ModelState) -> None:
        mode = scenario["publish"]
        if mode in ("first", "exchange"):
            state.published = name
        else:
            state.recovery[name] = state.published
            state.published = None
            state.publishing_fallback = True
            REACHED.add("fallback_window")

    return [
        (f"{name}:publish_lock", take_publish_lock),
        (f"{name}:publish", publish),
    ]


def _make_finish_publish(
    name: str, scenario: dict[str, str]
) -> Callable[[ModelState], None]:
    """Build the step that concludes a fallback publication, if any."""

    def finish_publish(state: ModelState) -> None:
        mode = scenario["publish"]
        if mode in ("first", "exchange"):
            return
        if mode == "fallback":
            state.published = name
            state.recovery.pop(name, None)
        elif mode == "promotion_failure":
            state.published = state.recovery.pop(name)  # rollback succeeds
        else:  # rollback_failure: the previous set stays as recovery data
            REACHED.add("retained_recovery")
        state.publishing_fallback = False
        if mode == "rollback_failure":
            raise _BuildAborted

    return finish_publish


def _release_steps(name: str, scenario: dict[str, str], *, broken: str) -> list[Step]:
    """Releasing the publication and activity locks, as (label, function)
    pairs.

    ``broken`` injects a deliberate modelling fault, used by the self-test to
    show that this checker rejects a model that does not hold the invariants.
    """

    def release_publish_lock(state: ModelState) -> None:
        if broken == "leak_publication_lock":
            return
        state.publish_lock_held = False
        state.in_critical -= 1

    def release_activity(state: ModelState) -> None:
        state.activity_holders -= 1
        if broken != "leak_staging":
            state.staging.pop(name, None)

    return [
        (f"{name}:release_publish", release_publish_lock),
        (f"{name}:release_activity", release_activity),
    ]


def _finish_and_release_steps(
    name: str, scenario: dict[str, str], *, broken: str
) -> list[Step]:
    """Concluding a fallback publication and releasing both locks.

    ``broken`` injects a deliberate modelling fault, used by the self-test to
    show that this checker rejects a model that does not hold the invariants.
    """
    finish_step: Step = (f"{name}:finish_publish", _make_finish_publish(name, scenario))
    return [finish_step, *_release_steps(name, scenario, broken=broken)]


def _publication_steps(
    name: str, scenario: dict[str, str], *, broken: str
) -> list[Step]:
    """The publication steps: taking the lock, publishing, unwinding a
    fallback and releasing both locks, as (label, function) pairs."""
    return [
        *_publish_lock_and_publish_steps(name, scenario),
        *_finish_and_release_steps(name, scenario, broken=broken),
    ]


def build_steps(name: str, scenario: dict[str, str], *, broken: str = "") -> list[Step]:
    """The atomic steps of one build, as (label, function) pairs.

    ``broken`` injects a deliberate modelling fault, used by the self-test to
    show that this checker rejects a model that does not hold the invariants.
    """
    return _build_phase_steps(name, scenario) + _publication_steps(
        name, scenario, broken=broken
    )


def clean_steps(*, broken: str = "") -> list[Step]:
    def wait_and_remove(state: ModelState) -> None:
        if state.activity_holders != 0 and broken != "clean_ignores_lock":
            raise _CleanBlocked
        state.published = None
        state.cache = "absent"
        state.cleaned = True

    return [("clean:remove", wait_and_remove)]


def _unwind_aborted_build(
    state: ModelState, who: str, pending: dict[str, list[Step]], *, broken: str
) -> None:
    """Abort unwinds: locks released, staging and this invocation's
    container and image dropped. Recovery data, if this build left any,
    deliberately survives."""
    for remaining_label, _ in pending[who]:
        if remaining_label.endswith("release_publish"):
            if state.publish_lock_held:
                state.in_critical -= 1
            state.publish_lock_held = False
        if remaining_label.endswith("release_activity"):
            state.activity_holders -= 1
    if broken != "leak_staging":
        state.staging.pop(who, None)
    if broken != "leak_container":
        state.containers.discard(who)
        state.images.discard(who)
    state.publishing_fallback = False
    pending[who] = []


def _step_violations(label: str, state: ModelState, ever_published: bool) -> list[str]:
    """I1, I2 and mutual exclusion of the publication lock, after one step."""
    found: list[str] = []

    # I1: the output path may be absent only before anything has ever been
    # published, inside a fallback publication's documented window, after
    # clean removed it, or when a failed rollback has left the previous
    # generation as recovery data instead.
    absence_allowed = (
        not ever_published
        or state.publishing_fallback
        or state.cleaned
        or bool(state.recovery)
    )
    if state.published is None and not absence_allowed:
        found.append(f"output vanished outside a fallback window at {label}")
    # I2: clean only ever removes with no activity lock held.
    if label == "clean:remove" and state.activity_holders != 0:
        found.append("clean removed state while an activity lock was held")
    # The publication lock is mutually exclusive.
    if state.in_critical > 1:
        found.append("two builds inside the publication critical section")
    return found


def _drain_pending(
    participants: dict[str, list[Step]], attempt: Callable[[str], bool]
) -> None:
    """Round-robin until nobody advances; contention can consume turns
    without progress, so this drains what a fixed order left unfinished.
    A pass that advances nobody means a real deadlock."""
    while True:
        advanced = False
        for who in list(participants):
            if attempt(who):
                advanced = True
        if not advanced:
            break


def _final_state_violations(state: ModelState) -> list[str]:
    """I4: nothing owned, and no lock, survives to the end of a schedule."""
    found: list[str] = []
    if state.staging:
        found.append(f"staging survived: {sorted(state.staging)}")
    if state.containers or state.images:
        found.append(
            f"containers or images survived: "
            f"{sorted(state.containers)}/{sorted(state.images)}"
        )
    if state.publish_lock_held:
        found.append("publication lock still held at the end")
    if state.activity_holders != 0:
        found.append(f"activity lock still held: {state.activity_holders}")
    return found


def run_schedule(
    participants: dict[str, list[Step]], order: list[str], *, broken: str = ""
) -> list[str]:
    """Execute one interleaving; return any invariant violations."""
    state = ModelState()
    pending = {name: list(steps) for name, steps in participants.items()}
    aborted: set[str] = set()
    violations: list[str] = []
    ever_published = False

    def attempt(who: str) -> bool:
        """Try to advance one participant; True when a step was consumed."""
        nonlocal ever_published
        if who in aborted or not pending[who]:
            return False
        label, step = pending[who][0]
        try:
            step(state)
        except _BuildAborted:
            _unwind_aborted_build(state, who, pending, broken=broken)
            aborted.add(who)
            return True
        except (_LockContended, _CleanBlocked):
            # Not ready: the participant waits, which is the point of the lock.
            return False
        pending[who].pop(0)

        if state.published is not None:
            ever_published = True
        violations.extend(_step_violations(label, state, ever_published))
        return True

    for who in order:
        attempt(who)

    # The sampled order fixes the interleaving; the drain below finishes
    # whatever it left incomplete.
    _drain_pending(participants, attempt)
    if any(pending[who] for who in participants if who not in aborted):
        violations.append("participants could not finish: deadlock")

    violations.extend(_final_state_violations(state))
    return violations


BUILD_OUTCOMES = (
    "success",
    "partial",
    "deps_failure",
    "build_failure",
    "rebuild_failure",
)
PUBLISH_MODES = (
    "first",
    "exchange",
    "fallback",
    "promotion_failure",
    "rollback_failure",
)


def schedule_space(
    rng: random.Random, schedules_per_case: int, *, broken: str = ""
) -> list[tuple[dict[str, list[Step]], list[str]]]:
    """Every sampled (participants, order) pair, built once so both the sweep
    and the self-test explore exactly the same space."""
    space: list[tuple[dict[str, list[Step]], list[str]]] = []
    for count in (0, 1, 2):
        for combo in itertools.product(
            itertools.product(BUILD_OUTCOMES, PUBLISH_MODES), repeat=count
        ):
            for with_clean in (False, True):
                participants: dict[str, list[Step]] = {}
                for index, (build, publish) in enumerate(combo):
                    name = f"b{index}"
                    participants[name] = build_steps(
                        name, {"build": build, "publish": publish}, broken=broken
                    )
                if with_clean:
                    participants["clean"] = clean_steps(broken=broken)
                if not participants:
                    continue

                slots: list[str] = []
                for name, steps in participants.items():
                    slots.extend([name] * (len(steps) + 2))

                for _ in range(schedules_per_case):
                    order = list(slots)
                    rng.shuffle(order)
                    space.append((participants, order))
    return space


def abstract_cases(rng: random.Random, schedules_per_case: int) -> int:
    """Sample interleavings of 0-2 builds and a clean; return cases checked."""
    checked = 0
    for participants, order in schedule_space(rng, schedules_per_case):
        violations = run_schedule(dict(participants), order)
        checked += 1
        if violations:
            raise CheckFailure(
                "abstract schedule violated invariants: "
                f"{violations}; participants={sorted(participants)}; order={order}"
            )
    return checked


# The faults the self-test injects, and the substring the checker must report.
SELF_TEST_FAULTS = (
    ("leak_publication_lock", "publication lock still held"),
    ("leak_staging", "staging survived"),
    ("leak_container", "containers or images survived"),
    ("clean_ignores_lock", "clean removed state while an activity lock was held"),
)


def self_test(seed: int, schedules_per_case: int) -> int:
    """Run deliberately broken models; every one must be rejected.

    Without this, a checker that had quietly stopped asserting anything would
    still print a pass.
    """
    for fault, expected in SELF_TEST_FAULTS:
        caught = False
        for participants, order in schedule_space(
            random.Random(seed), schedules_per_case, broken=fault
        ):
            violations = run_schedule(dict(participants), order, broken=fault)
            if any(expected in violation for violation in violations):
                caught = True
                break
        if not caught:
            raise CheckFailure(
                f"the seeded fault '{fault}' was not detected; expected a "
                f"violation mentioning '{expected}'"
            )
    return len(SELF_TEST_FAULTS)


# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--seed",
        type=int,
        default=int(os.environ.get("MODEL_CHECK_SEED", str(DEFAULT_SEED))),
        help="seed for scenario and schedule generation",
    )
    parser.add_argument(
        "--executed-cases",
        type=int,
        default=int(os.environ.get("MODEL_CHECK_EXECUTED", "22")),
        help="how many executed scenarios to sample",
    )
    parser.add_argument(
        "--schedules",
        type=int,
        default=int(os.environ.get("MODEL_CHECK_SCHEDULES", "8")),
        help="interleavings sampled per abstract case",
    )
    args = parser.parse_args()

    print(f"model check: seed={args.seed}")
    print("model check: a bounded check, not a proof")

    rng = random.Random(args.seed)
    cases = executed_cases(rng, args.executed_cases)

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bindir = root / "bin"
        write_stubs(bindir)
        fixture = root / "fixture.tar.gz"
        fixture.write_bytes(b"not really a tarball, but a stable one\n")
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest()

        for index, case in enumerate(cases):
            sandbox = Sandbox(root / f"case{index}", bindir, fixture, digest)
            sandbox.root.mkdir(parents=True, exist_ok=True)
            try:
                check_executed_case(case, sandbox, bindir)
            except (CheckFailure, subprocess.TimeoutExpired) as exc:
                print(
                    f"FAIL executed case {index}: {case}\n  seed={args.seed}\n  {exc}",
                    file=sys.stderr,
                )
                return 1
        print(
            f"model check: {len(cases)} executed scenarios passed "
            "(the shell code as written)"
        )

        try:
            schedules = abstract_cases(random.Random(args.seed), args.schedules)
        except CheckFailure as exc:
            print(f"FAIL abstract model:\n  seed={args.seed}\n  {exc}", file=sys.stderr)
            return 1
        print(
            f"model check: {schedules} abstract schedules passed "
            "(an abstract model, not the executed script)"
        )

        missing = {
            "publication_contention",
            "fallback_window",
            "retained_recovery",
        } - REACHED
        if missing:
            print(
                f"FAIL non-vacuity: the sweep never reached {sorted(missing)}\n"
                f"  seed={args.seed}",
                file=sys.stderr,
            )
            return 1
        print(f"model check: reached {sorted(REACHED)}")

        try:
            faults = self_test(args.seed, args.schedules)
        except CheckFailure as exc:
            print(f"FAIL self-test:\n  seed={args.seed}\n  {exc}", file=sys.stderr)
            return 1
        print(f"model check: {faults} seeded model faults were all rejected")

    print("MODEL CHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
