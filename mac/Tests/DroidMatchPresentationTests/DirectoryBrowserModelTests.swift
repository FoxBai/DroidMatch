@testable import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func directoryBrowserLoadsPagesInOrderAndFiltersBoundaryDuplicates() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    let query = DirectoryListingQuery(path: "dm://media-images/", pageSize: 2)

    model.load(query)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page(
        [entry("dm://media-images/media/1"), entry("dm://media-images/media/2")],
        next: "token-1"
    ))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.entries.map(\.path) == [
        "dm://media-images/media/1",
        "dm://media-images/media/2",
    ])
    #expect(model.canLoadMore)

    #expect(model.loadMore())
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.call(2)?.pageToken == "token-1")
    await client.succeed(2, page([
        entry("dm://media-images/media/2"),
        entry("dm://media-images/media/3"),
    ]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.entries.map(\.path) == [
        "dm://media-images/media/1",
        "dm://media-images/media/2",
        "dm://media-images/media/3",
    ])
    #expect(!model.canLoadMore)
}

@Test
@MainActor
func directoryBrowserLoadMoreFailurePreservesRowsAndTokenForRetry() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    let query = DirectoryListingQuery(path: "dm://app-sandbox/", pageSize: 1)

    model.load(query)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page(
        [entry("dm://app-sandbox/a.bin")],
        next: "retry-token"
    ))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.loadMore())
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.fail(2, .remote(.transportLost))
    #expect(await waitForDirectoryPhase(model, .failed))
    #expect(model.entries.map(\.path) == ["dm://app-sandbox/a.bin"])
    #expect(model.failure == .unavailable)
    #expect(model.isShowingStaleContent)
    #expect(model.canLoadMore)

    #expect(model.loadMore())
    #expect(await waitForDirectoryCallCount(client, 3))
    #expect(await client.call(3)?.pageToken == "retry-token")
    await client.succeed(3, page([entry("dm://app-sandbox/b.bin")]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.entries.map(\.path) == [
        "dm://app-sandbox/a.bin",
        "dm://app-sandbox/b.bin",
    ])
}

@Test
@MainActor
func directoryBrowserRefreshFailureKeepsStaleRowsUntilAtomicReplacement() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    let query = DirectoryListingQuery(path: "dm://media-videos/")

    model.load(query)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page(
        [entry("dm://media-videos/media/old")],
        next: "old-next"
    ))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.refresh())
    #expect(model.phase == .refreshing)
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.fail(2, .remote(.permissionRequired))
    #expect(await waitForDirectoryPhase(model, .failed))
    #expect(model.entries.map(\.path) == ["dm://media-videos/media/old"])
    #expect(model.failure == .permissionRequired)
    #expect(model.isShowingStaleContent)
    #expect(model.canLoadMore)

    #expect(model.refresh())
    #expect(await waitForDirectoryCallCount(client, 3))
    await client.succeed(3, page([entry("dm://media-videos/media/new")]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.entries.map(\.path) == ["dm://media-videos/media/new"])
    #expect(model.failure == nil)
    #expect(!model.isShowingStaleContent)
}

@Test
@MainActor
func directoryBrowserPathSwitchRejectsLateNonCooperativeResponse() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    let first = DirectoryListingQuery(path: "dm://media-images/")
    let second = DirectoryListingQuery(path: "dm://app-sandbox/")

    model.load(first)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([entry("dm://media-images/media/initial")]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.refresh())
    #expect(await waitForDirectoryCallCount(client, 2))
    model.load(second)
    #expect(model.entries.isEmpty)
    #expect(model.query == second)
    #expect(await waitForDirectoryCallCount(client, 3))

    await client.succeed(3, page([entry("dm://app-sandbox/current.bin")]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    await client.succeed(2, page([entry("dm://media-images/media/stale")]))
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(model.query == second)
    #expect(model.entries.map(\.path) == ["dm://app-sandbox/current.bin"])
}

@Test
@MainActor
func directoryBrowserRejectsCrossPageTokenCycleWithoutAppendingRows() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/", pageSize: 1))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page(
        [entry("dm://app-sandbox/a.bin")],
        next: "token-1"
    ))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.loadMore())
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.succeed(2, page(
        [entry("dm://app-sandbox/b.bin")],
        next: "token-2"
    ))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.loadMore())
    #expect(await waitForDirectoryCallCount(client, 3))
    await client.succeed(3, page(
        [entry("dm://app-sandbox/must-not-append.bin")],
        next: "token-1"
    ))
    #expect(await waitForDirectoryPhase(model, .failed))
    #expect(model.failure == .invalidResponse)
    #expect(model.entries.map(\.path) == [
        "dm://app-sandbox/a.bin",
        "dm://app-sandbox/b.bin",
    ])
    #expect(model.canLoadMore)
}

