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
    @StateObject private var transferNotificationCoordinator: TransferNotificationCoordinator

    init() {
        let discovery = AdbDeviceDiscovery()
        let pairingStore = KeychainPairingCredentialStore()
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
        _discoveryModel = StateObject(
            wrappedValue: DeviceDiscoveryModel(discovery: discovery)
        )
        let sessionModel = DeviceSessionModel(
                coordinator: ProductDeviceSessionCoordinator(
                    connectionPreparer: discovery,
                    credentialStore: pairingStore,
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
        _transferNotificationCoordinator = StateObject(
            wrappedValue: TransferNotificationCoordinator(sessionModel: sessionModel)
        )
        _trustedDevicesModel = StateObject(
            wrappedValue: TrustedDevicesModel(
                dataSource: KeychainTrustedDeviceDataSource(store: pairingStore)
            )
        )
    }

    var body: some Scene {
        WindowGroup(AppStrings.appName) {
            AppShellView(
                discoveryModel: discoveryModel,
                sessionModel: sessionModel,
                trustedDevicesModel: trustedDevicesModel
            )
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(AppStrings.refreshDevices) {
                    discoveryModel.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(discoveryModel.phase == .loading || discoveryModel.phase == .refreshing)
            }
        }

        Settings {
            ProductSettingsView()
        }
    }
}
