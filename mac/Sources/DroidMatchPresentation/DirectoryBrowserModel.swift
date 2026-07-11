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
}

/// Privacy-bounded row state for a device directory entry.
///
/// Device file names are intentionally displayable product data. This type does
/// not implement `CustomStringConvertible`, and the browser model never logs or
/// copies names into failure state.
public struct DirectoryBrowserItem: Identifiable, Sendable, Equatable {
    public var id: String { path }

    public let path: String
    public let name: String?
    public let kind: DirectoryEntryKind
    public let sizeBytes: Int64?
    public let modifiedUnixMillis: Int64?
    public let mimeType: String?
    public let canRead: Bool
    public let canWrite: Bool

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

/// Main-actor state boundary for a future native file browser.
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

    public var isShowingStaleContent: Bool {
        phase == .failed && !entries.isEmpty
    }

    private enum Operation {
        case initial
        case refresh
        case nextPage(requestedToken: String)
    }

    private let client: any DirectoryBrowserClient
    private var nextPageToken: String?
    private var seenEntryPaths = Set<String>()
    private var seenPageTokens = Set<String>()
    private var listingTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(client: any DirectoryBrowserClient) {
        self.client = client
    }

    deinit {
        listingTask?.cancel()
        mutationTask?.cancel()
    }

    /// Opens a new directory context. Old rows are cleared immediately so a
    /// failed navigation can never present the previous directory as the new one.
    public func load(_ query: DirectoryListingQuery) {
        generation &+= 1
        listingTask?.cancel()
        mutationTask?.cancel()
        listingTask = nil
        mutationTask = nil
        isMutating = false
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
        guard let mutationError = error as? DirectoryMutationError else {
            mutationFailure = .unavailable
            return
        }
        switch mutationError {
        case .invalidPath, .invalidResponse:
            mutationFailure = .unavailable
        case let .remote(failure):
            switch failure {
            case .permissionRequired: mutationFailure = .permissionRequired
            case .alreadyExists: mutationFailure = .alreadyExists
            case .notFound: mutationFailure = .notFound
            case .invalidArgument: mutationFailure = .invalidName
            case .unsupported: mutationFailure = .unsupported
            case .unavailable: mutationFailure = .unavailable
            }
        }
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
