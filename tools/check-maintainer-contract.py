#!/usr/bin/env python3
"""Guard takeover contracts, capability wiring, and async resource boundaries."""

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
ASYNC_TCP_SESSION = ROOT / "mac" / "Sources" / "DroidMatchCore" / "AsyncFramedTcpSession.swift"
TRANSPORT_ERROR = ROOT / "mac" / "Sources" / "DroidMatchCore" / "TransportError.swift"
ANDROID_DIAGNOSTICS_REPORTER = (
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "DiagnosticsReporter.java"
)
ANDROID_PROVIDER_ERROR_POLICY = {
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "ProviderDirectoryListings.java":
        'return error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown DroidMatch provider path");',
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "ProviderTransfers.java":
        'throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown DroidMatch provider path");',
}
ANDROID_PROVIDER_LISTING_ERROR_POLICY = {
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "ProviderMediaListings.java": (
        'ProviderErrorLabels.listing(exception.code, "media")',
    ),
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "ProviderDirectoryListings.java": (
        'ProviderErrorLabels.listing(exception.code, "app sandbox")',
        'ProviderErrorLabels.listing(exception.code, "SAF")',
    ),
}
ANDROID_PROVIDER_RESPONSE_ERROR_POLICY = {
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "ProviderMutations.java": "ProviderErrorLabels.mutation(",
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "ProviderThumbnails.java": "ProviderErrorLabels.thumbnail(",
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "ProviderTransfers.java": "ProviderErrorLabels.transfer(",
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "RpcTransferHandler.java": "ProviderErrorLabels.transfer(",
}
ANDROID_LOG_SOURCES = (
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "AdbEndpoint.java",
    ROOT / "android" / "app" / "src" / "main" / "java" / "app" / "droidmatch" / "m1"
    / "RpcDispatcher.java",
)
REQUIRED_PRODUCT_WIRING = {
    "mac/Sources/DroidMatchApp/DroidMatchDesktopApp.swift": (
        "transferPersistenceDirectoryURL: transferPersistenceDirectory",
        "BookmarkingTransferQueueFactory",
        "localFileAccessProviderFactory",
        "transferQueueDataSource",
    ),
    "mac/Sources/DroidMatchApp/ProductTransferQueueView.swift": (
        "queuePersistenceFailed",
        "case .interrupted",
    ),
    "mac/Sources/DroidMatchCore/ProductDeviceSessionCoordinator.swift": (
        "suspendForSessionEnd()",
    ),
    "mac/Sources/DroidMatchCore/LocalFileAccessOwnerID.swift": (
        "@_spi(DroidMatchAppSupport)",
        "CustomDebugStringConvertible",
        "CustomReflectable",
        "<redacted-local-file-access-owner>",
    ),
}
REQUIRED_CURRENT_CAPABILITY_WIRING = {
    "mac/Sources/DroidMatchCore/ProductDeviceSessionCoordinator.swift": (
        "let info = try await authenticate(",
        "authenticationState == .authenticated",
    ),
    "android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java": (
        "public void enableSecureConnection()",
        "pairingApprovals.openWindow(PairingApprovalController.DEFAULT_WINDOW_MILLIS)",
        "PairedDeviceManager",
    ),
    "mac/Sources/DroidMatchCore/AsyncUploadCoordinator.swift": (
        'destinationPath.hasPrefix("dm://saf-")',
        "automatic resume is limited to app-sandbox and SAF providers.",
    ),
    "android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java": (
        "private final AndroidSafUploadOpener uploadOpener;",
        "return uploadOpener.open(",
    ),
    "android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java": (
        "SafUploadOpenPolicy.mode(transferId, offsetBytes)",
        "SafUploadOpenPolicy.requiresTruncation(",
        "truncateSafUploadPartial(documentUri, offsetBytes);",
        "ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);",
        '"SAF provider cannot reconcile the upload partial"',
    ),
    "android/app/src/main/java/app/droidmatch/m1/SafUploadOpenPolicy.java": (
        "partialDocument.kind != FileKind.FILE_KIND_FILE",
        "partialDocument.sizeBytes < offsetBytes",
        "partialDocument.sizeBytes > offsetBytes",
    ),
    "mac/Sources/DroidMatchCore/DirectoryMutation.swift": (
        "Droidmatch_V1_DeletePathRequest()",
    ),
    "android/app/src/main/java/app/droidmatch/m1/RpcControlHandler.java": (
        "DeletePathRequest.parseFrom",
        "fileProvider.deletePath",
    ),
}
REQUIRED_CURRENT_CAPABILITY_COUNTS = {
    "android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java": {
        "ProviderIoCleanup.closeQuietly(outputStream);": 4,
        "ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);": 4,
    },
}


