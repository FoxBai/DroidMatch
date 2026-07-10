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
ALLOWED_SEMAPHORE_FILE = (
    ROOT / "mac" / "Sources" / "DroidMatchCore" / "ProcessRunner.swift"
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

swift_sources = list((ROOT / "mac" / "Sources").rglob("*.swift"))
for source in swift_sources:
    text = source.read_text(encoding="utf-8")
    if "DispatchSemaphore" in text and source != ALLOWED_SEMAPHORE_FILE:
        fail(f"blocking semaphore escaped the subprocess boundary: {source.relative_to(ROOT)}")
    if "Task.detached" in text:
        fail(f"detached-task blocking workaround is forbidden: {source.relative_to(ROOT)}")

network_importers = [
    source.relative_to(ROOT).as_posix()
    for source in swift_sources
    if "import Network" in source.read_text(encoding="utf-8")
]
if network_importers != ["mac/Sources/DroidMatchCore/AsyncFramedTcpSession.swift"]:
    fail(f"Network.framework ownership changed unexpectedly: {network_importers}")

print("Maintainer contract check passed.")
print("中文：维护者交接契约与异步网络边界检查通过。")
