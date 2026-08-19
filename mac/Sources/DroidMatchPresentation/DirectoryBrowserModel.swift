import Combine
import DroidMatchCore
import Foundation

/// Main-actor state boundary used by the native product file browser.
///
/// Only one page request is active at a time. Switching paths clears old rows;
/// refreshing the same query keeps rows until a replacement first page succeeds.
/// A generation guard rejects late results even when an injected client ignores
/// task cancellation.
@MainActor
public final class DirectoryBrowserModel: ObservableObject {
    @Published public private(set) var query: DirectoryListingQuery?
    @Published public private(set) var entries: [DirectoryBrowserItem] = []
    @Published public private(set) var phase: DirectoryBrowserPhase = .idle
    @Published public private(set) var failure: DirectoryBrowserFailure?
    @Published public private(set) var canLoadMore = false
    @Published public private(set) var isMutating = false
    @Published public private(set) var mutationIssue: DirectoryMutationPresentationIssue?
    @Published public private(set) var thumbnails: [String: Data] = [:]
    @Published private var previewPresentationState:
        DirectoryPreviewPresentationState = .invalidated
    @Published public private(set) var currentDirectory: DirectoryBrowserItem?
    @Published public private(set) var canGoBack = false
    @Published public private(set) var activeSearchToken: DirectoryBrowserSearchToken?

    public var isShowingStaleContent: Bool {
        phase == .failed && !entries.isEmpty
    }

    public var mutationFailure: DirectoryMutationPresentationFailure? {
        mutationIssue?.failure
    }

    private enum Operation {
        case initial
        case refresh
        case nextPage(requestedToken: String)
    }

    private struct NavigationLocation {
        let query: DirectoryListingQuery
        let directory: DirectoryBrowserItem?
    }

    private struct PreviewRequest: Equatable {
        let operationID: UInt64
        let thumbnailGeneration: UInt64
        let path: String
        let context: DirectoryPreviewContext
    }

    private let client: any DirectoryBrowserClient
    private let excludedRootPaths: Set<String>
    private let mutationRunner: DirectoryBrowserMutationRunner
    private var nextPageToken: String?
    private var seenEntryPaths = Set<String>()
    private var seenPageTokens = Set<String>()
    private var listingTask: Task<Void, Never>?
    private var thumbnailTasks: [
        DirectoryBrowserThumbnailState.RequestKey: Task<Void, Never>
    ] = [:]
    private var thumbnailState = DirectoryBrowserThumbnailState()
    private var previewTask: Task<Void, Never>?
    private var activePreviewRequest: PreviewRequest?
    private var queuedPreviewRequest: PreviewRequest?
    private var previewOperationID: UInt64 = 0
    private var currentPreviewContext: DirectoryPreviewContext?
    private var visibleDerivativeSurfaces = Set<DirectoryBrowserSurfaceContext>()
    private var generation: UInt64 = 0
    private var mutationContextIdentity = DirectoryMutationContextIdentity()
    private var activeMutationOperation: DirectoryMutationOperation?
    private var nextSearchOperationID: UInt64 = 0
    private var navigationHistory: [NavigationLocation] = []

    public init(
        client: any DirectoryBrowserClient,
        excludedRootPaths: Set<String> = []
    ) {
        self.client = client
        self.excludedRootPaths = excludedRootPaths
        mutationRunner = DirectoryBrowserMutationRunner(client: client)
    }

    /// Makes the newest edit authoritative across every window observing this
    /// session-owned model. The opaque token contains no search text or path.
    public func beginSearchEdit() -> DirectoryBrowserSearchToken {
        nextSearchOperationID &+= 1
        let token = DirectoryBrowserSearchToken(operationID: nextSearchOperationID)
        activeSearchToken = token
        return token
    }

    public func isCurrentSearchEdit(_ token: DirectoryBrowserSearchToken) -> Bool {
        activeSearchToken == token
    }

    @discardableResult
    public func finishSearchEdit(_ token: DirectoryBrowserSearchToken) -> Bool {
        guard activeSearchToken == token else { return false }
        activeSearchToken = nil
        return true
    }

    public func cancelSearchEdit(_ token: DirectoryBrowserSearchToken) {
        guard activeSearchToken == token else { return }
        activeSearchToken = nil
    }

