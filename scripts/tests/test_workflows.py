#!/usr/bin/env python3
"""Deterministic assertions against the GitHub Actions workflows.

Loads ``ci.yml``, ``acceptance.yml`` and ``release.yml``, plus the composite
actions they use, and checks the contract that
:doc:`/docs/developers-guide.md` (section 16, "Continuous integration and
releases") records: triggers, target matrices, the release job graph,
permissions, cancellation policy, pinned action references, checkout
settings, artefact names and paths, the candidate download flow, evidence
and publish ordering, and preflight environment setup.

Each assertion is a small, named check. After the real files pass, a set of
in-memory mutations to the workflow text confirms that removing a critical
guard makes the matching check fail, so the suite itself is exercised.

Run directly (if ``import yaml`` already works) or via::

    uv run --no-project --with pyyaml==6.0.2 python3 scripts/tests/test_workflows.py
"""

from __future__ import annotations

import re
import sys
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml  # ty: ignore[unresolved-import]

REPO_ROOT = Path(__file__).resolve().parents[2]
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
    needs = job.get("needs")
    if needs is None:
        return set()
    if isinstance(needs, str):
        return {needs}
    return set(needs)


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


# ---------------------------------------------------------------------------
# Named checks
# ---------------------------------------------------------------------------


def check_ci_triggers(bundle: Bundle) -> None:
    """CI runs on pull requests and pushes to main, and nothing else."""
    on = get_on(bundle.docs["ci"])
    assert set(on) == {"push", "pull_request"}, f"ci triggers: {on}"
    assert on["push"] == {"branches": ["main"]}, f"ci push trigger: {on['push']}"


def check_acceptance_triggers(bundle: Bundle) -> None:
    """Acceptance runs on pushes to main and manual dispatch only."""
    on = get_on(bundle.docs["acceptance"])
    assert set(on) == {"push", "workflow_dispatch"}, f"acceptance triggers: {on}"
    assert on["push"] == {"branches": ["main"]}, (
        f"acceptance push trigger: {on['push']}"
    )
    assert "pull_request" not in on, "acceptance must never trigger on pull_request"
    assert "pull_request_target" not in on, (
        "acceptance must never trigger on pull_request_target"
    )


def check_release_triggers(bundle: Bundle) -> None:
    """Release runs only on pushes of tags matching v*."""
    on = get_on(bundle.docs["release"])
    assert set(on) == {"push"}, f"release triggers: {on}"
    assert on["push"] == {"tags": ["v*"]}, f"release push trigger: {on['push']}"
    assert "pull_request" not in on, "release must never trigger on pull_request"
    assert "pull_request_target" not in on, (
        "release must never trigger on pull_request_target"
    )


def check_matrices(bundle: Bundle) -> None:
    """Every build/container/cuse job matrices exactly the two targets."""
    targets = [
        ("ci", "container"),
        ("acceptance", "cuse"),
        ("release", "build"),
        ("release", "cuse"),
    ]
    for wf_name, job_name in targets:
        job = bundle.docs[wf_name]["jobs"][job_name]
        strategy = job["strategy"]
        assert strategy["matrix"]["target"] == ["rocky-10", "fedora-43"], (
            f"{wf_name}:{job_name} matrix: {strategy['matrix']}"
        )
        assert strategy["fail-fast"] is False, (
            f"{wf_name}:{job_name} fail-fast: {strategy['fail-fast']}"
        )


def check_release_job_graph(bundle: Bundle) -> None:
    """cuse needs build; publish needs exactly lint-and-unit, build, cuse."""
    jobs = bundle.docs["release"]["jobs"]
    assert needs_set(jobs["cuse"]) == {"build"}, (
        f"cuse needs: {jobs['cuse'].get('needs')}"
    )
    assert needs_set(jobs["publish"]) == {"lint-and-unit", "build", "cuse"}, (
        f"publish needs: {jobs['publish'].get('needs')}"
    )


def check_permissions_top_level(bundle: Bundle) -> None:
    """Every workflow declares top-level contents: read."""
    for name, doc in bundle.docs.items():
        assert doc.get("permissions") == {"contents": "read"}, (
            f"{name} top-level permissions: {doc.get('permissions')}"
        )


