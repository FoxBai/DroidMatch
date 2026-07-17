import DroidMatchPresentation
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
    let contextTitle: String
    let locationTitle: String
    let selectedCount: Int?
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(contextTitle)
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
    let isMediaDirectory: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isMediaDirectory ? "photo.stack" : "folder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(isSearching
                ? AppStrings.noSearchResults
                : (isMediaDirectory ? AppStrings.mediaLocationIsEmpty : AppStrings.folderIsEmpty))
                .font(.title3.weight(.semibold))
            Text(isSearching
                ? (isMediaDirectory
                    ? AppStrings.noMediaSearchResultsDetail
                    : AppStrings.noSearchResultsDetail)
                : (isMediaDirectory
                    ? AppStrings.mediaLocationIsEmptyDetail
                    : AppStrings.folderIsEmptyDetail))
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
                .accessibilityHidden(true)
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

/// Shared product status for the fail-closed bookmark/queue persistence path.
/// Browsing and remote mutations remain usable; only transfer admission is
/// blocked until the authoritative App-owned stores are checked or recover.
struct ProductTransferPersistenceBanner: View {
    @ObservedObject var model: TransferQueueModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isPreparing
                ? "externaldrive.badge.timemachine"
                : "externaldrive.badge.exclamationmark")
                .foregroundStyle(isPreparing ? Color.orange : Color.red)
                .accessibilityHidden(true)
            Text(isPreparing
                ? AppStrings.queuePersistencePreparing
                : AppStrings.queuePersistenceFailed)
                .font(.subheadline)
            Spacer()
            if isPreparing || model.isRetryingPersistence {
                ProgressView()
                    .controlSize(.small)
            }
            if !isPreparing {
                Button(AppStrings.tryAgain) {
                    Task { @MainActor in await model.retryPersistence() }
                }
                .controlSize(.small)
                .disabled(
                    model.isRetryingPersistence
                        || model.isSubmittingTransfer
                        || model.isClearingCompleted
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background((isPreparing ? Color.orange : Color.red).opacity(0.08))
    }

    private var isPreparing: Bool { !model.isPersistenceStatusKnown }
}

struct ProductFileBrowserNewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failure: ProductFileBrowserMutationSheetFailure?
    let create: (String) -> ProductFileBrowserMutationSheetFailure?

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
        .alert(item: $failure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.detail),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
    }

    private func submit() {
        failure = create(name)
    }
}

struct ProductFileBrowserRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: ProductFileBrowserMutationSheetFailure?
    let rename: (String) -> ProductFileBrowserMutationSheetFailure?

    init(
        initialName: String,
        rename: @escaping (String) -> ProductFileBrowserMutationSheetFailure?
    ) {
        _name = State(initialValue: initialName)
        self.rename = rename
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppStrings.renameItem).font(.title2.weight(.semibold))
            TextField(AppStrings.newName, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button(AppStrings.cancel) { dismiss() }
                Button(AppStrings.rename) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .alert(item: $failure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.detail),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
    }

    private func submit() {
        failure = rename(name)
    }
}

struct ProductFileBrowserMutationSheetFailure: Identifiable {
    let title: String
    let detail: String

    var id: String { title }
}

extension DirectoryMutationOperation {
    var alertTitle: String {
        switch self {
        case .createDirectory: return AppStrings.folderCouldNotBeCreated
        case .renameItem: return AppStrings.itemCouldNotBeRenamed
        case .deleteItem: return AppStrings.itemCouldNotBeDeleted
        case .deleteItems: return AppStrings.someItemsCouldNotBeDeleted
        }
    }

    func localizedDetail(for failure: DirectoryMutationPresentationFailure?) -> String {
        switch guidance(for: failure) {
        case .invalidName: return AppStrings.folderNameInvalid
        case .staleItem: return AppStrings.itemChangedBeforeMutation
        case .permissionRequired: return AppStrings.folderPermissionRequired
        case .alreadyExists: return AppStrings.folderAlreadyExists
        case .locationUnavailable: return AppStrings.folderParentUnavailable
        case .itemUnavailable: return AppStrings.itemUnavailableForMutation
        case .createUnsupported: return AppStrings.folderCreationUnsupported
        case .renameUnsupported: return AppStrings.renameUnsupported
        case .deleteUnsupported: return AppStrings.deleteUnsupported
        case .createUnavailable: return AppStrings.folderCreationUnavailable
        case .renameUnavailable: return AppStrings.renameUnavailable
        case .deleteUnavailable: return AppStrings.deleteUnavailable
        case .batchDeleteUnavailable: return AppStrings.batchDeleteUnavailable
        case .partialDeletion: return AppStrings.partialDeletionDetail
        }
    }
}

enum ProductFileSubmissionFailure: String, Identifiable {
    case download
    case upload
    case batchUpload
    case batchUploadUnavailable
    case batchUploadPartial
    case droppedFiles
    case batchDownload
    case batchDownloadUnavailable
    case batchDownloadPartial

    var id: Self { self }

    var title: String {
        switch self {
        case .download: return AppStrings.downloadCouldNotStart
        case .upload: return AppStrings.uploadCouldNotStart
        case .batchUpload: return AppStrings.batchUploadCouldNotStart
        case .batchUploadUnavailable: return AppStrings.batchUploadUnavailable
        case .batchUploadPartial: return AppStrings.batchUploadPartiallyStarted
        case .droppedFiles: return AppStrings.droppedFilesInvalid
        case .batchDownload: return AppStrings.batchDownloadCouldNotStart
        case .batchDownloadUnavailable: return AppStrings.batchDownloadUnavailable
        case .batchDownloadPartial: return AppStrings.batchDownloadPartiallyStarted
        }
    }

    var detail: String {
        switch self {
        case .download: return AppStrings.downloadCouldNotStartDetail
        case .upload: return AppStrings.uploadCouldNotStartDetail
        case .batchUpload: return AppStrings.batchUploadCouldNotStartDetail
        case .batchUploadUnavailable: return AppStrings.batchUploadUnavailableDetail
        case .batchUploadPartial: return AppStrings.batchUploadPartiallyStartedDetail
        case .droppedFiles: return AppStrings.droppedFilesInvalidDetail
        case .batchDownload: return AppStrings.batchDownloadCouldNotStartDetail
        case .batchDownloadUnavailable: return AppStrings.batchDownloadUnavailableDetail
        case .batchDownloadPartial: return AppStrings.batchDownloadPartiallyStartedDetail
        }
    }

    static func uploadSelection(count: Int) -> Self {
        count == 1 ? .upload : .batchUpload
    }

    static func uploadSubmission(count: Int, acceptedCount: Int) -> Self {
        guard count > 1 else { return .upload }
        return acceptedCount == 0 ? .batchUploadUnavailable : .batchUploadPartial
    }

    static func downloadSubmission(acceptedCount: Int) -> Self {
        acceptedCount == 0 ? .batchDownloadUnavailable : .batchDownloadPartial
    }
}
