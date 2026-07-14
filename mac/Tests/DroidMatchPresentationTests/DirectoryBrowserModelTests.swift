@testable import DroidMatchCore
@testable import DroidMatchPresentation
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
func directoryBrowserRetainsNavigationStateOutsideEphemeralViewLifetime() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    let rootQuery = DirectoryListingQuery(path: "dm://roots/")
    let appSandbox = DirectoryListingEntry(
        path: "dm://app-sandbox/",
        name: "App sandbox",
        kind: .virtual,
        sizeBytes: nil,
        modifiedUnixMillis: nil,
        mimeType: nil,
        canRead: true,
        canWrite: true
    )

    model.load(rootQuery)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([appSandbox]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    let directory = try #require(model.entries.first)
    #expect(model.openDirectory(directory))
    #expect(model.currentDirectory == directory)
    #expect(model.currentDirectory?.canWrite == true)
    #expect(model.canGoBack)
    #expect(model.query?.path == appSandbox.path)

    #expect(await waitForDirectoryCallCount(client, 2))
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.currentDirectory == directory)

    #expect(model.goBack() == rootQuery)
    #expect(model.currentDirectory == nil)
    #expect(!model.canGoBack)
    #expect(model.query == rootQuery)
}

@Test
@MainActor
func directoryBrowserLoadsMoreThanOneThousandEntriesAcrossThreePages() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/", pageSize: 500))

    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, largeDirectoryPage(0..<500, next: "page-2"))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.loadMore())

    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.call(2)?.pageToken == "page-2")
    await client.succeed(2, largeDirectoryPage(500..<1_000, next: "page-3"))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.loadMore())

    #expect(await waitForDirectoryCallCount(client, 3))
    #expect(await client.call(3)?.pageToken == "page-3")
    await client.succeed(3, largeDirectoryPage(1_000..<1_205))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.entries.count == 1_205)
    #expect(Set(model.entries.map(\.path)).count == 1_205)
    #expect(model.entries.first?.path == "dm://app-sandbox/file-0000.bin")
    #expect(model.entries.last?.path == "dm://app-sandbox/file-1204.bin")
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
