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

private actor DirectoryListingClientProbe: DirectoryBrowserClient {
    struct Call: Sendable, Equatable {
        let query: DirectoryListingQuery
        let pageToken: String?
    }

    private var calls: [Call] = []
    private var continuations: [Int: CheckedContinuation<DirectoryListingPage, any Error>] = [:]
    private var createdPaths: [String] = []
    private var createError: DirectoryMutationError?
    private var renamedPaths: [(String, String)] = []
    private var deletedPaths: [(String, Bool)] = []
    private var deleteFailureAt: Int?
    private var thumbnailRequests: [(String, UInt32)] = []

    func createDirectory(path: String) throws {
        createdPaths.append(path)
        if let createError { throw createError }
    }

    func setCreateError(_ error: DirectoryMutationError?) {
        createError = error
    }

    func lastCreatedPath() -> String? { createdPaths.last }

    func renamePath(sourcePath: String, destinationPath: String) throws {
        renamedPaths.append((sourcePath, destinationPath))
        if let createError { throw createError }
    }

    func lastRename() -> [String]? {
        guard let value = renamedPaths.last else { return nil }
        return [value.0, value.1]
    }

    func deletePath(_ path: String, recursive: Bool) throws {
        deletedPaths.append((path, recursive))
        if deleteFailureAt == deletedPaths.count {
            throw DirectoryMutationError.remote(.unavailable)
        }
        if let createError { throw createError }
    }

    func lastDelete() -> (String, Bool)? { deletedPaths.last }

    func failDelete(at call: Int?) { deleteFailureAt = call }

    func deletes() -> [(String, Bool)] { deletedPaths }

    func thumbnail(path: String, maxDimensionPx: UInt32) throws -> MediaThumbnail {
        thumbnailRequests.append((path, maxDimensionPx))
        return MediaThumbnail(
            encodedImage: Data([1, 2, 3]),
            mimeType: "image/jpeg",
            widthPx: min(80, maxDimensionPx),
            heightPx: min(60, maxDimensionPx)
        )
    }

    func thumbnailCalls() -> [String] { thumbnailRequests.map(\.0) }
    func thumbnailDimensions() -> [UInt32] { thumbnailRequests.map(\.1) }

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

@Test
@MainActor
func directoryBrowserRenamesVisibleWritableEntryThenRefreshes() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let writable = DirectoryListingEntry(
        path: "dm://app-sandbox/Before/",
        name: "Before",
        kind: .directory,
        sizeBytes: nil,
        modifiedUnixMillis: 1,
        mimeType: "inode/directory",
        canRead: true,
        canWrite: true
    )
    await client.succeed(1, page([writable]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.rename(model.entries[0], to: "After"))
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.lastRename() == [
        "dm://app-sandbox/Before/",
        "dm://app-sandbox/After/",
    ])
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
}

@Test
@MainActor
func directoryBrowserDeletesConfirmedDirectoryRecursivelyThenRefreshes() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let writable = DirectoryListingEntry(
        path: "dm://app-sandbox/Archive/",
        name: "Archive",
        kind: .directory,
        sizeBytes: nil,
        modifiedUnixMillis: 1,
        mimeType: "inode/directory",
        canRead: true,
        canWrite: true
    )
    await client.succeed(1, page([writable]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.delete(model.entries[0]))
    #expect(await waitForDirectoryCallCount(client, 2))
    let deletion = await client.lastDelete()
    #expect(deletion?.0 == "dm://app-sandbox/Archive/")
    #expect(deletion?.1 == true)
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
}

@Test
@MainActor
func directoryBrowserBatchDeleteIsStableAndRefreshesAfterPartialFailure() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let first = DirectoryListingEntry(
        path: "dm://app-sandbox/a.txt", name: "a.txt", kind: .file,
        sizeBytes: 1, modifiedUnixMillis: 1, mimeType: "text/plain",
        canRead: true, canWrite: true
    )
    let second = DirectoryListingEntry(
        path: "dm://app-sandbox/b/", name: "b", kind: .directory,
        sizeBytes: nil, modifiedUnixMillis: 1, mimeType: "inode/directory",
        canRead: true, canWrite: true
    )
    await client.succeed(1, page([second, first]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    await client.failDelete(at: 2)

    #expect(model.delete(Array(model.entries.reversed())))
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.deletes().map(\.0) == [first.path, second.path])
    #expect(await client.deletes().map(\.1) == [false, true])
    #expect(model.mutationFailure == .partialFailure)
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
}

