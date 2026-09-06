import Foundation
import Testing
@testable import DroidMatchCore
@testable import DroidMatchPresentation

@Test @MainActor
func applicationLibraryPagingSearchAndRevocationUseOneCurrentQuery() async throws {
    let probe = ApplicationProbe()
    defer { Task { await probe.finish() } }
    let model = ApplicationLibraryModel(client: probe)
    model.activate()
    try #require(await applicationEventually { await probe.count == 1 })
    await probe.succeed(1, entries: applicationEntries(0..<100), total: 101, next: "next")
    try #require(await applicationEventually { model.phase == .ready })
    model.loadMore()
    try #require(await applicationEventually { await probe.count == 2 })
    #expect(await probe.calls[1].token == "next")
    await probe.succeed(2, entries: applicationEntries(100..<101), total: 101)
    try #require(await applicationEventually { model.entries.count == 101 })
    #expect(!model.hasMore)
    model.search("Notes")
    #expect(model.entries.isEmpty)
    try #require(await applicationEventually { await probe.count == 3 })
    #expect(await probe.calls[2].query.searchQuery == "Notes")
    #expect(await probe.calls[2].token == nil)
    await probe.fail(3, .permissionRequired)
    try #require(await applicationEventually { model.phase == .failed })
    #expect(model.failure == .permissionRequired && model.entries.isEmpty && !model.hasMore)
    model.sort(.recentlyUpdated)
    try #require(await applicationEventually { await probe.count == 4 })
    #expect(await probe.calls[3].query.sortOrder == .recentlyUpdated)
    await probe.succeed(4, entries: [], total: 0)
    try #require(await applicationEventually { model.phase == .ready })
}

@Test @MainActor
func applicationLibraryDiscardsLateHiddenResultsAndKeepsOtherVisibleWindows() async throws {
    let probe = ApplicationProbe()
    defer { Task { await probe.finish() } }
    let model = ApplicationLibraryModel(client: probe)
    let first = UUID(), second = UUID()
    model.attach(viewID: first)
    model.attach(viewID: second)
    try #require(await applicationEventually { await probe.count == 1 })
    model.detach(viewID: first)
    await probe.succeed(1, entries: applicationEntries(0..<1), total: 1)
    try #require(await applicationEventually { model.phase == .ready })
    #expect(model.entries.count == 1)
    model.refresh()
    try #require(await applicationEventually { await probe.count == 2 })
    model.detach(viewID: second)
    #expect(model.phase == .idle && model.entries.isEmpty)
    model.attach(viewID: first)
    try #require(await applicationEventually { await probe.count == 3 })
    await probe.succeed(2, entries: applicationEntries(9..<10), total: 1)
    await probe.succeed(3, entries: applicationEntries(1..<2), total: 1)
    try #require(await applicationEventually { model.phase == .ready })
    #expect(model.entries.map(\.id) == ["example.item1"])
    model.detach(viewID: first)
    let olderPeer = ApplicationLibraryModel(client: UnsupportedApplicationLibraryClient())
    olderPeer.activate()
    try #require(await applicationEventually { olderPeer.phase == .failed })
    #expect(olderPeer.failure == .unsupported && olderPeer.entries.isEmpty)
}

@Test @MainActor
func applicationLibraryRejectsCrossPageDuplicatesInsteadOfKeepingPartialInventory() async throws {
    let probe = ApplicationProbe()
    defer { Task { await probe.finish() } }
    let model = ApplicationLibraryModel(client: probe)
    model.activate()
    try #require(await applicationEventually { await probe.count == 1 })
    await probe.succeed(1, entries: applicationEntries(0..<100), total: 101, next: "next")
    try #require(await applicationEventually { model.phase == .ready })
    model.loadMore()
    try #require(await applicationEventually { await probe.count == 2 })
    await probe.succeed(2, entries: applicationEntries(0..<1), total: 101)
    try #require(await applicationEventually { model.phase == .failed })
    #expect(model.failure == .invalidResponse && model.entries.isEmpty && !model.hasMore)
}

private func applicationEntries(_ range: Range<Int>) -> [ApplicationLibraryEntry] {
    range.map { index in
        ApplicationLibraryEntry(packageIdentifier: "example.item\(index)", displayName: "App \(index)",
            versionName: "1.0", versionCode: 1, updatedUnixMillis: nil, isSystemApplication: false)
    }
}

@MainActor
private func applicationEventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private actor ApplicationProbe: ApplicationLibraryClient {
    struct Call: Sendable { let query: ApplicationLibraryQuery; let token: String? }
    var calls: [Call] = []
    var count: Int { calls.count }
    private var pending: [Int: CheckedContinuation<ApplicationLibraryPage, Error>] = [:]

    func listApplications(query: ApplicationLibraryQuery, pageToken: String?) async throws
        -> ApplicationLibraryPage {
        calls.append(Call(query: query, token: pageToken))
        let index = calls.count
        // Deliberately ignore cancellation to model a reply already admitted by RPC.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func succeed(_ index: Int, entries: [ApplicationLibraryEntry], total: Int, next: String? = nil) {
        pending.removeValue(forKey: index)?.resume(returning:
            ApplicationLibraryPage(entries: entries, totalCount: total, nextPageToken: next))
    }

    func fail(_ index: Int, _ error: ApplicationLibraryError) {
        pending.removeValue(forKey: index)?.resume(throwing: error)
    }

    func finish() {
        for item in pending.values { item.resume(throwing: CancellationError()) }
        pending = [:]
    }
}
