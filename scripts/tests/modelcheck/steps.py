"""Abstract layer: the atomic steps of one build or clean invocation.

Builds the (label, function) pairs for a build's fetch, dependency, commit,
build, rebuild, validation and publication phases, and for a clean
invocation. See ``modelcheck.__main__`` for how this fits with the executed
layer.
"""

from __future__ import annotations

from collections.abc import Callable

from .model import (
    REACHED,
    ModelState,
    Step,
    _BuildAborted,
    _CleanBlocked,
    _LockContended,
)


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
        """Take the activity lock, as the first step of a build."""
        state.activity_holders += 1

    def fetch(state: ModelState) -> None:
        """Mark the tarball cache as populated by a successful fetch."""
        state.cache = "valid"

    def phase_deps(state: ModelState) -> None:
        """Run the dependency phase, aborting on a modelled deps failure."""
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
        """Commit the build environment to an image."""
        state.images.add(name)

    def phase_build(state: ModelState) -> None:
        """Run the build phase, staging its set and aborting on failure."""
        state.staging[name] = scenario["build"]
        if scenario["build"] == "build_failure":
            raise _BuildAborted

    def phase_rebuild(state: ModelState) -> None:
        """Run the SRPM rebuild, releasing the container and image on
        success or aborting on a modelled rebuild failure.
        """
        if scenario["build"] == "rebuild_failure":
            raise _BuildAborted
        state.containers.discard(name)
        state.images.discard(name)

    def validate(state: ModelState) -> None:
        """Accept the staged set only when the scenario models success."""
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
        """Take the publication lock, or raise on contention."""
        if state.publish_lock_held:
            REACHED.add("publication_contention")
            raise _LockContended
        state.publish_lock_held = True
        state.in_critical += 1

    def publish(state: ModelState) -> None:
        """Publish directly, or enter the documented fallback window."""
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
        """Conclude a fallback publication: promote, roll back, or leave
        recovery data behind on a modelled rollback failure.
        """
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
        """Release the publication lock, unless ``broken`` models a leak."""
        if broken == "leak_publication_lock":
            return
        state.publish_lock_held = False
        state.in_critical -= 1

    def release_activity(state: ModelState) -> None:
        """Release the activity lock and drop this build's staging entry,
        unless ``broken`` models a staging leak.
        """
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
        """Wait for the activity lock to be free, then remove the output
        and cache, unless ``broken`` models clean ignoring the lock.
        """
        if state.activity_holders != 0 and broken != "clean_ignores_lock":
            raise _CleanBlocked
        state.published = None
        state.cache = "absent"
        state.cleaned = True

    return [("clean:remove", wait_and_remove)]


__all__ = [
    "build_steps",
    "clean_steps",
]
