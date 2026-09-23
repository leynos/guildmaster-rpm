"""Executed layer: drives the real scripts through stub commands and FIFOs.

This layer runs ``scripts/build-rpm.sh`` and ``scripts/clean.sh`` against a
generated combination of cache states, container-phase outcomes, publication
modes and clean positions, checking the shell code as written. See
``modelcheck.__main__`` for how this fits with the abstract layer.
"""

from __future__ import annotations

import fcntl
import itertools
import os
import random
import select
import shutil
import signal
import subprocess
from pathlib import Path

from .common import (
    BUILD_SH,
    CLEAN_SH,
    COMPLETE,
    MANIFEST,
    STUB_PLACEHOLDERS,
    STUBS_DIR,
    TARBALL,
    TARGET,
    CheckFailure,
)


def write_stubs(bindir: Path) -> None:
    """Install the curl, podman and publish-mv stubs into ``bindir``.

    Parameters
    ----------
    bindir : Path
        The directory to install the stub executables into. Created if it
        does not already exist.

    Returns
    -------
    None
    """
    bindir.mkdir(parents=True, exist_ok=True)
    for name, filename in (
        ("curl", "curl.sh"),
        ("podman", "podman.sh"),
        ("publish-mv", "publish-mv.sh"),
    ):
        body = (STUBS_DIR / filename).read_text()
        if name == "podman":
            for placeholder, value in STUB_PLACEHOLDERS:
                body = body.replace(placeholder, value)
        path = bindir / name
        path.write_text(body)
        path.chmod(0o755)


def classify(directory: Path) -> str:
    """Describe a package directory as absent, complete:<tag>, partial or mixed.

    Parameters
    ----------
    directory : Path
        The directory to inspect.

    Returns
    -------
    str
        ``"absent"``, ``"partial"``, ``"mixed"``, or ``"complete:<tag>"``
        where ``<tag>`` is the shared generation tag written by the podman
        stub.
    """
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
    """Check whether a lock file is uncontended.

    Parameters
    ----------
    path : Path
        The lock file to probe.

    Returns
    -------
    bool
        ``True`` if the path is absent or an exclusive, non-blocking lock on
        it can be taken and released; ``False`` if another holder has it.
    """
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
        """Set up the paths for one case's disposable sandbox.

        Parameters
        ----------
        root : Path
            The case's own directory; all other paths are derived from it.
        bindir : Path
            The directory holding the curl, podman and publish-mv stubs.
        fixture : Path
            The stable stand-in tarball served by the curl stub.
        digest : str
            The SHA-256 digest of ``fixture``, passed to the build script as
            ``TARBALL_SHA256``.
        """
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
        """Build the environment a build invocation needs.

        Parameters
        ----------
        tag : str
            The generation tag the podman stub should write into built
            packages.

        Returns
        -------
        dict[str, str]
            The environment, seeded from ``os.environ`` and overlaid with
            the sandbox's stub and directory wiring.
        """
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
        """Set the cache to one of absent/valid/corrupt/interrupted.

        Parameters
        ----------
        state : str
            One of ``"absent"``, ``"valid"``, ``"corrupt"`` or
            ``"interrupted"``.

        Returns
        -------
        set[str]
            The names of any temporary tarballs already present in the
            cache, for use as a pre-invocation baseline.
        """
        self.cache.mkdir(parents=True, exist_ok=True)
        target = self.cache / TARBALL
        match state:
            case "valid":
                shutil.copyfile(self.fixture, target)
            case "corrupt":
                target.write_text("truncated junk")
            case "interrupted":
                (self.cache / f"{TARBALL}.ABC123").write_text("half a download")
        return self.temp_tarballs()

    def temp_tarballs(self) -> set[str]:
        """List the temporary tarball names currently in the cache.

        Returns
        -------
        set[str]
            The names of files matching the temporary-download pattern.
        """
        if not self.cache.is_dir():
            return set()
        return {p.name for p in self.cache.glob(f"{TARBALL}.??????")}

    def staging_entries(self) -> tuple[tuple[str, ...], tuple[str, ...]]:
        """List the staging directory's owned and recovery entries.

        Returns
        -------
        tuple[tuple[str, ...], tuple[str, ...]]
            A pair of sorted name tuples: entries owned by the current
            invocation, and ``.previous`` recovery entries.
        """
        if not self.staging.is_dir():
            return ((), ())
        owned: list[str] = []
        recovery: list[str] = []
        for entry in self.staging.iterdir():
            (recovery if entry.name.endswith(".previous") else owned).append(entry.name)
        return tuple(sorted(owned)), tuple(sorted(recovery))

    def container_residue(self) -> tuple[str, ...]:
        """List the containers and images left in the podman stub's state.

        Returns
        -------
        tuple[str, ...]
            Sorted ``"containers/<name>"`` and ``"images/<name>"`` entries.
        """
        names: list[str] = []
        for kind in ("containers", "images"):
            directory = self.podman_state / kind
            if directory.is_dir():
                names.extend(f"{kind}/{p.name}" for p in directory.iterdir())
        return tuple(sorted(names))

    def run_build(
        self, tag: str, extra: dict[str, str]
    ) -> subprocess.CompletedProcess[str]:
        """Run the build script to completion.

        Parameters
        ----------
        tag : str
            The generation tag the podman stub should write.
        extra : dict[str, str]
            Additional environment variables overlaid on the base
            environment, such as publication or failure-injection settings.

        Returns
        -------
        subprocess.CompletedProcess[str]
            The finished process, with captured text output.
        """
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

    def run_clean(self) -> subprocess.CompletedProcess[str]:
        """Run the clean script to completion.

        Returns
        -------
        subprocess.CompletedProcess[str]
            The finished process, with captured text output.
        """
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
        """Check that no lock file in the sandbox is still held.

        Returns
        -------
        bool
            ``True`` if every ``*.lock`` file in the lock directory is
            uncontended.
        """
        locks = self.locks.glob("*.lock") if self.locks.is_dir() else []
        return all(lock_is_free(p) for p in locks)


