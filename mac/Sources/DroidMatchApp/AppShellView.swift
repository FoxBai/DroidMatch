import DroidMatchPresentation
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case devices
    case files
    case transfers
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .devices: return AppStrings.devices
        case .files: return AppStrings.files
        case .transfers: return AppStrings.transfers
        case .diagnostics: return AppStrings.diagnostics
        }
    }

    var symbol: String {
        switch self {
        case .devices: return "cable.connector"
        case .files: return "folder"
        case .transfers: return "arrow.up.arrow.down"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

struct AppShellView: View {
    @ObservedObject var discoveryModel: DeviceDiscoveryModel
    @ObservedObject var sessionModel: DeviceSessionModel
    @ObservedObject var trustedDevicesModel: TrustedDevicesModel
    @State private var selection: AppSection = .devices

    var body: some View {
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
        .task {
            if discoveryModel.phase == .idle {
                discoveryModel.refresh()
            }
        }
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
                ProductDiagnosticsView(model: diagnostics)
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
