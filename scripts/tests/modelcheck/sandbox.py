"""Executed layer: the disposable sandbox and its stub wiring.

Installs the curl, podman and publish-mv stubs, classifies a package
directory's contents, and provides ``Sandbox``, the one disposable case
directory wired to those stubs, plus the environment-variable helpers that
select a cache state, container-phase outcome or publication mode. See
``modelcheck.__main__`` for how this fits with the abstract layer.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from .common import (
    BUILD_SH,
    CLEAN_SH,
    COMPLETE,
    MANIFEST,
    STUB_PLACEHOLDERS,
    STUBS_DIR,
    TARBALL,
    TARGET,
    InspectionError,
)


@contextmanager
def _inspecting(what: str) -> Iterator[None]:
    """Wrap filesystem read and decode failures in :class:`InspectionError`.

    Parameters
    ----------
    what : str
        A description of the state being inspected, for the error message.

    Yields
    ------
    None
        Control to the inspecting block.

    Raises
    ------
    InspectionError
        If the block raises ``OSError`` or ``UnicodeDecodeError``.
    """
    try:
        yield
    except (OSError, UnicodeDecodeError) as exc:
        raise InspectionError(f"cannot inspect {what}: {exc}") from exc


def write_stubs(bindir: Path) -> None:
    """Install the curl, podman and publish-mv stubs into ``bindir``.

    Parameters
    ----------
    bindir : Path
        The directory to install the stub executables into. Created if it
        does not already exist.

    Returns
    -------
    None
    """
    bindir.mkdir(parents=True, exist_ok=True)
    for name, filename in (
        ("curl", "curl.sh"),
        ("podman", "podman.sh"),
        ("publish-mv", "publish-mv.sh"),
    ):
        body = (STUBS_DIR / filename).read_text()
        if name == "podman":
            for placeholder, value in STUB_PLACEHOLDERS:
                body = body.replace(placeholder, value)
        path = bindir / name
        path.write_text(body)
        path.chmod(0o755)


def classify(directory: Path) -> str:
    """Describe a package directory as absent, complete:<tag>, partial or mixed.

    Parameters
    ----------
    directory : Path
        The directory to inspect.

    Returns
    -------
    str
        ``"absent"``, ``"partial"``, ``"mixed"``, or ``"complete:<tag>"``
        where ``<tag>`` is the shared generation tag written by the podman
        stub.

    Raises
    ------
    InspectionError
        If the directory or a package file in it cannot be read, or a
        package file's generation tag is not valid UTF-8.
    """
    with _inspecting(f"package directory {directory}"):
        if not directory.is_dir():
            return "absent"
        found: dict[str, str] = {}
        for name in COMPLETE:
            candidate = directory / name
            if candidate.is_file():
                found[name] = candidate.read_text().strip()
        extra = {
            str(p.relative_to(directory))
            for p in directory.rglob("*.rpm")
            if p.is_file()
        } - set(COMPLETE)
        has_manifest = (directory / MANIFEST).is_file()
    if extra:
        return "mixed"
    if not found:
        return "absent"
    if len(found) != len(COMPLETE) or not has_manifest:
        return "partial"
    tags = set(found.values())
    if len(tags) != 1:
        return "mixed"
    return f"complete:{tags.pop()}"


# Matches a "/proc/locks" device:inode field, e.g. "08:31:1642067801": the
# device's major and minor numbers in hexadecimal, then the inode in
# decimal, as emitted by the kernel's lock-reporting code in fs/locks.c.
_PROC_LOCKS_DEVICE_INODE = re.compile(r"([0-9a-fA-F]+):([0-9a-fA-F]+):(\d+)")


def lock_is_held_by_anyone(path: Path) -> bool:
    """Observe whether a lock file is currently held, without touching it.

    This opens no file descriptor on ``path`` and takes no lock of its own:
    it stats the file for its device and inode, then reads ``/proc/locks``
    to see whether any process holds a ``flock`` or POSIX/OFD lock on that
    same (device, inode) pair. Reading ``/proc/locks`` does not require
    opening ``path`` itself, so this cannot change the file's content,
    mtime, or any lock another process holds on it.

    Parameters
    ----------
    path : Path
        The lock file to observe.

    Returns
    -------
    bool
        ``True`` if the path exists and some process currently holds a
        lock on it; ``False`` if the path is absent or unlocked.

    Raises
    ------
    InspectionError
        If ``path`` cannot be stat'ed or ``/proc/locks`` cannot be read.
    """
    with _inspecting(f"the lock state of {path} in /proc/locks"):
        if not path.exists():
            return False
        st = path.stat()
        lines = Path("/proc/locks").read_text().splitlines()
    target = (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
    for line in lines:
        if "->" in line:
            continue  # A blocked waiter's request, not a granted lock.
        match = _PROC_LOCKS_DEVICE_INODE.search(line)
        if match is None:
            continue
        major, minor, inode = match.groups()
        if (int(major, 16), int(minor, 16), int(inode)) == target:
            return True
    return False


class Sandbox:
    """One disposable case directory wired to the stubs."""

    def __init__(self, root: Path, bindir: Path, fixture: Path, digest: str) -> None:
        """Set up the paths for one case's disposable sandbox.

        Parameters
        ----------
        root : Path
            The case's own directory; all other paths are derived from it.
        bindir : Path
            The directory holding the curl, podman and publish-mv stubs.
        fixture : Path
            The stable stand-in tarball served by the curl stub.
        digest : str
            The SHA-256 digest of ``fixture``, passed to the build script as
            ``TARBALL_SHA256``.
        """
        self.root = root
        self.bindir = bindir
        self.fixture = fixture
        self.digest = digest
        self.out = root / TARGET
        self.cache = root / "cache"
        self.locks = self.cache / "locks"
        self.staging = root / ".staging"
        self.podman_state = root / "podman-state"

    def base_env(self, tag: str) -> dict[str, str]:
        """Build the environment a build invocation needs.

        Parameters
        ----------
        tag : str
            The generation tag the podman stub should write into built
            packages.

        Returns
        -------
        dict[str, str]
            The environment, seeded from ``os.environ`` and overlaid with
            the sandbox's stub and directory wiring.
        """
        env = os.environ.copy()
        env.update(
            {
                "CURL": str(self.bindir / "curl"),
                "PODMAN": str(self.bindir / "podman"),
                "CURL_STUB_FIXTURE": str(self.fixture),
                "PODMAN_STUB_TAG": tag,
                "PODMAN_STUB_STATE": str(self.podman_state),
                "TARBALL_URL": "https://example.invalid/" + TARBALL,
                "TARBALL_SHA256": self.digest,
                "CACHE_DIR": str(self.cache),
                "LOCK_DIR": str(self.locks),
                "STAGING_ROOT": str(self.staging),
            }
        )
        return env

    def seed_cache(self, state: str) -> set[str]:
        """Set the cache to one of absent/valid/corrupt/interrupted.

        Parameters
        ----------
        state : str
            One of ``"absent"``, ``"valid"``, ``"corrupt"`` or
            ``"interrupted"``.

        Returns
        -------
        set[str]
            The names of any temporary tarballs already present in the
            cache, for use as a pre-invocation baseline.

        Raises
        ------
        InspectionError
            If the cache directory cannot be listed afterwards.
        """
        self.cache.mkdir(parents=True, exist_ok=True)
        target = self.cache / TARBALL
        match state:
            case "valid":
                shutil.copyfile(self.fixture, target)
            case "corrupt":
                target.write_text("truncated junk")
            case "interrupted":
                (self.cache / f"{TARBALL}.ABC123").write_text("half a download")
        return self.temp_tarballs()

    def temp_tarballs(self) -> set[str]:
        """List the temporary tarball names currently in the cache.

        Returns
        -------
        set[str]
            The names of files matching the temporary-download pattern.

        Raises
        ------
        InspectionError
            If the cache directory cannot be listed.
        """
        with _inspecting(f"cache directory {self.cache}"):
            if not self.cache.is_dir():
                return set()
            return {p.name for p in self.cache.glob(f"{TARBALL}.??????")}

    def staging_entries(self) -> tuple[tuple[str, ...], tuple[str, ...]]:
        """List the staging directory's owned and recovery entries.

        Returns
        -------
        tuple[tuple[str, ...], tuple[str, ...]]
            A pair of sorted name tuples: entries owned by the current
            invocation, and ``.previous`` recovery entries.

        Raises
        ------
        InspectionError
            If the staging directory cannot be listed.
        """
        with _inspecting(f"staging directory {self.staging}"):
            if not self.staging.is_dir():
                return ((), ())
            entries = [entry.name for entry in self.staging.iterdir()]
        owned = [name for name in entries if not name.endswith(".previous")]
        recovery = [name for name in entries if name.endswith(".previous")]
        return tuple(sorted(owned)), tuple(sorted(recovery))

    def container_residue(self) -> tuple[str, ...]:
        """List the containers and images left in the podman stub's state.

        Returns
        -------
        tuple[str, ...]
            Sorted ``"containers/<name>"`` and ``"images/<name>"`` entries.

        Raises
        ------
        InspectionError
            If the podman stub's state directories cannot be listed.
        """
        names: list[str] = []
        with _inspecting(f"podman stub state {self.podman_state}"):
            for kind in ("containers", "images"):
                directory = self.podman_state / kind
                if directory.is_dir():
                    names.extend(f"{kind}/{p.name}" for p in directory.iterdir())
        return tuple(sorted(names))

    def run_build(
        self, tag: str, extra: dict[str, str]
    ) -> subprocess.CompletedProcess[str]:
        """Run the build script to completion.

        Parameters
        ----------
        tag : str
            The generation tag the podman stub should write.
        extra : dict[str, str]
            Additional environment variables overlaid on the base
            environment, such as publication or failure-injection settings.

        Returns
        -------
        subprocess.CompletedProcess[str]
            The finished process, with captured text output.
        """
        env = self.base_env(tag)
        env.update(extra)
        return subprocess.run(
            [str(BUILD_SH), "fake-image", str(self.out)],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
            check=False,
        )

    def run_clean(self) -> subprocess.CompletedProcess[str]:
        """Run the clean script to completion.

        Returns
        -------
        subprocess.CompletedProcess[str]
            The finished process, with captured text output.
        """
        env = os.environ.copy()
        env.update(
            {
                "CACHE_DIR": str(self.cache),
                "LOCK_DIR": str(self.locks),
                "DIST_DIR": str(self.out),
            }
        )
        return subprocess.run(
            [str(CLEAN_SH)],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
            check=False,
        )

    def locks_free(self) -> bool:
        """Check that no lock file in the sandbox is still held.

        Returns
        -------
        bool
            ``True`` if every ``*.lock`` file in the lock directory is
            uncontended.

        Raises
        ------
        InspectionError
            If the lock directory cannot be listed or a lock's state cannot
            be observed.
        """
        with _inspecting(f"lock directory {self.locks}"):
            locks = list(self.locks.glob("*.lock")) if self.locks.is_dir() else []
        return not any(lock_is_held_by_anyone(p) for p in locks)


def publication_env(mode: str, bindir: Path) -> dict[str, str]:
    """Build the environment variables that select a publication mode.

    Parameters
    ----------
    mode : str
        One of ``"first"``, ``"exchange"``, ``"fallback"``,
        ``"promotion_failure"`` or ``"rollback_failure"``.
    bindir : Path
        The directory holding the publish-mv stub, used when the mode
        injects a promotion or rollback failure.

    Returns
    -------
    dict[str, str]
        The environment variables to overlay on the build invocation.
    """
    match mode:
        case "first" | "exchange":
            return {}
        case "fallback":
            return {"PUBLISH_EXCHANGE": "never"}
        case "promotion_failure":
            return {
                "PUBLISH_EXCHANGE": "never",
                "PUBLISH_MV": str(bindir / "publish-mv"),
                "PUBLISH_MV_FAIL_PROMOTION": "1",
            }
        case _:  # "rollback_failure"
            return {
                "PUBLISH_EXCHANGE": "never",
                "PUBLISH_MV": str(bindir / "publish-mv"),
                "PUBLISH_MV_FAIL_PROMOTION": "1",
                "PUBLISH_MV_FAIL_ROLLBACK": "1",
            }


def build_env(outcome: str) -> dict[str, str]:
    """Build the environment variables that select a container-phase outcome.

    Parameters
    ----------
    outcome : str
        One of ``"success"``, ``"partial"``, ``"deps_failure"``,
        ``"build_failure"``, ``"rebuild_failure"`` or ``"cancel"``.

    Returns
    -------
    dict[str, str]
        The environment variables to overlay on the build invocation.
    """
    if outcome == "partial":
        return {"PODMAN_STUB_PARTIAL": "1"}
    if outcome in ("deps_failure", "build_failure", "rebuild_failure"):
        return {"PODMAN_STUB_FAIL_PHASE": outcome.removesuffix("_failure")}
    return {}


__all__ = [
    "Sandbox",
    "build_env",
    "classify",
    "lock_is_held_by_anyone",
    "publication_env",
    "write_stubs",
]