def publication_env(mode: str, bindir: Path) -> dict[str, str]:
    """Build the environment variables that select a publication mode.

    Parameters
    ----------
    mode : str
        One of ``"first"``, ``"exchange"``, ``"fallback"``,
        ``"promotion_failure"`` or ``"rollback_failure"``.
    bindir : Path
        The directory holding the publish-mv stub, used when the mode
        injects a promotion or rollback failure.

    Returns
    -------
    dict[str, str]
        The environment variables to overlay on the build invocation.
    """
    match mode:
        case "first" | "exchange":
            return {}
        case "fallback":
            return {"PUBLISH_EXCHANGE": "never"}
        case "promotion_failure":
            return {
                "PUBLISH_EXCHANGE": "never",
                "PUBLISH_MV": str(bindir / "publish-mv"),
                "PUBLISH_MV_FAIL_PROMOTION": "1",
            }
        case _:  # "rollback_failure"
            return {
                "PUBLISH_EXCHANGE": "never",
                "PUBLISH_MV": str(bindir / "publish-mv"),
                "PUBLISH_MV_FAIL_PROMOTION": "1",
                "PUBLISH_MV_FAIL_ROLLBACK": "1",
            }


def build_env(outcome: str) -> dict[str, str]:
    """Build the environment variables that select a container-phase outcome.

    Parameters
    ----------
    outcome : str
        One of ``"success"``, ``"partial"``, ``"deps_failure"``,
        ``"build_failure"``, ``"rebuild_failure"`` or ``"cancel"``.

    Returns
    -------
    dict[str, str]
        The environment variables to overlay on the build invocation.
    """
    if outcome == "partial":
        return {"PODMAN_STUB_PARTIAL": "1"}
    if outcome in ("deps_failure", "build_failure", "rebuild_failure"):
        return {"PODMAN_STUB_FAIL_PHASE": outcome.removesuffix("_failure")}
    return {}


