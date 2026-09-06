import Foundation
import Testing
@testable import DroidMatchCore
@testable import DroidMatchPresentation

@Test @MainActor func directoryPlaybackClosesLateOpenAndRejectsOldWindowContext() async throws {
    let probe = PlaybackBrowserProbe(holdOpen: true)
    let browser = DirectoryBrowserModel(client: probe)
    browser.load(DirectoryListingQuery(path: "dm://media-videos/"))
    #expect(await waitForDirectoryPhase(browser, .loaded))
    let oldTarget = try #require(browser.loadPreview(for: browser.entries[0]))
    let old = try #require(browser.playback(for: oldTarget))
    old.start()
    #expect(await playbackEventually { await probe.openCount == 1 })
    let target = try #require(browser.loadPreview(for: browser.entries[0]))
    #expect(old.phase == .invalidated)
    #expect(browser.playback(for: oldTarget) == nil)
    let first = await probe.releaseOpen()
    #expect(await playbackEventually { await first.closed })
    #expect(old.source == nil)
    let current = try #require(browser.playback(for: target))
    current.start()
    #expect(await playbackEventually { await probe.openCount == 2 })
    let second = await probe.releaseOpen()
    #expect(await playbackEventually { current.phase == .ready })
    #expect(!browser.clearPreview(context: oldTarget.context))
    #expect(current.phase == .ready)
    #expect(!(await second.closed))
    #expect(browser.clearPreview(context: target.context))
    #expect(current.phase == .invalidated)
    #expect(await playbackEventually { await second.closed })
}

@Test @MainActor func directoryPlaybackPermissionFailureInvalidatesTheVideoBrowser() async throws {
    let probe = PlaybackBrowserProbe()
    let browser = DirectoryBrowserModel(client: probe)
    browser.load(DirectoryListingQuery(path: "dm://media-videos/"))
    #expect(await waitForDirectoryPhase(browser, .loaded))
    let target = try #require(browser.loadPreview(for: browser.entries[0]))
    let playback = try #require(browser.playback(for: target))
    playback.start()
    #expect(await playbackEventually { playback.phase == .ready })
    let underlying = await probe.lastSource
    await underlying.setReadFailure(.permissionRequired)
    let source = try #require(playback.source)
    await #expect(throws: MediaPlaybackError.permissionRequired) {
        _ = try await source.read(offset: 0, length: 1)
    }
    #expect(browser.failure == .permissionRequired)
    #expect(browser.entries.isEmpty)
    #expect(playback.phase == .invalidated)
    #expect(await playbackEventually { await underlying.closed })
}

@Test @MainActor func directoryPlaybackRefreshRejectsAlreadyReadingBytes() async throws {
    let probe = PlaybackBrowserProbe()
    let browser = DirectoryBrowserModel(client: probe)
    browser.load(DirectoryListingQuery(path: "dm://media-videos/"))
    #expect(await waitForDirectoryPhase(browser, .loaded))
    let target = try #require(browser.loadPreview(for: browser.entries[0]))
    let playback = try #require(browser.playback(for: target))
    playback.start()
    #expect(await playbackEventually { playback.phase == .ready })
    let source = try #require(playback.source)
    let underlying = await probe.lastSource
    await underlying.setReadHold()
    let read = Task { try await source.read(offset: 0, length: 1) }
    #expect(await playbackEventually { await underlying.reading })
    #expect(browser.refresh())
    #expect(playback.phase == .invalidated)
    #expect(await playbackEventually { await underlying.closed })
    await underlying.releaseRead()
    await #expect(throws: MediaPlaybackError.closed) { _ = try await read.value }
    #expect(playback.source == nil)
}

@MainActor private func playbackEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private actor PlaybackBrowserProbe: DirectoryBrowserClient {
    let holdOpen: Bool
    var openCount = 0
    var lastSource = ControlledPlaybackSource()
    private var openContinuation: CheckedContinuation<any MediaPlaybackSource, Never>?

    init(holdOpen: Bool = false) { self.holdOpen = holdOpen }

    func listDirectoryPage(query: DirectoryListingQuery, pageToken: String?) -> DirectoryListingPage {
        DirectoryListingPage(entries: [DirectoryListingEntry(
            path: "dm://media-videos/media/1", name: "synthetic.mp4", kind: .file,
            sizeBytes: 32, modifiedUnixMillis: 1, mimeType: "video/mp4",
            canRead: true, canWrite: false
        )], nextPageToken: nil)
    }

    func openMediaPlayback(path: String, mimeType: String) async throws -> any MediaPlaybackSource {
        openCount += 1
        lastSource = ControlledPlaybackSource()
        if holdOpen {
            return await withCheckedContinuation { openContinuation = $0 }
        }
        return lastSource
    }

    func releaseOpen() -> ControlledPlaybackSource {
        openContinuation?.resume(returning: lastSource)
        openContinuation = nil
        return lastSource
    }
}

private actor ControlledPlaybackSource: MediaPlaybackSource {
    nonisolated let content = MediaPlaybackContent(byteCount: 32, mimeType: "video/mp4")
    var closed = false
    var reading = false
    private var readFailure: MediaPlaybackError?
    private var holdRead = false
    private var continuation: CheckedContinuation<Void, Never>?

    func setReadFailure(_ failure: MediaPlaybackError) { readFailure = failure }
    func setReadHold() { holdRead = true }
    func releaseRead() { continuation?.resume(); continuation = nil }

    func read(offset: Int64, length: Int) async throws -> Data {
        reading = true
        if let readFailure { throw readFailure }
        if holdRead { await withCheckedContinuation { continuation = $0 } }
        // Deliberately return after close to exercise the outer context guard.
        return Data(repeating: 0, count: length)
    }

    func close() { closed = true }
}
