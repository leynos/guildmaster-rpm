"""Command-line entry point for the model check.

Runs the executed layer's scenarios, then the abstract layer's schedules,
checks the non-vacuity guard, then the self-test. See :mod:`modelcheck` for
the invariants both layers assert, and ``scripts/tests/model_check.py`` for
the thin script that invokes :func:`main`.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

from . import __doc__ as _PACKAGE_DOC
from .boundaries import check_boundaries
from .common import DEFAULT_SEED, CheckFailure, InspectionError
from .executed_cases import executed_cases
from .executed_checks import check_executed_case
from .sandbox import Sandbox, write_stubs
from .schedule import abstract_cases
from .selftest import self_test

# States the non-vacuity guard requires the abstract sweep to have reached.
_REQUIRED_REACHED = {
    "publication_contention",
    "fallback_window",
    "retained_recovery",
}


def _parse_args() -> argparse.Namespace:
    """Parse the model check's command-line arguments.

    Returns
    -------
    argparse.Namespace
        The parsed ``--seed``, ``--executed-cases`` and ``--schedules``
        options.
    """
    parser = argparse.ArgumentParser(description=_PACKAGE_DOC)
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
    return parser.parse_args()


def _run_executed_cases(args: argparse.Namespace) -> int:
    """Run the sampled executed scenarios, inside their own temp directory.

    Parameters
    ----------
    args : argparse.Namespace
        The parsed command-line arguments.

    Returns
    -------
    int
        ``0`` on success, ``1`` if a scenario failed or its sandbox could
        not be inspected.
    """
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
            except InspectionError as exc:
                # Not an invariant failure: the case could not be observed.
                print(
                    f"FAIL executed case {index} could not be inspected: {case}\n"
                    f"  seed={args.seed}\n  {exc}",
                    file=sys.stderr,
                )
                return 1
        print(
            f"model check: {len(cases)} executed scenarios passed "
            "(the shell code as written)"
        )

        return 0


def _run_abstract_and_self_test(args: argparse.Namespace) -> int:
    """Run the abstract sweep, the non-vacuity guard, the self-test and the
    boundary checks.

    Parameters
    ----------
    args : argparse.Namespace
        The parsed command-line arguments.

    Returns
    -------
    int
        ``0`` on success, ``1`` on the first failure encountered.
    """
    try:
        sweep = abstract_cases(random.Random(args.seed), args.schedules)
    except CheckFailure as exc:
        print(f"FAIL abstract model:\n  seed={args.seed}\n  {exc}", file=sys.stderr)
        return 1
    print(
        f"model check: {sweep.checked} abstract schedules passed "
        "(an abstract model, not the executed script)"
    )

    missing = _REQUIRED_REACHED - sweep.reached
    if missing:
        print(
            f"FAIL non-vacuity: the sweep never reached {sorted(missing)}\n"
            f"  seed={args.seed}",
            file=sys.stderr,
        )
        return 1
    print(f"model check: reached {sorted(sweep.reached)}")

    try:
        faults = self_test(args.seed, args.schedules)
    except CheckFailure as exc:
        print(f"FAIL self-test:\n  seed={args.seed}\n  {exc}", file=sys.stderr)
        return 1
    print(f"model check: {faults} seeded model faults were all rejected")

    try:
        check_boundaries()
    except CheckFailure as exc:
        print(f"FAIL boundary checks:\n  seed={args.seed}\n  {exc}", file=sys.stderr)
        return 1
    except InspectionError as exc:
        print(
            f"FAIL boundary checks could not inspect their state:\n"
            f"  seed={args.seed}\n  {exc}",
            file=sys.stderr,
        )
        return 1
    print("model check: boundary checks passed")

    return 0


def main() -> int:
    """Run the full model check and report its outcome.

    Returns
    -------
    int
        ``0`` if every scenario, schedule and self-test fault passed;
        ``1`` on the first failure.
    """
    args = _parse_args()

    print(f"model check: seed={args.seed}")
    print("model check: a bounded check, not a proof")

    status = _run_executed_cases(args)
    if status != 0:
        return status

    status = _run_abstract_and_self_test(args)
    if status != 0:
        return status

    print("MODEL CHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
