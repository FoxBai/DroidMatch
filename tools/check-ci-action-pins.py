#!/usr/bin/env python3
"""Require immutable commits for every remote GitHub Actions dependency."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
USES = re.compile(r"^\s*-\s+uses:\s*([^\s#]+)(?:\s+#\s*(\S.*))?$")
SHA = re.compile(r"[0-9a-f]{40}")


def fail(message: str) -> None:
    print(f"CI action pin check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


found = 0
for workflow in sorted(WORKFLOWS.glob("*.y*ml")):
    for line_number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
        match = USES.match(line)
        if match is None:
            continue
        found += 1
        action, comment = match.groups()
        if action.startswith("./") or action.startswith("docker://"):
            continue
        if "@" not in action:
            fail(f"{workflow.name}:{line_number} has no ref: {action}")
        name, ref = action.rsplit("@", 1)
        if name.count("/") < 1 or SHA.fullmatch(ref) is None:
            fail(f"{workflow.name}:{line_number} must use a full commit SHA: {action}")
        if comment is None or re.match(r"v\d", comment) is None:
            fail(f"{workflow.name}:{line_number} needs a readable version comment")

if found == 0:
    fail("no workflow actions were found")

print(f"CI action pin check passed: {found} immutable references.")
print("中文：GitHub Actions 完整 commit SHA 固定检查通过。")
