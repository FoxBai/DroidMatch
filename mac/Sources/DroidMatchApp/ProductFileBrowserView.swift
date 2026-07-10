import AppKit
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductFileBrowserView: View {
    @ObservedObject var model: DirectoryBrowserModel
    @ObservedObject var transferQueue: TransferQueueModel
    let allowsUpload: Bool
    @State private var history: [BrowserLocation] = []
    @State private var currentDirectoryCanWrite = false
    @State private var submissionFailure: FileSubmissionFailure?

    var body: some View {
        VStack(spacing: 0) {
            browserHeader
            Divider()
            if model.phase == .failed {
                failureBanner
            }
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(AppStrings.files)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    goBack()
                } label: {
                    Label(AppStrings.back, systemImage: "chevron.left")
                }
                .disabled(history.isEmpty || isBusy)

                Button {
                    model.refresh()
                } label: {
                    Label(AppStrings.refresh, systemImage: "arrow.clockwise")
                }
                .disabled(model.query == nil || isBusy)

                Button {
                    chooseUploadSource()
                } label: {
                    Label(AppStrings.upload, systemImage: "arrow.up.doc")
                }
                .disabled(
                    !allowsUpload
                        || !currentDirectoryCanWrite
                        || model.query == nil
                        || isBusy
                )
            }
        }
        .alert(item: $submissionFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.detail),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
    }

    private var browserHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.authenticatedFiles)
                    .font(.headline)
                Text(model.query?.path ?? "dm://roots/")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && isBusy {
            ProgressView(AppStrings.loadingFiles)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(AppStrings.folderIsEmpty)
                    .font(.title3.weight(.semibold))
                Text(AppStrings.folderIsEmptyDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.entries) { entry in
                    FileEntryRow(
                        entry: entry,
                        open: { open(entry) },
                        download: { chooseDownloadDestination(for: entry) }
                    )
                }
                if model.canLoadMore {
                    HStack {
                        Spacer()
                        Button(AppStrings.loadMore) {
                            model.loadMore()
                        }
                        .disabled(isBusy)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(.inset)
        }
    }

    private var failureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(failureText)
                .font(.subheadline)
            Spacer()
            Button(AppStrings.tryAgain) {
                if model.query != nil {
                    model.refresh()
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    private var isBusy: Bool {
        switch model.phase {
        case .loading, .refreshing, .loadingMore: return true
        case .idle, .loaded, .failed: return false
        }
    }

    private var failureText: String {
        switch model.failure {
        case .permissionRequired: return AppStrings.filePermissionRequired
        case .notFound: return AppStrings.fileLocationUnavailable
        case .unsupported: return AppStrings.fileOperationUnsupported
        case .invalidRequest, .invalidResponse: return AppStrings.fileResponseInvalid
        case .unavailable, .none: return AppStrings.fileConnectionUnavailable
        }
    }

    private func open(_ entry: DirectoryBrowserItem) {
        guard entry.kind == .directory || entry.kind == .virtual,
              let current = model.query else { return }
        history.append(BrowserLocation(
            query: current,
            canWrite: currentDirectoryCanWrite
        ))
        currentDirectoryCanWrite = entry.canWrite
        model.load(
            DirectoryListingQuery(
                path: entry.path,
                pageSize: current.pageSize,
                sortField: current.sortField,
                descending: current.descending
            )
        )
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        currentDirectoryCanWrite = previous.canWrite
        model.load(previous.query)
    }

    private func chooseDownloadDestination(for entry: DirectoryBrowserItem) {
        guard entry.kind == .file, entry.canRead else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = safeSuggestedName(entry.name)
        panel.begin { response in
            guard response == .OK,
                  let destinationURL = panel.url,
                  destinationURL.isFileURL else { return }
            Task { @MainActor in
                let id = await transferQueue.submitDownload(
                    sourcePath: entry.path,
                    destinationURL: destinationURL
                )
                if id == nil {
                    submissionFailure = .download
                }
            }
        }
    }

    private func chooseUploadSource() {
        guard allowsUpload,
              currentDirectoryCanWrite,
              let directoryPath = model.query?.path else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK,
                  let sourceURL = panel.url,
                  sourceURL.isFileURL else { return }
            Task { @MainActor in
                let id = await transferQueue.submitUpload(
                    sourceURL: sourceURL,
                    directoryPath: directoryPath
                )
                if id == nil {
                    submissionFailure = .upload
                }
            }
        }
    }

    private func safeSuggestedName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return AppStrings.download }
        let basename = URL(fileURLWithPath: name).lastPathComponent
        let bidirectionalFormatting = CharacterSet(charactersIn:
            "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        let filtered = basename.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !bidirectionalFormatting.contains($0)
        }
        let value = String(String.UnicodeScalarView(filtered))
        guard !value.isEmpty, value != ".", value != ".." else {
            return AppStrings.download
        }
        return value
    }
}

private struct BrowserLocation {
    let query: DirectoryListingQuery
    let canWrite: Bool
}

private enum FileSubmissionFailure: String, Identifiable {
    case download
    case upload

    var id: Self { self }

    var title: String {
        switch self {
        case .download: return AppStrings.downloadCouldNotStart
        case .upload: return AppStrings.uploadCouldNotStart
        }
    }

    var detail: String {
        switch self {
        case .download: return AppStrings.downloadCouldNotStartDetail
        case .upload: return AppStrings.uploadCouldNotStartDetail
        }
    }
}

private struct FileEntryRow: View {
    let entry: DirectoryBrowserItem
    let open: () -> Void
    let download: () -> Void

    var body: some View {
        Button(action: primaryAction) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name ?? AppStrings.unnamedItem)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let size = entry.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let mimeType = entry.mimeType {
                            Text(mimeType)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.canWrite {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                        .help(AppStrings.writable)
                }
                if canOpen {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else if canDownload {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!canOpen && !canDownload)
        .accessibilityHint(
            canOpen ? AppStrings.openFolder : (canDownload ? AppStrings.downloadFile : "")
        )
    }

    private var canOpen: Bool {
        entry.kind == .directory || entry.kind == .virtual
    }

    private var canDownload: Bool {
        entry.kind == .file && entry.canRead
    }

    private func primaryAction() {
        if canOpen {
            open()
        } else if canDownload {
            download()
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .virtual: return "externaldrive.fill"
        case .file: return "doc.fill"
        case .symlink: return "link"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .directory: return .blue
        case .virtual: return .orange
        case .file, .symlink: return .secondary
        }
    }
}
