"""Abstract layer: the transition system's observable state and step type.

Defines ``ModelState``, the observable state the invariants talk about, the
exceptions a step raises to signal contention or an aborted build, the
``Step`` type alias, and ``REACHED``, the set of states the sweep must
actually reach for a pass to mean anything. See ``modelcheck.__main__`` for
how this fits with the executed layer.
"""

from __future__ import annotations

from collections.abc import Callable


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
    """Raised by a step to abort its build, as a phase failure would."""


class _LockContended(Exception):
    """Raised by a step that finds a lock already held by another build."""


class _CleanBlocked(Exception):
    """Raised by clean's step while an activity lock is held."""


Step = tuple[str, Callable[[ModelState], None]]

# States the sweep must actually reach for a pass to mean anything.
REACHED: set[str] = set()


__all__ = [
    "REACHED",
    "ModelState",
    "Step",
]