    /// Opens a readable child while retaining navigation metadata in
    /// session-owned state. SwiftUI may recreate the Files tab, so path, write
    /// capability, and back history must not live only in ephemeral View state.
    @discardableResult
    public func openDirectory(_ entry: DirectoryBrowserItem) -> Bool {
        guard entry.canBrowse, let query else { return false }
        navigationHistory.append(NavigationLocation(
            query: query,
            directory: currentDirectory
        ))
        currentDirectory = entry
        canGoBack = true
        load(DirectoryListingQuery(
            path: entry.path,
            pageSize: query.pageSize,
            sortField: query.sortField,
            descending: query.descending,
            searchQuery: ""
        ))
        return true
    }

    /// Restores the exact parent query and metadata captured before opening a
    /// child. The returned query lets the View restore its search field.
    @discardableResult
    public func goBack() -> DirectoryListingQuery? {
        guard let previous = navigationHistory.popLast() else { return nil }
        currentDirectory = previous.directory
        canGoBack = !navigationHistory.isEmpty
        load(previous.query)
        return previous.query
    }

    deinit {
        listingTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
        previewTask?.cancel()
    }

    /// Clears one browser surface without cancelling an admitted mutation.
    ///
    /// Media access can be revoked while a tab is not visible. Its coordinator
    /// uses this boundary to discard cached names and thumbnails immediately,
    /// without issuing a directory request that the latest root catalog already
    /// says is unauthorized.
    public func reset() {
        invalidateAuthorizationContent()
        query = nil
        navigationHistory = []
        canGoBack = false
    }

    /// Removes every device-derived display value while retaining only opaque
    /// queries needed for an explicit authorization retry.
    ///
    /// Directory metadata in the navigation stack can contain names, so it is
    /// sanitized together with the current directory. Admitted drain-safe work
    /// is not cancelled: Core cancellation returns before the wire response is
    /// drained, so retaining the await is what keeps the real request counted.
    /// Generation guards reject ordinary old values after the drain completes.
    public func invalidateAuthorizationContent() {
        rotateMutationContext()
        invalidateSearchEdit()
        generation &+= 1
        listingTask?.cancel()
        listingTask = nil
        invalidateThumbnails(clearCache: true)
        invalidatePreview()
        entries = []
        nextPageToken = nil
        seenEntryPaths = []
        seenPageTokens = []
        failure = nil
        mutationIssue = nil
        phase = .idle
        canLoadMore = false
        currentDirectory = nil
        navigationHistory = navigationHistory.map {
            NavigationLocation(query: $0.query, directory: nil)
        }
        canGoBack = !navigationHistory.isEmpty
    }

    /// Stops derivative work for a hidden browser without losing its listing,
    /// query, or navigation state. Admitted requests may drain, but the new
    /// generation prevents their results from being published after hiding.
    public func suspendDerivativeWork() {
        visibleDerivativeSurfaces.removeAll()
        invalidateThumbnails(clearCache: true)
        invalidatePreview()
    }

    /// Registers one visible SwiftUI surface that consumes shared derivatives.
    /// Repeated appearance for the same process-local context is idempotent.
    public func activateDerivativeSurface(_ context: DirectoryBrowserSurfaceContext) {
        visibleDerivativeSurfaces.insert(context)
    }

    /// Releases one browser surface without invalidating another window's
    /// preview. Shared derivatives are cleared only after the final visible
    /// surface leaves; the caller may clear only the preview context it owns.
    public func suspendDerivativeWork(
        for surface: DirectoryBrowserSurfaceContext,
        ownedPreviewContext: DirectoryPreviewContext?
    ) {
        visibleDerivativeSurfaces.remove(surface)
        if let ownedPreviewContext {
            _ = clearPreview(context: ownedPreviewContext)
        }
        guard visibleDerivativeSurfaces.isEmpty else { return }
        invalidateThumbnails(clearCache: true)
        invalidatePreview()
    }

