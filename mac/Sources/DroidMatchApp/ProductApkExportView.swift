import AppKit
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductApkExportButton: View {
    @ObservedObject var model: ApkExportModel
    let entry: ApplicationLibraryEntry
    @State private var panel: NSOpenPanel?
    @State private var visible = false

    var body: some View {
        Button { chooseFolder() } label: {
            Label(AppStrings.apkExportTitle, systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(format: AppStrings.apkExportApplication, entry.displayName))
        .disabled(!model.canExport || panel != nil)
        .onAppear { visible = true }
        .onDisappear { visible = false; panel?.cancel(nil); panel = nil }
    }

    private func chooseFolder() {
        guard visible, model.canExport, panel == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false; picker.canCreateDirectories = true
        picker.prompt = AppStrings.apkExportFolder
        picker.message = AppStrings.apkExportDetail
        panel = picker
        picker.begin { response in
            panel = nil
            guard visible, model.canExport, response == .OK, let directory = picker.url else { return }
            let scoped = directory.startAccessingSecurityScopedResource()
            let accepted = model.export(entry: entry, to: directory) {
                if scoped { directory.stopAccessingSecurityScopedResource() }
            }
            if !accepted && scoped { directory.stopAccessingSecurityScopedResource() }
        }
    }
}

struct ProductApkExportStatus: View {
    @ObservedObject var model: ApkExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.apkExportDetail).font(.caption).foregroundStyle(.secondary)
            if model.isBusy {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        if let name = model.selectedName { Text(name).font(.headline).lineLimit(1) }
                        Text(progressLabel).font(.callout)
                    }
                    Spacer()
                    Button(AppStrings.cancel, action: model.cancel).disabled(model.isCancelling)
                }
                if let progress = model.progress, progress.totalBytes > 0, progress.stage == .receiving {
                    ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes))
                        .accessibilityLabel(AppStrings.apkExportTitle)
                } else { ProgressView().controlSize(.small) }
            } else if let failure = model.failure {
                Label(failureLabel(failure), systemImage: "exclamationmark.triangle").font(.callout)
            } else if let name = model.completedFilename {
                Label(String(format: AppStrings.apkExportCompleted, name), systemImage: "checkmark.circle")
                    .font(.callout).textSelection(.enabled)
            } else if model.wasCancelled {
                Text(AppStrings.apkExportCancelled).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var progressLabel: String {
        if model.isCancelling { return AppStrings.apkExportCancelling }
        guard let progress = model.progress else { return AppStrings.apkExportPreparing }
        switch progress.stage {
        case .preparing: return AppStrings.apkExportPreparing
        case .validating: return AppStrings.apkExportValidating
        case .receiving:
            return String(format: AppStrings.apkExportReceiving,
                ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
        }
    }

    private func failureLabel(_ failure: ApkExportError) -> String {
        switch failure {
        case .permissionRequired: return AppStrings.apkExportPermission
        case .sourceChanged: return AppStrings.apkExportChanged
        case .unsupported: return AppStrings.apkExportUnsupported
        case .localFileFailed: return AppStrings.apkExportLocalFailure
        case .commitUncertain: return AppStrings.apkExportUncertain
        default: return AppStrings.apkExportConnection
        }
    }
}