def check_exit_status(
    result: subprocess.CompletedProcess[str], *, expect_success: bool
) -> None:
    """Assert the build's exit status matches what the scenario expects.

    Parameters
    ----------
    result : subprocess.CompletedProcess[str]
        The finished build invocation.
    expect_success : bool
        Whether the scenario expects a zero exit status.

    Raises
    ------
    CheckFailure
        If the exit status does not match the expectation.
    """
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
    """I3: the successful, rolled-back or recovery-retaining generation.

    Parameters
    ----------
    case : dict[str, object]
        The generated scenario under test.
    sandbox : Sandbox
        The sandbox the scenario ran in.
    state : str
        The classification of the published output after the run.
    recovery : tuple[str, ...]
        The names of any ``.previous`` recovery entries in staging.
    expect_success : bool
        Whether the scenario expects the build to have succeeded.
    primed : bool
        Whether a prior generation was published before this run.

    Raises
    ------
    CheckFailure
        If I3 does not hold.
    """
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
    """Assert I1, I3 and the owned-staging half of I4 for the result.

    Parameters
    ----------
    case : dict[str, object]
        The generated scenario under test.
    sandbox : Sandbox
        The sandbox the scenario ran in.
    expect_success : bool
        Whether the scenario expects the build to have succeeded.
    primed : bool
        Whether a prior generation was published before this run.

    Raises
    ------
    CheckFailure
        If I1, I3 or the owned-staging half of I4 does not hold.
    """
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
    left behind by this invocation.

    Parameters
    ----------
    sandbox : Sandbox
        The sandbox the scenario ran in.
    pre_temps : set[str]
        The temporary tarball names present before this invocation.

    Raises
    ------
    CheckFailure
        If any invocation-owned resource survived.
    """
    leaked = sandbox.temp_tarballs() - pre_temps
    if leaked:
        raise CheckFailure(f"temporary tarballs left behind: {sorted(leaked)}")
    residue = sandbox.container_residue()
    if residue:
        raise CheckFailure(f"containers or images left behind: {residue}")
    if not sandbox.locks_free():
        raise CheckFailure("a lock is still held")


def check_clean_after(sandbox: Sandbox) -> None:
    """Run clean after the build and assert I2 in its simplest form.

    Parameters
    ----------
    sandbox : Sandbox
        The sandbox the scenario ran in.

    Raises
    ------
    CheckFailure
        If clean fails, or leaves the output, cache or lock directory in
        the wrong state.
    """
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
    """Run one generated scenario and assert I1-I4 on the result.

    Parameters
    ----------
    case : dict[str, object]
        The generated scenario to run.
    sandbox : Sandbox
        The sandbox to run it in.
    bindir : Path
        The directory holding the curl, podman and publish-mv stubs.

    Raises
    ------
    CheckFailure
        If any invariant does not hold for this scenario.
    """
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
) -> subprocess.CompletedProcess[str]:
    """Start a build, block it inside the build phase, then signal it.

    Parameters
    ----------
    sandbox : Sandbox
        The sandbox to run the build in.
    extra : dict[str, str]
        Additional environment variables overlaid on the base environment.

    Returns
    -------
    subprocess.CompletedProcess[str]
        The terminated process, with captured text output.

    Raises
    ------
    CheckFailure
        If the container stub never announces that it started.
    """
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
    """A deterministic bounded sample of executable scenarios.

    Parameters
    ----------
    rng : random.Random
        The seeded generator used to shuffle and sample scenarios.
    limit : int
        The maximum number of scenarios to return.

    Returns
    -------
    list[dict[str, object]]
        The chosen scenarios, always including at least those needed to
        exercise the publication modes that carry recovery behaviour and a
        failure in each container phase.
    """
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


__all__ = [
    "Sandbox",
    "build_env",
    "check_clean_after",
    "check_executed_case",
    "check_exit_status",
    "check_invocation_residue",
    "check_published_state",
    "classify",
    "executed_cases",
    "lock_is_free",
    "publication_env",
    "run_cancelled_build",
    "write_stubs",
]
