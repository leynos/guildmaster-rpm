"""Abstract layer: the self-test that deliberately broken models must fail.

Runs each seeded modelling fault back through ``run_schedule`` and requires
every one of them to be rejected, so a checker that had quietly stopped
asserting anything would not still print a pass. See ``modelcheck.__main__``
for how this fits with the executed layer.
"""

from __future__ import annotations

import random

from .common import CheckFailure
from .schedule import run_schedule, schedule_space

# The faults the self-test injects, and the substring the checker must report.
SELF_TEST_FAULTS = (
    ("leak_publication_lock", "publication lock still held"),
    ("leak_staging", "staging survived"),
    ("leak_container", "containers or images survived"),
    ("clean_ignores_lock", "clean removed state while an activity lock was held"),
    ("release_unheld_lock", "critical section counter went negative"),
)


def self_test(seed: int, schedules_per_case: int) -> int:
    """Run deliberately broken models; every one must be rejected.

    Without this, a checker that had quietly stopped asserting anything
    would still print a pass.

    Parameters
    ----------
    seed : int
        The seed used to regenerate the schedule space for each fault.
    schedules_per_case : int
        How many orders to sample per combination of participants.

    Returns
    -------
    int
        The number of faults exercised, i.e. ``len(SELF_TEST_FAULTS)``.

    Raises
    ------
    CheckFailure
        If any seeded fault goes undetected.
    """
    for fault, expected in SELF_TEST_FAULTS:
        caught = False
        for participants, order in schedule_space(
            random.Random(seed), schedules_per_case, broken=fault
        ):
            result = run_schedule(dict(participants), order, broken=fault)
            if any(expected in violation for violation in result.violations):
                caught = True
                break
        if not caught:
            raise CheckFailure(
                f"the seeded fault '{fault}' was not detected; expected a "
                f"violation mentioning '{expected}'"
            )
    return len(SELF_TEST_FAULTS)


__all__ = [
    "SELF_TEST_FAULTS",
    "self_test",
]
