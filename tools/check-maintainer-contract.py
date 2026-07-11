#!/usr/bin/env python3
"""Guard takeover docs, product wiring truth, and async resource boundaries."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNBOOK = ROOT / "docs" / "maintainer-runbook.md"
CONTRIBUTING = ROOT / "CONTRIBUTING.md"
AGENT_GUIDE = ROOT / "AGENTS.md"
PULL_REQUEST_TEMPLATE = ROOT / ".github" / "pull_request_template.md"
REQUIRED_RUNBOOK_TEXT = (
    "Establish the current truth",
    "Ownership map",
    "Physical-device safety",
    "Incident triage",
    "Release readiness",
    "Handoff checklist",
    "bash tools/check-m1-skeleton.sh",
)
REQUIRED_CONTRIBUTING_TEXT = (
    "Change contract",
    "Required verification",
    "Pull-request handoff",
    "One writer owns a file set at a time",
    "adb devices -l",
)
REQUIRED_PULL_REQUEST_TEXT = (
    "Ownership and invariants",
    "Evidence",
    "Unverified and risky",
    "Next concrete action",
)
FORBIDDEN_PRODUCTION_NAMES = (
    "FramedTcpClient.swift",
    "RpcControlClient.swift",
)
ALLOWED_SEMAPHORE_FILE = (
    ROOT / "mac" / "Sources" / "DroidMatchCore" / "ProcessRunner.swift"
)
REQUIRED_PRODUCT_WIRING = {
    "mac/Sources/DroidMatchApp/DroidMatchDesktopApp.swift": (
        "transferPersistenceDirectoryURL: transferPersistenceDirectory",
        "BookmarkingTransferQueueDataSource",
    ),
    "mac/Sources/DroidMatchApp/ProductTransferQueueView.swift": (
        "queuePersistenceFailed",
        "case .interrupted",
    ),
    "mac/Sources/DroidMatchCore/ProductDeviceSessionCoordinator.swift": (
        "suspendForSessionEnd()",
    ),
}
LIVE_DOCS = (
    "README.md",
    "mac/README.md",
    "docs/m1-status.md",
    "docs/protocol-runtime.md",
    "docs/technical-debt.md",
)
FORBIDDEN_STALE_CLAIMS = (
    "A future app/harness still needs to supply its owned storage URL",
    "Integrate the persistent queue into the app target",
    "synchronous transfer evidence probes and concentrated ownership remain",
    "UI transfer-queue integration remain open",
    "把 Presentation model 装配进现有视觉 app target",
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

for path, required_text in (
    (CONTRIBUTING, REQUIRED_CONTRIBUTING_TEXT),
    (PULL_REQUEST_TEMPLATE, REQUIRED_PULL_REQUEST_TEXT),
):
    if not path.is_file():
        fail(f"{path.relative_to(ROOT)} is missing")
    content = path.read_text(encoding="utf-8")
    for required in required_text:
        if required not in content:
            fail(f"{path.relative_to(ROOT)} is missing required text: {required}")

agent_guide = AGENT_GUIDE.read_text(encoding="utf-8")
if "800-line ceiling" not in agent_guide or "850-line ceiling" in agent_guide:
    fail("AGENTS.md source-size contract is not synchronized to 800 lines")

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

# These checks intentionally bind documentation claims to concrete product
# composition points. They prevent an already-wired queue from being described
# as future work, and also catch accidental removal of its persistence/lifecycle
# boundaries before a broad end-to-end test happens to notice.
for relative_path, required_fragments in REQUIRED_PRODUCT_WIRING.items():
    source = ROOT / relative_path
    if not source.is_file():
        fail(f"required product wiring file is missing: {relative_path}")
    source_text = source.read_text(encoding="utf-8")
    for fragment in required_fragments:
        if fragment not in source_text:
            fail(f"{relative_path} is missing product wiring: {fragment}")

for relative_path in LIVE_DOCS:
    doc_text = (ROOT / relative_path).read_text(encoding="utf-8")
    for stale_claim in FORBIDDEN_STALE_CLAIMS:
        if stale_claim in doc_text:
            fail(f"{relative_path} contains stale product claim: {stale_claim}")

print("Maintainer contract check passed.")
print("中文：维护者交接契约与异步网络边界检查通过。")