    /// Opens a new directory context. Old rows are cleared immediately so a
    /// failed navigation can never present the previous directory as the new one.
    public func load(_ query: DirectoryListingQuery) {
        rotateMutationContext()
        invalidateSearchEdit()
        generation &+= 1
        listingTask?.cancel()
        listingTask = nil
        invalidateThumbnails(clearCache: true)
        invalidatePreview()
        self.query = query
        entries = []
        nextPageToken = nil
        seenEntryPaths = []
        seenPageTokens = []
        failure = nil
        mutationIssue = nil
        phase = .loading
        canLoadMore = false
        requestPage(
            query: query,
            pageToken: nil,
            operation: .initial,
            generation: generation
        )
    }

    private func invalidateSearchEdit() {
        guard activeSearchToken != nil else { return }
        activeSearchToken = nil
    }

    /// Replaces the current directory only after a fresh first page succeeds.
    /// Failure leaves old rows visible and marks them as stale.
    @discardableResult
    public func refresh() -> Bool {
        guard let query else { return false }
        rotateMutationContext()
        generation &+= 1
        listingTask?.cancel()
        invalidatePreview()
        invalidateThumbnails(clearCache: false)
        listingTask = nil
        failure = nil
        phase = .refreshing
        canLoadMore = false
        requestPage(
            query: query,
            pageToken: nil,
            operation: .refresh,
            generation: generation
        )
        return true
    }

    /// Requests the current opaque token once. Failure preserves the token and
    /// existing rows so a user action can retry the same page.
    @discardableResult
    public func loadMore() -> Bool {
        guard listingTask == nil,
              let query,
              let nextPageToken else {
            return false
        }
        rotateMutationContext()
        generation &+= 1
        failure = nil
        phase = .loadingMore
        canLoadMore = false
        requestPage(
            query: query,
            pageToken: nextPageToken,
            operation: .nextPage(requestedToken: nextPageToken),
            generation: generation
        )
        return true
    }

    /// Lazily loads only rows that become visible. Encoded responses are capped
    /// by Core and this cache keeps at most 64 device-owned thumbnails.
    public func loadThumbnail(for item: DirectoryBrowserItem) {
        guard DirectoryBrowserPolicy.supportsThumbnail(item),
              thumbnailState.enqueue(path: item.path) else { return }
        startQueuedThumbnailRequests()
    }

    private func startQueuedThumbnailRequests() {
        let visiblePaths = Set(entries.map(\.path))
        while let key = thumbnailState.nextRequest(visiblePaths: visiblePaths) {
            startThumbnailRequest(key)
        }
    }

    private func startThumbnailRequest(
        _ key: DirectoryBrowserThumbnailState.RequestKey
    ) {
        let client = self.client
        thumbnailTasks[key] = Task { [weak self] in
            do {
                let value = try await client.thumbnail(path: key.path, maxDimensionPx: 96)
                self?.finishThumbnailRequest(key, result: .success(value))
            } catch {
                self?.finishThumbnailRequest(key, result: .failure(error))
            }
        }
    }

    /// Requests a screen-sized derivative for the preview sheet. The provider
    /// still returns a bounded thumbnail; full media bytes never use control RPC.
    @discardableResult
    public func loadPreview(for item: DirectoryBrowserItem) -> DirectoryPreviewTarget? {
        guard DirectoryBrowserPolicy.supportsPreview(item), entries.contains(item) else {
            return nil
        }
        let context = DirectoryPreviewContext()
        previewOperationID &+= 1
        currentPreviewContext = context
        previewPresentationState = .loading
        // Pagination advances the listing generation but does not change the
        // directory or invalidate a user-requested preview. Navigation and
        // refresh advance this media generation and explicitly clear preview.
        queuedPreviewRequest = PreviewRequest(
            operationID: previewOperationID,
            thumbnailGeneration: thumbnailState.generation,
            path: item.path,
            context: context
        )
        startQueuedPreviewRequest()
        return DirectoryPreviewTarget(item: item, context: context)
    }

