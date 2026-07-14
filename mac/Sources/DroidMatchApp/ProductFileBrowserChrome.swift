import SwiftUI

/**
 Stateless visual chrome for the authenticated file browser.

 The parent view keeps navigation, selection, native panels, and transfer-queue
 ownership. These components receive only display values and bounded actions, so
 moving layout code cannot create a second browser or transfer state machine.

 中文：本文件只承载认证文件浏览器的无状态视觉组件；导航、选择、原生面板与传输
 队列仍由父视图唯一持有，避免视觉拆分复制产品状态。
 */
struct ProductFileBrowserDropOverlay: View {
    let isTargeted: Bool

    @ViewBuilder
    var body: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .background(Color.accentColor.opacity(0.08))
                .overlay {
                    Label(AppStrings.dropFilesToUpload, systemImage: "arrow.down.doc.fill")
                        .font(.title3.weight(.semibold))
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(8)
                .allowsHitTesting(false)
        }
    }
}

struct ProductFileBrowserHeader: View {
    let locationTitle: String
    let selectedCount: Int?
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.authenticatedFiles)
                    .font(.headline)
                Text(locationTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let selectedCount {
                Text(AppStrings.selectedCount(selectedCount))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

struct ProductFileBrowserEmptyState: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(isSearching ? AppStrings.noSearchResults : AppStrings.folderIsEmpty)
                .font(.title3.weight(.semibold))
            Text(isSearching
                ? AppStrings.noSearchResultsDetail
                : AppStrings.folderIsEmptyDetail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProductFileBrowserFailureBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button(AppStrings.tryAgain, action: retry)
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }
}

struct ProductFileBrowserNewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let create: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppStrings.newFolder).font(.title2.weight(.semibold))
            TextField(AppStrings.folderName, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button(AppStrings.cancel) { dismiss() }
                Button(AppStrings.create) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func submit() {
        create(name)
    }
}

struct ProductFileBrowserRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let rename: (String) -> Void

    init(initialName: String, rename: @escaping (String) -> Void) {
        _name = State(initialValue: initialName)
        self.rename = rename
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppStrings.renameItem).font(.title2.weight(.semibold))
            TextField(AppStrings.newName, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { rename(name) }
            HStack {
                Spacer()
                Button(AppStrings.cancel) { dismiss() }
                Button(AppStrings.rename) { rename(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

enum ProductFileSubmissionFailure: String, Identifiable {
    case download
    case upload
    case droppedFiles
    case batchDownload

    var id: Self { self }

    var title: String {
        switch self {
        case .download: return AppStrings.downloadCouldNotStart
        case .upload: return AppStrings.uploadCouldNotStart
        case .droppedFiles: return AppStrings.droppedFilesInvalid
        case .batchDownload: return AppStrings.batchDownloadCouldNotStart
        }
    }

    var detail: String {
        switch self {
        case .download: return AppStrings.downloadCouldNotStartDetail
        case .upload: return AppStrings.uploadCouldNotStartDetail
        case .droppedFiles: return AppStrings.droppedFilesInvalidDetail
        case .batchDownload: return AppStrings.batchDownloadCouldNotStartDetail
        }
    }
}