def check_permissions_publish_only(bundle: Bundle) -> None:
    """Only release.yml's publish job declares contents: write."""
    for wf_name, doc in bundle.docs.items():
        for job_name, job in doc["jobs"].items():
            perms = job.get("permissions")
            if wf_name == "release" and job_name == "publish":
                assert perms == {"contents": "write"}, f"publish permissions: {perms}"
            else:
                assert perms is None, (
                    f"{wf_name}:{job_name} declares permissions: {perms}"
                )


def check_concurrency(bundle: Bundle) -> None:
    """ci/acceptance cancel superseded runs; release never cancels."""
    for name in ("ci", "acceptance"):
        conc = bundle.docs[name]["concurrency"]
        assert conc["cancel-in-progress"] is True, f"{name} cancel-in-progress: {conc}"
    rel_conc = bundle.docs["release"]["concurrency"]
    assert rel_conc["cancel-in-progress"] is False, (
        f"release cancel-in-progress: {rel_conc}"
    )
    assert "ref" in rel_conc.get("group", ""), f"release group not per-ref: {rel_conc}"


def check_pinned_actions(bundle: Bundle) -> None:
    """Every non-local uses: is owner/repo@<40-hex sha> with a comment."""
    sources = {**bundle.raws, **bundle.action_raws}
    for source_name, raw in sources.items():
        for line in raw.splitlines():
            match = re.search(r"uses:\s*(\S+)", line)
            if match is None:
                continue
            ref = match.group(1)
            if ref.startswith("./"):
                continue
            assert PINNED_ACTION_RE.match(ref), (
                f"{source_name}: unpinned action {ref!r}"
            )
            assert "#" in line, f"{source_name}: missing version comment: {line!r}"


def check_checkout_persist_credentials(bundle: Bundle) -> None:
    """Every actions/checkout step sets persist-credentials: false."""
    for wf_name, doc in bundle.docs.items():
        for job_name, label, step in iter_steps(doc):
            uses = step.get("uses", "")
            if not uses.startswith(CHECKOUT_USES_PREFIX):
                continue
            with_block = step.get("with", {})
            assert with_block.get("persist-credentials") is False, (
                f"{wf_name}:{job_name}:{label} persist-credentials: "
                f"{with_block.get('persist-credentials')}"
            )


def check_artifact_names_release(bundle: Bundle) -> None:
    """release.yml's artefact names, paths and error-on-empty settings."""
    doc = bundle.docs["release"]

    candidate = find_step(doc, "build", "Upload candidate packages")["with"]
    assert candidate["name"] == "candidate-${{ matrix.target }}", candidate
    assert candidate["path"] == "dist/${{ matrix.target }}/", candidate
    assert candidate["if-no-files-found"] == "error", candidate

    evidence = find_step(doc, "build", "Upload container evidence")["with"]
    assert evidence["name"] == "evidence-container-${{ matrix.target }}", evidence
    assert evidence["if-no-files-found"] == "error", evidence

    download = find_step(doc, "cuse", "Download the candidate packages")["with"]
    assert download["name"] == "candidate-${{ matrix.target }}", download
    assert download["path"] == "dist/${{ matrix.target }}", download

    cuse_evidence = find_step(doc, "cuse", "Upload CUSE evidence")["with"]
    assert cuse_evidence["name"] == "evidence-cuse-${{ matrix.target }}", cuse_evidence
    assert cuse_evidence["if-no-files-found"] == "error", cuse_evidence

    diagnostics = find_step(doc, "cuse", "Upload diagnostics on failure")["with"]
    assert "!/var/tmp/tmt/gm-cuse-*/**/id_ecdsa*" in diagnostics["path"], diagnostics

    candidates_dl = find_step(doc, "publish", "Download candidates")["with"]
    assert candidates_dl["pattern"] == "candidate-*", candidates_dl

    evidence_dl = find_step(doc, "publish", "Download evidence")["with"]
    assert evidence_dl["pattern"] == "evidence-*", evidence_dl


