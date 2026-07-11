import Combine
import DroidMatchCore
import Foundation

public enum DirectoryBrowserPhase: String, Sendable, Equatable {
    case idle
    case loading
    case loaded
    case refreshing
    case loadingMore
    case failed
}

public enum DirectoryBrowserFailure: String, Sendable, Equatable {
    case invalidRequest
    case permissionRequired
    case notFound
    case unsupported
    case unavailable
    case invalidResponse
}

public enum DirectoryMutationPresentationFailure: String, Sendable, Equatable {
    case invalidName
    case permissionRequired
    case alreadyExists
    case notFound
    case unsupported
    case unavailable
    case partialFailure
}

/// Privacy-bounded row state for a device directory entry.
///
/// Device file names are intentionally displayable product data. This type does
/// not implement `CustomStringConvertible`, and the browser model never logs or
/// copies names into failure state.
public struct DirectoryBrowserItem: Identifiable, Sendable, Equatable {
    private static let disallowedDisplayFormatting = CharacterSet(charactersIn:
        "\u{061C}\u{200B}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"
    )
    public var id: String { path }

    public let path: String
    public let name: String?
    public let kind: DirectoryEntryKind
    public let sizeBytes: Int64?
    public let modifiedUnixMillis: Int64?
    public let mimeType: String?
    public let canRead: Bool
    public let canWrite: Bool

