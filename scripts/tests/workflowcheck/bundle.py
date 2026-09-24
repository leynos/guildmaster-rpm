"""Loading and parsing of the workflow and composite action files.

Defines :class:`Bundle`, the parsed and raw forms of every workflow and
composite action under test, along with the helpers that :mod:`.checks` and
:mod:`.mutations` use to navigate a bundle's documents. See
:mod:`workflowcheck` for what the check as a whole verifies.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml  # ty: ignore[unresolved-import]

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
ACTIONS_DIR = REPO_ROOT / ".github" / "actions"

WORKFLOW_FILES = {
    "ci": WORKFLOWS_DIR / "ci.yml",
    "acceptance": WORKFLOWS_DIR / "acceptance.yml",
    "release": WORKFLOWS_DIR / "release.yml",
}
ACTION_FILES = {
    "setup-container-tier": ACTIONS_DIR / "setup-container-tier" / "action.yml",
    "setup-cuse-tier": ACTIONS_DIR / "setup-cuse-tier" / "action.yml",
}

PINNED_ACTION_RE = re.compile(r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")
CHECKOUT_USES_PREFIX = "actions/checkout@"


def normalize_on_key(doc: dict[Any, Any]) -> None:
    """Rewrite PyYAML's boolean parse of the ``on:`` key back to a string.

    PyYAML resolves the bare key ``on`` to the boolean ``True`` under the
    YAML 1.1 resolver it uses. This mutates ``doc`` in place so that
    ``doc["on"]`` holds the triggers mapping regardless of that quirk.

    Parameters
    ----------
    doc : dict[Any, Any]
        A parsed workflow document, mutated in place. Its keys are ``Any``
        rather than ``str`` because PyYAML may hand back the boolean key
        this function normalizes away.
    """
    if True in doc:
        doc["on"] = doc.pop(True)


def parse_workflow(raw: str) -> dict[str, Any]:
    """Parse workflow YAML text into a normalized document.

    Parameters
    ----------
    raw : str
        The raw YAML text of a workflow or composite action.

    Returns
    -------
    dict[str, Any]
        The parsed document, with the ``on:`` key normalized.
    """
    doc = yaml.safe_load(raw)
    normalize_on_key(doc)
    return doc


@dataclass(frozen=True)
class Bundle:
    """The parsed and raw forms of every workflow and composite action.

    Attributes
    ----------
    raws : Mapping[str, str]
        Raw YAML text of the three workflows, keyed by short name.
    docs : Mapping[str, dict[str, Any]]
        Parsed workflow documents, keyed the same way.
    action_raws : Mapping[str, str]
        Raw YAML text of the composite actions, keyed by short name.
    action_docs : Mapping[str, dict[str, Any]]
        Parsed composite action documents, keyed the same way.
    """

    raws: Mapping[str, str]
    docs: Mapping[str, dict[str, Any]]
    action_raws: Mapping[str, str]
    action_docs: Mapping[str, dict[str, Any]]


def build_bundle(raws: Mapping[str, str], action_raws: Mapping[str, str]) -> Bundle:
    """Parse a set of raw workflow and action texts into a :class:`Bundle`.

    Parameters
    ----------
    raws : Mapping[str, str]
        Raw workflow YAML text, keyed by short name.
    action_raws : Mapping[str, str]
        Raw composite action YAML text, keyed by short name.

    Returns
    -------
    Bundle
        The parsed bundle.
    """
    docs = {name: parse_workflow(raw) for name, raw in raws.items()}
    action_docs = {name: parse_workflow(raw) for name, raw in action_raws.items()}
    return Bundle(
        raws=raws, docs=docs, action_raws=action_raws, action_docs=action_docs
    )


def load_bundle() -> Bundle:
    """Load the real workflow and composite action files from disk.

    Returns
    -------
    Bundle
        The parsed bundle of the repository's actual files.
    """
    raws = {name: path.read_text() for name, path in WORKFLOW_FILES.items()}
    action_raws = {name: path.read_text() for name, path in ACTION_FILES.items()}
    return build_bundle(raws, action_raws)


def mutate_workflow(bundle: Bundle, name: str, mutator: Callable[[str], str]) -> Bundle:
    """Return a copy of ``bundle`` with one workflow's raw text mutated.

    Parameters
    ----------
    bundle : Bundle
        The bundle to copy.
    name : str
        The short name of the workflow to mutate (a key of ``bundle.raws``).
    mutator : Callable[[str], str]
        A function that transforms the workflow's raw text.

    Returns
    -------
    Bundle
        A new bundle with the named workflow's text mutated and reparsed;
        every other workflow and action is unchanged.

    Raises
    ------
    AssertionError
        If ``mutator`` did not actually change the text, which would mean
        the mutation missed its target and the mutant would be vacuous.
    """
    new_raw = mutator(bundle.raws[name])
    assert new_raw != bundle.raws[name], f"mutator for {name!r} made no change"
    new_raws = dict(bundle.raws)
    new_raws[name] = new_raw
    return build_bundle(new_raws, bundle.action_raws)


def get_on(doc: dict[str, Any]) -> dict[str, Any]:
    """Return a workflow document's triggers mapping.

    Parameters
    ----------
    doc : dict[str, Any]
        A parsed, normalized workflow document.

    Returns
    -------
    dict[str, Any]
        The value of the ``on:`` key.
    """
    return doc["on"]


def needs_set(job: dict[str, Any]) -> set[str]:
    """Return a job's ``needs`` as a set, whether it is a string or a list.

    Parameters
    ----------
    job : dict[str, Any]
        A parsed job definition.

    Returns
    -------
    set[str]
        The job names in ``needs``, or an empty set if there is none.
    """
    match job.get("needs"):
        case None:
            return set()
        case str() as single:
            return {single}
        case names:
            return set(names)


def iter_steps(doc: dict[str, Any]) -> list[tuple[str, str, dict[str, Any]]]:
    """Yield every step of every job in a workflow document.

    Parameters
    ----------
    doc : dict[str, Any]
        A parsed workflow document.

    Returns
    -------
    list[tuple[str, str, dict[str, Any]]]
        ``(job_name, step_name_or_uses, step)`` triples, in document order.
    """
    steps = []
    for job_name, job in doc["jobs"].items():
        for step in job.get("steps", []):
            label = step.get("name", step.get("uses", "<unnamed step>"))
            steps.append((job_name, label, step))
    return steps


def find_step(doc: dict[str, Any], job_name: str, step_name: str) -> dict[str, Any]:
    """Find a step by job and step name.

    Parameters
    ----------
    doc : dict[str, Any]
        A parsed workflow document.
    job_name : str
        The job the step belongs to.
    step_name : str
        The step's ``name:``.

    Returns
    -------
    dict[str, Any]
        The matching step.

    Raises
    ------
    AssertionError
        If no such job or step exists.
    """
    job = doc["jobs"].get(job_name)
    assert job is not None, f"no job {job_name!r}"
    for step in job.get("steps", []):
        if step.get("name") == step_name:
            return step
    raise AssertionError(f"no step {step_name!r} in job {job_name!r}")