def check_artifact_names_ci_acceptance(bundle: Bundle) -> None:
    """ci.yml and acceptance.yml artefact names and error-on-empty settings."""
    ci_doc = bundle.docs["ci"]
    rpms = find_step(ci_doc, "container", "Upload packages")["with"]
    assert rpms["name"] == "rpms-${{ matrix.target }}", rpms
    assert rpms["if-no-files-found"] == "error", rpms

    acc_doc = bundle.docs["acceptance"]
    evidence = find_step(acc_doc, "cuse", "Upload evidence")["with"]
    assert evidence["name"] == "evidence-cuse-${{ matrix.target }}", evidence
    assert evidence["if-no-files-found"] == "error", evidence

    diagnostics = find_step(acc_doc, "cuse", "Upload diagnostics on failure")["with"]
    assert "!/var/tmp/tmt/gm-cuse-*/**/id_ecdsa*" in diagnostics["path"], diagnostics


def _ordered_run_texts(job: dict[str, Any]) -> list[str]:
    """Return a job's step ``run:`` bodies in step order.

    Parameters
    ----------
    job : dict[str, Any]
        A parsed job definition.

    Returns
    -------
    list[str]
        The ``run:`` text of each step that has one, in order.
    """
    return [step["run"] for step in job.get("steps", []) if "run" in step]


def check_candidate_flow(bundle: Bundle) -> None:
    """The release cuse job accepts; publish never builds and orders steps."""
    jobs = bundle.docs["release"]["jobs"]

    cuse_run = "\n".join(_ordered_run_texts(jobs["cuse"]))
    assert 'accept-cuse-${TARGET}"' in cuse_run, cuse_run
    assert "test-cuse" not in cuse_run, cuse_run

    publish_runs = _ordered_run_texts(jobs["publish"])
    combined = "\n".join(publish_runs)
    assert not re.search(r"\bmake\s", combined), f"publish job runs make: {combined!r}"

    evidence_at = combined.find("release-evidence.sh")
    assemble_at = combined.find("assemble-release.sh")
    create_at = combined.find("gh release create")
    edit_at = combined.find("gh release edit")
    assert -1 not in (evidence_at, assemble_at, create_at, edit_at), combined
    assert evidence_at < assemble_at < create_at < edit_at, (
        "expected release-evidence.sh, then assemble-release.sh, then "
        f"gh release create, then gh release edit; got offsets "
        f"{evidence_at}, {assemble_at}, {create_at}, {edit_at}"
    )
    assert "--draft" in combined[create_at : edit_at + 1], combined
    assert "--draft=false" in combined[edit_at:], combined


def check_tag_name_env(bundle: Bundle) -> None:
    """release.yml uses GITHUB_REF_NAME, never an interpolated ref_name."""
    raw = bundle.raws["release"]
    assert "${{ github.ref_name }}" not in raw, (
        "release.yml must not interpolate github.ref_name into run: scripts"
    )
    assert "GITHUB_REF_NAME" in raw, "release.yml never sets/uses GITHUB_REF_NAME"


def check_composite_setup_cuse(bundle: Bundle) -> None:
    """setup-cuse-tier is composite, preflights and pins tmt correctly."""
    doc = bundle.action_docs["setup-cuse-tier"]
    assert doc["runs"]["using"] == "composite", doc["runs"]
    raw = bundle.action_raws["setup-cuse-tier"]
    assert "scripts/virt-preflight.sh" in raw, raw
    assert re.search(r'PYTHON="\$\(dirname.*tmt.*python"', raw), (
        "setup-cuse-tier must set PYTHON from the tmt pipx environment"
    )
    assert "tmt[provision-virtual]==1.78.0" in raw, "tmt must be pinned to 1.78.0"


def check_composite_setup_container(bundle: Bundle) -> None:
    """setup-container-tier is composite, preflights and enables lingering."""
    doc = bundle.action_docs["setup-container-tier"]
    assert doc["runs"]["using"] == "composite", doc["runs"]
    raw = bundle.action_raws["setup-container-tier"]
    assert "scripts/podman-preflight.sh" in raw, raw
    assert "enable-linger" in raw, "setup-container-tier must enable lingering"


def check_logs_under_runner_temp(bundle: Bundle) -> None:
    """Every tee target in the workflows is under ${RUNNER_TEMP}."""
    for name, raw in bundle.raws.items():
        for line in raw.splitlines():
            stripped = line.strip()
            if " tee " not in line and not stripped.startswith("tee "):
                continue
            assert "RUNNER_TEMP" in line, f"{name}: tee not under RUNNER_TEMP: {line!r}"