    /// A bounded UI-only rendering that cannot visually reorder adjacent text.
    /// The raw name and canonical path remain unchanged for explicit operations.
    public var safeDisplayName: String? {
        guard let name else { return nil }
        let scalars = name.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !Self.disallowedDisplayFormatting.contains($0)
        }
        let value = String(String.UnicodeScalarView(scalars))
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return String(value.prefix(240))
    }

    init(_ entry: DirectoryListingEntry) {
        path = entry.path
        name = entry.name
        kind = entry.kind
        sizeBytes = entry.sizeBytes
        modifiedUnixMillis = entry.modifiedUnixMillis
        mimeType = entry.mimeType
        canRead = entry.canRead
        canWrite = entry.canWrite
    }
}

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
    @Published public private(set) var mutationFailure: DirectoryMutationPresentationFailure?
    @Published public private(set) var thumbnails: [String: Data] = [:]
    @Published public private(set) var preview: MediaThumbnail?
    @Published public private(set) var isLoadingPreview = false
    @Published public private(set) var previewFailed = false
    @Published public private(set) var currentDirectory: DirectoryBrowserItem?
    @Published public private(set) var canGoBack = false

    public var isShowingStaleContent: Bool {
        phase == .failed && !entries.isEmpty
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

    private let client: any DirectoryBrowserClient
    private var nextPageToken: String?
    private var seenEntryPaths = Set<String>()
    private var seenPageTokens = Set<String>()
    private var listingTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    private var thumbnailFailures = Set<String>()
    private var thumbnailCacheOrder: [String] = []
    private var previewTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var navigationHistory: [NavigationLocation] = []

    public init(client: any DirectoryBrowserClient) {
        self.client = client
    }

    /// Opens a child while retaining navigation metadata in session-owned
    /// state. SwiftUI may recreate the Files tab, so path, write capability,
    /// and back history must not live only in ephemeral View state.
    @discardableResult
    public func openDirectory(_ entry: DirectoryBrowserItem) -> Bool {
        guard entry.kind == .directory || entry.kind == .virtual,
              let query else { return false }
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
        mutationTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
        previewTask?.cancel()
    }

    /// Opens a new directory context. Old rows are cleared immediately so a
    /// failed navigation can never present the previous directory as the new one.
    public func load(_ query: DirectoryListingQuery) {
        generation &+= 1
        listingTask?.cancel()
        mutationTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
        listingTask = nil
        mutationTask = nil
        isMutating = false
        thumbnailTasks = [:]
        thumbnailFailures = []
        thumbnails = [:]
        thumbnailCacheOrder = []
        clearPreview()
        self.query = query
        entries = []
        nextPageToken = nil
        seenEntryPaths = []
        seenPageTokens = []
        failure = nil
        phase = .loading
        canLoadMore = false
        requestPage(
            query: query,
            pageToken: nil,
            operation: .initial,
            generation: generation
        )
    }

    /// Replaces the current directory only after a fresh first page succeeds.
    /// Failure leaves old rows visible and marks them as stale.
    @discardableResult
    public func refresh() -> Bool {
        guard let query else { return false }
        generation &+= 1
        listingTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
        clearPreview()
        thumbnailTasks = [:]
        thumbnailFailures = []
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
        let isMediaFile = item.kind == .file
            && (item.path.hasPrefix("dm://media-images/media/")
                || item.path.hasPrefix("dm://media-videos/media/"))
        let isImageAlbum = item.kind == .directory
            && item.path.hasPrefix("dm://media-images/albums/")
            && item.path != "dm://media-images/albums/"
        guard isMediaFile || isImageAlbum,
              thumbnails[item.path] == nil,
              thumbnailTasks[item.path] == nil,
              !thumbnailFailures.contains(item.path) else { return }
        let path = item.path
        let operationGeneration = generation
        let client = self.client
        thumbnailTasks[path] = Task { [weak self] in
            do {
                let value = try await client.thumbnail(path: path, maxDimensionPx: 96)
                guard !Task.isCancelled else { return }
                self?.applyThumbnail(value, path: path, generation: operationGeneration)
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyThumbnailFailure(path: path, generation: operationGeneration)
            }
        }
    }

    /// Requests a screen-sized derivative for the preview sheet. The provider
    /// still returns a bounded thumbnail; full media bytes never use control RPC.
    @discardableResult
    public func loadPreview(for item: DirectoryBrowserItem) -> Bool {
        guard item.kind == .file,
              item.path.hasPrefix("dm://media-images/media/")
                || item.path.hasPrefix("dm://media-videos/media/") else { return false }
        previewTask?.cancel()
        preview = nil
        previewFailed = false
        isLoadingPreview = true
        let operationGeneration = generation
        let path = item.path
        let client = self.client
        previewTask = Task { [weak self] in
            do {
                let value = try await client.thumbnail(path: path, maxDimensionPx: 512)
                guard !Task.isCancelled else { return }
                self?.finishPreview(value, generation: operationGeneration)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishPreview(nil, generation: operationGeneration)
            }
        }
        return true
    }

    public func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        preview = nil
        previewFailed = false
        isLoadingPreview = false
    }

    private func finishPreview(_ value: MediaThumbnail?, generation: UInt64) {
        guard generation == self.generation else { return }
        previewTask = nil
        preview = value
        previewFailed = value == nil
        isLoadingPreview = false
    }

    private func applyThumbnail(_ value: MediaThumbnail, path: String, generation: UInt64) {
        guard generation == self.generation,
              entries.contains(where: { $0.path == path }) else { return }
        thumbnailTasks[path] = nil
        thumbnails[path] = value.encodedImage
        thumbnailCacheOrder.removeAll { $0 == path }
        thumbnailCacheOrder.append(path)
        while thumbnailCacheOrder.count > 64 {
            thumbnails[thumbnailCacheOrder.removeFirst()] = nil
        }
    }

    private func applyThumbnailFailure(path: String, generation: UInt64) {
        guard generation == self.generation else { return }
        thumbnailTasks[path] = nil
        thumbnailFailures.insert(path)
    }

    /// Creates a direct child and refreshes only after the server confirms it.
    /// Names never enter error state or logs; providers receive one normalized
    /// logical path and remain responsible for platform-specific authorization.
    @discardableResult
    public func createDirectory(named name: String) -> Bool {
        guard !isMutating, let query else { return false }
        guard let trimmed = Self.normalizedMutationName(name) else {
            mutationFailure = .invalidName
            return false
        }
        let separator = query.path.hasSuffix("/") ? "" : "/"
        let path = query.path + separator + trimmed + "/"
        let operationGeneration = generation
        isMutating = true
        mutationFailure = nil
        let client = self.client
        mutationTask = Task { [weak self] in
            do {
                try await client.createDirectory(path: path)
                guard !Task.isCancelled else { return }
                self?.finishCreateDirectory(
                    success: true,
                    error: nil,
                    query: query,
                    generation: operationGeneration
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishCreateDirectory(
                    success: false,
                    error: error,
                    query: query,
                    generation: operationGeneration
                )
            }
        }
        return true
    }

    /// Renames a visible direct child in place. Moving between directories is
    /// intentionally rejected by the provider boundary and is not disguised as rename.
    @discardableResult
    public func rename(_ item: DirectoryBrowserItem, to name: String) -> Bool {
        guard !isMutating,
              let query,
              item.canWrite,
              item.kind == .file || item.kind == .directory,
              entries.contains(where: { $0.id == item.id }),
              let trimmed = Self.normalizedMutationName(name) else {
            mutationFailure = .invalidName
            return false
        }
        let separator = query.path.hasSuffix("/") ? "" : "/"
        let kindSuffix = item.kind == .directory ? "/" : ""
        let destinationPath = query.path + separator + trimmed + kindSuffix
        guard destinationPath != item.path else {
            mutationFailure = .invalidName
            return false
        }

        let operationGeneration = generation
        isMutating = true
        mutationFailure = nil
        let client = self.client
        mutationTask = Task { [weak self] in
            do {
                try await client.renamePath(
                    sourcePath: item.path,
                    destinationPath: destinationPath
                )
                guard !Task.isCancelled else { return }
                self?.finishCreateDirectory(
                    success: true,
                    error: nil,
                    query: query,
                    generation: operationGeneration
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishCreateDirectory(
                    success: false,
                    error: error,
                    query: query,
                    generation: operationGeneration
                )
            }
        }
        return true
    }

    /// Deletes only a currently visible writable file or directory. The caller
    /// must obtain user confirmation; directories always set the recursive bit.
    @discardableResult
    public func delete(_ item: DirectoryBrowserItem) -> Bool {
        guard !isMutating,
              let query,
              item.canWrite,
              item.kind == .file || item.kind == .directory,
              entries.contains(where: { $0.id == item.id }) else {
            mutationFailure = .invalidName
            return false
        }
        let operationGeneration = generation
        isMutating = true
        mutationFailure = nil
        let client = self.client
        mutationTask = Task { [weak self] in
            do {
                try await client.deletePath(
                    item.path,
                    recursive: item.kind == .directory
                )
                guard !Task.isCancelled else { return }
                self?.finishCreateDirectory(
                    success: true,
                    error: nil,
                    query: query,
                    generation: operationGeneration
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishCreateDirectory(
                    success: false,
                    error: error,
                    query: query,
                    generation: operationGeneration
                )
            }
        }
        return true
    }

    /// Executes a stable snapshot sequentially so providers never receive an
    /// ambiguous batch. A partial failure forces a refresh before it is shown.
    @discardableResult
    public func delete(_ items: [DirectoryBrowserItem]) -> Bool {
        guard !isMutating, let query, !items.isEmpty else { return false }
        let visibleByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let unique = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted { $0.path < $1.path }
        guard unique.allSatisfy({ item in
            item.canWrite
                && (item.kind == .file || item.kind == .directory)
                && visibleByPath[item.path] == item
        }) else {
            mutationFailure = .invalidName
            return false
        }

        let operationGeneration = generation
        isMutating = true
        mutationFailure = nil
        let client = self.client
        mutationTask = Task { [weak self] in
            var deletedCount = 0
            do {
                for item in unique {
                    try Task.checkCancellation()
                    try await client.deletePath(
                        item.path,
                        recursive: item.kind == .directory
                    )
                    deletedCount += 1
                }
                self?.finishBatchDeletion(
                    deletedCount: deletedCount,
                    error: nil,
                    query: query,
                    generation: operationGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishBatchDeletion(
                    deletedCount: deletedCount,
                    error: error,
                    query: query,
                    generation: operationGeneration
                )
            }
        }
        return true
    }

    public func clearMutationFailure() {
        mutationFailure = nil
    }

    private static func normalizedMutationName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\0") else { return nil }
        return value
    }

    private func finishCreateDirectory(
        success: Bool,
        error: Error?,
        query: DirectoryListingQuery,
        generation: UInt64
    ) {
        guard generation == self.generation, query == self.query else { return }
        mutationTask = nil
        isMutating = false
        if success {
            mutationFailure = nil
            _ = refresh()
            return
        }
        mutationFailure = Self.presentationMutationFailure(error)
    }

    private static func presentationMutationFailure(
        _ error: Error?
    ) -> DirectoryMutationPresentationFailure {
        guard let mutationError = error as? DirectoryMutationError else { return .unavailable }
        switch mutationError {
        case .invalidPath, .invalidResponse:
            return .unavailable
        case let .remote(failure):
            switch failure {
            case .permissionRequired: return .permissionRequired
            case .alreadyExists: return .alreadyExists
            case .notFound: return .notFound
            case .invalidArgument: return .invalidName
            case .unsupported: return .unsupported
            case .unavailable: return .unavailable
            }
        }
    }

    private func finishBatchDeletion(
        deletedCount: Int,
        error: Error?,
        query: DirectoryListingQuery,
        generation: UInt64
    ) {
        guard generation == self.generation, query == self.query else { return }
        mutationTask = nil
        isMutating = false
        if let error {
            if deletedCount > 0 {
                mutationFailure = .partialFailure
                _ = refresh()
            } else {
                mutationFailure = Self.presentationMutationFailure(error)
            }
            return
        }
        mutationFailure = nil
        _ = refresh()
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

        switch operation {
        case .initial, .refresh:
            entries = page.entries.map(DirectoryBrowserItem.init)
            seenEntryPaths = Set(page.entries.map(\.path))
            seenPageTokens = []
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
            let newEntries = page.entries.filter {
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
        failure = Self.presentationFailure(error)
        phase = .failed
        switch operation {
        case .initial:
            canLoadMore = false
        case .refresh, .nextPage:
            canLoadMore = nextPageToken != nil
        }
    }

    private static func presentationFailure(_ error: Error) -> DirectoryBrowserFailure {
        guard let error = error as? DirectoryListingError else {
            return .unavailable
        }
        switch error {
        case .invalidPath, .invalidPageSize:
            return .invalidRequest
        case .invalidResponse:
            return .invalidResponse
        case let .remote(failure):
            switch failure {
            case .permissionRequired, .unauthorized:
                return .permissionRequired
            case .notFound:
                return .notFound
            case .invalidArgument:
                return .invalidRequest
            case .unsupportedCapability:
                return .unsupported
            case .cancelled, .timeout, .transportLost, .other:
                return .unavailable
            }
        }
    }
}
