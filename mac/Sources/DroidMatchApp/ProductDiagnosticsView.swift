import AppKit
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI
import UniformTypeIdentifiers

struct ProductDiagnosticsView: View {
    @ObservedObject var model: DeviceDiagnosticsModel
    @State private var exportFailed = false

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.phase == .failed {
                    failureBanner
                }
                if let snapshot = model.snapshot {
                    overview(snapshot)
                    permissions(snapshot)
                    activity(snapshot)
                } else if model.phase == .loading {
                    ProgressView(AppStrings.loadingDiagnostics)
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(AppStrings.diagnostics)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportSupportReport()
                } label: {
                    Label(AppStrings.exportDiagnostics, systemImage: "square.and.arrow.up")
                }
                .disabled(model.snapshot == nil)

                Button {
                    model.refresh()
                } label: {
                    Label(AppStrings.refresh, systemImage: "arrow.clockwise")
                }
                .disabled(model.phase == .loading || model.phase == .refreshing)
            }
        }
        .alert(AppStrings.diagnosticsExportFailed, isPresented: $exportFailed) {
            Button(AppStrings.dismiss) {}
        } message: {
            Text(AppStrings.diagnosticsExportFailedDetail)
        }
    }

    private func exportSupportReport() {
        guard let snapshot = model.snapshot else { return }
        let context = supportReportContext
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "DroidMatch-Diagnostics.json"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                let data = try DiagnosticsSupportBundleEncoder.encode(
                    snapshot,
                    context: context
                )
                try data.write(to: destination, options: .atomic)
            } catch {
                exportFailed = true
            }
        }
    }

    private var supportReportContext: DiagnosticsSupportBundleContext {
        DiagnosticsSupportBundleContext(
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            snapshotFreshness: model.isShowingStaleSnapshot ? .stale : .fresh
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 48, height: 48)
                .background(Color.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AppStrings.deviceHealth)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(AppStrings.deviceHealthDetail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .refreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func overview(_ snapshot: ProductDeviceDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppStrings.overview)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                DiagnosticMetric(
                    symbol: "smartphone",
                    tint: .blue,
                    title: AppStrings.device,
                    value: deviceName(snapshot),
                    detail: snapshot.manufacturer
                )
                DiagnosticMetric(
                    symbol: "cpu",
                    tint: .purple,
                    title: AppStrings.system,
                    value: androidVersion(snapshot),
                    detail: snapshot.sdkLevel.map { String(format: AppStrings.apiLevel, $0) }
                )
                DiagnosticMetric(
                    symbol: "externaldrive.fill",
                    tint: .orange,
                    title: AppStrings.storage,
                    value: storageValue(snapshot),
                    detail: storageDetail(snapshot)
                )
                DiagnosticMetric(
                    symbol: "battery.75percent",
                    tint: batteryTint(snapshot.batteryPercent),
                    title: AppStrings.battery,
                    value: snapshot.batteryPercent.map { "\($0)%" } ?? AppStrings.notAvailable,
                    detail: nil
                )
                DiagnosticMetric(
                    symbol: "lock.shield.fill",
                    tint: serviceTint(snapshot.serviceState),
                    title: AppStrings.service,
                    value: serviceLabel(snapshot.serviceState),
                    detail: AppStrings.pairedProofVerified
                )
                DiagnosticMetric(
                    symbol: snapshot.recentErrorCount == 0
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill",
                    tint: snapshot.recentErrorCount == 0 ? .green : .orange,
                    title: AppStrings.recentIssues,
                    value: "\(snapshot.recentErrorCount)",
                    detail: AppStrings.errorDetailsStayPrivate
                )
            }
        }
    }

    private func permissions(_ snapshot: ProductDeviceDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppStrings.androidPermissions)
            VStack(spacing: 0) {
                ForEach(snapshot.permissions) { permission in
                    HStack(spacing: 12) {
                        Image(systemName: permissionSymbol(permission.kind))
                            .foregroundStyle(permissionTint(permission.state))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(permissionLabel(permission.kind))
                        Spacer()
                        Text(permissionStateLabel(permission.state))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(permissionTint(permission.state))
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
                    if permission.id != snapshot.permissions.last?.id {
                        Divider().padding(.leading, 51)
                    }
                }
            }
            .background(cardBackground)
        }
    }

    @ViewBuilder
    private func activity(_ snapshot: ProductDeviceDiagnosticsSnapshot) -> some View {
        let visibleCounters = ProductDiagnosticCounterKind.allCases.compactMap { kind in
            snapshot.counters[kind].map { (kind, $0) }
        }
        if !visibleCounters.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppStrings.sessionActivity)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(visibleCounters, id: \.0) { kind, value in
                        DiagnosticMetric(
                            symbol: counterSymbol(kind),
                            tint: .secondary,
                            title: counterLabel(kind),
                            value: counterValue(kind, value),
                            detail: nil
                        )
                    }
                }
            }
        }
    }

    private var failureBanner: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.diagnosticsUnavailable)
                    .font(.headline)
                Text(failureText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isShowingStaleSnapshot {
                Label(AppStrings.stale, systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value)
            .font(.title3.weight(.semibold))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            }
    }

    private var failureText: String {
        switch model.failure {
        case .sessionUnavailable: return AppStrings.diagnosticsSessionUnavailable
        case .unsupported: return AppStrings.diagnosticsUnsupported
        case .invalidResponse: return AppStrings.diagnosticsInvalidResponse
        case .unavailable, .none: return AppStrings.diagnosticsConnectionUnavailable
        }
    }

    private func deviceName(_ snapshot: ProductDeviceDiagnosticsSnapshot) -> String {
        snapshot.model ?? snapshot.manufacturer ?? AppStrings.androidDevice
    }

    private func androidVersion(_ snapshot: ProductDeviceDiagnosticsSnapshot) -> String {
        snapshot.androidVersion.map { "Android \($0)" } ?? AppStrings.notAvailable
    }

    private func storageValue(_ snapshot: ProductDeviceDiagnosticsSnapshot) -> String {
        guard let free = snapshot.freeStorageBytes else { return AppStrings.notAvailable }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    private func storageDetail(_ snapshot: ProductDeviceDiagnosticsSnapshot) -> String? {
        guard let total = snapshot.totalStorageBytes else { return nil }
        return String(
            format: AppStrings.totalStorage,
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }

    private func batteryTint(_ percent: Int?) -> Color {
        guard let percent else { return .secondary }
        if percent <= 15 { return .red }
        if percent <= 30 { return .orange }
        return .green
    }

    private func serviceTint(_ state: ProductServiceState) -> Color {
        switch state {
        case .connected, .available: return .green
        case .degraded: return .orange
        case .unavailable: return .red
        case .unknown: return .secondary
        }
    }

    private func serviceLabel(_ state: ProductServiceState) -> String {
        switch state {
        case .connected: return AppStrings.connected
        case .available: return AppStrings.available
        case .degraded: return AppStrings.degraded
        case .unavailable: return AppStrings.unavailable
        case .unknown: return AppStrings.unknown
        }
    }

    private func permissionLabel(_ kind: ProductPermissionKind) -> String {
        switch kind {
        case .mediaRead: return AppStrings.mediaLibrary
        case .notifications: return AppStrings.notificationsPermission
        case .safRoots: return AppStrings.sharedFolders
        }
    }

    private func permissionSymbol(_ kind: ProductPermissionKind) -> String {
        switch kind {
        case .mediaRead: return "photo.on.rectangle"
        case .notifications: return "bell.fill"
        case .safRoots: return "folder.badge.gearshape"
        }
    }

    private func permissionStateLabel(_ state: ProductPermissionState) -> String {
        switch state {
        case .granted: return AppStrings.granted
        case .denied: return AppStrings.denied
        case .needsUserAction: return AppStrings.actionNeeded
        case .notApplicable: return AppStrings.notApplicable
        case .unknown: return AppStrings.unknown
        }
    }

    private func permissionTint(_ state: ProductPermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .needsUserAction: return .orange
        case .notApplicable, .unknown: return .secondary
        }
    }

    private func counterLabel(_ kind: ProductDiagnosticCounterKind) -> String {
        switch kind {
        case .framesReceived: return AppStrings.framesReceived
        case .framesSent: return AppStrings.framesSent
        case .handshakesAccepted: return AppStrings.handshakes
        case .authenticationsAccepted: return AppStrings.authentications
        case .authenticationsRejected: return AppStrings.rejectedAuthentications
        case .directoryRequests: return AppStrings.directoryRequests
        case .diagnosticRequests: return AppStrings.diagnosticRequests
        case .transferBytesSent: return AppStrings.bytesSent
        case .transferBytesReceived: return AppStrings.bytesReceived
        case .uploadsCompleted: return AppStrings.transfersCompleted
        }
    }

    private func counterSymbol(_ kind: ProductDiagnosticCounterKind) -> String {
        switch kind {
        case .framesReceived, .transferBytesReceived: return "arrow.down"
        case .framesSent, .transferBytesSent: return "arrow.up"
        case .handshakesAccepted, .authenticationsAccepted: return "checkmark.shield"
        case .authenticationsRejected: return "xmark.shield"
        case .directoryRequests: return "folder"
        case .diagnosticRequests: return "stethoscope"
        case .uploadsCompleted: return "checkmark.circle"
        }
    }

    private func counterValue(_ kind: ProductDiagnosticCounterKind, _ value: Int64) -> String {
        switch kind {
        case .transferBytesSent, .transferBytesReceived:
            return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
        default:
            return value.formatted()
        }
    }
}

private struct DiagnosticMetric: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}
