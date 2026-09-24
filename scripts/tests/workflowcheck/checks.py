"""Named checks against a parsed workflow :class:`~.bundle.Bundle`.

Each ``check_*`` function asserts one clause of the contract that
:doc:`/docs/developers-guide.md` (section 16, "Continuous integration and
releases") records. :data:`CHECKS` pairs each with the name shown in the
report. See :mod:`workflowcheck` for how these fit into the check as a
whole, and :mod:`.mutations` for the mutants each check must catch.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

from .bundle import (
    CHECKOUT_USES_PREFIX,
    PINNED_ACTION_RE,
    Bundle,
    find_step,
    get_on,
    iter_steps,
    needs_set,
)


def check_ci_triggers(bundle: Bundle) -> None:
    """CI runs on pull requests and pushes to main, and nothing else.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If ``ci.yml`` has any trigger other than ``push`` and
        ``pull_request``, or its push trigger is not limited to ``main``.
    """
    on = get_on(bundle.docs["ci"])
    assert set(on) == {"push", "pull_request"}, f"ci triggers: {on}"
    assert on["push"] == {"branches": ["main"]}, f"ci push trigger: {on['push']}"


def check_acceptance_triggers(bundle: Bundle) -> None:
    """Acceptance runs on pushes to main and manual dispatch only.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If ``acceptance.yml`` has any trigger other than ``push`` and
        ``workflow_dispatch``, or its push trigger is not limited to ``main``.
    """
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
    """Release runs only on pushes of tags matching v*.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If ``release.yml`` runs on anything but pushes of tags
        matching ``v*``.
    """
    on = get_on(bundle.docs["release"])
    assert set(on) == {"push"}, f"release triggers: {on}"
    assert on["push"] == {"tags": ["v*"]}, f"release push trigger: {on['push']}"
    assert "pull_request" not in on, "release must never trigger on pull_request"
    assert "pull_request_target" not in on, (
        "release must never trigger on pull_request_target"
    )


def check_matrices(bundle: Bundle) -> None:
    """Every build/container/cuse job matrices exactly the two targets.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If a build, container or cuse job does not run on exactly the
        ``rocky-10`` and ``fedora-43`` targets.
    """
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
    """cuse needs build; publish needs exactly lint-and-unit, build, cuse.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If the release ``cuse`` job does not need ``build``, or
        ``publish`` does not need exactly ``lint-and-unit``, ``build`` and
        ``cuse``.
    """
    jobs = bundle.docs["release"]["jobs"]
    assert needs_set(jobs["cuse"]) == {"build"}, (
        f"cuse needs: {jobs['cuse'].get('needs')}"
    )
    assert needs_set(jobs["publish"]) == {"lint-and-unit", "build", "cuse"}, (
        f"publish needs: {jobs['publish'].get('needs')}"
    )


def check_permissions_top_level(bundle: Bundle) -> None:
    """Every workflow declares top-level contents: read.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If a workflow does not declare top-level
        ``contents: read``.
    """
    for name, doc in bundle.docs.items():
        assert doc.get("permissions") == {"contents": "read"}, (
            f"{name} top-level permissions: {doc.get('permissions')}"
        )


def check_permissions_publish_only(bundle: Bundle) -> None:
    """Only release.yml's publish job declares contents: write.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If any job other than ``release.yml``'s ``publish``
        declares ``contents: write``.
    """
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
    """ci/acceptance cancel superseded runs; release never cancels.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If ``ci.yml`` or ``acceptance.yml`` does not cancel superseded
        runs, or ``release.yml`` may cancel one.
    """
    for name in ("ci", "acceptance"):
        conc = bundle.docs[name]["concurrency"]
        assert conc["cancel-in-progress"] is True, f"{name} cancel-in-progress: {conc}"
    rel_conc = bundle.docs["release"]["concurrency"]
    assert rel_conc["cancel-in-progress"] is False, (
        f"release cancel-in-progress: {rel_conc}"
    )
    assert "ref" in rel_conc.get("group", ""), f"release group not per-ref: {rel_conc}"


def check_pinned_actions(bundle: Bundle) -> None:
    """Every non-local uses: is owner/repo@<40-hex sha> with a comment.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If a non-local ``uses:`` reference is not pinned to a 40-digit
        commit SHA with a version comment.
    """
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
    """Every actions/checkout step sets persist-credentials: false.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If an ``actions/checkout`` step does not set
        ``persist-credentials: false``.
    """
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
    """release.yml's artefact names, paths and error-on-empty settings.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If a ``release.yml`` artefact has an unexpected name or
        path, or does not fail when it would upload nothing.
    """
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
    """ci.yml and acceptance.yml artefact names and error-on-empty settings.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If a ``ci.yml`` or ``acceptance.yml`` artefact has an
        unexpected name, or does not fail when it would upload nothing.
    """
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
    """The release cuse job accepts; publish never builds and orders steps.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If the release ``cuse`` job does not accept the built
        candidate, ``publish`` builds anything itself, or ``publish``'s steps
        are out of order.
    """
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
    """release.yml uses GITHUB_REF_NAME, never an interpolated ref_name.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If ``release.yml`` interpolates ``ref_name`` rather than
        reading ``GITHUB_REF_NAME`` from the environment.
    """
    raw = bundle.raws["release"]
    assert "${{ github.ref_name }}" not in raw, (
        "release.yml must not interpolate github.ref_name into run: scripts"
    )
    assert "GITHUB_REF_NAME" in raw, "release.yml never sets/uses GITHUB_REF_NAME"


def check_composite_setup_cuse(bundle: Bundle) -> None:
    """setup-cuse-tier is composite, preflights and pins tmt correctly.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If ``setup-cuse-tier`` is not a composite action, does not
        run the preflight, does not export tmt's Python to the job as
        ``PYTHON``, or does not pin tmt as required.
    """
    doc = bundle.action_docs["setup-cuse-tier"]
    assert doc["runs"]["using"] == "composite", doc["runs"]
    raw = bundle.action_raws["setup-cuse-tier"]
    assert "scripts/virt-preflight.sh" in raw, raw
    # Exported for the whole job: scripts/cuse-guest.sh reruns the preflight,
    # and without tmt's interpreter it checks the system python3 and fails.
    assert re.search(
        r'echo "PYTHON=\$\(dirname.*tmt.*python" >> "\$GITHUB_ENV"', raw
    ), "setup-cuse-tier must export PYTHON from the tmt pipx environment to GITHUB_ENV"
    assert "tmt[provision-virtual]==1.78.0" in raw, "tmt must be pinned to 1.78.0"


def check_composite_setup_container(bundle: Bundle) -> None:
    """setup-container-tier is composite, preflights and enables lingering.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If ``setup-container-tier`` is not a composite action, or
        does not run the preflight and enable lingering.
    """
    doc = bundle.action_docs["setup-container-tier"]
    assert doc["runs"]["using"] == "composite", doc["runs"]
    raw = bundle.action_raws["setup-container-tier"]
    assert "scripts/podman-preflight.sh" in raw, raw
    assert "enable-linger" in raw, "setup-container-tier must enable lingering"


def check_hidden_paths_uploaded(bundle: Bundle) -> None:
    """Uploads of paths under a hidden directory opt in to hidden files.

    ``actions/upload-artifact`` v4.4 and later skips hidden files and every
    file inside a directory whose name starts with a dot, so an upload of
    ``.build/...`` finds nothing unless ``include-hidden-files`` is true.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If an ``actions/upload-artifact`` step uploads a path under
        a hidden directory without ``include-hidden-files: true``.
    """
    for name, doc in bundle.docs.items():
        for job_name, label, step in iter_steps(doc):
            if not step.get("uses", "").startswith("actions/upload-artifact@"):
                continue
            with_ = step.get("with", {})
            paths = str(with_.get("path", "")).split()
            hidden = [p for p in paths if re.search(r"(^|/)\.[^/.]", p.lstrip("!"))]
            if not hidden:
                continue
            assert with_.get("include-hidden-files") is True, (
                f"{name}:{job_name}:{label} uploads {hidden} "
                "without include-hidden-files: true"
            )


UV_MAKE_TARGET = re.compile(
    r"make\b[^\n]*?[\s\"'](lint|unit|test-(?:\$\{TARGET\}|rocky-10|fedora-43))(?![\w-])"
)
"""``make`` targets whose recipes run ``uv``/``uvx``, directly or via ``unit``."""


def _job_provides_uv(job: dict[str, Any], container_action_raw: str) -> bool:
    """Whether a job installs uv before its steps run.

    Parameters
    ----------
    job : dict[str, Any]
        A parsed workflow job.
    container_action_raw : str
        Raw text of the setup-container-tier composite action.

    Returns
    -------
    bool
        True when a step uses astral-sh/setup-uv, or uses the container-tier
        set-up action and that action installs uv.
    """
    for step in job.get("steps", []):
        uses = step.get("uses", "")
        if uses.startswith("astral-sh/setup-uv@"):
            return True
        if uses == "./.github/actions/setup-container-tier":
            return "astral-sh/setup-uv@" in container_action_raw
    return False


def check_uv_available_for_make(bundle: Bundle) -> None:
    """Every job running a make target that needs uv installs uv first.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If a job runs a ``make`` target whose recipe needs uv
        without installing uv first.
    """
    container_raw = bundle.action_raws["setup-container-tier"]
    for name, doc in bundle.docs.items():
        for job_name, job in doc["jobs"].items():
            runs = "\n".join(step.get("run", "") for step in job.get("steps", []))
            if UV_MAKE_TARGET.search(runs) is None:
                continue
            assert _job_provides_uv(job, container_raw), (
                f"{name}:{job_name} runs a make target that needs uv, "
                "but no step installs it"
            )


def check_logs_under_runner_temp(bundle: Bundle) -> None:
    """Every tee target in the workflows is under ${RUNNER_TEMP}.

    Parameters
    ----------
    bundle : Bundle
        The parsed workflow and composite action files under test.

    Raises
    ------
    AssertionError
        If a workflow ``tee`` target is not under
        ``${RUNNER_TEMP}``.
    """
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
    ("uv installed wherever make needs it", check_uv_available_for_make),
    ("hidden upload paths include hidden files", check_hidden_paths_uploaded),
]
