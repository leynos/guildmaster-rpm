#!/usr/bin/env python3
"""Thin entry point for the ``modelcheck`` package.

The package directory is named ``modelcheck`` (not ``model_check``) because a
module file and a package directory of the same name cannot coexist
importably in the same directory as this script; naming the package
differently avoids that clash while keeping this file, its path and its CLI
unchanged for the Makefile's ``unit`` target. See
``scripts/tests/modelcheck/__init__.py`` for what the check does and why.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from modelcheck.__main__ import main

if __name__ == "__main__":
    sys.exit(main())
