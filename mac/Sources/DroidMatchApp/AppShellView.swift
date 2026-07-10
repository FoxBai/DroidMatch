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
            DeviceDashboardView(model: discoveryModel)
        case .files:
            ProductPlaceholderView(
                symbol: "folder.badge.questionmark",
                title: AppStrings.filesNeedSession,
                detail: AppStrings.filesNeedSessionDetail
            )
        case .transfers:
            ProductPlaceholderView(
                symbol: "arrow.up.arrow.down.circle",
                title: AppStrings.transfersNeedSession,
                detail: AppStrings.transfersNeedSessionDetail
            )
        case .diagnostics:
            ProductPlaceholderView(
                symbol: "stethoscope",
                title: AppStrings.diagnosticsNeedSession,
                detail: AppStrings.diagnosticsNeedSessionDetail
            )
        }
    }
}

private struct ProductPlaceholderView: View {
    let symbol: String
    let title: String
    let detail: String

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
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
