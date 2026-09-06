import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import DroidMatchAppSupport
import DroidMatchCore

@Test func videoAssetRangesClampEndAndRejectOverflow() throws {
    #expect(try VideoAssetResourceLoader.nextRange(
        requestedOffset: 10, currentOffset: 10, requestedLength: 50, toEnd: false, total: 32
    ) == 10..<32)
    #expect(try VideoAssetResourceLoader.nextRange(
        requestedOffset: 0, currentOffset: 16, requestedLength: 1, toEnd: true, total: 32
    ) == 16..<32)
    #expect(try VideoAssetResourceLoader.nextRange(
        requestedOffset: 0, currentOffset: 0, requestedLength: Int.max, toEnd: true,
        total: Int64.max
    ).count == MediaPlaybackPolicy.maximumReadBytes)
    #expect(throws: MediaPlaybackError.invalidRequest) {
        try VideoAssetResourceLoader.nextRange(
            requestedOffset: 1, currentOffset: 1, requestedLength: Int.max,
            toEnd: false, total: Int64.max
        )
    }
    #expect(throws: MediaPlaybackError.invalidRequest) {
        try VideoAssetResourceLoader.nextRange(
            requestedOffset: -1, currentOffset: 0, requestedLength: 1, toEnd: false, total: 32
        )
    }
}

@Test @MainActor func videoAssetDecodesPlaysSeeksAndClosesSyntheticMedia() async throws {
    let bytes = try await makeSyntheticVideo()
    let source = SyntheticVideoSource(bytes: bytes)
    let controller = VideoPlaybackController()
    controller.load(source: source)
    defer { controller.stop() }
    let player = try #require(controller.player)
    let item = try #require(player.currentItem)
    #expect(item.asset.referenceRestrictions == .forbidAll)
    #expect(!player.allowsExternalPlayback)
    #expect(await videoEventually { item.status == .readyToPlay || controller.failed })
    #expect(!controller.failed)
    #expect(item.status == .readyToPlay)
    #expect(await videoEventually { player.currentTime().seconds > 0.1 })
    player.pause()
    #expect(player.rate == 0)
    let sought = await player.seek(
        to: CMTime(seconds: 1.5, preferredTimescale: 600),
        toleranceBefore: .zero, toleranceAfter: .zero
    )
    #expect(sought)
    #expect(abs(player.currentTime().seconds - 1.5) < 0.1)
    let imageGenerator = AVAssetImageGenerator(asset: item.asset)
    let (_, actualTime) = try await imageGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
    #expect(actualTime.seconds >= 0)
    let snapshot = await source.snapshot()
    #expect(snapshot.readCount > 0)
    #expect(snapshot.maximumRead <= MediaPlaybackPolicy.maximumReadBytes)
    #expect(snapshot.maximumConcurrent == 1)
    let url = try #require((item.asset as? AVURLAsset)?.url)
    #expect(url.scheme == "droidmatch-video")
    #expect(!url.absoluteString.contains("synthetic"))
    controller.stop()
    #expect(controller.player == nil)
    #expect(await videoEventually { await source.isClosed })
}

@MainActor private func videoEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private actor SyntheticVideoSource: MediaPlaybackSource {
    nonisolated let content: MediaPlaybackContent
    let bytes: Data
    var isClosed = false
    private var readCount = 0
    private var maximumRead = 0
    private var active = 0
    private var maximumConcurrent = 0

    init(bytes: Data) {
        self.bytes = bytes
        content = MediaPlaybackContent(byteCount: Int64(bytes.count), mimeType: "video/mp4")
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard !isClosed else { throw MediaPlaybackError.closed }
        let count = try MediaPlaybackPolicy.readLength(offset: offset, requested: length, total: content.byteCount)
        readCount += 1
        maximumRead = max(maximumRead, count)
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        await Task.yield()
        return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
    }

    func close() { isClosed = true }
    func snapshot() -> (readCount: Int, maximumRead: Int, maximumConcurrent: Int) {
        (readCount, maximumRead, maximumConcurrent)
    }
}

/// Only generated color frames touch this temporary fixture; no user media is read.
private func makeSyntheticVideo() async throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-video-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 160, AVVideoHeightKey: 90
    ])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90
    ])
    writer.add(input)
    guard writer.startWriting() else { throw MediaPlaybackError.unavailable }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<60 {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA,
                                  nil, &pixel) == kCVReturnSuccess, let pixel else {
            throw MediaPlaybackError.unavailable
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) {
            memset(address, Int32(30 + frame * 3), CVPixelBufferGetBytesPerRow(pixel) * 90)
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for _ in 0..<200 {
            if input.isReadyForMoreMediaData { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard input.isReadyForMoreMediaData,
              adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 20)) else {
            throw MediaPlaybackError.unavailable
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw MediaPlaybackError.unavailable }
    return try Data(contentsOf: url)
}
