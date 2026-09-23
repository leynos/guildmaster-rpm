"""Constants and helpers shared by the executed and abstract layers.

See ``modelcheck.__main__`` for the bounded state-space check these two
layers make up, and the invariants (I1-I4) they both assert.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
BUILD_SH = REPO_ROOT / "scripts" / "build-rpm.sh"
CLEAN_SH = REPO_ROOT / "scripts" / "clean.sh"
STUBS_DIR = Path(__file__).resolve().parent.parent / "stubs"

COMMIT = "463382ba5b47625a9355832cd792a164c54237f9"
VERSION = "0.1^20251202git463382b"
RELEASE = "1.fc43"
ARCH = "x86_64"
TARGET = "fedora-43"
TARBALL = f"guildmaster-{COMMIT}.tar.gz"

BASE_RPM = f"guildmaster-{VERSION}-{RELEASE}.{ARCH}.rpm"
DEBUGINFO_RPM = f"guildmaster-debuginfo-{VERSION}-{RELEASE}.{ARCH}.rpm"
DEBUGSOURCE_RPM = f"guildmaster-debugsource-{VERSION}-{RELEASE}.{ARCH}.rpm"
SRC_RPM = f"srpm/guildmaster-{VERSION}-{RELEASE}.src.rpm"
COMPLETE = (BASE_RPM, DEBUGINFO_RPM, DEBUGSOURCE_RPM, SRC_RPM)
MANIFEST = "manifest.tsv"

DEFAULT_SEED = 20260921

# Placeholder tokens substituted into the podman stub template at load time,
# in ``executed.write_stubs``.
STUB_PLACEHOLDERS = (
    ("@BASE@", BASE_RPM),
    ("@DEBUGINFO@", DEBUGINFO_RPM),
    ("@DEBUGSOURCE@", DEBUGSOURCE_RPM),
    ("@SRC@", SRC_RPM),
    ("@MANIFEST@", MANIFEST),
    ("@ARCH@", ARCH),
)


class CheckFailure(Exception):
    """An invariant did not hold for a generated case."""