@Test
@MainActor
func directoryBrowserDoesNotStayBusyOnDependencyCancellation() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://roots/"))
    #expect(await waitForDirectoryCallCount(client, 1))

    await client.cancel(1)

    #expect(await waitForDirectoryPhase(model, .failed))
    #expect(model.failure == .unavailable)
    #expect(model.entries.isEmpty)
}

private actor DirectoryListingClientProbe: DirectoryBrowserClient {
    struct Call: Sendable, Equatable {
        let query: DirectoryListingQuery
        let pageToken: String?
    }

    private var calls: [Call] = []
    private var continuations: [Int: CheckedContinuation<DirectoryListingPage, any Error>] = [:]
    private var createdPaths: [String] = []
    private var createError: DirectoryMutationError?

    func createDirectory(path: String) throws {
        createdPaths.append(path)
        if let createError { throw createError }
    }

    func setCreateError(_ error: DirectoryMutationError?) {
        createError = error
    }

    func lastCreatedPath() -> String? { createdPaths.last }

    func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) async throws -> DirectoryListingPage {
        let number = calls.count + 1
        calls.append(Call(query: query, pageToken: pageToken))
        return try await withCheckedThrowingContinuation { continuation in
            continuations[number] = continuation
        }
    }

    func succeed(_ number: Int, _ page: DirectoryListingPage) {
        continuations.removeValue(forKey: number)?.resume(returning: page)
    }

    func fail(_ number: Int, _ error: DirectoryListingError) {
        continuations.removeValue(forKey: number)?.resume(throwing: error)
    }

    func cancel(_ number: Int) {
        continuations.removeValue(forKey: number)?.resume(
            throwing: CancellationError()
        )
    }

    func count() -> Int {
        calls.count
    }

    func call(_ number: Int) -> Call? {
        guard number > 0, number <= calls.count else { return nil }
        return calls[number - 1]
    }
}

@Test
@MainActor
func directoryBrowserCreatesDirectChildThenRefreshes() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/exports/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.createDirectory(named: "Receipts"))
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.lastCreatedPath() == "dm://app-sandbox/exports/Receipts/")
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.mutationFailure == nil)
}

@Test
@MainActor
func directoryBrowserRejectsUnsafeNameAndClassifiesRemoteFailure() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(!model.createDirectory(named: "../escape"))
    #expect(model.mutationFailure == .invalidName)

    await client.setCreateError(.remote(.alreadyExists))
    #expect(model.createDirectory(named: "Existing"))
    for _ in 0..<200 where model.isMutating {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.mutationFailure == .alreadyExists)
    #expect(await client.lastCreatedPath() == "dm://app-sandbox/Existing/")
}

private func entry(_ path: String) -> DirectoryListingEntry {
    DirectoryListingEntry(
        path: path,
        name: String(path.split(separator: "/").last ?? "entry"),
        kind: .file,
        sizeBytes: 1,
        modifiedUnixMillis: 1,
        mimeType: "application/octet-stream",
        canRead: true,
        canWrite: false
    )
}

private func page(
    _ entries: [DirectoryListingEntry],
    next: String? = nil
) -> DirectoryListingPage {
    DirectoryListingPage(entries: entries, nextPageToken: next)
}

private func waitForDirectoryCallCount(
    _ client: DirectoryListingClientProbe,
    _ expected: Int
) async -> Bool {
    for _ in 0..<200 {
        if await client.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
private func waitForDirectoryPhase(
    _ model: DirectoryBrowserModel,
    _ expected: DirectoryBrowserPhase
) async -> Bool {
    for _ in 0..<200 {
        if model.phase == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
