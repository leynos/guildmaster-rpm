"""Executed layer: the generated sample of executable scenarios.

Builds the deterministic, bounded sample of cache/build/publish/clean
combinations that ``modelcheck.__main__`` drives through the real scripts.
See ``modelcheck.__main__`` for how this fits with the abstract layer.
"""

from __future__ import annotations

import itertools
import random


def executed_cases(rng: random.Random, limit: int) -> list[dict[str, object]]:
    """A deterministic bounded sample of executable scenarios.

    Parameters
    ----------
    rng : random.Random
        The seeded generator used to shuffle and sample scenarios.
    limit : int
        The maximum number of scenarios to return.

    Returns
    -------
    list[dict[str, object]]
        The chosen scenarios, always including at least those needed to
        exercise the publication modes that carry recovery behaviour and a
        failure in each container phase.
    """
    caches = ["absent", "valid", "corrupt", "interrupted"]
    builds = [
        "success",
        "partial",
        "deps_failure",
        "build_failure",
        "rebuild_failure",
        "cancel",
    ]
    publishes = [
        "first",
        "exchange",
        "fallback",
        "promotion_failure",
        "rollback_failure",
    ]
    cleans = ["none", "before", "after"]

    everything: list[dict[str, object]] = []
    for cache, build, publish, clean in itertools.product(
        caches, builds, publishes, cleans
    ):
        # "first" publication means nothing was published before; every other
        # mode needs a primed generation to act on.
        primed = publish != "first"
        # Publication mode only matters when the build reaches publication.
        if build != "success" and publish not in ("first", "exchange"):
            continue
        everything.append(
            {
                "cache": cache,
                "build": build,
                "publish": publish,
                "clean": clean,
                "primed": primed,
            }
        )

    # Always exercise the publication modes that carry recovery behaviour, and
    # at least one failure in each container phase.
    required = [
        c
        for c in everything
        if c["cache"] == "valid"
        and c["clean"] == "none"
        and (
            c["publish"] in ("promotion_failure", "rollback_failure")
            or c["build"] in ("deps_failure", "build_failure", "rebuild_failure")
        )
    ]
    rest = [c for c in everything if c not in required]
    rng.shuffle(rest)
    chosen = required + rest[: max(0, limit - len(required))]
    return chosen


__all__ = ["executed_cases"]
