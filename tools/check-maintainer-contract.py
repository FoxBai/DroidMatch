#!/usr/bin/env python3
"""Guard durable takeover docs and prevent deleted sync networking from returning."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNBOOK = ROOT / "docs" / "maintainer-runbook.md"
REQUIRED_RUNBOOK_TEXT = (
    "Establish the current truth",
    "Ownership map",
    "Physical-device safety",
    "Incident triage",
    "Release readiness",
    "Handoff checklist",
    "bash tools/check-m1-skeleton.sh",
)
FORBIDDEN_PRODUCTION_NAMES = (
    "FramedTcpClient.swift",
    "RpcControlClient.swift",
)


def fail(message: str) -> None:
    print(f"maintainer contract failed: {message}", file=sys.stderr)
    raise SystemExit(1)


if not RUNBOOK.is_file():
    fail("docs/maintainer-runbook.md is missing")

runbook = RUNBOOK.read_text(encoding="utf-8")
for required in REQUIRED_RUNBOOK_TEXT:
    if required not in runbook:
        fail(f"runbook is missing required section/text: {required}")

core = ROOT / "mac" / "Sources" / "DroidMatchCore"
for name in FORBIDDEN_PRODUCTION_NAMES:
    if (core / name).exists():
        fail(f"deleted synchronous networking source returned: {name}")

print("Maintainer contract check passed.")
print("中文：维护者交接契约与异步网络边界检查通过。")
