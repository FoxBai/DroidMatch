#!/usr/bin/env python3
"""Fail-closed tests for the executable maintainer ownership contract."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from maintainer_android_provider_race_test_cases import (
    ANDROID_PROVIDER_RACE_REPLACEMENT_CASES,
)


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
    (Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"), "if (!catalog.complete) {\n            pairedDevices.addView(mutedText(R.string.paired_devices_incomplete));\n            Button retry = button(R.string.paired_devices_retry);\n            retry.setOnClickListener(view -> actions.refreshPairedDevices());"),
    (Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"), "void showPairedDevicesUnavailable() {\n        pairedDevices.removeAllViews();\n        pairedDevices.addView(mutedText(R.string.paired_devices_unavailable));\n        Button retry = button(R.string.paired_devices_retry);\n        retry.setOnClickListener(view -> actions.refreshPairedDevices());"),
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
        Path("android/app/src/main/java/app/droidmatch/m1/SafUploadOpenPolicy.java"),
        "sizeBytes < offsetBytes",
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
    (Path("tools/push-main-with-gates.sh"), "Git trailer configuration is not allowed"),
    (Path("tools/push-main-with-gates.sh"), "--no-verify"),
    (Path("tools/push-main-with-gates.sh"), "core.hooksPath=/dev/null"),
    (Path("tools/push-main-with-gates.sh"), "core.fsmonitor=false"),
    (Path("tools/check-m0.sh"), "bash tools/test-push-main-git-safety.sh"),
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
ANDROID_PROVIDER_REPLACEMENT_CASES = (
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java"),
        "this.safDocumentCache = PROCESS_SAF_DOCUMENTS;",
        """this.safDocumentCache =
                new ProviderSafDocumentCache(MAX_SAF_DOCUMENT_CACHE_ENTRIES);""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java"),
        """                safDocumentCache,
                PROCESS_PROVIDER_PATHS
        );
    }

    public void discardUploadPartial""",
        """                safDocumentCache,
                new ProviderPathCoordinator()
        );
    }

    public void discardUploadPartial""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        "pathCoordinator.runLeased(",
        "runWithoutProviderCoordination(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        """pathCoordinator.runLeased(
                        ProviderPathCoordinator.Claim.appSandbox(relative),
                        () -> appSandboxCatalog.createDirectory(relative)
                );""",
        """pathCoordinator.runLeased(
                        ProviderPathCoordinator.Claim.appSandbox(relative),
                        () -> {
                        }
                );
                appSandboxCatalog.createDirectory(relative);""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "pathCoordinator.openLeased(",
        "openWithoutProviderCoordination(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "saf.rootsSnapshot,",
        "java.util.Collections.singletonList(saf.root),",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "path, safRoots, safDocumentCache",
        "path, Collections.singletonList(safRoots.get(0)), safDocumentCache",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);",
        """List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);
        safRoots = java.util.Collections.singletonList(safRoots.get(0));""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);",
        """final List<SafRoot> allSafRoots =
                ProviderSafCatalog.snapshotRoots(safCatalog);
        final List<SafRoot> safRoots = java.util.Collections.unmodifiableList(
                java.util.Collections.singletonList(allSafRoots.get(0))
        );""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "pathCoordinator.runLeased(",
        "runWithoutProviderCoordination(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderSafCatalog.java"),
        "return Collections.unmodifiableList(new ArrayList<>(catalog.roots()));",
        """List<SafRoot> roots = catalog.roots();
        return Collections.unmodifiableList(
                new ArrayList<>(Collections.singletonList(roots.get(0)))
        );""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderSafCatalog.java"),
        """    static List<SafRoot> snapshotRoots(final ProviderSafCatalog catalog) {
        return Collections.unmodifiableList(new ArrayList<>(catalog.roots()));
    }""",
        """    static List<SafRoot> snapshotRoots(ProviderSafCatalog catalog) {
        catalog = ProviderSafCatalog.empty();
        return Collections.unmodifiableList(new ArrayList<>(catalog.roots()));
    }""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        "validatePartialForCleanup(existing, expectedSizeBytes);",
        "bypassPartialValidation(existing, expectedSizeBytes);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        "|| document.sizeBytes < 0",
        "|| false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        "exception.code != ErrorCode.ERROR_CODE_NOT_FOUND",
        "true",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathCoordinator.java"),
        "authorityWideSafClaim(root, persistedRoots)",
        "false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathCoordinator.java"),
        "!safRootStableId.equals(other.safRootStableId)",
        "false",
    ),
    (
        Path(
            "android/app/src/main/java/app/droidmatch/m1/"
            "AndroidSafMutationIdentityReader.java"
        ),
        "!returnedDocumentId.equals(identity.documentId)",
        "!returnedDocumentId.equals(identity.documentId)\n                && false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        "safDocumentCache.rebindAfterRename(",
        "safDocumentCache.remember(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        "safDocumentCache.invalidateAfterDelete(",
        "safDocumentCache.remember(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderSafDocumentCache.java"),
        "return root.providerAuthority.equals(target.providerAuthority);",
        "return root.stableId.equals(target.rootStableId);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderDirectoryListings.java"),
        "safDocumentCache.rememberListingIfCurrent(",
        "safDocumentCache.remember(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderDirectoryListings.java"),
        "target.cacheEpoch",
        "safDocumentCache.resolveForListing(target.root, null).epoch",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathRouter.java"),
        "SafUploadTarget.file(root, roots, parentDocumentId, displayName)",
        "SafUploadTarget.file(root, java.util.Collections.singletonList(root), parentDocumentId, displayName)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathRouter.java"),
        "resolution.epoch",
        "new Object()",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathRouter.java"),
        """    static SafUploadTarget safUpload(
            String path,
            final List<SafRoot> roots,
            ProviderSafDocumentCache safDocumentCache
    ) {
        for (SafRoot root : roots) {""",
        """    static SafUploadTarget safUpload(
            String path,
            List<SafRoot> roots,
            ProviderSafDocumentCache safDocumentCache
    ) {
        roots = java.util.Collections.singletonList(roots.get(0));
        for (SafRoot root : roots) {""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathRouter.java"),
        """        private static SafTarget directory(
                SafRoot root,
                final List<SafRoot> rootsSnapshot,
                String documentId,
                String parentDocumentId,
                String displayName,
                FileKind kind,
                final Object cacheEpoch
        ) {
            return new SafTarget(""",
        """        private static SafTarget directory(
                SafRoot root,
                final List<SafRoot> rootsSnapshot,
                String documentId,
                String parentDocumentId,
                String displayName,
                FileKind kind,
                Object cacheEpoch
        ) {
            cacheEpoch = new Object();
            return new SafTarget(""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathRouter.java"),
        """                    cacheEpoch,
                    null""",
        """                    new Object(),
                    null""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathRouter.java"),
        "private static SafTarget directory(",
        "static SafTarget directory(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderPathRouter.java"),
        "private static SafUploadTarget file(",
        "static SafUploadTarget file(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java"),
        "    private String documentDisplayName(",
        """    void injectedUnleasedDelete(SafRoot root)
            throws ProviderCatalogException {
        deleteDocument(root, "outside-lease", false);
    }

    private String documentDisplayName(""",
    ),
)
ANDROID_PROVIDER_APPEND_CASES = (
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        """
final class InjectedDirectResolverRegression {
    void run(android.content.ContentResolver contentResolver) {
        contentResolver.query(null, null, null, null, null);
    }
}
""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        """
final class InjectedSplitProviderCoordinator {
    private final ProviderPathCoordinator coordinator =
            new ProviderPathCoordinator();
}
""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        """
final class InjectedUnleasedMutation {
    void run(ProviderAppSandboxCatalog appSandboxCatalog)
            throws DmFileProvider.ProviderCatalogException {
        appSandboxCatalog.createDirectory("outside-lease");
    }
}
""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java"),
        """
final class InjectedAliasedSafMutation {
    void run(ProviderSafCatalog safCatalog, DmFileProvider.SafRoot root)
            throws DmFileProvider.ProviderCatalogException {
        ProviderSafCatalog catalog = safCatalog;
        catalog.deleteDocument(root, "outside-lease", false);
    }
}
""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java"),
        """
final class InjectedOpaqueSafMutation {
    void run(ProviderSafCatalog safCatalog, DmFileProvider.SafRoot root)
            throws DmFileProvider.ProviderCatalogException {
        (safCatalog).deleteDocument(root, "outside-lease", false);
    }
}
""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java"),
        """
interface InjectedDeleteCall {
    void run(DmFileProvider.SafRoot root, String documentId, boolean recursive)
            throws DmFileProvider.ProviderCatalogException;
}
final class InjectedMethodReferenceSafMutation {
    void run(ProviderSafCatalog safCatalog, DmFileProvider.SafRoot root)
            throws DmFileProvider.ProviderCatalogException {
        InjectedDeleteCall operation = safCatalog::deleteDocument;
        operation.run(root, "outside-lease", false);
    }
}
""",
    ),
)
ANDROID_PROVIDER_NEW_FILE_CASES = (
    (
        Path(
            "android/app/src/main/java/app/droidmatch/m1/"
            "InjectedUnleasedSafMutation.java"
        ),
        """package app.droidmatch.m1;
final class InjectedUnleasedSafMutation {
    void run(ProviderSafCatalog safCatalog, DmFileProvider.SafRoot root)
            throws DmFileProvider.ProviderCatalogException {
        safCatalog.deleteDocument(root, "outside-lease", false);
    }
}
""",
    ),
    (
        Path(
            "android/app/src/main/java/injected/"
            "InjectedOutsideProviderRoot.java"
        ),
        """package app.droidmatch.m1;
final class InjectedOutsideProviderRoot {
    void run(ProviderSafCatalog safCatalog, DmFileProvider.SafRoot root)
            throws DmFileProvider.ProviderCatalogException {
        safCatalog.deleteDocument(root, "outside-lease", false);
    }
}
""",
    ),
    (
        Path(
            "android/app/src/release/java/app/droidmatch/m1/"
            "InjectedReleaseSafMutation.java"
        ),
        """package app.droidmatch.m1;
final class InjectedReleaseSafMutation {
    void run(ProviderSafCatalog safCatalog, DmFileProvider.SafRoot root)
            throws DmFileProvider.ProviderCatalogException {
        safCatalog.deleteDocument(root, "outside-lease", false);
    }
}
""",
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
        [sys.executable, str(CHECKER)],
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

        codeowners = repository / ".github" / "CODEOWNERS"
        original_codeowners = codeowners.read_text(encoding="utf-8")
        codeowners.write_text(
            original_codeowners + "* @invalid-owner\n",
            encoding="utf-8",
        )
        rejected_codeowners = run_checker(repository)
        codeowners.write_text(original_codeowners, encoding="utf-8")
        if rejected_codeowners.returncode == 0:
            raise AssertionError("checker accepted the wrong Phase A CODEOWNER")
        if "CODEOWNERS" not in rejected_codeowners.stderr:
            raise AssertionError(
                f"unexpected CODEOWNERS rejection: {rejected_codeowners.stderr}"
            )

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

        for relative_path, guarded_fragment, bypass_fragment in (
            ANDROID_PROVIDER_REPLACEMENT_CASES
            + ANDROID_PROVIDER_RACE_REPLACEMENT_CASES
        ):
            source = repository / relative_path
            original = source.read_text(encoding="utf-8")
            if guarded_fragment not in original:
                raise AssertionError(
                    f"test fixture is missing provider seam: {relative_path}"
                )
            source.write_text(
                original.replace(guarded_fragment, bypass_fragment, 1),
                encoding="utf-8",
            )
            rejected = run_checker(repository)
            source.write_text(original, encoding="utf-8")
            if rejected.returncode == 0:
                raise AssertionError(
                    f"checker accepted Android provider bypass: {relative_path}"
                )
            if "Android provider integrity contract" not in rejected.stderr:
                raise AssertionError(
                    f"unexpected provider rejection for {relative_path}: {rejected.stderr}"
                )

        for relative_path, forbidden_fragment in ANDROID_PROVIDER_APPEND_CASES:
            source = repository / relative_path
            original = source.read_text(encoding="utf-8")
            source.write_text(original + forbidden_fragment, encoding="utf-8")
            rejected = run_checker(repository)
            source.write_text(original, encoding="utf-8")
            if rejected.returncode == 0:
                raise AssertionError(
                    f"checker accepted direct SAF resolver wiring: {relative_path}"
                )
            if "Android provider integrity contract" not in rejected.stderr:
                raise AssertionError(
                    f"unexpected provider rejection for {relative_path}: {rejected.stderr}"
                )

        for relative_path, contents in ANDROID_PROVIDER_NEW_FILE_CASES:
            source = repository / relative_path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(contents, encoding="utf-8")
            rejected = run_checker(repository)
            source.unlink()
            if rejected.returncode == 0:
                raise AssertionError(
                    f"checker accepted new unleased SAF owner: {relative_path}"
                )
            if "Android provider integrity contract" not in rejected.stderr:
                raise AssertionError(
                    f"unexpected new-owner rejection for {relative_path}: {rejected.stderr}"
                )

        old_lease = (
            repository
            / "android/app/src/main/java/app/droidmatch/m1/ProviderUploadLeases.java"
        )
        old_lease.write_text(
            "package app.droidmatch.m1; final class ProviderUploadLeases {}\n",
            encoding="utf-8",
        )
        rejected = run_checker(repository)
        if rejected.returncode == 0:
            raise AssertionError("checker accepted revived ProviderUploadLeases")
        if "Android provider integrity contract" not in rejected.stderr:
            raise AssertionError(f"unexpected old-lease rejection: {rejected.stderr}")

    print("maintainer contract fail-closed tests passed.")
    print("中文：维护者契约 fail-closed 测试通过。")


if __name__ == "__main__":
    main()
