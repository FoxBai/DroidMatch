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
REQUIRED_AGENT_GUIDE_TEXT = (
    "Treat changes in a disposable or secondary worktree as unpublished",
    "the authoritative branch and path",
    "temporary worktree",
)
REQUIRED_WORKTREE_HANDOFF_TEXT = (
    "canonical worktree is",
    "content-compared with the reviewed source",
    "authoritative branch",
    "规范工作树",
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
        "ProviderMimeTypes.isCanonicalVideoMetadata(item.mimeType)",
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
        "queuePersistencePreparing",
        "model.canPerformQueueActions",
        "transferActionFailed",
        "case .interrupted",
    ),
    "mac/Sources/DroidMatchCore/DeviceDiscovery.swift": ("ProcessRunner(timeoutSeconds: timeoutSeconds)", "catch is ProcessRunnerError", "continuation.resume(throwing: DeviceDiscoveryError.timedOut)"), "mac/Sources/DroidMatchApp/ProductFileBrowserView.swift": (
        "transferQueue.canPresentTransferSubmission",
        "ProductTransferPersistenceBanner",
    ),
    "mac/Sources/DroidMatchApp/ProductMediaLibraryView.swift": (
        "transferQueue.canPresentTransferSubmission",
        "ProductTransferPersistenceBanner",
    ),
    "mac/Sources/DroidMatchApp/DeviceDashboardView.swift": (
        "trustRemovalFailedDetail",
        "presentedAlert = .revocationFailed",
        "guard !isRevokingTrust else { return }",
        "let succeeded = await trustedDevicesModel.revoke",
    ),
    "mac/Sources/DroidMatchPresentation/TransferQueueModel.swift": (
        "public var canSubmitTransfers: Bool",
        "public var canPresentTransferSubmission: Bool",
        "public var canPerformQueueActions: Bool",
        "guard canSubmitTransfers else { return false }",
    ),
    "mac/Sources/DroidMatchPresentation/TrustedDevicesModel.swift": (
        "activeLoadGeneration",
        "invalidateRefreshForMutation()",
        "guard generation == operationGeneration else { return }",
    ),
    "mac/Sources/DroidMatchCore/ProductDeviceSessionCoordinator.swift": ("suspendForSessionEnd()",),
    "mac/Sources/DroidMatchCore/LocalFileAccessOwnerID.swift": (
        "@_spi(DroidMatchAppSupport)",
        "CustomDebugStringConvertible",
        "CustomReflectable",
        "<redacted-local-file-access-owner>",
    ),
}
REQUIRED_CURRENT_CAPABILITY_WIRING = {
    "mac/Sources/DroidMatchCore/PrivateAtomicFileWriterInternals.swift": ("extension PrivateAtomicFileWriter", "static func pinnedLocation(", "static func rollbackPublication(", "static func rollbackRemoval("),
    "mac/Sources/DroidMatchCore/AtomicDownloadWriter.swift": ("AtomicDownloadPartialFile.openDirectory(", "AtomicDownloadPartialFile.open(", "AtomicDownloadPartialFile.unlockAndClose("),
    "mac/Sources/DroidMatchCore/AtomicDownloadPartialFile.swift": ("enum AtomicDownloadPartialFile", "O_RDWR | O_CLOEXEC | O_NOFOLLOW", "droidMatchPartialFileFlock(descriptor, LOCK_EX | LOCK_NB)", "static func sameOptionalEntrySnapshot("),
    "mac/Sources/DroidMatchApp/ProductFileBrowserContent.swift": ("struct ProductFileBrowserContent", "struct State", "struct Actions", "else if entry.canBrowse", "else if state.allowsUpload && entry.canAcceptUpload"),
    "mac/Sources/DroidMatchAppSupport/ProductFileBrowserTransferPolicy.swift": ("isCurrentAuthorizedSnapshot(", "isCurrentWritableUploadTarget(", "downloadRequests(", ".widthInsensitive"),
    ".github/workflows/m0.yml": ('sdkmanager "platforms;android-36" "build-tools;36.0.0"',),
    "android/app/build.gradle": ("compileSdk = 36", 'buildToolsVersion = "36.0.0"', "targetSdk = 36"),
    "android/gradle/wrapper/gradle-wrapper.properties": ("gradle-8.14.5-bin.zip", "distributionSha256Sum=6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854"),
    "mac/Sources/DroidMatchApp/AppStrings.swift": (
        'value("Connect and authenticate a device to browse and manage its files.")',
        'value("Diagnostics need an authenticated session")',
        'value("Connect and authenticate a device to view structured transport, permission, storage, and battery status.")',
        'static let selected = value("Selected")',
        'static let notSelected = value("Not selected")',
    ),
    "mac/Sources/DroidMatchApp/AppShellView.swift": (
        "private struct SessionRequiredView: View",
        ".accessibilityHidden(true)",
    ),
    "mac/Sources/DroidMatchApp/DeviceDashboardView.swift": (
        "if trustedDevicesModel.isRefreshOutstanding {",
        "trustedDevicesModel.canRefresh",
        "trustedDevicesSystemRequestPending",
        ".accessibilityElement(children: .ignore)",
        '.accessibilityLabel(Text("\\(value), \\(label)"))',
    ),
    "mac/Sources/DroidMatchApp/FileBrowserItemViews.swift": (
        ".accessibilityValue(selectionAccessibilityValue)",
        ".accessibilityLabel(AppStrings.upload)",
        ".accessibilityLabel(AppStrings.rename)",
        ".accessibilityLabel(AppStrings.delete)",
        "return isSelected ? AppStrings.selected : AppStrings.notSelected",
    ),
    "mac/Sources/DroidMatchApp/MediaGridCard.swift": (
        ".accessibilityValue(selectionAccessibilityValue)",
        "return isSelected ? AppStrings.selected : AppStrings.notSelected",
    ),
    "mac/Sources/DroidMatchApp/ProductFileBrowserToolbar.swift": (
        "state.sortField == field ? AppStrings.selected : AppStrings.notSelected",
        ".accessibilityHidden(true)",
    ),
    "mac/Sources/DroidMatchApp/ProductTransferQueueView.swift": (
        ".accessibilityLabel(item.kind == .download ? AppStrings.download : AppStrings.upload)",
    ),
    "mac/Sources/DroidMatchCore/ProductDeviceDiagnostics.swift": ("enum ProductDeviceDiagnosticsNormalization", "private static func permissionKey(for kind: ProductPermissionKind)", "switch kind", "deviceInfo.permissions[permissionKey(for: kind)]"), "mac/Sources/DroidMatchCore/DiagnosticsSupportBundle.swift": ("ProductDeviceDiagnosticsNormalization.displayValue(", "ProductDeviceDiagnosticsNormalization.freeStorage(", "ProductDeviceDiagnosticsNormalization.recentErrorCount(", "ProductDeviceDiagnosticsNormalization.counterValue("), "mac/Tests/DroidMatchCoreTests/DiagnosticsSupportBundleTests.swift": ("diagnosticsSupportBundleRevalidatesConstructedSnapshotValues", "model.unicodeScalars.count == 120", "counters == [\"framesReceived\": 2]"), "mac/Sources/DroidMatchCore/ProductDisplayText.swift": (
        "precomposedStringWithCanonicalMapping",
        "CharacterSet.whitespacesAndNewlines.contains(scalar)",
        "case .control, .format, .surrogate:",
        "maximumScalars",
        "if wasTruncated, maximumScalars > 1 {",
        "visible.append(Unicode.Scalar(0x2026)!)",
    ),
    "mac/Sources/DroidMatchCore/ProductMimeType.swift": (
        "public static let maximumUTF8Length = 127",
        "bytes.allSatisfy({ $0 < 0x80 })",
        "productLabels.contains(canonical)",
        "isRestrictedName(canonicalBytes[..<slash])",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProviderMimeTypes.java": ("MAXIMUM_METADATA_UTF8_BYTES = 127", "canonicalMetadata(rawValue)", "isRestrictedName(canonical, 0, slash)"),
    "mac/Sources/DroidMatchCore/DirectoryListing.swift": ("let canonicalMimeType = ProductMimeType.value(mimeType)", "self.mimeType = canonicalMimeType", "canonicalMimeType?.hasPrefix(\"video/\") == true", "mimeType: value.mimeType,", "durationMillis: value.durationMillis"),
    "mac/Sources/DroidMatchPresentation/DeviceSessionModel.swift": (
        "public struct DevicePairingPresentation: Sendable, Equatable",
        "public let androidDisplayName: String?",
        "public let shortAuthenticationString: String",
        "@Published public private(set) var pairingPresentation: DevicePairingPresentation?",
        "pairingPresentation = DevicePairingPresentation(presentation)",
        "displayName: ProductDisplayText.value(info.displayName) ?? \"\"",
    ),
    "mac/Sources/DroidMatchPresentation/TransferQueuePresentationItem.swift": (
        "localFileName = Self.localFileName(from: localPath)",
        "return ProductDisplayText.value(name)",
    ),
    "mac/Sources/DroidMatchPresentation/TrustedDevicesModel.swift": (
        "@Published public private(set) var isRefreshOutstanding",
        "public var canRefresh: Bool",
        "guard canRefresh, loadTask == nil else { return false }",
        "ProductDisplayText.value(displayName)",
    ),
    "mac/Sources/DroidMatchCore/ProductDeviceSessionCoordinator.swift": (
        "let info = try await authenticate(",
        "authenticationState == .authenticated",
    ),
    "mac/Sources/DroidMatchCore/PairingCredentialStore.swift": ("protocol PairingCredentialDisplayMetadataListing", "func listForDisplay()", ".map(displayMetadata(from:))", "Credential selection happens only", "attributes: [kSecAttrGeneric as String: data]", "Self.pairingID(account: account)"), "mac/Sources/DroidMatchAppSupport/KeychainTrustedDeviceDataSource.swift": ("PairingCredentialStoring & PairingCredentialDisplayMetadataListing", "let metadata = try store.listForDisplay()"),
    "mac/Sources/DroidMatchPresentation/DirectoryBrowserPresentationTypes.swift": (
        "public enum DirectoryMutationOperation",
        "public enum DirectoryMutationGuidance",
        "public func guidance(",
        "public var canBrowse: Bool",
        "canRead && (kind == .directory || kind == .virtual)",
        "public var canAcceptUpload: Bool",
        "canWrite && (kind == .directory || kind == .virtual)",
    ),
    "mac/Sources/DroidMatchPresentation/DirectoryBrowserModel.swift": ("guard entry.canBrowse, let query else { return false }", "private let mutationRunner: DirectoryBrowserMutationRunner", "private func finishMutation(_ outcome: DirectoryBrowserMutationRunner.Outcome)", "invalidateThumbnails(clearCache: true)", "thumbnailState.finish(key)"),
    "mac/Sources/DroidMatchPresentation/DirectoryBrowserMutationRunner.swift": ("final class DirectoryBrowserMutationRunner", "private var task: Task<Void, Never>?",
        "guard activeOperationID == nil else { return nil }", "activeOperationID = nil", "completion(outcome)"), "mac/Sources/DroidMatchPresentation/DirectoryBrowserThumbnailState.swift": ("struct DirectoryBrowserThumbnailState", "mutating func invalidate(clearCache: Bool)", "mutating func nextRequest(", "activeKeys.remove(key)", "while images.count > maximumCachedCount"),
    "mac/Sources/DroidMatchCore/AsyncTransferScheduler.swift": ("AsyncTransferSchedulerExecutionPolicy.applyRetry(", "AsyncTransferSchedulerExecutionPolicy.applyProgress(", "AsyncTransferSchedulerExecutionPolicy.expireRecentRate(", "let resolution = AsyncTransferSchedulerCompletionPolicy.reconcile(", "if let finalOutcome = resolution.outcomeToSettle"),
    "mac/Sources/DroidMatchCore/AsyncTransferSchedulerExecutionPolicy.swift": ("enum AsyncTransferSchedulerExecutionPolicy", "case persist(previousRecord: AsyncTransferSchedulerJobRecord)", "static func applyRetryPersistenceFailure(", "progress.confirmedBytes >= record.confirmedBytes", "record.rateSampleGeneration == generation"),
    "mac/Sources/DroidMatchCore/AsyncTransferSchedulerCompletionPolicy.swift": ("enum AsyncTransferSchedulerCompletionPolicy", "case interrupted(AsyncTransferJobOutcome)", "static func reconcile(", "record.state == .pausing"), "mac/Sources/DroidMatchCore/AsyncRpcOneShot.swift": ("enum AsyncRpcOneShotStateError", "private var waitClaimed = false", "guard !waitClaimed else { return false }", "throw AsyncRpcOneShotStateError.waitAlreadyClaimed", "throwing: AsyncRpcOneShotStateError.missingResolvedValue"), "mac/Sources/DroidMatchCore/AsyncTimeoutPolicy.swift": ("guard seconds.isFinite, seconds > 0", "return UInt64.max", "UInt64.max - nowNanoseconds"), "mac/Sources/DroidMatchCore/AsyncFramedTcpSession.swift": ("let oneShot = AsyncRpcOneShot<Success>()", "cancellationPolicy: .firstResolutionWins", "onCancel: cancel", "AsyncTimeoutPolicy.dispatchDeadline(after: timeoutSeconds)", "throw FramedTcpClientError.invalidTimeout"), "mac/Sources/DroidMatchCore/AsyncRpcMultiplexer.swift": ("AsyncTimeoutPolicy.nanoseconds(for: requestTimeoutSeconds)", "throw FramedTcpClientError.invalidTimeout"), "mac/Sources/DroidMatchCore/AsyncRpcDeadlines.swift": ("AsyncTimeoutPolicy.nanoseconds(for: requestTimeoutSeconds) ?? 0",), "mac/Sources/DroidMatchCore/ProcessRunner.swift": ("AsyncTimeoutPolicy.nanoseconds(for: timeoutSeconds)", "AsyncTimeoutPolicy.nanoseconds(for: terminationGraceSeconds)", "throw ProcessRunnerError.invalidTimeout", "dispatchDeadline(after: timeoutSeconds)"), "mac/Sources/DroidMatchHarness/HarnessCLI.swift": ("func positiveFiniteDouble(", "if flags.contains(option)", "value.isFinite, value > 0"), "mac/Sources/DroidMatchHarness/HarnessMutationCommands.swift": ('options.positiveFiniteDouble("--timeout-seconds")',), "mac/Sources/DroidMatchHarness/HarnessTransferCommands.swift": ('options.positiveFiniteDouble("--timeout-seconds")',), "mac/Sources/DroidMatchHarness/HarnessUploadCommands.swift": ('options.positiveFiniteDouble("--timeout-seconds")',), "mac/Sources/DroidMatchHarness/HarnessDirectoryCommands.swift": ('options.positiveFiniteDouble("--timeout-seconds")',), "mac/Sources/DroidMatchHarness/main.swift": ('options.positiveFiniteDouble("--timeout-seconds")',), "mac/Tests/DroidMatchCoreTests/PairingCredentialStoreTests.swift": ("DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST", ".enabled("), "mac/Sources/DroidMatchCore/AsyncRpcControlClient.swift": ("case ready(HandshakeSmokeResult)", "case let .ready(handshake):", "state = .ready(authenticatedResult)", "guard case let .ready(handshake) = state"), "mac/Sources/DroidMatchCore/AsyncTransferSchedulerPersistenceState.swift": ("guard let store else {", "throw TransferQueuePersistenceStoreError.ioFailure"), "mac/Sources/DroidMatchCore/AsyncTransferSchedulerAdmission.swift": ("throws(AsyncTransferSchedulerError)", "catch {", "error: error"),
    "mac/Sources/DroidMatchApp/ProductFileBrowserView.swift": (
        "@State private var selectionState = DirectoryBrowserSelectionState()", "selectionState.synchronize(visibleEntries: entries)", "selectionState.removeAcceptedPaths(Set(admissions.map",
        "private func chooseUploadSource(into entry: DirectoryBrowserItem)",
        "mutationOperation.localizedDetail", "consumeSheetMutationFailure",
    ), "mac/Sources/DroidMatchPresentation/DirectoryBrowserSelectionState.swift": ("public struct DirectoryBrowserSelectionState", "public mutating func synchronize(", "selectedPaths.formIntersection", "public mutating func toggleAllLoaded(", "public mutating func removeAcceptedPaths(", "private static func isSelectable("),
    "mac/Sources/DroidMatchApp/ProductFileBrowserChrome.swift": (
        "struct ProductFileBrowserMutationSheetFailure",
        "@State private var failure: ProductFileBrowserMutationSheetFailure?",
        ".alert(item: $failure)",
        "func localizedDetail(",
    ),
    "android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java": (
        "public void enableSecureConnection()",
        "pairingApprovals.openWindow(PairingApprovalController.DEFAULT_WINDOW_MILLIS)",
        "PairedDeviceManager",
        "public void manageMediaAccess()",
        "mediaPermissionController.manageAccess(mediaSettingsRecommended)",
        "mediaPermissionController.requestNeedsSettingsFallback(",
        "outState.putBoolean(STATE_MEDIA_SETTINGS_RECOMMENDED",
        "refreshMediaAccess();", "screen.showMediaAccessDetails(",
        "requestCode == MediaPermissionController.REQUEST_MEDIA_READ",
        "SafGrantStatePolicy.grantConfirmed",
        "SafGrantStatePolicy.removalConfirmed",
        "storageRootsAvailable",
        "R.string.readiness_counts_storage_unavailable",
        "public void refreshPairedDevices()",
        "ProductReadiness.countsState(",
        "R.string.readiness_counts_paired_unavailable",
        "R.string.readiness_counts_both_unavailable",
        "showStorageAuthorizationFailure(",
        "ProductDisplayName.name(",
        "PairingAccessibilityPolicy.state(",
        "PairingAccessibilityPolicy.spokenDigits(",
        "screen.setTextIfChanged(screen.pairingCountdown, countdown)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java": (
        "void manageMediaAccess();",
        "void refreshFolders();",
        "void refreshPairedDevices();",
        "actions.manageMediaAccess()",
        "mediaAccessStatus.setAccessibilityLiveRegion", "void showMediaAccessDetails(",
        "pairedDevices.setAccessibilityLiveRegion",
        "void showStorageRootsUnavailable()",
        "actions.refreshFolders()",
        "void showPairedDevicesUnavailable()",
        "actions.refreshPairedDevices()",
        "ProductDisplayName.name(",
        "pairingCode.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO)",
        "pairingStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE)",
        "pairingCountdown.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO)",
        "Build.VERSION_CODES.VANILLA_ICE_CREAM",
        "WindowInsets.Type.systemBars()", "WindowInsets.Type.displayCutout()",
    ),
    "android/app/src/main/java/app/droidmatch/m1/PairingAccessibilityPolicy.java": (
        "static State state(",
        "static String spokenDigits(",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProductReadiness.java": (
        "enum CountsState",
        "static CountsState countsState(",
        "CountsState.PAIRED_DEVICES_UNAVAILABLE",
        "CountsState.BOTH_UNAVAILABLE",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProductDisplayName.java": (
        "Normalizer.normalize(rawName, Normalizer.Form.NFC)",
        "Character.isWhitespace(codePoint)",
        "type == Character.CONTROL",
        "type == Character.FORMAT",
        "type == Character.SURROGATE",
        "DEVICE_FALLBACK",
        "static String name(String rawName, String fallback)",
        "MAXIMUM_VISIBLE_CODE_POINTS = 120",
        "Math.min(normalized.length(),",
        "MAXIMUM_VISIBLE_CODE_POINTS * 2",
        "visible.appendCodePoint(ELLIPSIS_CODE_POINT)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/PairingApprovalController.java": (
        "ProductDisplayName.deviceName(clientDisplayName)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/PairedDeviceManager.java": (
        "ProductDisplayName.deviceName(displayName)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/SafGrantStatePolicy.java": (
        "static boolean grantConfirmed(",
        "static boolean removalConfirmed(",
        "roots == null",
    ),
    "android/app/src/main/java/app/droidmatch/m1/MediaPermissionController.java": (
        "MediaPermissionPolicy.managementAction(access)",
        "activity.requestPermissions(",
        "MediaPermissionPolicy.requestPermissions(Build.VERSION.SDK_INT)",
        "MediaPermissionPolicy.permissionCallbackComplete(",
        "MediaPermissionPolicy.shouldRecommendSettingsFallback(",
        "settingsFallbackStillAppropriate()",
        "Settings.ACTION_APPLICATION_DETAILS_SETTINGS",
        "catch (ActivityNotFoundException | SecurityException exception)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/MediaPermissionPolicy.java": (
        "Manifest.permission.READ_EXTERNAL_STORAGE",
        "Manifest.permission.READ_MEDIA_IMAGES",
        "Manifest.permission.READ_MEDIA_VIDEO",
        "static final String READ_MEDIA_VISUAL_USER_SELECTED =",
        "case MEDIA_IMAGE_ALBUMS:",
        "return LibraryAccess.LIMITED;",
        "static boolean canWriteMedia(int sdkInt)",
        "static boolean permissionCallbackComplete(",
        "static boolean shouldRecommendSettingsFallback(",
    ),
    "mac/Sources/DroidMatchCore/AsyncUploadCoordinator.swift": (
        'destinationPath.hasPrefix("dm://saf-")',
        "automatic resume is limited to app-sandbox and SAF providers.",
    ),
    "android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java": (
        "private final AndroidSafUploadOpener uploadOpener;",
        "ProviderLiveAuthorization authorization = () -> requirePersistedPermission(",
        "return ProviderAuthorizedTransfers.upload(writer, authorization);",
    ),
    "android/app/src/main/java/app/droidmatch/m1/AppSandboxPathResolver.java": ("final class AppSandboxPathResolver", "ProviderPathRouter.isCanonicalAppSandboxRelativePath(relativePath)", "Files.isSymbolicLink(candidatePath)", "!resolvedPath.startsWith(rootPath + File.separator)"),
    "android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java": (
        "SafUploadOpenPolicy.mode(transferId, offsetBytes)",
        "SafUploadOpenPolicy.requiresTruncation(",
        "truncateSafUploadPartial(documentUri, offsetBytes);",
        "ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);",
        '"SAF provider cannot reconcile the upload partial"',
        "ProviderLiveAuthorization commitAuthorization",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProviderAuthorizedTransfers.java": (
        "return delegate.readNextChunk();",
        "delegate.writeChunk(offsetBytes, data, finalChunk);",
        "closeQuietly(delegate);",
        "final class ProviderMediaReadAuthorization",
        "itemVisibility.currentItemVisible()",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java": (
        "commitAuthorization.requireAuthorized();",
        '"SAF write permission is required to upload this document"',
        '"MediaStore write permission is required to upload this item"',
    ),
    "android/app/src/main/java/app/droidmatch/m1/AndroidMediaCatalog.java": (
        "public boolean canReadMedia(DmFileProvider.RootKind rootKind)",
        "new ProviderMediaReadAuthorization(",
        "() -> isMediaItemVisible(uri)",
        "ProviderAuthorizedTransfers.download(seekableReader, authorization)",
        "return cursor != null && cursor.moveToFirst();",
    ),
    "android/app/src/main/java/app/droidmatch/m1/PermissionStateProvider.java": (
        "PermissionState publicMediaReadState(DmFileProvider.RootKind rootKind)",
        "MediaReadAccess publicMediaReadAccess(DmFileProvider.RootKind rootKind)",
        "MediaPermissionPolicy.readPermission(",
        "MediaPermissionPolicy.rootAccess(",
        "MediaPermissionPolicy.LibraryAccess publicMediaLibraryAccess()",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProviderMediaCatalog.java": (
        "default boolean canReadMedia(RootKind rootKind)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProviderDirectoryListings.java": (
        "rootCanRead(root, mediaCatalog)",
        "return mediaCatalog.canReadMedia(RootKind.MEDIA_IMAGES);",
        ".setCanRead(canRead).setCanWrite(canWrite)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java": (
        "if (!mediaCatalog.canUploadMedia(media.rootKind))",
        '"MediaStore upload is not available on this device"',
    ),
    "android/app/src/main/java/app/droidmatch/m1/ProviderIoCleanup.java": (
        "catch (IOException | RuntimeException ignored)",
    ),
    "android/app/src/main/java/app/droidmatch/m1/SafUploadOpenPolicy.java": (
        "partialDocument.kind != FileKind.FILE_KIND_FILE",
        "partialDocument.sizeBytes < offsetBytes",
        "partialDocument.sizeBytes > offsetBytes",
    ),
    "mac/Sources/DroidMatchCore/DirectoryMutation.swift": (
        "Droidmatch_V1_DeletePathRequest()",
    ),
    "tools/swift-build-compat.sh": (
        "export CLANG_MODULE_CACHE_PATH=",
        "export SWIFTPM_MODULECACHE_OVERRIDE=",
        "droidmatch_default_swift_target_available",
        "droidmatch_arm64e_swift_target_available",
        "--triple \"${droidmatch_swift_probe_target}\"",
    ),
    "tools/run-swift-tests.sh": (
        'source "${repo_root}/tools/swift-build-compat.sh"',
        '"${droidmatch_swift_compat_args[@]}"',
    ),
    "tools/build-mac-app.sh": (
        'source "${repo_root}/tools/swift-build-compat.sh"',
        '"${droidmatch_swift_compat_args[@]}"',
        'bash "${repo_root}/tools/build-mac-icon.sh"', "os.makedirs(sys.argv[1], exist_ok=True)",
    ), "tools/test-build-mac-app.sh": ("preserved-parent-mode", '[[ "${permission_after}" == "${permission_before}" ]]'),
    "tools/build-mac-icon.sh": (
        'python3 "${repo_root}/tools/package-mac-icon.py"',
        'iconutil -c iconset "${output_path}"',
    ),
    "tools/package-mac-icon.py": (
        '(b"icp4", "icon_16x16.png", 16)',
        '(b"ic10", "icon_512x512@2x.png", 1024)',
        "write_exclusive(output, build_container(Path(sys.argv[1])))",
    ),
    "android/app/src/main/java/app/droidmatch/m1/RpcControlHandler.java": (
        "DeletePathRequest.parseFrom",
        "fileProvider.deletePath",
    ),
}
FORBIDDEN_CURRENT_CAPABILITY_WIRING = {
    "mac/Sources/DroidMatchApp/AppStrings.swift": (
        "Device discovery is live. File browsing will unlock after the product session boundary is connected.",
        "Session diagnostics are not connected yet",
        "This product surface will use structured transport and permission state, never raw harness output.",
    ),
    "tools/build-mac-app.sh": (
        "iconutil -c icns", 'install -d "${output_parent_input}"',
    ),
    "mac/Sources/DroidMatchPresentation/TransferQueuePresentationItem.swift": (
        "public let remotePath:",
        "remotePath = Self.remotePath(",
        "private static func remotePath(",
    ),
    "android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java": (
        "announceForAccessibility(",
    ), "mac/Sources/DroidMatchCore/DeviceDiscovery.swift": ("precondition(timeoutSeconds > 0",), "mac/Sources/DroidMatchCore/ProductDeviceDiagnostics.swift": ("permissionKeys[kind]!",), "mac/Sources/DroidMatchCore/DiagnosticsSupportBundle.swift": ("manufacturer: snapshot.manufacturer", "model: snapshot.model", "recentErrorCount: snapshot.recentErrorCount", "counters: Dictionary(uniqueKeysWithValues: snapshot.counters.map"),
    "mac/Sources/DroidMatchCore/AsyncFramedTcpSession.swift": ("AsyncNetworkResultGate", "preconditionFailure(", ".now() + timeoutSeconds"), "mac/Sources/DroidMatchCore/AsyncRpcDeadlines.swift": ("UInt64(rawNanoseconds)",), "mac/Sources/DroidMatchCore/ProcessRunner.swift": (".now() + timeoutSeconds", ".now() + terminationGraceSeconds"), "mac/Sources/DroidMatchHarness/HarnessCLI.swift": ("func double(",), "mac/Sources/DroidMatchHarness/HarnessMutationCommands.swift": ("options.double(",), "mac/Sources/DroidMatchHarness/HarnessTransferCommands.swift": ("options.double(",), "mac/Sources/DroidMatchHarness/HarnessUploadCommands.swift": ("options.double(",), "mac/Sources/DroidMatchHarness/HarnessDirectoryCommands.swift": ("options.double(",), "mac/Sources/DroidMatchHarness/main.swift": ("options.double(",), "mac/Sources/DroidMatchCore/AsyncRpcControlClient.swift": ("cachedHandshake", "preconditionFailure("), "mac/Sources/DroidMatchCore/AsyncTransferSchedulerPersistenceState.swift": ("preconditionFailure(",), "mac/Sources/DroidMatchCore/AsyncTransferSchedulerAdmission.swift": ("preconditionFailure(",),
}
REQUIRED_CURRENT_CAPABILITY_COUNTS = {
    "android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java": {
        "ProviderIoCleanup.closeQuietly(outputStream);": 4,
        "ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);": 4,
    },
    "android/app/src/main/java/app/droidmatch/m1/ProviderAuthorizedTransfers.java": {
        "authorization.requireAuthorized();": 2,
        "closeQuietly(delegate);": 2,
        "itemVisibility.currentItemVisible()": 1,
    },
    "android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java": {
        "mediaPermissionController.manageAccess(mediaSettingsRecommended)": 1,
    },
    "android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java": {
        "actions.manageMediaAccess()": 1,
    },
    "android/app/src/main/java/app/droidmatch/m1/MediaPermissionController.java": {
        "activity.requestPermissions(": 1,
        "MediaPermissionPolicy.shouldRecommendSettingsFallback(": 1,
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
for required in REQUIRED_AGENT_GUIDE_TEXT:
    if required not in agent_guide:
        fail(f"AGENTS.md is missing worktree-publication text: {required}")
for required in REQUIRED_WORKTREE_HANDOFF_TEXT:
    if required not in runbook:
        fail(f"runbook is missing worktree-publication text: {required}")

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

for relative_path, forbidden_fragments in FORBIDDEN_CURRENT_CAPABILITY_WIRING.items():
    source = ROOT / relative_path
    if not source.is_file():
        fail(f"required current-capability source is missing: {relative_path}")
    source_text = source.read_text(encoding="utf-8")
    for fragment in forbidden_fragments:
        if fragment in source_text:
            fail(f"{relative_path} has forbidden current capability wiring: {fragment}")

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
actual_android_tests = count_test_annotations(ROOT / "android" / "app" / "src" / "test", (".java", ".kt"))
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
    f"inventory is {actual_swift_tests}/{actual_android_tests}",
    f"测试库存为 {actual_swift_tests}/{actual_android_tests}",
):
    if expected_text not in technical_debt:
        fail(f"docs/technical-debt.md is missing test inventory text: {expected_text}")

print("Maintainer contract check passed.")
print("中文：维护者交接契约与异步网络边界检查通过。")
