#!/usr/bin/env python3
"""Guard takeover docs, product wiring truth, and async resource boundaries."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNBOOK = ROOT / "docs" / "maintainer-runbook.md"
CONTRIBUTING = ROOT / "CONTRIBUTING.md"
AGENT_GUIDE = ROOT / "AGENTS.md"
PULL_REQUEST_TEMPLATE = ROOT / ".github" / "pull_request_template.md"
GITHUB_GOVERNANCE = ROOT / "docs" / "github-governance.md"
TECHNICAL_DEBT = ROOT / "docs" / "technical-debt.md"
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
REQUIRED_GOVERNANCE_TEXT = (
    "Current observed state",
    "Phase A: safe single-owner baseline",
    "Phase B: second-maintainer baseline",
    "gh api repos/FoxBai/DroidMatch/branches/main/protection",
    "disallow bypass, force-push, and deletion",
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
    "docs/m1-status-zh.md",
    "docs/m1-testing-guide.md",
    "docs/m1-testing-guide-zh.md",
    "docs/developer-onboarding.md",
    "docs/developer-onboarding-zh.md",
    "docs/mac-code-overview.md",
    "docs/android-code-overview.md",
    "docs/protocol-runtime.md",
    "docs/technical-debt.md",
    "docs/pairing-auth-design.md",
)
FORBIDDEN_STALE_CLAIMS = (
    "A future app/harness still needs to supply its owned storage URL",
    "Integrate the persistent queue into the app target",
    "synchronous transfer evidence probes and concentrated ownership remain",
    "UI transfer-queue integration remain open",
    "把 Presentation model 装配进现有视觉 app target",
    "Physical-device product-auth/transfer/revocation and sandbox file-transfer evidence",
    "sandbox file-transfer evidence, and physical product-auth/transfer evidence remain",
    "仍缺产品认证/传输与 sandbox 文件传输证据",
    "USB unplug during upload/download",
    "上传/下载期间 USB 拔插",
    "sandbox 产品传输与产品上传证据",
    "Run and archive `--dual-download-check` on the required device slots",
    "在所需设备槽位运行并归档 `--dual-download-check`",
    "把持久化队列装配进 app target（M1 后）",
    "真机配对/重连证据仍待归档",
    "sandbox 文件传输仍待验证",
    "尚未完成的是 sandbox 产品认证/文件传输与混合流真机证据",
    "but no archived physical-device result yet",
    "product-auth evidence remain open",
    "新增认证 App 配对/重连/下载路径的归档真机证据",
    "Keystore 真机证据仍待归档",
    "No device pass is claimed yet",
    "Flyme currently rejects its test APK",
    "尚未声称真机通过",
    "Flyme 当前以 `INSTALL_FAILED_USER_RESTRICTED` 拒绝测试 APK",
    "Real-device Keychain/Keystore/reconnect evidence remains open",
    "Sandbox file transfer, archived product-auth/transfer",
    "Archived physical dual/mixed evidence",
    "尚缺归档双流/混合流真机证据",
    "M1 still requires archived product-auth/file-transfer evidence",
    "发布声明前仍需归档产品认证/文件传输证据",
    "仍缺归档真机 App 配对/重连/传输与 sandbox 文件访问证据",
    "❌ **缺失：** 下载期间物理拔线",
    "记录 MEIZU M20 Slot C 下载期间的物理 USB 拔线",
    "未来 app/harness 仍需提供自己拥有的存储 URL",
    "Product authentication/transfers and mixed-stream behavior still lack archived physical-device App evidence",
    "A sandbox-entitled bundle still needs end-to-end verification",
    "216 Swift tests",
    "218 Swift tests",
    "220 Swift tests",
    "221 Swift tests",
    "222 Swift tests",
    "129 Android unit tests",
    "scheduler actor is now 774 lines",
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
    (GITHUB_GOVERNANCE, REQUIRED_GOVERNANCE_TEXT),
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

# Keep the takeover baseline tied to the executable test inventory. Counting
# annotations is intentionally language-agnostic for the current Swift Testing
# and JUnit suites; generated/build trees are outside these source roots.
technical_debt = TECHNICAL_DEBT.read_text(encoding="utf-8")
inventory_match = re.search(
    r"<!-- test-inventory swift=(\d+) android-unit=(\d+) -->",
    technical_debt,
)
if inventory_match is None:
    fail("docs/technical-debt.md is missing the test-inventory marker")


def count_test_annotations(root: Path, suffixes: tuple[str, ...]) -> int:
    count = 0
    for suffix in suffixes:
        for source in root.rglob(f"*{suffix}"):
            text = source.read_text(encoding="utf-8")
            count += len(re.findall(r"(?m)^\s*@Test(?:\s|\()", text))
    return count


actual_swift_tests = count_test_annotations(ROOT / "mac" / "Tests", (".swift",))
actual_android_tests = count_test_annotations(
    ROOT / "android" / "app" / "src" / "test",
    (".java", ".kt"),
)
documented_swift_tests = int(inventory_match.group(1))
documented_android_tests = int(inventory_match.group(2))
if (documented_swift_tests, documented_android_tests) != (
    actual_swift_tests,
    actual_android_tests,
):
    fail(
        "test inventory drifted: docs say "
        f"swift={documented_swift_tests} android-unit={documented_android_tests}, "
        f"sources contain swift={actual_swift_tests} android-unit={actual_android_tests}"
    )
for expected_text in (
    f"{actual_swift_tests} Swift tests",
    f"{actual_android_tests} Android unit tests/lint",
):
    if expected_text not in technical_debt:
        fail(f"docs/technical-debt.md is missing test inventory text: {expected_text}")

print("Maintainer contract check passed.")
print("中文：维护者交接契约与异步网络边界检查通过。")
