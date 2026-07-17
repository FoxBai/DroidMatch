import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct DeviceDashboardView: View {
    @ObservedObject var model: DeviceDiscoveryModel
    @ObservedObject var sessionModel: DeviceSessionModel
    @ObservedObject var trustedDevicesModel: TrustedDevicesModel
    let openFiles: () -> Void
    @State private var presentedAlert: DeviceDashboardAlert?
    @State private var isRevokingTrust = false

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
                if sessionModel.phase != .idle {
                    DeviceSessionPanel(model: sessionModel, openFiles: openFiles)
                }
                deviceContent
                trustedDevices
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(AppStrings.devices)
        .task {
            trustedDevicesModel.refresh()
        }
        .onChange(of: sessionModel.phase) { phase in
            if phase == .ready {
                // Pairing persists trust after this view's initial load. Refresh
                // secret-free metadata without requiring an App restart.
                trustedDevicesModel.refresh()
            }
        }
        .alert(item: $presentedAlert) { alert in
            switch alert {
            case let .confirmRevocation(device):
                return Alert(
                    title: Text(AppStrings.removeTrustedDevice),
                    message: Text(String(
                        format: AppStrings.removeTrustedDeviceDetail,
                        trustedDeviceName(device)
                    )),
                    primaryButton: .destructive(Text(AppStrings.removeAndDisconnect)) {
                        revoke(device)
                    },
                    secondaryButton: .cancel(Text(AppStrings.keepDevice))
                )
            case .revocationFailed:
                return Alert(
                    title: Text(AppStrings.trustRemovalFailed),
                    message: Text(AppStrings.trustRemovalFailedDetail),
                    dismissButton: .default(Text(AppStrings.dismiss))
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                    trustedDevicesModel.refresh()
                } label: {
                    Label(AppStrings.refresh, systemImage: "arrow.clockwise")
                }
                .disabled(model.phase == .loading || model.phase == .refreshing)
                .help(AppStrings.refreshDevices)
            }
        }
    }

    private var trustedDevices: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppStrings.trustedAndroidDevices)
                        .font(.title2.weight(.semibold))
                    Text(AppStrings.trustedAndroidDevicesDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if trustedDevicesModel.isLoading || trustedDevicesModel.isMutating || isRevokingTrust {
                    ProgressView().controlSize(.small)
                }
            }

            if trustedDevicesModel.isUnavailable {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            AppStrings.trustedDevicesUnavailable,
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        if trustedDevicesModel.isRefreshOutstanding {
                            Text(AppStrings.trustedDevicesSystemRequestPending)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if !trustedDevicesModel.isRefreshOutstanding {
                        Button(AppStrings.tryAgain) {
                            trustedDevicesModel.refresh()
                        }
                        .disabled(!trustedDevicesModel.canRefresh || isRevokingTrust)
                    }
                }
            } else if trustedDevicesModel.items.isEmpty && !trustedDevicesModel.isLoading {
                Text(AppStrings.noTrustedDevices)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trustedDevicesModel.items) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "smartphone.badge.checkmark")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trustedDeviceName(device)).font(.headline)
                            Text(String(
                                format: AppStrings.lastUsed,
                                device.lastUsedAt.formatted(date: .abbreviated, time: .shortened)
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(AppStrings.removeTrust, role: .destructive) {
                            presentedAlert = .confirmRevocation(device)
                        }
                        .disabled(trustedDevicesModel.isMutating || isRevokingTrust)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.top, 4)
    }

    private func revoke(_ device: TrustedDeviceItem) {
        guard !isRevokingTrust else { return }
        isRevokingTrust = true
        Task {
            defer { isRevokingTrust = false }
            await sessionModel.disconnectAndWaitIfNeeded()
            let succeeded = await trustedDevicesModel.revoke(id: device.id)
            if !succeeded {
                presentedAlert = .revocationFailed
            }
        }
    }

    private func trustedDeviceName(_ device: TrustedDeviceItem) -> String {
        device.displayName ?? AppStrings.androidDevice
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
                    .accessibilityHidden(true)
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
                    DeviceCard(
                        device: device,
                        stale: model.isShowingStaleDevices,
                        selected: sessionModel.selectedDeviceID == device.id,
                        sessionBusy: sessionIsBusy,
                        onConnect: { sessionModel.connect(to: device.id) }
                    )
                }
            }
        }
    }

    private var failureBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
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

    private var sessionIsBusy: Bool {
        switch sessionModel.phase {
        case .connecting, .startingPairing, .awaitingApproval,
             .finalizingPairing, .disconnecting:
            return true
        case .idle, .pairingRequired, .ready, .failed:
            return false
        }
    }
}

private enum DeviceDashboardAlert: Identifiable {
    case confirmRevocation(TrustedDeviceItem)
    case revocationFailed

    var id: String {
        switch self {
        case let .confirmRevocation(device):
            return "confirm-revocation-\(device.id.uuidString)"
        case .revocationFailed:
            return "revocation-failed"
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(value), \(label)"))
    }
}

private struct DeviceCard: View {
    let device: DeviceDiscoveryItem
    let stale: Bool
    let selected: Bool
    let sessionBusy: Bool
    let onConnect: () -> Void

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

            Button(selected ? AppStrings.reconnect : AppStrings.connect) {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                stale
                || device.connectionState != .ready
                || sessionBusy
            )
        }
        .padding(17)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(selected ? Color.accentColor : stateColor.opacity(0.18), lineWidth: selected ? 2 : 1)
        }
        .opacity(stale ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(ProductAccessibilityIdentifiers.discoveryDeviceCard)
        .accessibilityLabel(Text(productAccessibilityLabel))
    }

    private var stateLabel: String {
        switch device.connectionState {
        case .ready: return AppStrings.ready
        case .unauthorized: return AppStrings.unauthorized
        case .offline: return AppStrings.offline
        case .unavailable: return AppStrings.unavailable
        }
    }

    private var productAccessibilityLabel: String {
        let modelName = device.modelName ?? AppStrings.androidDevice
        var parts = [modelName]
        if let productName = device.productName,
           productName.caseInsensitiveCompare(modelName) != .orderedSame {
            parts.append(productName)
        }
        parts.append("ADB")
        parts.append(stateLabel)
        if stale {
            parts.append(AppStrings.stale)
        }
        parts.append(selected ? AppStrings.reconnect : AppStrings.connect)
        return parts.joined(separator: ", ")
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
