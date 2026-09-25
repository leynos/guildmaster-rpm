"""Mutations that should each make one named check fail.

Each mutator rewrites one workflow's or composite action's raw text to
remove or invert a critical guard. :data:`MUTATIONS` pairs a mutator with the check from :mod:`.checks`
that must catch it, exercising the checks themselves. See
:mod:`workflowcheck` for how mutation checks fit into the check as a whole.
"""

from __future__ import annotations

from collections.abc import Callable

from .bundle import Bundle
from .checks import (
    check_acceptance_triggers,
    check_candidate_flow,
    check_checkout_persist_credentials,
    check_composite_setup_cuse,
    check_concurrency,
    check_hidden_paths_uploaded,
    check_permissions_publish_only,
    check_pinned_actions,
    check_release_job_graph,
    check_uv_available_for_make,
)


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


def _drop_setup_uv_from_ci(raw: str) -> str:
    """Remove the setup-uv step from ci.yml's lint-and-unit job."""
    return raw.replace(
        "      - uses: astral-sh/setup-uv@d0cc045d04ccac9d8b7881df0226f9e82c39688e"
        " # v6.8.0\n",
        "",
        1,
    )


def _drop_setup_uv_from_container_tier(raw: str) -> str:
    """Remove the setup-uv step from the setup-container-tier action."""
    return raw.replace(
        "    - name: Install uv\n"
        "      uses: astral-sh/setup-uv@d0cc045d04ccac9d8b7881df0226f9e82c39688e"
        " # v6.8.0\n",
        "",
        1,
    )


def _keep_tmt_python_out_of_job_env(raw: str) -> str:
    """Stop setup-cuse-tier exporting tmt's Python to the rest of the job."""
    return raw.replace('/python" >> "$GITHUB_ENV"', '/python"', 1)


def _drop_testcloud_vga(raw: str) -> str:
    """Stop setup-cuse-tier giving testcloud guests a VGA device."""
    return raw.replace(
        'CMD_LINE_ARGS = ["-device", "VGA,bus=pcie.0,addr=0x10"]',
        "CMD_LINE_ARGS = []",
        1,
    )


def _drop_include_hidden_from_release(raw: str) -> str:
    """Remove include-hidden-files from one release.yml evidence upload."""
    return raw.replace("          include-hidden-files: true\n", "", 1)


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
    (
        "ci lint-and-unit loses its uv set-up",
        "ci",
        _drop_setup_uv_from_ci,
        check_uv_available_for_make,
    ),
    (
        "setup-container-tier loses its uv set-up",
        "setup-container-tier",
        _drop_setup_uv_from_container_tier,
        check_uv_available_for_make,
    ),
    (
        "setup-cuse-tier stops exporting tmt's Python",
        "setup-cuse-tier",
        _keep_tmt_python_out_of_job_env,
        check_composite_setup_cuse,
    ),
    (
        "setup-cuse-tier stops giving guests a VGA device",
        "setup-cuse-tier",
        _drop_testcloud_vga,
        check_composite_setup_cuse,
    ),
    (
        "a release evidence upload loses include-hidden-files",
        "release",
        _drop_include_hidden_from_release,
        check_hidden_paths_uploaded,
    ),
]
