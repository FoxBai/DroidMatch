import AppKit
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductFileBrowserView: View {
    @ObservedObject var model: DirectoryBrowserModel
    @ObservedObject var transferQueue: TransferQueueModel
    let allowsUpload: Bool
    @State private var submissionFailure: ProductFileSubmissionFailure?
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
    @State private var previewEntry: DirectoryBrowserItem?
    @AppStorage(AppPreferenceKeys.mediaGridByDefault) private var prefersMediaGrid = true

    var body: some View {
        browserSurface
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            ProductFileBrowserDropOverlay(isTargeted: isDropTarget)
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
        .onChange(of: model.entries) { entries in
            selectedPaths.formIntersection(Set(entries.map(\.path)))
        }
        .onDisappear { searchTask?.cancel() }
        .toolbar {
            ProductFileBrowserToolbar(state: toolbarState, actions: toolbarActions)
        }
        .alert(item: $submissionFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.detail),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
        .sheet(isPresented: $isPresentingNewFolder) {
            ProductFileBrowserNewFolderSheet { name in
                if model.createDirectory(named: name) {
                    isPresentingNewFolder = false
                }
            }
        }
        .sheet(item: $renameEntry) { entry in
            ProductFileBrowserRenameSheet(initialName: entry.safeDisplayName ?? "") { name in
                mutationAlertTitle = AppStrings.itemCouldNotBeRenamed
                if model.rename(entry, to: name) {
                    renameEntry = nil
                }
            }
        }
        .sheet(item: $previewEntry, onDismiss: model.clearPreview) { entry in
            MediaPreviewSheet(
                entry: entry,
                model: model,
                download: {
                    previewEntry = nil
                    chooseDownloadDestination(for: entry)
                }
            )
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

    private var browserSurface: some View {
        VStack(spacing: 0) {
            browserHeader
            Divider()
            if model.phase == .failed {
                failureBanner
            }
            content
        }
    }

    private var toolbarState: ProductFileBrowserToolbar.State {
        .init(
            canGoBack: model.canGoBack && !isBusy,
            canRefreshAndSort: model.query != nil && !isBusy,
            canUpload: allowsUpload
                && currentDirectoryCanWrite
                && model.query != nil
                && !isBusy,
            canCreateFolder: currentDirectoryCanWrite && model.query != nil && !isBusy,
            canSelect: !model.entries.isEmpty && !isBusy,
            isSelecting: isSelecting,
            canToggleAll: !selectableEntries.isEmpty && !isBusy,
            allLoadedSelected: allLoadedSelectableEntriesAreSelected,
            canDownloadSelection: canDownloadSelection && !isBusy,
            canDeleteSelection: canDeleteSelection && !isBusy,
            isMediaDirectory: isMediaDirectory,
            prefersMediaGrid: prefersMediaGrid,
            sortField: model.query?.sortField,
            descending: model.query?.descending
        )
    }

    private var toolbarActions: ProductFileBrowserToolbar.Actions {
        .init(
            goBack: goBack,
            refresh: { _ = model.refresh() },
            changeSort: changeSort,
            upload: chooseUploadSource,
            createFolder: {
                model.clearMutationFailure()
                mutationAlertTitle = AppStrings.folderCouldNotBeCreated
                isPresentingNewFolder = true
            },
            toggleSelecting: {
                isSelecting.toggle()
                if !isSelecting { selectedPaths.removeAll() }
            },
            toggleAll: toggleAllLoadedSelection,
            downloadSelection: chooseBatchDownloadDirectory,
            deleteSelection: { isConfirmingBatchDelete = true },
            toggleMediaLayout: { prefersMediaGrid.toggle() }
        )
    }

    private var browserHeader: some View {
        ProductFileBrowserHeader(
            locationTitle: currentLocationTitle,
            selectedCount: isSelecting ? selectedPaths.count : nil,
            isBusy: isBusy
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && isBusy {
            ProgressView(AppStrings.loadingFiles)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ProductFileBrowserEmptyState(isSearching: !searchText.isEmpty)
        } else if isMediaDirectory && prefersMediaGrid {
            mediaGrid
        } else {
            List {
                ForEach(model.entries) { entry in
                    FileEntryRow(
                        entry: entry,
                        open: { open(entry) },
                        preview: { openPreview(entry) },
                        download: { chooseDownloadDestination(for: entry) },
                        upload: { chooseUploadSource(into: entry) },
                        allowsUpload: allowsUpload,
                        rename: { renameEntry = entry },
                        delete: { deleteEntry = entry },
                        isSelecting: isSelecting,
                        isSelected: selectedPaths.contains(entry.path),
                        toggleSelection: { toggleSelection(entry) },
                        thumbnailData: model.thumbnails[entry.path],
                        loadThumbnail: { model.loadThumbnail(for: entry) }
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

    private var isMediaDirectory: Bool {
        guard let path = model.query?.path else { return false }
        return path.hasPrefix("dm://media-images/") || path.hasPrefix("dm://media-videos/")
    }

    private var mediaGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 138, maximum: 190), spacing: 14)],
                spacing: 16
            ) {
                ForEach(model.entries) { entry in
                    MediaGridCard(
                        entry: entry,
                        thumbnailData: model.thumbnails[entry.path],
                        isSelecting: isSelecting,
                        isSelected: selectedPaths.contains(entry.path),
                        activate: {
                            if isSelecting {
                                toggleSelection(entry)
                            } else if entry.canBrowse {
                                open(entry)
                            } else if allowsUpload && entry.canAcceptUpload {
                                chooseUploadSource(into: entry)
                            } else {
                                openPreview(entry)
                            }
                        },
                        download: { chooseDownloadDestination(for: entry) },
                        upload: { chooseUploadSource(into: entry) },
                        allowsUpload: allowsUpload,
                        rename: { renameEntry = entry },
                        delete: { deleteEntry = entry },
                        loadThumbnail: { model.loadThumbnail(for: entry) }
                    )
                }
            }
            .padding(18)
            if model.canLoadMore {
                Button(AppStrings.loadMore) { model.loadMore() }
                    .disabled(isBusy)
                    .padding(.bottom, 18)
            }
        }
    }

    private var failureBanner: some View {
        ProductFileBrowserFailureBanner(message: failureText) {
            if model.query != nil {
                model.refresh()
            }
        }
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
        guard model.openDirectory(entry) else { return }
        selectedPaths.removeAll()
        isSelecting = false
        searchTask?.cancel()
        searchText = ""
    }

    private func openPreview(_ entry: DirectoryBrowserItem) {
        guard model.loadPreview(for: entry) else { return }
        previewEntry = entry
    }

    private func goBack() {
        guard let previous = model.goBack() else { return }
        selectedPaths.removeAll()
        isSelecting = false
        searchTask?.cancel()
        searchText = previous.searchQuery
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

    private func changeSort(
        field: DirectorySortField? = nil,
        descending: Bool? = nil
    ) {
        guard let query = model.query else { return }
        let nextField = field ?? (query.sortField == .providerDefault ? .name : query.sortField)
        let nextDescending = descending ?? query.descending
        guard nextField != query.sortField || nextDescending != query.descending else { return }
        searchTask?.cancel()
        selectedPaths.removeAll()
        isSelecting = false
        model.load(DirectoryListingQuery(
            path: query.path,
            pageSize: query.pageSize,
            sortField: nextField,
            descending: nextDescending,
            searchQuery: query.searchQuery
        ))
    }

    private func toggleSelection(_ entry: DirectoryBrowserItem) {
        guard isSelectable(entry) else { return }
        if !selectedPaths.insert(entry.path).inserted {
            selectedPaths.remove(entry.path)
        }
    }

    private func isSelectable(_ entry: DirectoryBrowserItem) -> Bool {
        (entry.kind == .file && (entry.canRead || entry.canWrite))
            || (entry.kind == .directory && entry.canWrite)
    }

    private var selectableEntries: [DirectoryBrowserItem] {
        model.entries.filter(isSelectable)
    }

    private var allLoadedSelectableEntriesAreSelected: Bool {
        !selectableEntries.isEmpty
            && selectableEntries.allSatisfy { selectedPaths.contains($0.path) }
    }

    private func toggleAllLoadedSelection() {
        if allLoadedSelectableEntriesAreSelected {
            selectedPaths.removeAll()
        } else {
            selectedPaths.formUnion(selectableEntries.map(\.path))
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
            let name = safeSuggestedName(entry.safeDisplayName)
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
            let ids = await transferQueue.submitDownloads(
                requests,
                authorizationURL: directoryURL
            )
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

    private var currentDirectoryCanWrite: Bool {
        model.currentDirectory?.canWrite ?? false
    }

    private var currentLocationTitle: String {
        model.currentDirectory.map(FileEntryDisplayName.value) ?? AppStrings.files
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK,
                  let directoryURL = panel.url,
                  directoryURL.isFileURL else { return }
            let destinationURL = directoryURL.appendingPathComponent(
                safeSuggestedName(entry.safeDisplayName),
                isDirectory: false
            )
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                submissionFailure = .download
                return
            }
            Task { @MainActor in
                let id = await transferQueue.submitDownload(
                    sourcePath: entry.path,
                    destinationURL: destinationURL,
                    authorizationURL: directoryURL
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
        chooseUploadSource(directoryPath: directoryPath)
    }

    private func chooseUploadSource(into entry: DirectoryBrowserItem) {
        guard allowsUpload, entry.canAcceptUpload else { return }
        chooseUploadSource(directoryPath: entry.path)
    }

    private func chooseUploadSource(directoryPath: String) {
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