def fail(message: str) -> None:
    print(f"maintainer contract failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_android_diagnostics_policy() -> None:
    """Keep Android diagnostics type-only after the privacy boundary fix.

    A future redaction regex cannot prove that unknown provider text is safe.
    This executable guard keeps `Throwable` messages out of the diagnostics
    ring and requires the stable operation-code/class shape tested by M1.
    中文：禁止异常原文回流 Android diagnostics，防止未知 provider 文本泄露。
    """
    if not ANDROID_DIAGNOSTICS_REPORTER.is_file():
        fail("Android DiagnosticsReporter.java is missing")
    source = ANDROID_DIAGNOSTICS_REPORTER.read_text(encoding="utf-8")
    for forbidden in (".getMessage()", "getLocalizedMessage()", "redact("):
        if forbidden in source:
            fail(
                "Android diagnostics must not retain raw Throwable text or a "
                f"regex redactor: {forbidden}"
            )
    required = (
        'String exceptionType = throwable == null',
        'code + ":" + exceptionType',
        'addEventLocked("error", code + ":" + exceptionType, null)',
    )
    for fragment in required:
        if fragment not in source:
            fail(f"Android diagnostics policy is missing required boundary: {fragment}")


def check_android_provider_error_policy() -> None:
    """Keep caller-controlled provider paths out of protocol error labels.

    The path may contain a personal file name, an absolute host path, or an
    accidentally supplied content URI. Require the bounded labels at both
    provider exits so a future refactor cannot reintroduce path echoing.
    中文：provider 错误不得回显调用方路径，防止文件名和 URI 泄露。
    """
    for source_path, required in ANDROID_PROVIDER_ERROR_POLICY.items():
        if not source_path.is_file():
            fail(f"Android provider error source is missing: {source_path.relative_to(ROOT)}")
        source = source_path.read_text(encoding="utf-8")
        if "unknown DroidMatch provider path:" in source:
            fail(
                "Android provider error must not echo a caller path: "
                f"{source_path.relative_to(ROOT)}"
            )
        if required not in source:
            fail(
                "Android provider error policy is missing bounded label: "
                f"{source_path.relative_to(ROOT)}"
            )


def check_android_provider_listing_error_policy() -> None:
    """Keep catalog exception messages out of directory wire responses.

    Provider implementations may use detailed local messages, but directory
    assembly must use fixed provider-owned labels before crossing the protocol
    boundary. 中文：目录响应不得透传 provider 异常原文。
    """
    for source_path, required_fragments in ANDROID_PROVIDER_LISTING_ERROR_POLICY.items():
        if not source_path.is_file():
            fail(f"Android provider listing source is missing: {source_path.relative_to(ROOT)}")
        source = source_path.read_text(encoding="utf-8")
        if "exception.getMessage()" in source:
            fail(
                "Android provider listing must not echo catalog exception text: "
                f"{source_path.relative_to(ROOT)}"
            )
        for fragment in required_fragments:
            if fragment not in source:
                fail(
                    "Android provider listing policy is missing bounded label: "
                    f"{source_path.relative_to(ROOT)} / {fragment}"
                )


def check_android_provider_response_error_policy() -> None:
    """Keep provider mutation, thumbnail, and transfer details off the wire.

    These responses may carry platform paths, content URIs, document IDs, or
    private file names when a provider fails. Only fixed operation labels may
    cross the RPC boundary. 中文：provider mutation、缩略图和传输错误不得透传异常原文。
    """
    forbidden = ("exception.getMessage()", ".getError().getMessage()", "target.error.getMessage()")
    for source_path, required_fragment in ANDROID_PROVIDER_RESPONSE_ERROR_POLICY.items():
        if not source_path.is_file():
            fail(f"Android provider response source is missing: {source_path.relative_to(ROOT)}")
        source = source_path.read_text(encoding="utf-8")
        for fragment in forbidden:
            if fragment in source:
                fail(
                    "Android provider response must not echo catalog details: "
                    f"{source_path.relative_to(ROOT)} / {fragment}"
                )
        if required_fragment not in source:
            fail(
                "Android provider response policy is missing bounded labels: "
                f"{source_path.relative_to(ROOT)} / {required_fragment}"
            )


def check_android_log_privacy_policy() -> None:
    """Keep warning/error Logcat calls on the bounded exception-label path.

    ``Throwable`` messages can contain provider paths, content URIs, or file
    names.  A future endpoint/RPC catch must therefore use the type-only
    ``AndroidLogLabel.error`` helper (or the endpoint's equivalent wrapper),
    rather than passing an exception directly to Logcat.  中文：Logcat 的
    warning/error 必须走有界异常类型标签，禁止透传异常原文。
    """
    log_call = re.compile(
        r"android\.util\.Log\.(?:e|w)\s*\((.*?)\)\s*;",
        flags=re.DOTALL,
    )
    for source_path in ANDROID_LOG_SOURCES:
        if not source_path.is_file():
            fail(f"Android Logcat source is missing: {source_path.relative_to(ROOT)}")
        source = source_path.read_text(encoding="utf-8")
        calls = list(log_call.finditer(source))
        if not calls:
            fail(
                "Android Logcat privacy policy found no guarded warning/error call: "
                f"{source_path.relative_to(ROOT)}"
            )
        for call in calls:
            body = call.group(1)
            if "AndroidLogLabel.error(" not in body and "safeErrorLabel(" not in body:
                fail(
                    "Android warning/error Logcat calls must use bounded labels: "
                    f"{source_path.relative_to(ROOT)}"
                )


check_android_diagnostics_policy()
check_android_provider_error_policy()
check_android_provider_listing_error_policy()
check_android_provider_response_error_policy()
check_android_log_privacy_policy()


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

for target in ("DroidMatchPresentation", "DroidMatchApp"):
    for source in (ROOT / "mac" / "Sources" / target).rglob("*.swift"):
        if "@_spi(DroidMatchAppSupport)" in source.read_text(encoding="utf-8"):
            fail(
                "bookmark-owner SPI escaped AppSupport into "
                f"{source.relative_to(ROOT)}"
            )

network_importers = [
    source.relative_to(ROOT).as_posix()
    for source in swift_sources
    if "import Network" in source.read_text(encoding="utf-8")
]
if network_importers != ["mac/Sources/DroidMatchCore/AsyncFramedTcpSession.swift"]:
    fail(f"Network.framework ownership changed unexpectedly: {network_importers}")

# Network.framework controls its localized failure text. Keep that text below
# the transport error boundary so endpoint details cannot reach harness output,
# retry diagnostics, or future product presentation through a stable error.
async_session_text = ASYNC_TCP_SESSION.read_text(encoding="utf-8")
if ".localizedDescription" in async_session_text:
    fail("AsyncFramedTcpSession must not publish Network.framework localizedDescription")
if "FramedTcpClientError.connectionFailed(error" in async_session_text:
    fail("AsyncFramedTcpSession must use a bounded transport failure label")
transport_error_text = TRANSPORT_ERROR.read_text(encoding="utf-8")
if "connection failed: \\(message)" in transport_error_text:
    fail("FramedTcpClientError must not interpolate raw connection-failure text")

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

# Bind the highest-risk live capability claims to concrete implementation seams.
# This is deliberately selective: it prevents a green link/format gate from
# preserving known-false SAF resume, product-auth, or delete statements without
# pretending that literal matching can prove every sentence in the repository.
# 中文：把高风险当前事实绑定到实现接缝；该门禁是有意选择性的，不声称理解全部文档语义。
for relative_path, required_fragments in REQUIRED_CURRENT_CAPABILITY_WIRING.items():
    source = ROOT / relative_path
    if not source.is_file():
        fail(f"required current-capability source is missing: {relative_path}")
    source_text = source.read_text(encoding="utf-8")
    for fragment in required_fragments:
        if fragment not in source_text:
            fail(f"{relative_path} is missing current capability wiring: {fragment}")

for relative_path, required_counts in REQUIRED_CURRENT_CAPABILITY_COUNTS.items():
    source = ROOT / relative_path
    if not source.is_file():
        fail(f"required current-capability source is missing: {relative_path}")
    source_text = source.read_text(encoding="utf-8")
    for fragment, expected_count in required_counts.items():
        actual_count = source_text.count(fragment)
        if actual_count != expected_count:
            fail(
                f"{relative_path} has current capability wiring count "
                f"{actual_count}, expected {expected_count}: {fragment}"
            )

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