CHECKS: list[tuple[str, Callable[[Bundle], None]]] = [
    ("ci triggers", check_ci_triggers),
    ("acceptance triggers", check_acceptance_triggers),
    ("release triggers", check_release_triggers),
    ("target matrices", check_matrices),
    ("release job graph", check_release_job_graph),
    ("top-level permissions", check_permissions_top_level),
    ("publish-only write permissions", check_permissions_publish_only),
    ("concurrency and cancellation", check_concurrency),
    ("pinned action references", check_pinned_actions),
    ("checkout persist-credentials", check_checkout_persist_credentials),
    ("release artefact names and paths", check_artifact_names_release),
    ("ci/acceptance artefact names and paths", check_artifact_names_ci_acceptance),
    ("candidate flow and publish ordering", check_candidate_flow),
    ("tag name from GITHUB_REF_NAME", check_tag_name_env),
    ("setup-cuse-tier preflight", check_composite_setup_cuse),
    ("setup-container-tier preflight", check_composite_setup_container),
    ("logs under RUNNER_TEMP", check_logs_under_runner_temp),
]


# ---------------------------------------------------------------------------
# Mutation checks
# ---------------------------------------------------------------------------


def _add_pull_request_to_acceptance(raw: str) -> str:
    """Add a pull_request trigger to acceptance.yml's raw text."""
    return raw.replace(
        "  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request:\n", 1
    )


def _drop_cuse_from_publish_needs(raw: str) -> str:
    """Remove cuse from release.yml publish job's needs list."""
    return raw.replace(
        "needs: [lint-and-unit, build, cuse]", "needs: [lint-and-unit, build]", 1
    )


def _give_build_job_write_permissions(raw: str) -> str:
    """Add contents: write permissions to release.yml's build job."""
    return raw.replace(
        "  build:\n    name: Build and container tier (${{ matrix.target }})\n"
        "    runs-on: ubuntu-24.04\n",
        "  build:\n    name: Build and container tier (${{ matrix.target }})\n"
        "    runs-on: ubuntu-24.04\n    permissions:\n      contents: write\n",
        1,
    )


def _unpin_a_checkout_action(raw: str) -> str:
    """Replace one pinned checkout SHA with an unpinned tag reference."""
    return raw.replace(
        "actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0",
        "actions/checkout@v4",
        1,
    )


def _enable_persisted_credentials(raw: str) -> str:
    """Flip one checkout step's persist-credentials to true."""
    return raw.replace("persist-credentials: false", "persist-credentials: true", 1)


def _rebuild_instead_of_accept_in_release_cuse(raw: str) -> str:
    """Make release.yml's cuse job rebuild instead of accepting the candidate."""
    return raw.replace('make "accept-cuse-${TARGET}"', 'make "test-cuse-${TARGET}"', 1)


def _never_cancel_becomes_always_cancel(raw: str) -> str:
    """Flip release.yml's cancel-in-progress to true."""
    return raw.replace("cancel-in-progress: false", "cancel-in-progress: true", 1)


MUTATIONS: list[tuple[str, str, Callable[[str], str], Callable[[Bundle], None]]] = [
    (
        "acceptance.yml gains a pull_request trigger",
        "acceptance",
        _add_pull_request_to_acceptance,
        check_acceptance_triggers,
    ),
    (
        "publish's needs drops cuse",
        "release",
        _drop_cuse_from_publish_needs,
        check_release_job_graph,
    ),
    (
        "build job gains contents: write",
        "release",
        _give_build_job_write_permissions,
        check_permissions_publish_only,
    ),
    (
        "a pinned SHA is replaced with @v4",
        "release",
        _unpin_a_checkout_action,
        check_pinned_actions,
    ),
    (
        "persist-credentials is set to true",
        "release",
        _enable_persisted_credentials,
        check_checkout_persist_credentials,
    ),
    (
        "release cuse rebuilds instead of accepting",
        "release",
        _rebuild_instead_of_accept_in_release_cuse,
        check_candidate_flow,
    ),
    (
        "release cancel-in-progress becomes true",
        "release",
        _never_cancel_becomes_always_cancel,
        check_concurrency,
    ),
]


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
