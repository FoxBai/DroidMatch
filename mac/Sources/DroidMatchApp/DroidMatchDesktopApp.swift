import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

@main
@MainActor
struct DroidMatchDesktopApp: App {
    @StateObject private var discoveryModel: DeviceDiscoveryModel
    @StateObject private var sessionModel: DeviceSessionModel

    init() {
        let discovery = AdbDeviceDiscovery()
        _discoveryModel = StateObject(
            wrappedValue: DeviceDiscoveryModel(discovery: discovery)
        )
        _sessionModel = StateObject(
            wrappedValue: DeviceSessionModel(
                coordinator: ProductDeviceSessionCoordinator(
                    connectionPreparer: discovery
                )
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
