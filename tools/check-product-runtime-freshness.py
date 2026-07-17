#!/usr/bin/env python3
"""Fail closed when stale-runtime product safety wiring is weakened."""

from __future__ import annotations

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
PUBLICATION_GUARD_CALL = (
    'python3 "${repo_root}/tools/check-mac-app-not-running.py" "${output_path}"'
)

REQUIRED_SNIPPETS = {
    "tools/check-mac-app-not-running.py": (
        'DELETED_SUFFIX = " (deleted)"',
        'argument_path = os.path.join(os.readlink(entry / "cwd"), argument_path)',
        'library.proc_pidpath',
        'mib = (ctypes.c_int * 3)(1, 49, pid)',
        'launch_path = argument_executable(pid)',
        'yield os.fsdecode(path_buffer.value)',
        'yield launch_path',
        'target = normalized_path(app_path / APP_EXECUTABLE)',
        'DroidMatch is still running from the publication target.',
    ),
    "tools/build-mac-app.sh": (PUBLICATION_GUARD_CALL,),
    "mac/Sources/DroidMatchAppSupport/ProductExecutableFreshnessMonitor.swift": (
        "_dyld_get_image_header(0)",
        "proc_pidinfo(",
        "PROC_PIDREGIONPATHINFO",
        "region.prp_vip.vip_vi.vi_stat",
        "device: UInt64(UInt32(truncatingIfNeeded: metadata.st_dev))",
        "device: UInt64(UInt32(truncatingIfNeeded: metadata.vst_dev))",
        "inode: metadata.vst_ino",
        "replacementDetected = originalIdentity == nil",
        "replacementDetected = Self.identity(at: executableURL) != originalIdentity",
        "guard replacementDetected, !didNotifyReplacement else { return }",
    ),
    "mac/Sources/DroidMatchAppSupport/ProductWindowActivityCoordinator.swift": (
        "private var activeWindowIDs: Set<UUID> = []",
        "guard activeWindowIDs.insert(windowID).inserted else { return }",
        "guard activeWindowIDs.remove(windowID) != nil else { return }",
        "if activeWindowIDs.isEmpty { onLastActiveWindow() }",
        "runtimeInvalidated = true",
        "activeWindowIDs.removeAll()",
    ),
    "mac/Sources/DroidMatchApp/DroidMatchDesktopApp.swift": (
        "@StateObject private var executableFreshness: ProductExecutableFreshnessMonitor",
        "@StateObject private var windowActivity: ProductWindowActivityCoordinator",
        "onFirstActiveWindow: { discoveryModel.startAutomaticRefresh() }",
        "onLastActiveWindow: { discoveryModel.stopAutomaticRefresh() }",
        "windowActivity.invalidateForRuntimeReplacement()",
        "discoveryModel.invalidateForRuntimeReplacement()",
        "trustedDevicesModel.invalidateForRuntimeReplacement()",
        "sessionModel.invalidateForRuntimeReplacement()",
        "executableFreshness.start()",
        "executableFreshness: executableFreshness",
        "windowActivity: windowActivity",
        "guard !executableFreshness.replacementDetected else { return }",
        "executableFreshness.replacementDetected\n                        || discoveryModel.phase",
    ),
    "mac/Sources/DroidMatchApp/AppShellView.swift": (
        "if executableFreshness.replacementDetected {",
        "ProductRuntimeReplacementBanner()",
        "else {\n                navigation",
        "let shouldBeActive = phase == .active && !executableFreshness.replacementDetected",
        "windowActivity.setActive(active, windowID: windowID)",
        ".onDisappear { setWindowActive(false) }",
    ),
    "mac/Sources/DroidMatchPresentation/DeviceDiscoveryModel.swift": (
        "guard !runtimeInvalidated,\n              automaticRefreshTask == nil",
        "public func refresh() {\n        guard !runtimeInvalidated else { return }",
        "public func invalidateForRuntimeReplacement()",
        "guard !runtimeInvalidated, generation == self.generation else { return }",
    ),
    "mac/Sources/DroidMatchPresentation/TrustedDevicesModel.swift": (
        "!runtimeInvalidated && !isRefreshOutstanding && !isMutating",
        "guard !runtimeInvalidated, !isMutating else { return false }",
        "public func invalidateForRuntimeReplacement()",
        "activeLoadGeneration = nil",
        "loadTask?.cancel()",
    ),
    "mac/Sources/DroidMatchPresentation/DeviceSessionModel.swift": (
        "public func connect(to deviceID: UUID) {\n        guard !runtimeInvalidated else { return }",
        "public func beginPairing() -> Bool {\n        guard !runtimeInvalidated,",
        "public func approvePairing() {\n        guard !runtimeInvalidated else { return }",
        "public func rejectPairing() {\n        guard !runtimeInvalidated else { return }",
        "public func invalidateForRuntimeReplacement()",
        "runtimeInvalidated = true\n        disconnect()",
    ),
}

