import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct DeviceDashboardView: View {
    @ObservedObject var model: DeviceDiscoveryModel

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.phase == .failed {
                    failureBanner
                }
                summary
                deviceContent
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(AppStrings.devices)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label(AppStrings.refresh, systemImage: "arrow.clockwise")
                }
                .disabled(model.phase == .loading || model.phase == .refreshing)
                .help(AppStrings.refreshDevices)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(AppStrings.deviceOverview)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(AppStrings.deviceOverviewDetail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .loading || model.phase == .refreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            SummaryMetric(
                value: "\(model.devices.count)",
                label: AppStrings.visible,
                symbol: "rectangle.connected.to.line.below",
                tint: .blue
            )
            SummaryMetric(
                value: "\(model.readyDeviceCount)",
                label: AppStrings.ready,
                symbol: "checkmark.circle.fill",
                tint: .green
            )
            SummaryMetric(
                value: "ADB",
                label: AppStrings.transport,
                symbol: "cable.connector",
                tint: .orange
            )
        }
    }

    @ViewBuilder
    private var deviceContent: some View {
        if model.devices.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
                Text(model.phase == .loading ? AppStrings.lookingForDevices : AppStrings.noDevices)
                    .font(.title3.weight(.semibold))
                Text(AppStrings.noDevicesDetail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 230)
            .padding(24)
            .background(cardBackground)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(model.devices) { device in
                    DeviceCard(device: device, stale: model.isShowingStaleDevices)
                }
            }
        }
    }

    private var failureBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(failureTitle)
                    .font(.headline)
                Text(model.isShowingStaleDevices
                     ? AppStrings.staleDeviceDetail
                     : AppStrings.discoveryFailureDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var failureTitle: String {
        switch model.failure {
        case .adbUnavailable: return AppStrings.adbUnavailable
        case .timedOut: return AppStrings.discoveryTimedOut
        case .unavailable, .none: return AppStrings.discoveryUnavailable
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            }
    }
}

private struct SummaryMetric: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DeviceCard: View {
    let device: DeviceDiscoveryItem
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: "smartphone")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(stateColor)
                    .frame(width: 42, height: 42)
                    .background(stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                Spacer()
                Label(stateLabel, systemImage: stateSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(device.modelName ?? AppStrings.androidDevice)
                    .font(.headline)
                    .lineLimit(1)
                if let productName = device.productName,
                   productName.caseInsensitiveCompare(device.modelName ?? "") != .orderedSame {
                    Text(productName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Label("ADB", systemImage: "cable.connector")
                Spacer()
                if stale {
                    Label(AppStrings.stale, systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(17)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(stateColor.opacity(0.18))
        }
        .opacity(stale ? 0.72 : 1)
        .accessibilityElement(children: .combine)
    }

    private var stateLabel: String {
        switch device.connectionState {
        case .ready: return AppStrings.ready
        case .unauthorized: return AppStrings.unauthorized
        case .offline: return AppStrings.offline
        case .unavailable: return AppStrings.unavailable
        }
    }

    private var stateSymbol: String {
        switch device.connectionState {
        case .ready: return "checkmark.circle.fill"
        case .unauthorized: return "lock.trianglebadge.exclamationmark"
        case .offline: return "wifi.slash"
        case .unavailable: return "exclamationmark.circle"
        }
    }

    private var stateColor: Color {
        switch device.connectionState {
        case .ready: return .green
        case .unauthorized: return .orange
        case .offline, .unavailable: return .secondary
        }
    }
}
