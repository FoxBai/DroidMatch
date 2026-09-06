import Combine
import DroidMatchCore
import Foundation

public enum ApplicationLibraryPhase: String, Sendable {
    case idle
    case loading
    case ready
    case failed
}

/// Session-owned application information. Navigation and reactivation invalidate
/// pending publications and recheck Android consent. 中文：不持久化应用清单。
@MainActor
public final class ApplicationLibraryModel: ObservableObject {
    @Published public private(set) var phase: ApplicationLibraryPhase = .idle
    @Published public private(set) var query = ApplicationLibraryQuery()
    @Published public private(set) var entries: [ApplicationLibraryEntry] = []
    @Published public private(set) var totalCount = 0
    @Published public private(set) var failure: ApplicationLibraryError?
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var hasMore = false

    public var isBusy: Bool { phase == .loading || isLoadingMore }
    private let client: any ApplicationLibraryClient
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var nextPageToken: String?
    private var seenTokens = Set<String>()
    private var visibleViews = Set<UUID>()

    public init(client: any ApplicationLibraryClient) { self.client = client }
    deinit { task?.cancel() }

    public func attach(viewID: UUID) {
        let first = visibleViews.isEmpty
        visibleViews.insert(viewID)
        if first { activate() }
    }

    public func detach(viewID: UUID) {
        visibleViews.remove(viewID)
        if visibleViews.isEmpty { deactivate() }
    }

    public func activate() {
        guard !isBusy else { return }
        refresh()
    }

    public func refresh() {
        invalidate()
        phase = .loading
        fetch(append: false)
    }

    public func search(_ text: String) {
        query = ApplicationLibraryQuery(searchQuery: text, sortOrder: query.sortOrder)
        refresh()
    }

    public func sort(_ order: ApplicationLibrarySortOrder) {
        guard query.sortOrder != order else { return }
        query = ApplicationLibraryQuery(searchQuery: query.searchQuery, sortOrder: order)
        refresh()
    }

    public func loadMore() {
        guard phase == .ready, !isBusy, nextPageToken != nil else { return }
        isLoadingMore = true
        fetch(append: true)
    }

    public func deactivate() {
        visibleViews = []
        invalidate()
        phase = .idle
    }

    private func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        entries = []
        totalCount = 0
        nextPageToken = nil
        seenTokens = []
        hasMore = false
        isLoadingMore = false
        failure = nil
    }

    private func fetch(append: Bool) {
        let operation = generation
        let client = self.client
        let query = self.query
        let token = append ? nextPageToken : nil
        task = Task { [weak self] in
            do {
                let page = try await client.listApplications(query: query, pageToken: token)
                guard !Task.isCancelled else { return }
                self?.accept(page, append: append, generation: operation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.reject(error as? ApplicationLibraryError ?? .connectionUnavailable,
                             generation: operation)
            }
        }
    }

    private func accept(_ page: ApplicationLibraryPage, append: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        let prior = append ? entries : []
        let combined = prior + page.entries
        guard (0...4096).contains(page.totalCount), page.entries.count <= query.pageSize,
              combined.count <= page.totalCount,
              !append || page.totalCount == totalCount,
              Set(combined.map(\.id)).count == combined.count else {
            reject(.invalidResponse, generation: generation)
            return
        }
        if let next = page.nextPageToken {
            guard !next.isEmpty, next.utf8.count <= 92, page.entries.count == query.pageSize,
                  combined.count < page.totalCount, seenTokens.insert(next).inserted else {
                reject(.invalidResponse, generation: generation)
                return
            }
        } else if combined.count != page.totalCount {
            reject(.invalidResponse, generation: generation)
            return
        }
        entries = combined
        totalCount = page.totalCount
        nextPageToken = page.nextPageToken
        hasMore = nextPageToken != nil
        task = nil
        isLoadingMore = false
        failure = nil
        phase = .ready
    }

    private func reject(_ error: ApplicationLibraryError, generation: UInt64) {
        guard generation == self.generation else { return }
        invalidate()
        failure = error
        phase = .failed
    }
}