    private func startQueuedPreviewRequest() {
        guard previewTask == nil, let request = queuedPreviewRequest else { return }
        guard request.operationID == previewOperationID,
              request.thumbnailGeneration == thumbnailState.generation,
              request.context == currentPreviewContext,
              entries.contains(where: { $0.path == request.path }) else {
            queuedPreviewRequest = nil
            if request.context == currentPreviewContext {
                previewPresentationState = .invalidated
                currentPreviewContext = nil
            }
            return
        }
        queuedPreviewRequest = nil
        activePreviewRequest = request
        let client = self.client
        previewTask = Task { [weak self] in
            do {
                let value = try await client.thumbnail(path: request.path, maxDimensionPx: 512)
                self?.finishPreview(request, result: .success(value))
            } catch {
                self?.finishPreview(request, result: .failure(error))
            }
        }
    }

    public func previewState(
        for context: DirectoryPreviewContext
    ) -> DirectoryPreviewPresentationState {
        guard context == currentPreviewContext else { return .invalidated }
        return previewPresentationState
    }

    /// Clears only the preview generation owned by the dismissing sheet.
    /// A stale window cannot clear a newer window's queued or active preview.
    @discardableResult
    public func clearPreview(context: DirectoryPreviewContext) -> Bool {
        guard context == currentPreviewContext else { return false }
        invalidatePreview()
        return true
    }

    private func invalidatePreview() {
        previewOperationID &+= 1
        queuedPreviewRequest = nil
        currentPreviewContext = nil
        previewPresentationState = .invalidated
    }

    private func finishPreview(
        _ request: PreviewRequest,
        result: Result<MediaThumbnail, Error>
    ) {
        guard activePreviewRequest == request else { return }
        previewTask = nil
        activePreviewRequest = nil
        defer { startQueuedPreviewRequest() }
        if case let .failure(error) = result,
           applyAuthoritativePermissionFailure(error, requestPath: request.path) {
            return
        }
        guard request.operationID == previewOperationID,
              request.thumbnailGeneration == thumbnailState.generation,
              request.context == currentPreviewContext else { return }
        switch result {
        case let .success(value):
            previewPresentationState = .ready(value)
        case .failure:
            previewPresentationState = .unavailable
        }
    }

    private func finishThumbnailRequest(
        _ key: DirectoryBrowserThumbnailState.RequestKey,
        result: Result<MediaThumbnail, Error>
    ) {
        thumbnailTasks[key] = nil
        thumbnailState.finish(key)
        defer { startQueuedThumbnailRequests() }
        if case let .failure(error) = result,
           applyAuthoritativePermissionFailure(error, requestPath: key.path) {
            return
        }
        guard thumbnailState.canPublish(
            key,
            visiblePaths: Set(entries.map(\.path))
        ) else { return }
        switch result {
        case let .success(value):
            thumbnailState.store(value.encodedImage, for: key)
            thumbnails = thumbnailState.images
        case .failure:
            thumbnailState.recordFailure(for: key)
        }
    }

    private func applyAuthoritativePermissionFailure(
        _ error: Error,
        requestPath: String
    ) -> Bool {
        guard DirectoryBrowserMediaAuthorizationPolicy.isPermissionFailure(error),
              let query,
              DirectoryBrowserMediaAuthorizationPolicy.sharesDomain(
                  requestPath,
                  query.path
              ) else {
            return false
        }
        invalidateAuthorizationContent()
        failure = .permissionRequired
        phase = .failed
        return true
    }

    private func retainThumbnails(for paths: Set<String>) {
        thumbnailState.retainImages(for: paths)
        thumbnails = thumbnailState.images
    }

    private func invalidateThumbnails(clearCache: Bool) {
        thumbnailState.invalidate(clearCache: clearCache)
        thumbnails = thumbnailState.images
    }

    /// Captures the current displayed snapshot for a later mutation decision.
    /// Busy listing states cannot issue tickets; their next applied page rotates
    /// the identity again before actions reopen.
    public func captureMutationContext() -> DirectoryMutationContext? {
        guard query != nil, failure != .permissionRequired else { return nil }
        switch phase {
        case .loaded, .failed:
            return DirectoryMutationContext(identity: mutationContextIdentity)
        case .idle, .loading, .refreshing, .loadingMore:
            return nil
        }
    }

