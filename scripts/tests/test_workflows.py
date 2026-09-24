#!/usr/bin/env python3
"""Thin entry point for the ``workflowcheck`` package.

See ``scripts/tests/workflowcheck/__init__.py`` for what this check
verifies and why. This script's path and CLI stay unchanged for the
Makefile's ``unit`` target; see ``scripts/tests/model_check.py`` for the
same pattern applied to ``modelcheck``.

Run directly (if ``import yaml`` already works) or via::

    uv run --no-project --with pyyaml==6.0.2 python3 scripts/tests/test_workflows.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from workflowcheck.__main__ import main

if __name__ == "__main__":
    sys.exit(main())
