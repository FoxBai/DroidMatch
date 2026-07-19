#!/usr/bin/env python3
"""Fail-closed tests for the executable maintainer ownership contract."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CHECKER = Path("tools/check-maintainer-contract.py")
CASES = (
    (
        Path("mac/Sources/DroidMatchCore/AsyncTransferSchedulerCompletionPolicy.swift"),
        "case interrupted(AsyncTransferJobOutcome)",
    ),
    (
        Path("mac/Sources/DroidMatchCore/AsyncTransferSchedulerExecutionPolicy.swift"),
        "record.rateSampleGeneration == generation",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/DirectoryBrowserMutationRunner.swift"),
        "guard activeOperationID == nil else { return nil }",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/DirectoryBrowserSelectionState.swift"),
        "selectedPaths.formIntersection",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/DirectoryBrowserThumbnailState.swift"),
        "activeKeys.remove(key)",
    ),
    (
        Path("mac/Sources/DroidMatchAppSupport/ProductFileBrowserTransferPolicy.swift"),
        ".widthInsensitive",
    ),
    (
        Path("mac/Sources/DroidMatchCore/PrivateAtomicFileWriterInternals.swift"),
        "static func rollbackPublication(",
    ),
    (
        Path("mac/Sources/DroidMatchCore/AtomicDownloadWriter.swift"),
        "AtomicDownloadPartialFile.open(",
    ),
    (
        Path("mac/Sources/DroidMatchCore/AtomicDownloadPartialFile.swift"),
        "droidMatchPartialFileFlock(descriptor, LOCK_EX | LOCK_NB)",
    ),
    (
        Path(".github/workflows/m0.yml"),
        'sdkmanager "platforms;android-36" "build-tools;36.0.0"',
    ),
    (
        Path("android/app/build.gradle"),
        "compileSdk = 36",
    ),
    (
        Path("android/gradle/wrapper/gradle-wrapper.properties"),
        "distributionSha256Sum=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854",
    ),
    (
        Path("mac/Sources/DroidMatchApp/DeviceDashboardView.swift"),
        '.accessibilityLabel(Text("\\(value), \\(label)"))',
    ),
    (
        Path("mac/Sources/DroidMatchApp/FileBrowserItemViews.swift"),
        ".accessibilityLabel(AppStrings.upload)",
    ),
    (
        Path("mac/Sources/DroidMatchApp/MediaGridCard.swift"),
        "return isSelected ? AppStrings.selected : AppStrings.notSelected",
    ),
    (
        Path("mac/Sources/DroidMatchApp/ProductFileBrowserToolbar.swift"),
        "state.sortField == field ? AppStrings.selected : AppStrings.notSelected",
    ),
    (
        Path("mac/Sources/DroidMatchApp/ProductTransferQueueView.swift"),
        ".accessibilityLabel(item.kind == .download ? AppStrings.download : AppStrings.upload)",
    ),
    (
        Path("mac/Sources/DroidMatchApp/AppShellView.swift"),
        ".accessibilityHidden(true)",
    ),
    (
        Path("mac/Sources/DroidMatchApp/AppStrings.swift"),
        'value("Connect and authenticate a device to browse and manage its files.")',
    ),
    (
        Path("tools/swift-build-compat.sh"),
        '--triple "${droidmatch_swift_probe_target}"',
    ),
    (
        Path("tools/build-mac-icon.sh"),
        'iconutil -c iconset "${output_path}"',
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/DirectoryBrowserPresentationTypes.swift"),
        "public var canBrowse: Bool",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/DirectoryBrowserModel.swift"),
        "guard entry.canBrowse, let query else { return false }",
    ),
    (
        Path("mac/Sources/DroidMatchApp/ProductFileBrowserContent.swift"),
        "else if state.allowsUpload && entry.canAcceptUpload",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/TrustedDevicesModel.swift"),
        "guard canRefresh, loadTask == nil else { return false }",
    ),
    (
        Path("mac/Sources/DroidMatchApp/DeviceDashboardView.swift"),
        "if trustedDevicesModel.isRefreshOutstanding {",
    ),
    (
        Path("mac/Sources/DroidMatchCore/ProductDisplayText.swift"),
        "case .control, .format, .surrogate:",
    ),
    (
        Path("mac/Sources/DroidMatchCore/ProductDisplayText.swift"),
        "if wasTruncated, maximumScalars > 1 {",
    ),
    (
        Path("mac/Sources/DroidMatchCore/ProductMimeType.swift"),
        "public static let maximumUTF8Length = 127",
    ),
    (
        Path("mac/Sources/DroidMatchCore/DirectoryListing.swift"),
        "canonicalMimeType?.hasPrefix(\"video/\") == true",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMimeTypes.java"),
        "isRestrictedName(canonical, 0, slash)",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/DeviceSessionModel.swift"),
        "pairingPresentation = DevicePairingPresentation(presentation)",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/TransferQueuePresentationItem.swift"),
        "return ProductDisplayText.value(name)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java"),
        "mediaPermissionController.manageAccess(mediaSettingsRecommended)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java"),
        "outState.putBoolean(STATE_MEDIA_SETTINGS_RECOMMENDED",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "actions.manageMediaAccess()",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "void showMediaAccessDetails(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java"),
        "ProductReadiness.countsState(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "actions.refreshPairedDevices()",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "ProductDisplayName.name(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java"),
        "ProductDisplayName.name(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProductReadiness.java"),
        "static CountsState countsState(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProductDisplayName.java"),
        "type == Character.FORMAT",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProductDisplayName.java"),
        "visible.appendCodePoint(ELLIPSIS_CODE_POINT)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProductDisplayName.java"),
        "Math.min(normalized.length(),",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java"),
        "screen.setTextIfChanged(screen.pairingCountdown, countdown)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "pairingCountdown.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "WindowInsets.Type.systemBars()",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/PairingAccessibilityPolicy.java"),
        "static String spokenDigits(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/PairingApprovalController.java"),
        "ProductDisplayName.deviceName(clientDisplayName)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/PairedDeviceManager.java"),
        "ProductDisplayName.deviceName(displayName)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/MediaPermissionController.java"),
        "activity.requestPermissions(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/MediaPermissionController.java"),
        "MediaPermissionPolicy.permissionCallbackComplete(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/MediaPermissionPolicy.java"),
        "static final String READ_MEDIA_VISUAL_USER_SELECTED =",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderDirectoryListings.java"),
        "return mediaCatalog.canReadMedia(RootKind.MEDIA_IMAGES);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "if (!mediaCatalog.canUploadMedia(media.rootKind))",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java"),
        "private final AndroidSafUploadOpener uploadOpener;",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java"),
        "return ProviderAuthorizedTransfers.upload(writer, authorization);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        "truncateSafUploadPartial(documentUri, offsetBytes);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        "ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/SafUploadOpenPolicy.java"),
        "partialDocument.sizeBytes < offsetBytes",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderAuthorizedTransfers.java"),
        "authorization.requireAuthorized();",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java"),
        "commitAuthorization.requireAuthorized();",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidMediaCatalog.java"),
        "() -> isMediaItemVisible(uri)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/PermissionStateProvider.java"),
        "MediaReadAccess publicMediaReadAccess(DmFileProvider.RootKind rootKind)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderIoCleanup.java"),
        "catch (IOException | RuntimeException ignored)",
    ),
)
FORBIDDEN_CASES = (
    (
        Path("mac/Sources/DroidMatchApp/AppStrings.swift"),
        "\n// Session diagnostics are not connected yet\n",
    ),
    (
        Path("tools/build-mac-app.sh"),
        "\n# iconutil -c icns\n",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/TransferQueuePresentationItem.swift"),
        "\npublic let remotePath: String?\n",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "\n// pairingStatus.announceForAccessibility(\"status\");\n",
    ),
)


def copy_repository(destination: Path) -> None:
    ignored = shutil.ignore_patterns(
        ".git",
        ".gradle",
        ".swiftpm",
        ".build",
        "build",
        "DerivedData",
    )
    shutil.copytree(ROOT, destination, ignore=ignored)


def run_checker(repository: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(CHECKER)],
        cwd=repository,
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="droidmatch-maintainer-contract-") as temporary:
        repository = Path(temporary) / "repository"
        copy_repository(repository)

        baseline = run_checker(repository)
        if baseline.returncode != 0:
            raise AssertionError(f"baseline checker failed: {baseline.stderr}")

        for relative_path, required_fragment in CASES:
            source = repository / relative_path
            original = source.read_text(encoding="utf-8")
            if required_fragment not in original:
                raise AssertionError(
                    f"test fixture is missing guarded fragment: {relative_path} / {required_fragment}"
                )
            source.write_text(
                original.replace(required_fragment, "guarded fragment removed", 1),
                encoding="utf-8",
            )
            rejected = run_checker(repository)
            source.write_text(original, encoding="utf-8")
            if rejected.returncode == 0:
                raise AssertionError(
                    f"checker accepted missing ownership seam: {relative_path} / {required_fragment}"
                )
            if "current capability wiring" not in rejected.stderr:
                raise AssertionError(f"unexpected rejection for {relative_path}: {rejected.stderr}")

        for relative_path, forbidden_fragment in FORBIDDEN_CASES:
            source = repository / relative_path
            original = source.read_text(encoding="utf-8")
            source.write_text(original + forbidden_fragment, encoding="utf-8")
            rejected = run_checker(repository)
            source.write_text(original, encoding="utf-8")
            if rejected.returncode == 0:
                raise AssertionError(
                    f"checker accepted forbidden ownership seam: "
                    f"{relative_path} / {forbidden_fragment.strip()}"
                )
            if "forbidden current capability wiring" not in rejected.stderr:
                raise AssertionError(f"unexpected rejection for {relative_path}: {rejected.stderr}")

    print("maintainer contract fail-closed tests passed.")
    print("中文：维护者契约 fail-closed 测试通过。")


if __name__ == "__main__":
    main()