    /// Creates a direct child and refreshes only after the server confirms it.
    /// Names never enter error state or logs; providers receive one normalized
    /// logical path and remain responsible for platform-specific authorization.
    @discardableResult
    public func createDirectory(
        named name: String,
        context: DirectoryMutationContext
    ) -> Bool {
        guard !isMutating else { return false }
        guard admits(context), let query else {
            publishMutationFailure(.staleContext, operation: .createDirectory)
            return false
        }
        guard let path = DirectoryBrowserPolicy.createDirectoryPath(in: query, name: name) else {
            publishMutationFailure(.invalidName, operation: .createDirectory)
            return false
        }
        return startMutation(operation: .createDirectory) {
            mutationRunner.createDirectory(
                path: path,
                query: query,
                completion: mutationCompletion
            )
        }
    }

    /// Renames a visible direct child in place. Moving between directories is
    /// intentionally rejected by the provider boundary and is not disguised as rename.
    @discardableResult
    public func rename(
        _ item: DirectoryBrowserItem,
        to name: String,
        context: DirectoryMutationContext
    ) -> Bool {
        guard !isMutating else { return false }
        guard admits(context), entries.contains(item) else {
            publishMutationFailure(.staleContext, operation: .renameItem)
            return false
        }
        guard let query,
              let destinationPath = DirectoryBrowserPolicy.renameDestination(
                  for: item,
                  to: name,
                  in: query,
                  visibleEntries: entries
              ) else {
            publishMutationFailure(.invalidName, operation: .renameItem)
            return false
        }
        return startMutation(operation: .renameItem) {
            mutationRunner.rename(
                sourcePath: item.path,
                destinationPath: destinationPath,
                query: query,
                completion: mutationCompletion
            )
        }
    }

    /// Deletes only a currently visible writable file or directory. The caller
    /// must obtain user confirmation; directories always set the recursive bit.
    @discardableResult
    public func delete(
        _ item: DirectoryBrowserItem,
        context: DirectoryMutationContext
    ) -> Bool {
        guard !isMutating else { return false }
        guard admits(context), entries.contains(item) else {
            publishMutationFailure(.staleContext, operation: .deleteItem)
            return false
        }
        guard let query,
              DirectoryBrowserPolicy.canDelete(item, visibleEntries: entries) else {
            publishMutationFailure(.invalidName, operation: .deleteItem)
            return false
        }
        return startMutation(operation: .deleteItem) {
            mutationRunner.delete(
                path: item.path,
                recursive: item.kind == .directory,
                query: query,
                completion: mutationCompletion
            )
        }
    }

    /// Executes a stable snapshot sequentially so providers never receive an
    /// ambiguous batch. A partial failure forces a refresh before it is shown.
    @discardableResult
    public func delete(
        _ items: [DirectoryBrowserItem],
        context: DirectoryMutationContext
    ) -> Bool {
        guard !isMutating, !items.isEmpty else { return false }
        guard admits(context), items.allSatisfy(entries.contains) else {
            publishMutationFailure(.staleContext, operation: .deleteItems)
            return false
        }
        guard let query else {
            publishMutationFailure(.staleContext, operation: .deleteItems)
            return false
        }
        guard let unique = DirectoryBrowserPolicy.batchDeletionItems(
            items,
            visibleEntries: entries
        ) else {
            publishMutationFailure(.invalidName, operation: .deleteItems)
            return false
        }
        return startMutation(operation: .deleteItems) {
            mutationRunner.delete(
                unique,
                query: query,
                completion: mutationCompletion
            )
        }
    }

    public func clearMutationFailure() {
        mutationIssue = nil
    }

    private func admits(_ context: DirectoryMutationContext) -> Bool {
        context.identity === mutationContextIdentity
    }

    private func rotateMutationContext() {
        mutationContextIdentity = DirectoryMutationContextIdentity()
    }

    private var mutationCompletion: DirectoryBrowserMutationRunner.Completion {
        { [weak self] outcome in
            self?.finishMutation(outcome)
        }
    }

    private func startMutation(
        operation: DirectoryMutationOperation,
        _ start: () -> Bool
    ) -> Bool {
        guard start() else { return false }
        activeMutationOperation = operation
        isMutating = true
        mutationIssue = nil
        return true
    }

