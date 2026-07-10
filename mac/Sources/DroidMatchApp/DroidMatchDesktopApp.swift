import DroidMatchCore
import DroidMatchAppSupport
import DroidMatchPresentation
import SwiftUI

@main
@MainActor
struct DroidMatchDesktopApp: App {
    @StateObject private var discoveryModel: DeviceDiscoveryModel
    @StateObject private var sessionModel: DeviceSessionModel

    init() {
        let discovery = AdbDeviceDiscovery()
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
        let localAccessProvider: any LocalFileAccessProviding = bookmarkStore
            ?? UnavailableLocalFileAccessProvider()
        _discoveryModel = StateObject(
            wrappedValue: DeviceDiscoveryModel(discovery: discovery)
        )
        _sessionModel = StateObject(
            wrappedValue: DeviceSessionModel(
                coordinator: ProductDeviceSessionCoordinator(
                    connectionPreparer: discovery,
                    transferPersistenceDirectoryURL: transferPersistenceDirectory,
                    localFileAccessProvider: localAccessProvider
                ),
                transferDataSourceFactory: { scheduler in
                    BookmarkingTransferQueueDataSource(
                        scheduler: scheduler,
                        store: bookmarkStore
                    )
                }
            )
        )
    }

    var body: some Scene {
        WindowGroup(AppStrings.appName) {
            AppShellView(
                discoveryModel: discoveryModel,
                sessionModel: sessionModel
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
    }
}