FORBIDDEN_SNIPPETS = {
    "tools/build-mac-app.sh": (
        'rm -rf "${output_path}"',
        "mac/.build/app-icon",
    ),
    "mac/Sources/DroidMatchApp/AppShellView.swift": (
        "discoveryModel.startAutomaticRefresh()",
        "discoveryModel.stopAutomaticRefresh()",
    ),
    "mac/Sources/DroidMatchAppSupport/ProductExecutableFreshnessMonitor.swift": (
        "Keychain",
        "NSWorkspace.shared.open",
    ),
}


class ProductRuntimeFreshnessContractError(Exception):
    pass


def read_source(root: Path, relative_path: str) -> str:
    try:
        return (root / relative_path).read_text(encoding="utf-8")
    except OSError as error:
        raise ProductRuntimeFreshnessContractError(
            f"{relative_path} is unavailable"
        ) from error


def validate(root: Path) -> None:
    sources = {
        relative_path: read_source(root, relative_path)
        for relative_path in REQUIRED_SNIPPETS
    }
    for relative_path, snippets in REQUIRED_SNIPPETS.items():
        missing = [snippet for snippet in snippets if snippet not in sources[relative_path]]
        if missing:
            raise ProductRuntimeFreshnessContractError(
                f"{relative_path} is missing stale-runtime safety wiring: {missing}"
            )

    for relative_path, snippets in FORBIDDEN_SNIPPETS.items():
        present = [snippet for snippet in snippets if snippet in sources[relative_path]]
        if present:
            raise ProductRuntimeFreshnessContractError(
                f"{relative_path} bypasses stale-runtime ownership: {present}"
            )

    builder = sources["tools/build-mac-app.sh"]
    guard_offsets = []
    offset = 0
    while True:
        offset = builder.find(PUBLICATION_GUARD_CALL, offset)
        if offset < 0:
            break
        guard_offsets.append(offset)
        offset += len(PUBLICATION_GUARD_CALL)
    if len(guard_offsets) != 3:
        raise ProductRuntimeFreshnessContractError(
            "App publication guard must cover recovery, replacement, and first publication"
        )
    transaction_recovery = builder.find("\nif [[ -e \"${transaction_root}\"")
    replacement_state = builder.find("write_transaction_state swapping")
    replacement_swap = builder.find("  swap_exact_directories", replacement_state)
    first_state = builder.find("write_transaction_state installing-new")
    first_install = builder.find("  install_exact_directory", first_state)
    if not (
        0 <= guard_offsets[0] < transaction_recovery
        and replacement_state < guard_offsets[1] < replacement_swap
        and first_state < guard_offsets[2] < first_install
    ):
        raise ProductRuntimeFreshnessContractError(
            "App publication guard does not protect every mutation boundary"
        )


def main() -> int:
    try:
        validate(ROOT)
    except ProductRuntimeFreshnessContractError as error:
        print(f"Product runtime freshness contract failed: {error}", file=sys.stderr)
        print(f"中文：产品运行时新鲜度契约失败：{error}", file=sys.stderr)
        return 1

    print("Product runtime freshness contract passed: stale processes fail closed.")
    print("中文：产品运行时新鲜度契约通过：旧进程会安全关闭设备入口。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
