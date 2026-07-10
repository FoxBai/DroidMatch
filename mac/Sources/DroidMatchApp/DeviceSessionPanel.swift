import DroidMatchPresentation
import SwiftUI

struct DeviceSessionPanel: View {
    @ObservedObject var model: DeviceSessionModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            Spacer(minLength: 10)
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.18))
        }
        .sheet(isPresented: approvalPresented) {
            if let presentation = model.pairingPresentation {
                PairingApprovalView(
                    deviceName: presentation.androidDisplayName,
                    code: presentation.shortAuthenticationString,
                    approve: model.approvePairing,
                    reject: model.rejectPairing
                )
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .pairingRequired:
            HStack {
                Button(AppStrings.startPairing) {
                    model.beginPairing()
                }
                .buttonStyle(.borderedProminent)
                Button(AppStrings.disconnect) {
                    model.disconnect()
                }
            }
            .padding(.top, 3)
        case .ready:
            Button(AppStrings.disconnect) {
                model.disconnect()
            }
            .padding(.top, 3)
        case .failed:
            HStack {
                if let deviceID = model.selectedDeviceID {
                    Button(AppStrings.tryAgain) {
                        model.connect(to: deviceID)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(AppStrings.disconnect) {
                    model.disconnect()
                }
            }
            .padding(.top, 3)
        case .idle, .connecting, .startingPairing, .awaitingApproval,
             .finalizingPairing, .disconnecting:
            EmptyView()
        }
    }

    private var approvalPresented: Binding<Bool> {
        Binding(
            get: { model.phase == .awaitingApproval && model.pairingPresentation != nil },
            set: { presented in
                if !presented, model.phase == .awaitingApproval {
                    model.rejectPairing()
                }
            }
        )
    }

    private var isWorking: Bool {
        switch model.phase {
        case .connecting, .startingPairing, .finalizingPairing, .disconnecting:
            return true
        case .idle, .pairingRequired, .awaitingApproval, .ready, .failed:
            return false
        }
    }

    private var symbol: String {
        switch model.phase {
        case .ready: return "lock.shield.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pairingRequired, .startingPairing, .awaitingApproval, .finalizingPairing:
            return "person.badge.key.fill"
        case .idle, .connecting, .disconnecting: return "cable.connector"
        }
    }

    private var tint: Color {
        switch model.phase {
        case .ready: return .green
        case .failed: return .orange
        case .pairingRequired, .startingPairing, .awaitingApproval, .finalizingPairing:
            return .blue
        case .idle, .connecting, .disconnecting: return .secondary
        }
    }

    private var title: String {
        switch model.phase {
        case .idle: return AppStrings.sessionIdle
        case .connecting: return AppStrings.connectingSecurely
        case .pairingRequired: return AppStrings.pairingRequired
        case .startingPairing: return AppStrings.startingPairing
        case .awaitingApproval: return AppStrings.confirmPairingCode
        case .finalizingPairing: return AppStrings.finishingPairing
        case .ready: return model.sessionInfo?.displayName ?? AppStrings.secureSessionReady
        case .disconnecting: return AppStrings.disconnecting
        case .failed: return AppStrings.connectionFailed
        }
    }

    private var detail: String {
        switch model.phase {
        case .idle: return ""
        case .connecting:
            return AppStrings.connectingSecurelyDetail
        case .pairingRequired:
            return AppStrings.pairingRequiredDetail
        case .startingPairing:
            return AppStrings.startingPairingDetail
        case .awaitingApproval:
            return AppStrings.confirmPairingCodeDetail
        case .finalizingPairing:
            return AppStrings.finishingPairingDetail
        case .ready:
            return AppStrings.secureSessionReadyDetail
        case .disconnecting:
            return AppStrings.disconnectingDetail
        case .failed:
            return failureDetail
        }
    }

    private var failureDetail: String {
        switch model.failure {
        case .deviceUnavailable: return AppStrings.sessionDeviceUnavailable
        case .deviceNotReady: return AppStrings.sessionDeviceNotReady
        case .adbUnavailable: return AppStrings.adbUnavailable
        case .timedOut: return AppStrings.sessionTimedOut
        case .pairingRejected: return AppStrings.sessionPairingRejected
        case .identityChanged: return AppStrings.sessionIdentityChanged
        case .credentialsUnavailable: return AppStrings.sessionCredentialsUnavailable
        case .authenticationFailed: return AppStrings.sessionAuthenticationFailed
        case .connectionUnavailable, .none: return AppStrings.sessionConnectionUnavailable
        }
    }
}

private struct PairingApprovalView: View {
    let deviceName: String
    let code: String
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 38))
                .foregroundStyle(.blue)
            VStack(spacing: 7) {
                Text(AppStrings.confirmPairingCode)
                    .font(.title2.weight(.bold))
                Text(String(format: AppStrings.compareCodeWithDevice, deviceName))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(code)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .tracking(5)
                .padding(.vertical, 8)
                .accessibilityLabel(String(format: AppStrings.pairingCodeAccessibility, code))
            HStack(spacing: 12) {
                Button(AppStrings.codesDoNotMatch, action: reject)
                    .keyboardShortcut(.cancelAction)
                Button(AppStrings.codesMatch, action: approve)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}