@Test
@MainActor
func directoryBrowserLoadsVisibleMediaThumbnailOnce() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://media-images/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let media = DirectoryListingEntry(
        path: "dm://media-images/media/42", name: "photo.jpg", kind: .file,
        sizeBytes: 10, modifiedUnixMillis: 1, mimeType: "image/jpeg",
        canRead: true, canWrite: false
    )
    await client.succeed(1, page([media]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    model.loadThumbnail(for: model.entries[0])
    for _ in 0..<200 where model.thumbnails[media.path] == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    model.loadThumbnail(for: model.entries[0])
    #expect(model.thumbnails[media.path] == Data([1, 2, 3]))
    #expect(await client.thumbnailCalls() == [media.path])
}

@Test @MainActor
func directoryBrowserLoadsBoundedMediaPreviewAndClearsIt() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://media-images/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let media = DirectoryListingEntry(
        path: "dm://media-images/media/42", name: "photo.jpg", kind: .file,
        sizeBytes: 10, modifiedUnixMillis: 1, mimeType: "image/jpeg",
        canRead: true, canWrite: false
    )
    await client.succeed(1, page([media]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.loadPreview(for: model.entries[0]))
    for _ in 0..<200 where model.preview == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.preview?.encodedImage == Data([1, 2, 3]))
    #expect(await client.thumbnailDimensions() == [512])
    #expect(!model.isLoadingPreview)
    #expect(!model.previewFailed)

    model.clearPreview()
    #expect(model.preview == nil)
}

@Test @MainActor
func directoryBrowserLoadsImageAlbumCoverWithoutTreatingItAsPreview() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://media-images/albums/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let album = DirectoryListingEntry(
        path: "dm://media-images/albums/0123456789abcdef01234567/",
        name: "Camera",
        kind: .directory,
        sizeBytes: nil,
        modifiedUnixMillis: 1,
        mimeType: "vnd.droidmatch.media-album",
        canRead: true,
        canWrite: false
    )
    await client.succeed(1, page([album]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    model.loadThumbnail(for: model.entries[0])
    for _ in 0..<200 where model.thumbnails[album.path] == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.thumbnails[album.path] == Data([1, 2, 3]))
    #expect(await client.thumbnailDimensions() == [96])
    #expect(!model.loadPreview(for: model.entries[0]))
}

@Test
func directoryBrowserItemSanitizesDisplayNameWithoutChangingIdentity() {
    let rawName = "invoice\u{202E}gpj\n\u{200B}.txt"
    let item = DirectoryBrowserItem(DirectoryListingEntry(
        path: "dm://app-sandbox/original-id",
        name: rawName,
        kind: .file,
        sizeBytes: 1,
        modifiedUnixMillis: 1,
        mimeType: "text/plain",
        canRead: true,
        canWrite: true
    ))

    #expect(item.safeDisplayName == "invoicegpj.txt")
    #expect(item.name == rawName)
    #expect(item.path == "dm://app-sandbox/original-id")

    let hidden = DirectoryBrowserItem(DirectoryListingEntry(
        path: "dm://app-sandbox/hidden-id",
        name: "\u{202E}\n\u{200B}",
        kind: .file,
        sizeBytes: nil,
        modifiedUnixMillis: nil,
        mimeType: nil,
        canRead: true,
        canWrite: false
    ))
    #expect(hidden.safeDisplayName == nil)
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

private func largeDirectoryPage(
    _ indexes: Range<Int>,
    next: String? = nil
) -> DirectoryListingPage {
    page(indexes.map { index in
        entry(String(format: "dm://app-sandbox/file-%04d.bin", index))
    }, next: next)
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
