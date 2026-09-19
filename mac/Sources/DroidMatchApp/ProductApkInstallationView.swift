import AppKit
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI
import UniformTypeIdentifiers

struct ProductApkInstallationView: View {
    @ObservedObject var model: ApkInstallationModel
    @Environment(\.dismiss) private var dismiss
    @State private var viewID = UUID()
    @State private var visible = false
    @State private var panel: NSOpenPanel?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shippingbox").font(.system(size: 32)).foregroundStyle(.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppStrings.apkInstallTitle).font(.title2.bold())
                    Text(AppStrings.apkInstallDetail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(statusHint).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(7)
            }
            if model.isUploading {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.selectedFilename ?? AppStrings.apkInstallTitle).lineLimit(1)
                    if let progress = model.uploadProgress {
                        ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes))
                            .accessibilityLabel(progress.stage == .checkingFile
                                ? AppStrings.apkChecking : AppStrings.apkSending)
                        Text(String(format: progress.stage == .checkingFile ? AppStrings.apkCheckingProgress
                                    : AppStrings.apkSendingProgress, bytes(progress.completedBytes), bytes(progress.totalBytes)))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView(AppStrings.apkPreparing) }
                    Button(AppStrings.apkCancelTransfer, action: model.cancelUpload)
                }
            }
            if let error = model.uploadFailure {
                Label(hint(error), systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(action: chooseApk) { Label(AppStrings.apkChoose, systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(!model.canChooseFile || panel != nil)
                Spacer()
                Button(action: model.refresh) { Label(AppStrings.refresh, systemImage: "arrow.clockwise") }
                    .disabled(model.isRefreshing)
            }
            Divider()
            if model.snapshot?.operations.isEmpty != false {
                VStack(spacing: 9) {
                    Image(systemName: "tray").font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(model.isRefreshing ? AppStrings.apkLoading : AppStrings.apkNoRequests)
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach((model.snapshot?.operations ?? []).reversed()) { operation in
                            operationRow(operation)
                        }
                    }.padding(.trailing, 4)
                }
            }
            HStack {
                Text(AppStrings.apkConfirmationDetail).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(AppStrings.done) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isUploading || model.isCancelling)
            }
        }
        .padding(24)
        .frame(width: 590, height: 590)
        .interactiveDismissDisabled(model.isUploading || model.isCancelling)
        .onAppear { visible = true; model.attach(viewID: viewID) }
        .onDisappear {
            visible = false
            panel?.cancel(nil); panel = nil
            model.detach(viewID: viewID)
        }
    }

    private func operationRow(_ operation: ApkInstallationOperation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(operation.state)).foregroundStyle(operation.state == .succeeded ? .green : .secondary)
                .font(.title3).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(operation.displayName).font(.headline).lineLimit(1)
                Text(bytes(operation.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                Text(stateLabel(operation.state)).font(.callout)
                if operation.state == .failed, let failure = operation.failure {
                    Text(hint(failure)).font(.caption).foregroundStyle(.secondary)
                }
                if operation.state == .uploading {
                    ProgressView(value: Double(operation.uploadedBytes), total: Double(operation.sizeBytes))
                        .accessibilityLabel(AppStrings.apkSending)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if operation.state.canCancel {
                Button(operation.state == .cleanupRequired ? AppStrings.apkRetryCleanup : AppStrings.cancel) {
                    model.cancel(operation: operation)
                }.disabled(model.isUploading || model.isCancelling)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusHint: String {
        if let failure = model.failure { return hint(failure) }
        guard let snapshot = model.snapshot else { return AppStrings.apkLoading }
        if !snapshot.systemSourceTrusted || !snapshot.incomingRequestsEnabled { return AppStrings.apkEnablePhone }
        return snapshot.canStartInstall ? AppStrings.apkReady : AppStrings.apkNeedsAttention
    }

    private func chooseApk() {
        guard visible, model.canChooseFile, panel == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = true; picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false; picker.resolvesAliases = true
        picker.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        picker.prompt = AppStrings.apkChoose
        panel = picker
        picker.begin { response in
            panel = nil
            guard visible, response == .OK, let url = picker.url, model.canChooseFile else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            let accepted = model.upload(sourceURL: url) {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            if !accepted && scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
    private func symbol(_ state: ApkInstallationState) -> String {
        switch state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .outcomeUnknown, .cleanupRequired: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        default: return "shippingbox"
        }
    }
    private func stateLabel(_ state: ApkInstallationState) -> String {
        switch state {
        case .waitingForUpload: return AppStrings.apkWaitingUpload
        case .uploading: return AppStrings.apkSending
        case .waitingForAndroidApproval: return AppStrings.apkWaitingAndroid
        case .submitting: return AppStrings.apkSubmitting
        case .waitingForSystemConfirmation: return AppStrings.apkWaitingSystem
        case .waitingForSystemResult: return AppStrings.apkWaitingResult
        case .succeeded: return AppStrings.apkSucceeded
        case .failed: return AppStrings.apkFailed
        case .cancelled: return AppStrings.apkCancelled
        case .outcomeUnknown: return AppStrings.apkUnknown
        case .cleanupRequired: return AppStrings.apkCleanupRequired
        }
    }
    private func hint(_ failure: ApkInstallationError) -> String {
        switch failure {
        case .unsupported: return AppStrings.apkUnsupported
        case .permissionRequired: return AppStrings.apkEnablePhone
        case .needsAndroidAttention: return AppStrings.apkNeedsAttention
        case .invalidFile: return AppStrings.apkInvalidFile
        case .sourceChanged: return AppStrings.apkSourceChanged
        case .integrityFailure: return AppStrings.apkIntegrityFailed
        case .cancelled: return AppStrings.apkCancelled
        case .connectionUnavailable: return AppStrings.apkConnectionLost
        default: return AppStrings.apkUnavailable
        }
    }
}
