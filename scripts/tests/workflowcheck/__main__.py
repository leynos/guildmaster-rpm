"""Command-line entry point for the workflow check.

Runs every named check from :mod:`.checks` against the real workflow files,
then every mutation from :mod:`.mutations` and confirms its matching check
now fails, then reports the combined pass/fail counts. See
:mod:`workflowcheck` for the contract these checks assert, and
``scripts/tests/test_workflows.py`` for the thin script that invokes
:func:`main`.
"""

from __future__ import annotations

import sys

from .bundle import Bundle, load_bundle, mutate_workflow
from .checks import CHECKS
from .mutations import MUTATIONS


def run_named_checks(bundle: Bundle) -> list[tuple[str, bool, str]]:
    """Run every named check against a bundle and record pass/fail.

    Parameters
    ----------
    bundle : Bundle
        The bundle to check.

    Returns
    -------
    list[tuple[str, bool, str]]
        ``(check_name, passed, detail)`` for every check.
    """
    results = []
    for name, check in CHECKS:
        try:
            check(bundle)
        except AssertionError as exc:
            results.append((name, False, str(exc)))
        else:
            results.append((name, True, "ok"))
    return results


def run_mutation_checks(bundle: Bundle) -> list[tuple[str, bool, str]]:
    """Apply each mutant and confirm its matching check now fails.

    Parameters
    ----------
    bundle : Bundle
        The real, unmutated bundle to derive mutants from.

    Returns
    -------
    list[tuple[str, bool, str]]
        ``(mutant_name, caught, detail)`` for every mutation.
    """
    results = []
    for name, wf_name, mutator, check in MUTATIONS:
        mutant = mutate_workflow(bundle, wf_name, mutator)
        try:
            check(mutant)
        except AssertionError:
            results.append((name, True, "caught"))
        else:
            results.append((name, False, "mutant escaped: check still passed"))
    return results


def print_results(title: str, results: list[tuple[str, bool, str]]) -> tuple[int, int]:
    """Print one line per result and return the pass/fail counts.

    Parameters
    ----------
    title : str
        A heading printed before the results.
    results : list[tuple[str, bool, str]]
        ``(name, passed, detail)`` triples.

    Returns
    -------
    tuple[int, int]
        The number of passes and the number of failures.
    """
    print(f"-- {title} --")
    passed = 0
    failed = 0
    for name, ok, detail in results:
        if ok:
            passed += 1
            print(f"PASS {name}")
        else:
            failed += 1
            print(f"FAIL {name}: {detail}")
    return passed, failed


def main() -> int:
    """Run every check and mutant against the real workflow files.

    Returns
    -------
    int
        ``0`` if every check passed and every mutant was caught, else ``1``.
    """
    bundle = load_bundle()

    check_results = run_named_checks(bundle)
    check_passed, check_failed = print_results("workflow checks", check_results)

    mutation_results = run_mutation_checks(bundle)
    mutant_caught, mutant_missed = print_results("mutation checks", mutation_results)

    total_passed = check_passed + mutant_caught
    total_failed = check_failed + mutant_missed
    print(f"workflow tests: {total_passed} passed, {total_failed} failed")
    return 1 if total_failed else 0


if __name__ == "__main__":
    sys.exit(main())
