import Foundation
import Testing
@testable import DroidMatchCore
@testable import DroidMatchPresentation

@Test(arguments: [false, true]) @MainActor func directoryPlaybackClosesLateOpenAndRejectsOldWindowContext(audio: Bool) async throws {
    let probe = PlaybackBrowserProbe(audio: audio, holdOpen: true)
    let browser = DirectoryBrowserModel(client: probe)
    browser.load(DirectoryListingQuery(path: probe.root))
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

@Test(arguments: [false, true]) @MainActor func directoryPlaybackPermissionFailureInvalidatesTheMediaBrowser(audio: Bool) async throws {
    let probe = PlaybackBrowserProbe(audio: audio)
    let browser = DirectoryBrowserModel(client: probe)
    browser.load(DirectoryListingQuery(path: probe.root))
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

@Test(arguments: [false, true]) @MainActor func directoryPlaybackRefreshRejectsAlreadyReadingBytes(audio: Bool) async throws {
    let probe = PlaybackBrowserProbe(audio: audio)
    let browser = DirectoryBrowserModel(client: probe)
    browser.load(DirectoryListingQuery(path: probe.root))
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

@Test @MainActor func musicPreviewWaitsForPlayAndNeverRequestsThumbnail() async throws {
    let probe = PlaybackBrowserProbe(audio: true)
    let browser = DirectoryBrowserModel(client: probe)
    browser.load(DirectoryListingQuery(path: probe.root))
    #expect(await waitForDirectoryPhase(browser, .loaded))
    let item = try #require(browser.entries.first)
    browser.loadThumbnail(for: item)
    let target = try #require(browser.loadPreview(for: item))
    let playback = try #require(browser.playback(for: target))
    #expect(playback.phase == .idle)
    #expect(browser.previewState(for: target.context) == .unavailable)
    #expect(await probe.openCount == 0)
    #expect(await probe.thumbnailCount == 0)
    playback.start()
    #expect(await playbackEventually { playback.phase == .ready })
    #expect(await probe.openCount == 1)
    #expect(browser.clearPreview(context: target.context))
    #expect(await playbackEventually { await probe.lastSource.closed })
    #expect(await probe.thumbnailCount == 0)
    #expect(browser.playback(for: target) == nil)
}

@MainActor private func playbackEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private actor PlaybackBrowserProbe: DirectoryBrowserClient {
    nonisolated let root: String
    nonisolated let mimeType: String
    let holdOpen: Bool
    var thumbnailCount = 0
    var openCount = 0
    var lastSource = ControlledPlaybackSource()
    private var openContinuation: CheckedContinuation<any MediaPlaybackSource, Never>?

    init(audio: Bool = false, holdOpen: Bool = false) {
        self.holdOpen = holdOpen
        root = audio ? "dm://media-audio/" : "dm://media-videos/"
        mimeType = audio ? "audio/mpeg" : "video/mp4"
    }

    func thumbnail(path: String, maxDimensionPx: UInt32) throws -> MediaThumbnail {
        thumbnailCount += 1
        throw MediaPlaybackError.unsupported
    }

    func listDirectoryPage(query: DirectoryListingQuery, pageToken: String?) -> DirectoryListingPage {
        DirectoryListingPage(entries: [DirectoryListingEntry(
            path: root + "media/1", name: "synthetic", kind: .file,
            sizeBytes: 32, modifiedUnixMillis: 1, mimeType: mimeType,
            canRead: true, canWrite: false
        )], nextPageToken: nil)
    }

    func openMediaPlayback(path: String, mimeType: String) async throws -> any MediaPlaybackSource {
        #expect(path == root + "media/1")
        #expect(mimeType == self.mimeType)
        openCount += 1
        lastSource = ControlledPlaybackSource(mimeType: mimeType)
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
    nonisolated let content: MediaPlaybackContent
    init(mimeType: String = "video/mp4") {
        content = MediaPlaybackContent(byteCount: 32, mimeType: mimeType)
    }
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
