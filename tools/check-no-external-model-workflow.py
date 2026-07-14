#!/usr/bin/env python3
"""Reject reintroduction of repository-managed external model orchestration.

The project no longer ships a model-selection wrapper or a provider-specific
review workflow.  This guard scans tracked UTF-8 text so a future contributor
does not accidentally restore one through a script, documentation snippet, or
CI configuration.  The terms are assembled from adjacent literals on purpose:
the checker must not flag its own policy definition.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys
from collections.abc import Iterable


FORBIDDEN_PATTERNS = (
    re.compile(r"z\s*code", re.IGNORECASE),
    re.compile(r"mi\s*mo", re.IGNORECASE),
    re.compile(r"deep\s*seek", re.IGNORECASE),
    re.compile(r"glm\s*[- ]?\s*5", re.IGNORECASE),
)


def tracked_paths(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return [root / relative for relative in result.stdout.decode().split("\0") if relative]


def find_references(paths: Iterable[Path]) -> list[tuple[Path, int]]:
    references: list[tuple[Path, int]] = []
    for path in paths:
        try:
            data = path.read_bytes()
            if b"\0" in data:
                continue
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            if any(pattern.search(line) for pattern in FORBIDDEN_PATTERNS):
                references.append((path, line_number))
    return references


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the checkout containing this script)",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    references = find_references(tracked_paths(root))
    if references:
        print("external model workflow guard failed:", file=sys.stderr)
        for path, line_number in references:
            print(f"  {path.relative_to(root)}:{line_number}", file=sys.stderr)
        return 1
    print("External model workflow guard passed.")
    print("中文：外部模型工作流防回归检查通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
