import AppKit
import DroidMatchAppSupport
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductFileBrowserView: View {
    @ObservedObject var model: DirectoryBrowserModel
    @ObservedObject var transferQueue: TransferQueueModel
    let allowsUpload: Bool
    let title: String
    let rootDirectory: DirectoryBrowserItem?
    let onPermissionRequired: (() -> Void)?
    @State private var submissionFailure: ProductFileSubmissionFailure?
    @State private var isPresentingNewFolder = false
    @State private var createMutationContext: DirectoryMutationContext?
    @State private var renameTarget: DirectoryItemMutationTarget?
    @State private var mutationOperation = DirectoryMutationOperation.createDirectory
    @State private var deleteTarget: DirectoryItemMutationTarget?
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchState = ProductFileBrowserSearchState()
    @State private var searchToken: DirectoryBrowserSearchToken?
    @State private var selectionState = DirectoryBrowserSelectionState()
    @State private var batchDeleteTarget: DirectoryBatchMutationTarget?
    @State private var isDropTarget = false
    @State private var previewTarget: DirectoryPreviewTarget?
    @State private var derivativeSurfaceContext = DirectoryBrowserSurfaceContext()
    @AppStorage(AppPreferenceKeys.mediaGridByDefault) private var prefersMediaGrid = true

    init(
        model: DirectoryBrowserModel,
        transferQueue: TransferQueueModel,
        allowsUpload: Bool,
        title: String = AppStrings.files,
        rootDirectory: DirectoryBrowserItem? = nil,
        onPermissionRequired: (() -> Void)? = nil
    ) {
        self.model = model
        self.transferQueue = transferQueue
        self.allowsUpload = allowsUpload
        self.title = title
        self.rootDirectory = rootDirectory
        self.onPermissionRequired = onPermissionRequired
    }

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
        .navigationTitle(title)
        .focusedSceneValue(\.productRefreshAction, ProductRefreshAction(
            title: isMediaDirectory ? AppStrings.refreshCurrentMediaItems : AppStrings.refresh,
            isEnabled: toolbarState.canRefreshAndSort,
            perform: toolbarActions.refresh
        ))
        .searchable(
            text: $searchText,
            prompt: isMediaDirectory ? AppStrings.searchMedia : AppStrings.searchFiles
        )
        .onAppear {
            model.activateDerivativeSurface(derivativeSurfaceContext)
            synchronizeSearchText()
            if model.failure == .permissionRequired { handlePermissionRequired() }
        }
        .onChange(of: searchText) { value in
            scheduleSearch(value)
        }
        .onChange(of: model.query) { _ in
            synchronizeSearchText()
        }
        .onChange(of: model.activeSearchToken) { _ in
            synchronizeSearchText()
        }
        .onChange(of: isBusy) { busy in
            guard !busy, let token = searchToken else { return }
            applySearchQuery(searchState.becameAvailable(
                currentQuery: model.query,
                isBusy: isBusy
            ), token: token)
        }
        .onChange(of: model.failure) { failure in
            if failure == .permissionRequired { handlePermissionRequired() }
        }
        .onChange(of: model.entries) { entries in
            selectionState.synchronize(visibleEntries: entries)
        }
        .onDisappear {
            cancelPendingSearch()
            model.suspendDerivativeWork(
                for: derivativeSurfaceContext,
                ownedPreviewContext: previewTarget?.context
            )
            previewTarget = nil
        }
        .toolbar {
            ProductFileBrowserToolbar(state: toolbarState, actions: toolbarActions)
        }
        .disabled(isBusy)
        .alert(item: $submissionFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.detail),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
        .sheet(isPresented: $isPresentingNewFolder, onDismiss: {
            createMutationContext = nil
        }) {
            ProductFileBrowserNewFolderSheet { name in
                mutationOperation = .createDirectory
                guard let context = createMutationContext,
                      model.createDirectory(named: name, context: context) else {
                    return consumeSheetMutationFailure()
                }
                isPresentingNewFolder = false
                return nil
            }
        }
        .sheet(item: $renameTarget) { target in
            ProductFileBrowserRenameSheet(initialName: target.item.safeDisplayName ?? "") { name in
                mutationOperation = .renameItem
                guard model.rename(target.item, to: name, context: target.context) else {
                    return consumeSheetMutationFailure()
                }
                renameTarget = nil
                return nil
            }
        }
        .sheet(item: previewTargetBinding) { target in
            MediaPreviewSheet(
                target: target,
                model: model,
                allowsTransferSubmission: transferQueue.canPresentTransferSubmission,
                download: {
                    dismissPreview(target)
                    chooseDownloadDestination(for: target.item)
                }
            )
        }
        .confirmationDialog(
            AppStrings.deleteItem,
            isPresented: deleteConfirmationPresented,
            presenting: deleteTarget
        ) { target in
            Button(AppStrings.delete, role: .destructive) {
                mutationOperation = .deleteItem
                _ = model.delete(target.item, context: target.context)
                deleteTarget = nil
            }
            Button(AppStrings.cancel, role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text(target.item.kind == .directory
                ? AppStrings.deleteFolderDetail
                : AppStrings.deleteFileDetail)
        }
        .confirmationDialog(
            AppStrings.deleteSelectedItems,
            isPresented: batchDeleteConfirmationPresented,
            presenting: batchDeleteTarget
        ) { target in
            Button(AppStrings.delete, role: .destructive) { deleteSelection(target) }
            Button(AppStrings.cancel, role: .cancel) {}
        } message: { _ in
            Text(AppStrings.deleteSelectedItemsDetail)
        }
        .alert(
            (model.mutationIssue?.operation ?? mutationOperation).alertTitle,
            isPresented: mutationFailurePresented
        ) {
            Button(AppStrings.dismiss) { model.clearMutationFailure() }
        } message: {
            Text((model.mutationIssue?.operation ?? mutationOperation).localizedDetail(
                for: model.mutationFailure
            ))
        }
    }

    private var browserSurface: some View {
        VStack(spacing: 0) {
            browserHeader
            if !transferQueue.isPersistenceStatusKnown
                || transferQueue.persistenceStatus == .writeFailed {
                Divider()
                ProductTransferPersistenceBanner(model: transferQueue)
            }
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
                && transferQueue.canPresentTransferSubmission
                && !isBusy,
            canCreateFolder: currentDirectoryCanWrite
                && !isMediaDirectory
                && model.query != nil
                && !isBusy,
            canSelect: !isBusy
                && (selectionState.isSelecting
                    || !selectionState.selectableEntries(in: model.entries).isEmpty),
            isSelecting: selectionState.isSelecting,
            canToggleAll: !selectionState.selectableEntries(in: model.entries).isEmpty && !isBusy,
            allLoadedSelected: selectionState.allLoadedSelectableEntriesAreSelected(
                in: model.entries
            ),
            canDownloadSelection: selectionState.canDownloadSelection(in: model.entries)
                && transferQueue.canPresentTransferSubmission
                && !isBusy,
            canDeleteSelection: selectionState.canDeleteSelection(in: model.entries) && !isBusy,
            isMediaDirectory: isMediaDirectory,
            prefersMediaGrid: prefersMediaGrid,
            sortField: model.query?.sortField,
            descending: model.query?.descending
        )
    }

    private var toolbarActions: ProductFileBrowserToolbar.Actions {
        .init(
            goBack: goBack,
            refresh: { if !isBusy { _ = model.refresh() } },
            changeSort: changeSort,
            upload: chooseUploadSource,
            createFolder: presentCreateFolder,
            toggleSelecting: { selectionState.toggleMode() },
            toggleAll: toggleAllLoadedSelection,
            downloadSelection: chooseBatchDownloadDirectory,
            deleteSelection: presentBatchDelete,
            toggleMediaLayout: { prefersMediaGrid.toggle() }
        )
    }

    private var browserHeader: some View {
        ProductFileBrowserHeader(
            contextTitle: isMediaDirectory
                ? AppStrings.authenticatedMedia
                : AppStrings.authenticatedFiles,
            locationTitle: currentLocationTitle,
            selectedCount: selectionState.isSelecting ? selectionState.selectedPaths.count : nil,
            isBusy: isBusy
        )
    }

    private var content: some View {
        ProductFileBrowserContent(state: contentState, actions: contentActions)
    }

    private var contentState: ProductFileBrowserContent.State {
        .init(
            entries: model.entries,
            phase: model.phase,
            isBusy: isBusy,
            isSearching: !searchText.isEmpty,
            isMediaDirectory: isMediaDirectory,
            prefersMediaGrid: prefersMediaGrid,
            canLoadMore: model.canLoadMore,
            allowsUpload: allowsUpload,
            allowsTransferSubmission: transferQueue.canPresentTransferSubmission,
            isSelecting: selectionState.isSelecting,
            selectedPaths: selectionState.selectedPaths,
            thumbnails: model.thumbnails
        )
    }

    private var contentActions: ProductFileBrowserContent.Actions {
        .init(
            open: open,
            preview: openPreview,
            download: chooseDownloadDestination,
            upload: chooseUploadSource,
            rename: presentRename,
            delete: presentDelete,
            toggleSelection: toggleSelection,
            loadThumbnail: model.loadThumbnail,
            loadMore: { _ = model.loadMore() }
        )
    }

    private var isMediaDirectory: Bool {
        guard let path = model.query?.path else { return false }
        return path.hasPrefix("dm://media-images/") || path.hasPrefix("dm://media-videos/")
    }

    private var failureBanner: some View {
        ProductFileBrowserFailureBanner(message: failureText) {
            if model.query != nil {
                model.refresh()
            }
        }
    }

    private var isBusy: Bool {
        if model.isMutating || transferQueue.isSubmittingTransfer { return true }
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
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var batchDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { batchDeleteTarget != nil },
            set: { if !$0 { batchDeleteTarget = nil } }
        )
    }

    private func consumeSheetMutationFailure() -> ProductFileBrowserMutationSheetFailure {
        let failure = ProductFileBrowserMutationSheetFailure(
            title: mutationOperation.alertTitle,
            detail: mutationOperation.localizedDetail(for: model.mutationFailure)
        )
        model.clearMutationFailure()
        return failure
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
        selectionState.clear()
        cancelPendingSearch()
        searchText = ""
    }

    private func openPreview(_ entry: DirectoryBrowserItem) {
        guard let target = model.loadPreview(for: entry) else { return }
        previewTarget = target
    }

    private func goBack() {
        guard let previous = model.goBack() else { return }
        selectionState.clear()
        cancelPendingSearch()
        searchText = previous.searchQuery
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        guard let token = searchState.edit(value, currentQuery: model.query) else {
            cancelPendingSearch()
            return
        }
        let searchToken = model.beginSearchEdit()
        self.searchToken = searchToken
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            applySearchQuery(searchState.debounceFinished(
                token: token,
                currentQuery: model.query,
                isBusy: isBusy
            ), token: searchToken)
        }
    }

    private func applySearchQuery(_ query: DirectoryListingQuery?, token: DirectoryBrowserSearchToken) {
        guard model.isCurrentSearchEdit(token) else {
            cancelPendingSearch(if: token)
            return
        }
        guard let query else { return }
        guard model.finishSearchEdit(token) else { return }
        searchTask = nil
        searchToken = nil
        model.load(query)
    }

    private func changeSort(
        field: DirectorySortField? = nil,
        descending: Bool? = nil
    ) {
        guard let query = model.query else { return }
        let nextField = field ?? (query.sortField == .providerDefault ? .name : query.sortField)
        let nextDescending = descending ?? query.descending
        guard nextField != query.sortField || nextDescending != query.descending else { return }
        cancelPendingSearch()
        selectionState.clear()
        model.load(DirectoryListingQuery(
            path: query.path,
            pageSize: query.pageSize,
            sortField: nextField,
            descending: nextDescending,
            searchQuery: query.searchQuery
        ))
    }

    private func toggleSelection(_ entry: DirectoryBrowserItem) {
        guard !isBusy else { return }
        selectionState.toggle(entry)
    }

    private func toggleAllLoadedSelection() {
        selectionState.toggleAllLoaded(in: model.entries)
    }

    private func presentCreateFolder() {
        guard let context = model.captureMutationContext() else { return }
        model.clearMutationFailure()
        mutationOperation = .createDirectory
        createMutationContext = context
        isPresentingNewFolder = true
    }

    private func presentRename(_ entry: DirectoryBrowserItem) {
        guard let context = model.captureMutationContext() else { return }
        renameTarget = DirectoryItemMutationTarget(item: entry, context: context)
    }

    private func presentDelete(_ entry: DirectoryBrowserItem) {
        guard let context = model.captureMutationContext() else { return }
        deleteTarget = DirectoryItemMutationTarget(item: entry, context: context)
    }

    private func presentBatchDelete() {
        let items = selectionState.selectedEntries(in: model.entries)
        guard !items.isEmpty, let context = model.captureMutationContext() else { return }
        batchDeleteTarget = DirectoryBatchMutationTarget(items: items, context: context)
    }

    private func deleteSelection(_ target: DirectoryBatchMutationTarget) {
        mutationOperation = .deleteItems
        if model.delete(target.items, context: target.context) {
            selectionState.clear()
        }
        batchDeleteTarget = nil
    }

    private func chooseBatchDownloadDirectory() {
        let entries = selectionState.selectedEntries(in: model.entries)
        guard selectionState.canDownloadSelection(in: model.entries),
              let listingQuery = model.query,
              isCurrentAuthorizedSnapshot(entries, query: listingQuery) else { return }
        let selectedPathSnapshot = selectionState.selectedPaths
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK,
                  let directoryURL = panel.url,
                  selectionState.selectedPaths == selectedPathSnapshot,
                  isCurrentAuthorizedSnapshot(entries, query: listingQuery) else {
                if response == .OK { submissionFailure = .batchDownload }
                return
            }
            Task { @MainActor in
                submitBatchDownloads(entries, to: directoryURL)
            }
        }
    }

    private func submitBatchDownloads(
        _ entries: [DirectoryBrowserItem],
        to directoryURL: URL
    ) {
        guard let plannedRequests = ProductFileBrowserTransferPolicy.downloadRequests(
            for: entries,
            in: directoryURL,
            fallbackName: AppStrings.download
        ) else {
            submissionFailure = .batchDownload
            return
        }
        let requests = plannedRequests.map {
            TransferQueueDownloadRequest(
                sourcePath: $0.sourcePath,
                destinationURL: $0.destinationURL,
                publicationPolicy: $0.publicationPolicy
            )
        }
        Task { @MainActor in
            let admissions = await transferQueue.submitDownloads(
                requests,
                authorizationURL: directoryURL
            )
            selectionState.removeAcceptedPaths(Set(admissions.map {
                requests[$0.requestIndex].sourcePath
            }))
            if admissions.count != requests.count {
                submissionFailure = .downloadSubmission(acceptedCount: admissions.count)
            }
        }
    }

    private var canAcceptDrop: Bool {
        allowsUpload && currentDirectoryCanWrite && model.query != nil
            && transferQueue.canPresentTransferSubmission
            && !isBusy
    }

    private var currentDirectoryCanWrite: Bool {
        model.currentDirectory?.canWrite ?? rootDirectory?.canWrite ?? false
    }

    private var currentLocationTitle: String {
        if let directory = model.currentDirectory {
            return FileEntryDisplayName.value(directory)
        }
        if let rootDirectory {
            return FileEntryDisplayName.value(rootDirectory)
        }
        return title
    }

    private func synchronizeSearchText() {
        if let searchToken, !model.isCurrentSearchEdit(searchToken) {
            cancelPendingSearch(if: searchToken)
        }
        let value = searchState.synchronize(to: model.query)
        if searchText != value { searchText = value }
    }

    private func cancelPendingSearch(if expectedToken: DirectoryBrowserSearchToken? = nil) {
        guard expectedToken == nil || searchToken == expectedToken else { return }
        let token = searchToken
        searchTask?.cancel()
        searchTask = nil
        searchState.cancel()
        searchToken = nil
        if let token { model.cancelSearchEdit(token) }
    }

    private func handlePermissionRequired() {
        cancelPendingSearch()
        selectionState.clear()
        if let previewTarget {
            _ = model.clearPreview(context: previewTarget.context)
            self.previewTarget = nil
        }
        renameTarget = nil
        deleteTarget = nil
        isPresentingNewFolder = false
        createMutationContext = nil
        batchDeleteTarget = nil
        isDropTarget = false
        onPermissionRequired?()
    }

    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard canAcceptDrop,
              let listingQuery = model.query,
              let target = model.currentDirectory ?? rootDirectory,
              isCurrentWritableUploadTarget(
                  target, query: listingQuery, requiresListingMembership: false
              ),
              !urls.isEmpty,
              urls.count <= ProductUploadPanelPolicy.maximumFileCount else {
            submissionFailure = .droppedFiles
            return false
        }
        guard let files = ProductUploadPanelPolicy.acceptedFiles(
            urls,
            directoryPath: target.path
        ) else {
            submissionFailure = .droppedFiles
            return false
        }
        Task { @MainActor in
            guard isCurrentWritableUploadTarget(
                target, query: listingQuery, requiresListingMembership: false
            ) else {
                submissionFailure = .droppedFiles
                return
            }
            let ids = await transferQueue.submitUploads(
                sourceURLs: files,
                directoryPath: target.path
            )
            if ids.count != files.count {
                submissionFailure = .uploadSubmission(
                    count: files.count,
                    acceptedCount: ids.count
                )
            }
        }
        return true
    }

    private func chooseDownloadDestination(for entry: DirectoryBrowserItem) {
        guard entry.kind == .file,
              entry.canRead,
              let listingQuery = model.query,
              isCurrentAuthorizedSnapshot([entry], query: listingQuery) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK,
                  let directoryURL = panel.url,
                  directoryURL.isFileURL,
                  isCurrentAuthorizedSnapshot([entry], query: listingQuery) else {
                if response == .OK { submissionFailure = .download }
                return
            }
            guard let request = ProductFileBrowserTransferPolicy.downloadRequests(
                for: [entry],
                in: directoryURL,
                fallbackName: AppStrings.download
            )?.first else {
                submissionFailure = .download
                return
            }
            Task { @MainActor in
                let id = await transferQueue.submitDownload(
                    sourcePath: request.sourcePath,
                    destinationURL: request.destinationURL,
                    publicationPolicy: request.publicationPolicy,
                    authorizationURL: directoryURL
                )
                if id == nil {
                    submissionFailure = .download
                }
            }
        }
    }

    /// Native panels outlive the row action that opened them. Revalidate the
    /// exact listing tuple and row values before a completion can enqueue work;
    /// a navigation, refresh, permission failure, or changed row makes the
    /// captured display object stale even though Android will authorize again.
    private func isCurrentAuthorizedSnapshot(
        _ entries: [DirectoryBrowserItem],
        query: DirectoryListingQuery
    ) -> Bool {
        ProductFileBrowserTransferPolicy.isCurrentAuthorizedSnapshot(
            entries,
            query: query,
            current: currentTransferSnapshot
        )
    }

    private func chooseUploadSource() {
        guard allowsUpload,
              currentDirectoryCanWrite,
              let listingQuery = model.query,
              let target = model.currentDirectory ?? rootDirectory,
              isCurrentWritableUploadTarget(
                  target,
                  query: listingQuery,
                  requiresListingMembership: false
              ) else { return }
        chooseUploadSource(
            into: target,
            query: listingQuery,
            requiresListingMembership: false
        )
    }

    private func chooseUploadSource(into entry: DirectoryBrowserItem) {
        guard let listingQuery = model.query,
              isCurrentWritableUploadTarget(
                  entry,
                  query: listingQuery,
                  requiresListingMembership: true
              ) else { return }
        chooseUploadSource(
            into: entry,
            query: listingQuery,
            requiresListingMembership: true
        )
    }

    private func chooseUploadSource(
        into target: DirectoryBrowserItem,
        query listingQuery: DirectoryListingQuery,
        requiresListingMembership: Bool
    ) {
        let directoryPath = target.path
        let panel = ProductUploadPanelPolicy.makePanel(directoryPath: directoryPath)
        panel.begin { response in
            let selectedURLs = panel.urls
            guard response == .OK,
                  isCurrentWritableUploadTarget(
                      target,
                      query: listingQuery,
                      requiresListingMembership: requiresListingMembership
                  ),
                  let sourceURLs = ProductUploadPanelPolicy.acceptedFiles(
                      selectedURLs,
                      directoryPath: directoryPath
                  ) else {
                if response == .OK {
                    submissionFailure = .uploadSelection(count: selectedURLs.count)
                }
                return
            }
            Task { @MainActor in
                guard isCurrentWritableUploadTarget(
                    target,
                    query: listingQuery,
                    requiresListingMembership: requiresListingMembership
                ) else {
                    submissionFailure = .uploadSelection(count: sourceURLs.count)
                    return
                }
                let ids = await transferQueue.submitUploads(
                    sourceURLs: sourceURLs,
                    directoryPath: directoryPath
                )
                if ids.count != sourceURLs.count {
                    submissionFailure = .uploadSubmission(
                        count: sourceURLs.count,
                        acceptedCount: ids.count
                    )
                }
            }
        }
    }

    private func isCurrentWritableUploadTarget(
        _ target: DirectoryBrowserItem,
        query: DirectoryListingQuery,
        requiresListingMembership: Bool
    ) -> Bool {
        ProductFileBrowserTransferPolicy.isCurrentWritableUploadTarget(
            target,
            query: query,
            current: currentTransferSnapshot,
            allowsUpload: allowsUpload,
            requiresListingMembership: requiresListingMembership
        )
    }

    private var currentTransferSnapshot: ProductFileBrowserTransferSnapshot {
        ProductFileBrowserTransferSnapshot(
            query: model.query,
            entries: model.entries,
            phase: model.phase,
            failure: model.failure,
            currentDirectory: model.currentDirectory,
            rootDirectory: rootDirectory,
            canPresentTransferSubmission: transferQueue.canPresentTransferSubmission
        )
    }

    private var previewTargetBinding: Binding<DirectoryPreviewTarget?> {
        Binding(
            get: { previewTarget },
            set: { next in
                if next == nil, let previewTarget {
                    _ = model.clearPreview(context: previewTarget.context)
                }
                previewTarget = next
            }
        )
    }

    private func dismissPreview(_ target: DirectoryPreviewTarget) {
        _ = model.clearPreview(context: target.context)
        if previewTarget?.id == target.id {
            previewTarget = nil
        }
    }
}
