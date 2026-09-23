"""Executed layer: assertions run against a finished build or clean invocation.

Runs one generated scenario's build (including the cancelled-build FIFO
dance) and asserts I1-I4 on the result. See ``modelcheck.__main__`` for how
this fits with the abstract layer.
"""

from __future__ import annotations

import os
import select
import signal
import subprocess
from pathlib import Path

from .common import BUILD_SH, TARBALL, CheckFailure
from .sandbox import Sandbox, build_env, classify, publication_env


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


__all__ = [
    "check_clean_after",
    "check_executed_case",
    "check_exit_status",
    "check_invocation_residue",
    "check_published_state",
    "run_cancelled_build",
]
