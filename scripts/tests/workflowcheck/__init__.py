"""Deterministic assertions against the GitHub Actions workflows.

Loads ``ci.yml``, ``acceptance.yml`` and ``release.yml``, plus the composite
actions they use, and checks the contract that
:doc:`/docs/developers-guide.md` (section 16, "Continuous integration and
releases") records: triggers, target matrices, the release job graph,
permissions, cancellation policy, pinned action references, checkout
settings, artefact names and paths, the candidate download flow, evidence
and publish ordering, and preflight environment setup.

Each assertion is a small, named check, defined in :mod:`.checks`. After the
real files pass, a set of in-memory mutations to the workflow text, defined
in :mod:`.mutations`, confirms that removing a critical guard makes the
matching check fail, so the suite itself is exercised. :mod:`.bundle` loads
and parses the workflow and action files; :mod:`.__main__` runs the checks
and mutations and reports the outcome.

Run directly (if ``import yaml`` already works) or via::

    uv run --no-project --with pyyaml==6.0.2 python3 scripts/tests/test_workflows.py
"""

from __future__ import annotations
