import DroidMatchCore
import DroidMatchAppSupport
import DroidMatchPresentation
import SwiftUI

@main
@MainActor
struct DroidMatchDesktopApp: App {
    @StateObject private var discoveryModel: DeviceDiscoveryModel
    @StateObject private var sessionModel: DeviceSessionModel
    @StateObject private var trustedDevicesModel: TrustedDevicesModel
    @StateObject private var transferNotificationPreference: TransferNotificationPreferenceStore
    @StateObject private var transferNotificationCoordinator: TransferNotificationCoordinator
    @StateObject private var executableFreshness: ProductExecutableFreshnessMonitor
    @StateObject private var windowActivity: ProductWindowActivityCoordinator

    init() {
        let discovery = AdbDeviceDiscovery()
        let pairingStore = KeychainPairingCredentialStore()
        let trustedDisplayNameCache = TrustedDeviceDisplayNameCache()
        let transferPersistenceDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DroidMatch", isDirectory: true)
            .appendingPathComponent("TransferQueues", isDirectory: true)
        let bookmarkStore = transferPersistenceDirectory.flatMap {
            try? SecurityScopedBookmarkStore(
                fileURL: $0.appendingPathComponent("SecurityScopedBookmarks.json")
            )
        }
        let transferQueueFactory = BookmarkingTransferQueueFactory(store: bookmarkStore)
        let discoveryModel = DeviceDiscoveryModel(
            discovery: discovery,
            unnamedDeviceLabel: AppStrings.androidDevice
        )
        _discoveryModel = StateObject(wrappedValue: discoveryModel)
        let sessionModel = DeviceSessionModel(
                coordinator: ProductDeviceSessionCoordinator(
                    connectionPreparer: discovery,
                    credentialStore: pairingStore,
                    trustedDisplayNameCache: trustedDisplayNameCache,
                    transferPersistenceDirectoryURL: transferPersistenceDirectory,
                    localFileAccessProviderFactory: { ownerID in
                        transferQueueFactory.localFileAccessProvider(for: ownerID)
                    }
                ),
                transferDataSourceFactory: { scheduler in
                    transferQueueFactory.transferQueueDataSource(for: scheduler)
                }
        )
        _sessionModel = StateObject(wrappedValue: sessionModel)
        let transferNotificationPreference = TransferNotificationPreferenceStore()
        _transferNotificationPreference = StateObject(
            wrappedValue: transferNotificationPreference
        )
        _transferNotificationCoordinator = StateObject(
            wrappedValue: TransferNotificationCoordinator(
                sessionModel: sessionModel,
                preference: transferNotificationPreference
            )
        )
        let trustedDevicesModel = TrustedDevicesModel(
            dataSource: KeychainTrustedDeviceDataSource(
                store: pairingStore,
                displayNameCache: trustedDisplayNameCache
            )
        )
        _trustedDevicesModel = StateObject(wrappedValue: trustedDevicesModel)
        let windowActivity = ProductWindowActivityCoordinator(
            onFirstActiveWindow: { discoveryModel.startAutomaticRefresh() },
            onLastActiveWindow: { discoveryModel.stopAutomaticRefresh() }
        )
        _windowActivity = StateObject(wrappedValue: windowActivity)
        let executableFreshness = ProductExecutableFreshnessMonitor {
            windowActivity.invalidateForRuntimeReplacement()
            discoveryModel.invalidateForRuntimeReplacement()
            trustedDevicesModel.invalidateForRuntimeReplacement()
            sessionModel.invalidateForRuntimeReplacement()
        }
        _executableFreshness = StateObject(wrappedValue: executableFreshness)
        executableFreshness.start()
    }

    var body: some Scene {
        WindowGroup(AppStrings.appName) {
            AppShellView(
                discoveryModel: discoveryModel,
                sessionModel: sessionModel,
                trustedDevicesModel: trustedDevicesModel,
                executableFreshness: executableFreshness,
                windowActivity: windowActivity
            )
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(AppStrings.refreshDevices) {
                    guard !executableFreshness.replacementDetected else { return }
                    discoveryModel.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(
                    executableFreshness.replacementDetected
                        || discoveryModel.phase == .loading
                        || discoveryModel.phase == .refreshing
                )
            }
            ProductHelpCommands()
        }

        Settings {
            ProductSettingsView(notificationPreference: transferNotificationPreference)
        }

        Window(AppStrings.helpWindowTitle, id: ProductHelpWindow.id) {
            ProductHelpView()
        }
        .defaultSize(width: 760, height: 620)
        .windowResizability(.contentMinSize)
    }
}
