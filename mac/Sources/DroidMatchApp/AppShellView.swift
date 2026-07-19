import DroidMatchAppSupport
import DroidMatchPresentation
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case devices
    case files
    case media
    case transfers
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .devices: return AppStrings.devices
        case .files: return AppStrings.files
        case .media: return AppStrings.media
        case .transfers: return AppStrings.transfers
        case .diagnostics: return AppStrings.diagnostics
        }
    }

    var symbol: String {
        switch self {
        case .devices: return "cable.connector"
        case .files: return "folder"
        case .media: return "photo.on.rectangle.angled"
        case .transfers: return "arrow.up.arrow.down"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

struct AppShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var discoveryModel: DeviceDiscoveryModel
    @ObservedObject var sessionModel: DeviceSessionModel
    @ObservedObject var trustedDevicesModel: TrustedDevicesModel
    @ObservedObject var executableFreshness: ProductExecutableFreshnessMonitor
    let windowActivity: ProductWindowActivityCoordinator
    @State private var selection: AppSection = .devices
    @State private var windowID = UUID()
    @State private var isRegisteredActive = false

    var body: some View {
        VStack(spacing: 0) {
            if executableFreshness.replacementDetected {
                ProductRuntimeReplacementBanner()
                Spacer()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                navigation
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { updateWindowActivity(for: scenePhase) }
        .onChange(of: scenePhase) { phase in
            updateWindowActivity(for: phase)
        }
        .onChange(of: executableFreshness.replacementDetected) { _ in
            updateWindowActivity(for: scenePhase)
        }
        .onDisappear { setWindowActive(false) }
    }

    private var navigation: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle(AppStrings.appName)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppStrings.localFirst)
                        .font(.caption.weight(.semibold))
                    Text(AppStrings.adbFoundation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.ultraThinMaterial)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detail
        }
    }

    private func updateWindowActivity(for phase: ScenePhase) {
        let shouldBeActive = phase == .active && !executableFreshness.replacementDetected
        setWindowActive(shouldBeActive)
        if shouldBeActive {
            if selection == .media {
                sessionModel.mediaLibrary?.activate()
            }
        }
    }

    private func setWindowActive(_ active: Bool) {
        guard active != isRegisteredActive else { return }
        isRegisteredActive = active
        windowActivity.setActive(active, windowID: windowID)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .devices:
            DeviceDashboardView(
                model: discoveryModel,
                sessionModel: sessionModel,
                trustedDevicesModel: trustedDevicesModel,
                openFiles: { selection = .files }
            )
        case .files:
            if sessionModel.phase == .ready,
               let browser = sessionModel.directoryBrowser,
               let transferQueue = sessionModel.transferQueue {
                ProductFileBrowserView(
                    model: browser,
                    transferQueue: transferQueue,
                    allowsUpload: sessionModel.canUploadFiles
                )
            } else {
                SessionRequiredView(
                    symbol: "folder.badge.questionmark",
                    title: AppStrings.filesNeedSession,
                    detail: AppStrings.filesNeedSessionDetail,
                    action: { selection = .devices }
                )
            }
        case .media:
            if sessionModel.phase == .ready,
               let mediaLibrary = sessionModel.mediaLibrary,
               let transferQueue = sessionModel.transferQueue {
                ProductMediaLibraryView(
                    model: mediaLibrary,
                    transferQueue: transferQueue,
                    allowsUpload: sessionModel.canUploadFiles
                )
            } else {
                SessionRequiredView(
                    symbol: "photo.badge.exclamationmark",
                    title: AppStrings.mediaNeedSession,
                    detail: AppStrings.mediaNeedSessionDetail,
                    action: { selection = .devices }
                )
            }
        case .transfers:
            if sessionModel.phase == .ready,
               let transferQueue = sessionModel.transferQueue {
                ProductTransferQueueView(model: transferQueue)
            } else {
                SessionRequiredView(
                    symbol: "arrow.up.arrow.down.circle",
                    title: AppStrings.transfersNeedSession,
                    detail: AppStrings.transfersNeedSessionDetail,
                    action: { selection = .devices }
                )
            }
        case .diagnostics:
            if sessionModel.phase == .ready,
               let diagnostics = sessionModel.diagnostics {
                ProductDiagnosticsView(
                    model: diagnostics,
                    sessionDisplayName: sessionModel.sessionDisplayName
                )
            } else {
                SessionRequiredView(
                    symbol: "stethoscope",
                    title: AppStrings.diagnosticsNeedSession,
                    detail: AppStrings.diagnosticsNeedSessionDetail,
                    action: { selection = .devices }
                )
            }
        }
    }
}

/// Product empty state shown when a section requires an authenticated device.
private struct SessionRequiredView: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(AppStrings.goToDevices, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
