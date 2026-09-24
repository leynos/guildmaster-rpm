"""Boundary checks: repeated calls stay independent, queries stay read-only.

Guards the seams CodeRabbit's "Unit Architecture" review flagged:
``run_schedule`` must not depend on, or leave behind, any hidden mutable
state; ``lock_is_held_by_anyone`` must observe a lock without altering it;
and ``classify`` must report unreadable state as a documented
``InspectionError`` rather than an arbitrary exception or a verdict. All
three run on every ``model_check.py`` invocation, alongside the executed and
abstract layers and the self-test; see ``modelcheck.__main__``.
"""

from __future__ import annotations

import random
import subprocess
import sys
import tempfile
from pathlib import Path

from .common import COMPLETE, MANIFEST, CheckFailure, InspectionError
from .sandbox import classify, lock_is_held_by_anyone
from .schedule import run_schedule, schedule_space

# Any fixed seed works here: this check only needs one reusable case, not
# coverage of the schedule space.
_INDEPENDENCE_SEED = 924_1867


def _check_schedule_independence() -> None:
    """Run the same schedule twice; the two results must agree exactly.

    Raises
    ------
    CheckFailure
        If the two runs disagree, which would mean ``run_schedule`` reads
        or writes state that outlives a single call.
    """
    participants, order = schedule_space(random.Random(_INDEPENDENCE_SEED), 1)[0]
    first = run_schedule(dict(participants), order)
    second = run_schedule(dict(participants), order)
    if first.violations != second.violations or first.reached != second.reached:
        raise CheckFailure(
            "run_schedule gave different results for identical inputs across "
            f"repeated calls: {first} != {second}; this means it depends on, "
            "or leaks into, state that outlives a single call"
        )


def _spawn_lock_holder(lock_path: Path) -> subprocess.Popen[str]:
    """Start a subprocess that takes an exclusive ``flock`` and holds it.

    Parameters
    ----------
    lock_path : Path
        The file the subprocess should lock.

    Returns
    -------
    subprocess.Popen[str]
        The running subprocess; it prints ``"locked"`` once the lock is
        held, then sleeps until terminated.
    """
    script = (
        "import fcntl, sys, time\n"
        "fd = open(sys.argv[1])\n"
        "fcntl.flock(fd, fcntl.LOCK_EX)\n"
        "print('locked', flush=True)\n"
        "time.sleep(30)\n"
    )
    return subprocess.Popen(
        [sys.executable, "-c", script, str(lock_path)],
        stdout=subprocess.PIPE,
        text=True,
    )


def _check_lock_observation_is_read_only() -> None:
    """Observing a held lock must not alter it, and releasing it must show.

    Holds an exclusive ``flock`` on a temporary file from a subprocess,
    checks that ``lock_is_held_by_anyone`` reports it held without changing
    its content or mtime and without releasing it, then releases the lock
    and checks that the same query now reports it free.

    Raises
    ------
    CheckFailure
        If the holder could not be arranged, if the query fails to observe
        the held lock, if observing it changed the file, or if it reported
        the file free while still held or held after release.
    """
    with tempfile.TemporaryDirectory() as tmp:
        lock_path = Path(tmp) / "boundary.lock"
        lock_path.write_text("original content\n")
        before_mtime = lock_path.stat().st_mtime_ns

        holder = _spawn_lock_holder(lock_path)
        try:
            assert holder.stdout is not None, "lock holder stdout pipe was not created"
            if holder.stdout.readline().strip() != "locked":
                raise CheckFailure("boundary check could not arrange a held lock")

            if not lock_is_held_by_anyone(lock_path):
                raise CheckFailure("lock_is_held_by_anyone did not observe a held lock")
            if lock_path.read_text() != "original content\n":
                raise CheckFailure("observing a lock changed the file's content")
            if lock_path.stat().st_mtime_ns != before_mtime:
                raise CheckFailure("observing a lock changed the file's mtime")
            if not lock_is_held_by_anyone(lock_path):
                raise CheckFailure("observing a held lock released it")
        finally:
            holder.terminate()
            holder.wait(timeout=5)

        if lock_is_held_by_anyone(lock_path):
            raise CheckFailure("lock file still reported held after release")


def _check_unreadable_state_is_an_inspection_error() -> None:
    """``classify`` must wrap a decode failure in ``InspectionError``.

    Writes a complete package directory whose first package holds bytes
    that are not UTF-8, so reading its generation tag fails.

    Raises
    ------
    CheckFailure
        If ``classify`` returns a classification instead of raising, or the
        failure escapes as anything other than ``InspectionError``.
    """
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp) / "out"
        for name in COMPLETE:
            package = directory / name
            package.parent.mkdir(parents=True, exist_ok=True)
            package.write_text("current\n")
        (directory / MANIFEST).write_text("manifest\n")
        (directory / COMPLETE[0]).write_bytes(b"\xff\xfe not a tag\n")
        try:
            state = classify(directory)
        except InspectionError as exc:
            if not isinstance(exc.__cause__, UnicodeDecodeError):
                raise CheckFailure(
                    f"InspectionError does not carry the decode failure: {exc!r}"
                ) from exc
            return
        # Deliberately broad: the check is that nothing else escapes.
        except Exception as exc:
            raise CheckFailure(
                f"classify let {type(exc).__name__} escape instead of "
                f"InspectionError: {exc}"
            ) from exc
        raise CheckFailure(f"classify returned {state!r} for an unreadable package")


def check_boundaries() -> None:
    """Run every boundary check.

    Raises
    ------
    CheckFailure
        If any boundary check fails.
    InspectionError
        If a boundary check's own state cannot be inspected.
    """
    _check_schedule_independence()
    _check_lock_observation_is_read_only()
    _check_unreadable_state_is_an_inspection_error()


__all__ = ["check_boundaries"]
