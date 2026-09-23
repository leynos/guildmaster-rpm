"""Abstract layer: a hand-written transition system for interleavings.

This layer models the build, publication and cleanup algorithm as a small
transition system and samples interleavings of up to two concurrent builds
and a clean. It is an abstract model, not the executed script: it can agree
with the documentation and disagree with the shell. See
``modelcheck.__main__`` for how this fits with the executed layer.
"""

from __future__ import annotations

import itertools
import random
from collections.abc import Callable

from .common import CheckFailure


class ModelState:
    """The observable state the invariants talk about."""

    def __init__(self) -> None:
        """Initialise a fresh model state with nothing published or held."""
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
    """Acquiring the activity lock, fetching, and the dependency phase.

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.

    Returns
    -------
    list[Step]
        The (label, function) pairs for these steps.
    """

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
    """The commit, build and rebuild phases, followed by validation.

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.

    Returns
    -------
    list[Step]
        The (label, function) pairs for these steps.
    """

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
    validation, as (label, function) pairs.

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.

    Returns
    -------
    list[Step]
        The (label, function) pairs for these steps.
    """
    return _fetch_and_deps_steps(name, scenario) + _build_and_validate_steps(
        name, scenario
    )


def _publish_lock_and_publish_steps(name: str, scenario: dict[str, str]) -> list[Step]:
    """Taking the publication lock and publishing (or beginning a fallback).

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.

    Returns
    -------
    list[Step]
        The (label, function) pairs for these steps.
    """

    def take_publish_lock(state: ModelState) -> None:
        if state.publish_lock_held:
            REACHED.add("publication_contention")
            raise _LockContended
        state.publish_lock_held = True
        state.in_critical += 1

    def publish(state: ModelState) -> None:
        match scenario["publish"]:
            case "first" | "exchange":
                state.published = name
            case _:
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
    """Build the step that concludes a fallback publication, if any.

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.

    Returns
    -------
    Callable[[ModelState], None]
        The step function to run at the end of publication.
    """

    def finish_publish(state: ModelState) -> None:
        match scenario["publish"]:
            case "first" | "exchange":
                return
            case "fallback":
                state.published = name
                state.recovery.pop(name, None)
            case "promotion_failure":
                state.published = state.recovery.pop(name)  # rollback succeeds
            case _:  # rollback_failure: the previous set stays as recovery data
                REACHED.add("retained_recovery")
        state.publishing_fallback = False
        if scenario["publish"] == "rollback_failure":
            raise _BuildAborted

    return finish_publish


def _release_steps(name: str, scenario: dict[str, str], *, broken: str) -> list[Step]:
    """Releasing the publication and activity locks, as (label, function)
    pairs.

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.
    broken : str
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants.

    Returns
    -------
    list[Step]
        The (label, function) pairs for these steps.
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

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.
    broken : str
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants.

    Returns
    -------
    list[Step]
        The (label, function) pairs for these steps.
    """
    finish_step: Step = (f"{name}:finish_publish", _make_finish_publish(name, scenario))
    return [finish_step, *_release_steps(name, scenario, broken=broken)]


def _publication_steps(
    name: str, scenario: dict[str, str], *, broken: str
) -> list[Step]:
    """The publication steps: taking the lock, publishing, unwinding a
    fallback and releasing both locks, as (label, function) pairs.

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.
    broken : str
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants.

    Returns
    -------
    list[Step]
        The (label, function) pairs for these steps.
    """
    return [
        *_publish_lock_and_publish_steps(name, scenario),
        *_finish_and_release_steps(name, scenario, broken=broken),
    ]


def build_steps(name: str, scenario: dict[str, str], *, broken: str = "") -> list[Step]:
    """The atomic steps of one build, as (label, function) pairs.

    Parameters
    ----------
    name : str
        This build's participant name.
    scenario : dict[str, str]
        The build and publish outcomes this participant follows.
    broken : str, optional
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants.

    Returns
    -------
    list[Step]
        The (label, function) pairs for this build's full sequence of steps.
    """
    return _build_phase_steps(name, scenario) + _publication_steps(
        name, scenario, broken=broken
    )


def clean_steps(*, broken: str = "") -> list[Step]:
    """The atomic steps of one clean invocation, as (label, function) pairs.

    Parameters
    ----------
    broken : str, optional
        Injects a deliberate modelling fault, used by the self-test to show
        that this checker rejects a model that does not hold the
        invariants.

    Returns
    -------
    list[Step]
        A single-step (label, function) list.
    """

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
    deliberately survives.

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
        invariants.

    Returns
    -------
    None
    """
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
    return found


def run_schedule(
    participants: dict[str, list[Step]], order: list[str], *, broken: str = ""
) -> list[str]:
    """Execute one interleaving; return any invariant violations.

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
    list[str]
        Any violation messages found; empty if the schedule holds every
        invariant.
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


def abstract_cases(rng: random.Random, schedules_per_case: int) -> int:
    """Sample interleavings of 0-2 builds and a clean; return cases checked.

    Parameters
    ----------
    rng : random.Random
        The seeded generator used to shuffle attempt orders.
    schedules_per_case : int
        How many orders to sample per combination of participants.

    Returns
    -------
    int
        The number of schedules checked.

    Raises
    ------
    CheckFailure
        If any sampled schedule violates an invariant.
    """
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


__all__ = [
    "BUILD_OUTCOMES",
    "PUBLISH_MODES",
    "REACHED",
    "SELF_TEST_FAULTS",
    "ModelState",
    "Step",
    "abstract_cases",
    "build_steps",
    "clean_steps",
    "run_schedule",
    "schedule_space",
    "self_test",
]
