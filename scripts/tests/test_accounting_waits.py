#!/usr/bin/env python3
"""Offline tests for the bounded waits in the guest accounting test.

``tests/cuse/accounting/test_accounting.py`` runs only in a CUSE guest, but
its ``wait_until`` helper takes an injectable clock, so its bounding logic
can be checked here with a fake clock and no real time passing. Importing the
module starts no client and touches no device.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path
from types import ModuleType

MODULE_PATH = (
    Path(__file__).resolve().parents[2] / "tests/cuse/accounting/test_accounting.py"
)


def load_module() -> ModuleType:
    """Import the guest test module from its path.

    Returns
    -------
    ModuleType
        The loaded ``test_accounting`` module.
    """
    spec = importlib.util.spec_from_file_location("test_accounting", MODULE_PATH)
    assert spec is not None, f"cannot load {MODULE_PATH}"
    assert spec.loader is not None, f"no loader for {MODULE_PATH}"
    module = importlib.util.module_from_spec(spec)
    # Dataclasses resolve their annotations through sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


RUNAWAY_SECONDS = 1000.0
RUNAWAY_READS = 100_000


class FakeClock:
    """A clock that advances only when slept on, and records the sleeps.

    Attributes
    ----------
    time : float
        The current fake time in seconds.
    sleeps : list[float]
        Every pause requested, in order.
    reads : int
        How many times the time has been read.
    """

    def __init__(self) -> None:
        """Start at time zero with no sleeps recorded."""
        self.time = 0.0
        self.sleeps: list[float] = []
        self.reads = 0

    def now(self) -> float:
        """Return the current fake time.

        Returns
        -------
        float
            Seconds since the fake clock started.
        """
        # Counted separately from fake time, so that a wait that stops
        # advancing the clock, for example by pausing for zero seconds, is
        # still caught rather than spinning forever.
        self.reads += 1
        if self.reads > RUNAWAY_READS:
            raise RuntimeError(
                f"the wait read the clock more than {RUNAWAY_READS} times"
            )
        return self.time

    def sleep(self, seconds: float) -> None:
        """Advance the fake time and record the pause.

        Parameters
        ----------
        seconds : float
            How far to advance.
        """
        self.sleeps.append(seconds)
        self.time += seconds
        # A wait that ignores its bound would otherwise spin forever here.
        if self.time > RUNAWAY_SECONDS:
            raise RuntimeError(f"the wait ran past {RUNAWAY_SECONDS}s of fake time")


def check(results: list[tuple[str, bool]], name: str, ok: bool) -> None:
    """Record and print one named check.

    Parameters
    ----------
    results : list[tuple[str, bool]]
        Collected results, appended to.
    name : str
        What was checked.
    ok : bool
        Whether it held.
    """
    results.append((name, ok))
    print(f"{'ok' if ok else 'FAIL'}: {name}")


def run_checks(module: ModuleType) -> list[tuple[str, bool]]:
    """Exercise ``wait_until`` against a fake clock.

    Parameters
    ----------
    module : ModuleType
        The loaded guest test module.

    Returns
    -------
    list[tuple[str, bool]]
        Each check's name and outcome.
    """
    results: list[tuple[str, bool]] = []

    clock = FakeClock()
    fake = module.Clock(now=clock.now, sleep=clock.sleep)
    check(
        results,
        "a condition already true returns at once without sleeping",
        module.wait_until(lambda: True, timeout=5, clock=fake) and not clock.sleeps,
    )

    clock = FakeClock()
    fake = module.Clock(now=clock.now, sleep=clock.sleep)
    calls = iter([False, False, True])
    check(
        results,
        "a condition that becomes true is reported true",
        module.wait_until(lambda: next(calls), timeout=5, clock=fake)
        and len(clock.sleeps) == 2,
    )

    clock = FakeClock()
    fake = module.Clock(now=clock.now, sleep=clock.sleep)
    try:
        outcome = module.wait_until(lambda: False, timeout=1.0, clock=fake)
    except RuntimeError:
        outcome = None
    check(results, "a condition that never holds times out", outcome is False)
    check(
        results,
        "the wait is bounded by the clock and stops at the deadline",
        1.0 <= clock.time < 1.0 + 2 * module.POLL_INTERVAL,
    )
    check(
        results,
        "every pause is the poll interval",
        set(clock.sleeps) == {module.POLL_INTERVAL},
    )
    return results


class StuckProcess:
    """A stand-in for ``subprocess.Popen`` whose process never exits.

    Attributes
    ----------
    waits : list[float | None]
        The ``timeout`` of every ``wait`` call, in order.
    killed : bool
        Whether ``kill`` was called.
    """

    def __init__(self) -> None:
        """Start as a running process with a closed input pipe."""
        self.waits: list[float | None] = []
        self.killed = False

    def poll(self) -> None:
        """Report the process as still running.

        Returns
        -------
        None
            Always, as a running process does.
        """

    def kill(self) -> None:
        """Record the kill; the process ignores it."""
        self.killed = True

    def wait(self, timeout: float | None = None) -> int:
        """Record the wait and time out, as a process that never exits would.

        Parameters
        ----------
        timeout : float | None
            The bound requested by the caller.

        Returns
        -------
        int
            Never returns.

        Raises
        ------
        subprocess.TimeoutExpired
            Always.
        """
        self.waits.append(timeout)
        raise subprocess.TimeoutExpired("gmclient", timeout or 0)


def run_finish_checks(module: ModuleType) -> list[tuple[str, bool]]:
    """Check that ``Client.finish`` bounds every wait, including after SIGKILL.

    Parameters
    ----------
    module : ModuleType
        The loaded guest test module.

    Returns
    -------
    list[tuple[str, bool]]
        Each check's name and outcome.
    """
    results: list[tuple[str, bool]] = []
    client = object.__new__(module.Client)
    client.name = "stuck"
    process = StuckProcess()
    client.process = process

    def broken_send(command: str) -> None:
        raise BrokenPipeError(command)

    client.send = broken_send
    try:
        client.finish()
        outcome = "returned"
    except module.CheckFailed:
        outcome = "check failed"
    except Exception as error:  # noqa: BLE001 - any other outcome is a failure
        outcome = type(error).__name__
    check(
        results,
        "a client that survives SIGKILL fails the check",
        outcome == "check failed",
    )
    check(results, "finish killed the client", process.killed)
    check(
        results,
        "every wait in finish is bounded",
        bool(process.waits) and None not in process.waits,
    )
    return results


def main() -> int:
    """Run the checks and print a summary.

    Returns
    -------
    int
        0 when every check passed, otherwise 1.
    """
    module = load_module()
    results = run_checks(module) + run_finish_checks(module)
    failed = sum(1 for _, ok in results if not ok)
    print(f"accounting wait tests: {len(results) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