    private func finishMutation(_ outcome: DirectoryBrowserMutationRunner.Outcome) {
        let operation = activeMutationOperation
        activeMutationOperation = nil
        isMutating = false
        switch outcome {
        case let .completed(query):
            guard query.path == self.query?.path else { return }
            mutationIssue = nil
            _ = refresh()
        case let .failed(query, error):
            guard query.path == self.query?.path else { return }
            guard let operation else { return }
            publishMutationFailure(
                DirectoryBrowserPolicy.presentationMutationFailure(error),
                operation: operation
            )
        case let .batchFailed(query, deletedCount, error):
            guard query.path == self.query?.path else { return }
            guard let operation else { return }
            if deletedCount > 0 {
                publishMutationFailure(.partialFailure, operation: operation)
                _ = refresh()
            } else {
                publishMutationFailure(
                    DirectoryBrowserPolicy.presentationMutationFailure(error),
                    operation: operation
                )
            }
        }
    }

    private func publishMutationFailure(
        _ failure: DirectoryMutationPresentationFailure,
        operation: DirectoryMutationOperation
    ) {
        mutationIssue = DirectoryMutationPresentationIssue(
            operation: operation,
            failure: failure
        )
    }

    private func requestPage(
        query: DirectoryListingQuery,
        pageToken: String?,
        operation: Operation,
        generation: UInt64
    ) {
        let client = self.client
        listingTask = Task { [weak self] in
            do {
                let page = try await client.listDirectoryPage(
                    query: query,
                    pageToken: pageToken
                )
                guard !Task.isCancelled else { return }
                self?.apply(
                    page,
                    query: query,
                    operation: operation,
                    generation: generation
                )
            } catch is CancellationError {
                // Navigation/refresh cancellation is expected. A dependency may
                // also throw CancellationError without this task being cancelled;
                // that must finish the current UI state instead of leaving it busy.
                guard !Task.isCancelled else { return }
                self?.applyFailure(
                    DirectoryListingError.remote(.cancelled),
                    query: query,
                    operation: operation,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(
                    error,
                    query: query,
                    operation: operation,
                    generation: generation
                )
            }
        }
    }

    private func apply(
        _ page: DirectoryListingPage,
        query: DirectoryListingQuery,
        operation: Operation,
        generation: UInt64
    ) {
        guard generation == self.generation, query == self.query else { return }
        rotateMutationContext()
        let visibleEntries = query.path == "dm://roots/"
            ? page.entries.filter { !excludedRootPaths.contains($0.path) }
            : page.entries

        switch operation {
        case .initial, .refresh:
            entries = visibleEntries.map(DirectoryBrowserItem.init)
            seenEntryPaths = Set(visibleEntries.map(\.path))
            seenPageTokens = []
            retainThumbnails(for: seenEntryPaths)
        case .nextPage:
            if let token = page.nextPageToken,
               seenPageTokens.contains(token) {
                applyFailure(
                    DirectoryListingError.invalidResponse(.repeatedPageToken),
                    query: query,
                    operation: operation,
                    generation: generation
                )
                return
            }
            let newEntries = visibleEntries.filter {
                seenEntryPaths.insert($0.path).inserted
            }
            entries.append(contentsOf: newEntries.map(DirectoryBrowserItem.init))
        }

        if let token = page.nextPageToken {
            seenPageTokens.insert(token)
        }
        nextPageToken = page.nextPageToken
        listingTask = nil
        failure = nil
        phase = .loaded
        canLoadMore = nextPageToken != nil
    }

    private func applyFailure(
        _ error: Error,
        query: DirectoryListingQuery,
        operation: Operation,
        generation: UInt64
    ) {
        guard generation == self.generation, query == self.query else { return }
        listingTask = nil
        let presentationFailure = DirectoryBrowserPolicy.presentationFailure(error)
        if presentationFailure == .permissionRequired {
            // A permission error is authoritative, unlike a transient transport
            // failure. Do not retain names or derivatives that Android just
            // stopped authorizing, even when this was an atomic refresh.
            invalidateAuthorizationContent()
            failure = presentationFailure
            phase = .failed
            return
        }
        failure = presentationFailure
        phase = .failed
        switch operation {
        case .initial:
            canLoadMore = false
        case .refresh, .nextPage:
            canLoadMore = nextPageToken != nil
        }
    }
}
