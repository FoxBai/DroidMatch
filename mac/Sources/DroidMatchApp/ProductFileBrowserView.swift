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
    @State private var isPresentingNewFolder = false
    @State private var renameEntry: DirectoryBrowserItem?
    @State private var mutationAlertTitle = AppStrings.folderCouldNotBeCreated
    @State private var deleteEntry: DirectoryBrowserItem?
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var isSelecting = false
    @State private var selectedPaths = Set<String>()
    @State private var isConfirmingBatchDelete = false
    @State private var isDropTarget = false

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
        .overlay {
            if isDropTarget {
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
        .dropDestination(for: URL.self) { urls, _ in
            acceptDroppedFiles(urls)
        } isTargeted: { targeted in
            isDropTarget = targeted && canAcceptDrop
        }
        .navigationTitle(AppStrings.files)
        .searchable(text: $searchText, prompt: AppStrings.searchFiles)
        .onChange(of: searchText) { value in
            scheduleSearch(value)
        }
        .onDisappear { searchTask?.cancel() }
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

                Button {
                    model.clearMutationFailure()
                    mutationAlertTitle = AppStrings.folderCouldNotBeCreated
                    isPresentingNewFolder = true
                } label: {
                    Label(AppStrings.newFolder, systemImage: "folder.badge.plus")
                }
                .disabled(!currentDirectoryCanWrite || model.query == nil || isBusy)

                Button {
                    isSelecting.toggle()
                    if !isSelecting { selectedPaths.removeAll() }
                } label: {
                    Label(
                        isSelecting ? AppStrings.done : AppStrings.select,
                        systemImage: isSelecting ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
                .disabled(model.entries.isEmpty || isBusy)

                if isSelecting {
                    Button {
                        chooseBatchDownloadDirectory()
                    } label: {
                        Label(AppStrings.downloadSelected, systemImage: "arrow.down.doc")
                    }
                    .disabled(!canDownloadSelection || isBusy)

                    Button(role: .destructive) {
                        isConfirmingBatchDelete = true
                    } label: {
                        Label(AppStrings.delete, systemImage: "trash")
                    }
                    .disabled(!canDeleteSelection || isBusy)
                }
            }
        }
        .alert(item: $submissionFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.detail),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
        .sheet(isPresented: $isPresentingNewFolder) {
            NewFolderSheet { name in
                if model.createDirectory(named: name) {
                    isPresentingNewFolder = false
                }
            }
        }
        .sheet(item: $renameEntry) { entry in
            RenameItemSheet(initialName: entry.name ?? "") { name in
                mutationAlertTitle = AppStrings.itemCouldNotBeRenamed
                if model.rename(entry, to: name) {
                    renameEntry = nil
                }
            }
        }
        .confirmationDialog(
            AppStrings.deleteItem,
            isPresented: deleteConfirmationPresented,
            presenting: deleteEntry
        ) { entry in
            Button(AppStrings.delete, role: .destructive) {
                mutationAlertTitle = AppStrings.itemCouldNotBeDeleted
                _ = model.delete(entry)
                deleteEntry = nil
            }
            Button(AppStrings.cancel, role: .cancel) { deleteEntry = nil }
        } message: { entry in
            Text(entry.kind == .directory
                ? AppStrings.deleteFolderDetail
                : AppStrings.deleteFileDetail)
        }
        .confirmationDialog(
            AppStrings.deleteSelectedItems,
            isPresented: $isConfirmingBatchDelete
        ) {
            Button(AppStrings.delete, role: .destructive) { deleteSelection() }
            Button(AppStrings.cancel, role: .cancel) {}
        } message: {
            Text(AppStrings.deleteSelectedItemsDetail)
        }
        .alert(
            mutationAlertTitle,
            isPresented: mutationFailurePresented
        ) {
            Button(AppStrings.dismiss) { model.clearMutationFailure() }
        } message: {
            Text(mutationFailureText)
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
            if isSelecting {
                Text(AppStrings.selectedCount(selectedPaths.count))
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
                Text(searchText.isEmpty ? AppStrings.folderIsEmpty : AppStrings.noSearchResults)
                    .font(.title3.weight(.semibold))
                Text(searchText.isEmpty
                    ? AppStrings.folderIsEmptyDetail
                    : AppStrings.noSearchResultsDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.entries) { entry in
                    FileEntryRow(
                        entry: entry,
                        open: { open(entry) },
                        download: { chooseDownloadDestination(for: entry) },
                        rename: { renameEntry = entry },
                        delete: { deleteEntry = entry },
                        isSelecting: isSelecting,
                        isSelected: selectedPaths.contains(entry.path),
                        toggleSelection: { toggleSelection(entry) }
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
        if model.isMutating { return true }
        switch model.phase {
        case .loading, .refreshing, .loadingMore: return true
        case .idle, .loaded, .failed: return false
        }
    }

    private var mutationFailurePresented: Binding<Bool> {
        Binding(
            get: { model.mutationFailure != nil },
            set: { if !$0 { model.clearMutationFailure() } }
        )
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deleteEntry != nil },
            set: { if !$0 { deleteEntry = nil } }
        )
    }

    private var mutationFailureText: String {
        switch model.mutationFailure {
        case .invalidName: return AppStrings.folderNameInvalid
        case .permissionRequired: return AppStrings.folderPermissionRequired
        case .alreadyExists: return AppStrings.folderAlreadyExists
        case .notFound: return AppStrings.folderParentUnavailable
        case .unsupported: return AppStrings.folderCreationUnsupported
        case .partialFailure: return AppStrings.someItemsCouldNotBeDeleted
        case .unavailable, .none: return AppStrings.folderCreationUnavailable
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
        selectedPaths.removeAll()
        isSelecting = false
        currentDirectoryCanWrite = entry.canWrite
        searchTask?.cancel()
        searchText = ""
        model.load(
            DirectoryListingQuery(
                path: entry.path,
                pageSize: current.pageSize,
                sortField: current.sortField,
                descending: current.descending,
                searchQuery: ""
            )
        )
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        currentDirectoryCanWrite = previous.canWrite
        selectedPaths.removeAll()
        isSelecting = false
        searchTask?.cancel()
        searchText = previous.query.searchQuery
        model.load(previous.query)
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        guard let current = model.query, value != current.searchQuery else { return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let query = model.query else { return }
            model.load(DirectoryListingQuery(
                path: query.path,
                pageSize: query.pageSize,
                sortField: query.sortField,
                descending: query.descending,
                searchQuery: value
            ))
        }
    }

    private func toggleSelection(_ entry: DirectoryBrowserItem) {
        guard (entry.kind == .file && (entry.canRead || entry.canWrite))
                || (entry.kind == .directory && entry.canWrite) else { return }
        if !selectedPaths.insert(entry.path).inserted {
            selectedPaths.remove(entry.path)
        }
    }

    private func deleteSelection() {
        let selected = model.entries.filter { selectedPaths.contains($0.path) }
        mutationAlertTitle = AppStrings.someItemsCouldNotBeDeleted
        if model.delete(selected) {
            selectedPaths.removeAll()
            isSelecting = false
        }
    }

    private var selectedEntries: [DirectoryBrowserItem] {
        model.entries.filter { selectedPaths.contains($0.path) }
    }

    private var canDeleteSelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy {
            $0.canWrite && ($0.kind == .file || $0.kind == .directory)
        }
    }

    private var canDownloadSelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy {
            $0.kind == .file && $0.canRead
        }
    }

    private func chooseBatchDownloadDirectory() {
        guard canDownloadSelection else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let directoryURL = panel.url else { return }
            Task { @MainActor in submitBatchDownloads(to: directoryURL) }
        }
    }

    private func submitBatchDownloads(to directoryURL: URL) {
        var names = Set<String>()
        var requests: [(sourcePath: String, destinationURL: URL)] = []
        for entry in selectedEntries {
            let name = safeSuggestedName(entry.name)
            let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
            let destination = directoryURL.appendingPathComponent(name, isDirectory: false)
            guard names.insert(normalized).inserted,
                  !FileManager.default.fileExists(atPath: destination.path) else {
                submissionFailure = .batchDownload
                return
            }
            requests.append((entry.path, destination))
        }
        Task { @MainActor in
            let ids = await transferQueue.submitDownloads(requests)
            if ids.count != requests.count {
                submissionFailure = .batchDownload
            } else {
                selectedPaths.removeAll()
                isSelecting = false
            }
        }
    }

    private var canAcceptDrop: Bool {
        allowsUpload && currentDirectoryCanWrite && model.query != nil && !isBusy
    }

    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard canAcceptDrop,
              let directoryPath = model.query?.path,
              !urls.isEmpty,
              urls.count <= 100 else {
            submissionFailure = .droppedFiles
            return false
        }
        var names = Set<String>()
        let files = urls.filter { url in
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            let normalizedName = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            return !normalizedName.isEmpty && names.insert(normalizedName).inserted
        }
        guard files.count == urls.count else {
            submissionFailure = .droppedFiles
            return false
        }
        Task { @MainActor in
            let ids = await transferQueue.submitUploads(
                sourceURLs: files,
                directoryPath: directoryPath
            )
            if ids.count != files.count {
                submissionFailure = .droppedFiles
            }
        }
        return true
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

private struct NewFolderSheet: View {
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

private struct RenameItemSheet: View {
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

private enum FileSubmissionFailure: String, Identifiable {
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

private struct FileEntryRow: View {
    let entry: DirectoryBrowserItem
    let open: () -> Void
    let download: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let isSelecting: Bool
    let isSelected: Bool
    let toggleSelection: () -> Void

    var body: some View {
        Button(action: isSelecting ? toggleSelection : primaryAction) {
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
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .blue : .secondary)
                } else if entry.canWrite {
                    if entry.kind == .file || entry.kind == .directory {
                        Button(action: rename) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(AppStrings.rename)
                        Button(action: delete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help(AppStrings.delete)
                    } else {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .help(AppStrings.writable)
                    }
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
        .disabled(isSelecting ? !canSelect : (!canOpen && !canDownload))
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


    private var canSelect: Bool {
        (entry.kind == .file && (entry.canRead || entry.canWrite))
            || (entry.kind == .directory && entry.canWrite)
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
