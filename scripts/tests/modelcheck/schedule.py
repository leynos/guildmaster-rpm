"""Abstract layer: executing interleavings and sampling the schedule space.

Runs one sampled interleaving of builds and a clean against ``ModelState``,
checking I1, I2 and mutual exclusion after every step and I4 at the end, then
samples the space of participants and attempt orders both the sweep and the
self-test explore. See ``modelcheck.__main__`` for how this fits with the
executed layer.
"""

from __future__ import annotations

import itertools
import random
from collections.abc import Callable
from dataclasses import dataclass

from .common import CheckFailure
from .model import ModelState, Step, _BuildAborted, _CleanBlocked, _LockContended
from .steps import build_steps, clean_steps


@dataclass(frozen=True)
class ScheduleResult:
    """The outcome of executing one sampled interleaving.

    Attributes
    ----------
    violations : list[str]
        Any invariant violations found while executing the schedule; empty
        if the schedule held every invariant.
    reached : frozenset[str]
        The tracked states this schedule's steps actually reached.
    """

    violations: list[str]
    reached: frozenset[str]


@dataclass(frozen=True)
class SweepResult:
    """The outcome of sampling and checking the abstract schedule space.

    Attributes
    ----------
    checked : int
        The number of schedules checked.
    reached : frozenset[str]
        The union of every checked schedule's reached states.
    """

    checked: int
    reached: frozenset[str]


def _unwind_aborted_build(
    state: ModelState, who: str, pending: dict[str, list[Step]], *, broken: str
) -> None:
    """Abort unwinds: locks released, staging and this invocation's
    container and image dropped. Recovery data, if this build left any,
    deliberately survives.

    The publication lock is only released if this build's own
    ``publish_lock`` step already ran and its ``release_publish`` has not:
    that is, only if this build actually holds the lock. Releasing another
    build's lock, or a lock nobody holds, would corrupt the shared critical
    section count.

    Parameters
    ----------
    state : ModelState
        The model state to mutate.
    who : str
        The aborting participant's name.
    pending : dict[str, list[Step]]
        Each participant's remaining steps; ``who``'s are cleared.
    broken : str
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants. ``"release_unheld_lock"`` reinstates the unguarded
        release this function otherwise refuses to perform.

    Returns
    -------
    None
    """
    took_lock = broken == "release_unheld_lock" or not any(
        label == f"{who}:publish_lock" for label, _ in pending[who]
    )
    for remaining_label, _ in pending[who]:
        if remaining_label.endswith("release_publish") and took_lock:
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
    """I1, I2 and mutual exclusion of the publication lock, after one step.

    Parameters
    ----------
    label : str
        The label of the step just executed.
    state : ModelState
        The model state after that step.
    ever_published : bool
        Whether anything has ever been published in this schedule.

    Returns
    -------
    list[str]
        Any violation messages found; empty if none.
    """
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
    A pass that advances nobody means a real deadlock.

    Parameters
    ----------
    participants : dict[str, list[Step]]
        The schedule's participants, used only to enumerate names.
    attempt : Callable[[str], bool]
        Tries to advance one participant by name; returns whether a step
        was consumed.

    Returns
    -------
    None
    """
    while True:
        advanced = False
        for who in list(participants):
            if attempt(who):
                advanced = True
        if not advanced:
            break


def _final_state_violations(state: ModelState) -> list[str]:
    """I4: nothing owned, and no lock, survives to the end of a schedule.

    Parameters
    ----------
    state : ModelState
        The model state at the end of a schedule.

    Returns
    -------
    list[str]
        Any violation messages found; empty if none.
    """
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
    if state.in_critical < 0:
        found.append(f"critical section counter went negative: {state.in_critical}")
    return found


def run_schedule(
    participants: dict[str, list[Step]], order: list[str], *, broken: str = ""
) -> ScheduleResult:
    """Execute one interleaving; return its violations and reached states.

    Each call runs against a fresh ``ModelState``, so repeated calls with
    the same inputs are independent: nothing carries over between them.

    Parameters
    ----------
    participants : dict[str, list[Step]]
        Each participant's full sequence of (label, function) steps.
    order : list[str]
        The sampled attempt order; ties and contention are resolved by the
        drain that follows it.
    broken : str, optional
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants.

    Returns
    -------
    ScheduleResult
        Any violation messages found (empty if the schedule holds every
        invariant), and the states this schedule's steps reached.
    """
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
    return ScheduleResult(violations=violations, reached=frozenset(state.reached))


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
    and the self-test explore exactly the same space.

    Parameters
    ----------
    rng : random.Random
        The seeded generator used to shuffle attempt orders.
    schedules_per_case : int
        How many orders to sample per combination of participants.
    broken : str, optional
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants.

    Returns
    -------
    list[tuple[dict[str, list[Step]], list[str]]]
        The sampled (participants, order) pairs.
    """
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


def abstract_cases(rng: random.Random, schedules_per_case: int) -> SweepResult:
    """Sample interleavings of 0-2 builds and a clean; check every one.

    Parameters
    ----------
    rng : random.Random
        The seeded generator used to shuffle attempt orders.
    schedules_per_case : int
        How many orders to sample per combination of participants.

    Returns
    -------
    SweepResult
        The number of schedules checked, and the union of every checked
        schedule's reached states.

    Raises
    ------
    CheckFailure
        If any sampled schedule violates an invariant.
    """
    checked = 0
    reached: set[str] = set()
    for participants, order in schedule_space(rng, schedules_per_case):
        result = run_schedule(dict(participants), order)
        checked += 1
        reached.update(result.reached)
        if result.violations:
            raise CheckFailure(
                "abstract schedule violated invariants: "
                f"{result.violations}; participants={sorted(participants)}; "
                f"order={order}"
            )
    return SweepResult(checked=checked, reached=frozenset(reached))


__all__ = [
    "BUILD_OUTCOMES",
    "PUBLISH_MODES",
    "ScheduleResult",
    "SweepResult",
    "abstract_cases",
    "run_schedule",
    "schedule_space",
]
