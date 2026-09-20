import AVFoundation
import Foundation
import Testing
@testable import DroidMatchAppSupport
import DroidMatchCore

@Test(arguments: ["wav", "m4a"]) @MainActor
func musicAssetDecodesPausesSeeksRestartsAndCloses(format: String) async throws {
    let source = SyntheticPlaybackSource(
        bytes: try makeSyntheticAudio(format: format),
        mimeType: format == "wav" ? "audio/wav" : "audio/mp4"
    )
    let controller = MediaPlaybackController()
    controller.load(source: source)
    defer { controller.stop() }
    let player = try #require(controller.player)
    player.isMuted = true
    #expect(!player.preventsDisplaySleepDuringVideoPlayback)
    #expect(!player.allowsExternalPlayback)
    #expect(player.currentItem?.asset.referenceRestrictions == .forbidAll)
    #expect(await musicEventually { controller.isReady && controller.elapsedSeconds > 0.1 })
    #expect(!controller.failed)
    #expect(controller.durationSeconds >= 3.9 && controller.durationSeconds < 4.2)
    #expect(controller.isPlaying)
    controller.pause()
    #expect(await musicEventually { !controller.isPlaying })
    controller.seek(to: 1.5)
    #expect(await musicEventually { !controller.isSeeking })
    #expect(abs(controller.elapsedSeconds - 1.5) < 0.1)
    #expect(player.rate == 0)
    for _ in 0..<4 { controller.play(); controller.pause() }
    #expect(await musicEventually { !controller.isPlaying && player.rate == 0 })
    controller.seek(to: .nan)
    #expect(!controller.isSeeking)
    controller.seek(to: .infinity)
    #expect(!controller.isSeeking)
    controller.seek(to: controller.durationSeconds + 10)
    #expect(await musicEventually { !controller.isSeeking })
    #expect(abs(controller.elapsedSeconds - controller.durationSeconds) < 0.1)
    controller.play()
    #expect(await musicEventually {
        controller.isPlaying && controller.elapsedSeconds > 0.1 && controller.elapsedSeconds < 1
    })
    let snapshot = await source.snapshot()
    #expect(snapshot.readCount > 0)
    #expect(snapshot.maximumRead <= MediaPlaybackPolicy.maximumReadBytes)
    #expect(snapshot.maximumConcurrent == 1)
    // A seek callback and time observer must not revive a closed preview.
    // 中文：关闭时尚未完成的跳转和时间回调不能恢复旧预览。
    controller.seek(to: 2)
    controller.stop()
    #expect(await musicEventually { await source.isClosed })
    #expect(controller.player == nil && !controller.isPlaying && !controller.isSeeking)
    #expect(controller.elapsedSeconds == 0 && controller.durationSeconds == 0)
}

@Test @MainActor func musicAssetRejectsUnsupportedAndMalformedContentAndCanReplaceFailure() async throws {
    let controller = MediaPlaybackController()
    defer { controller.stop() }
    let denied = SyntheticPlaybackSource(bytes: Data([1]), mimeType: "audio/ogg")
    controller.load(source: denied)
    #expect(controller.failed && controller.player == nil)
    #expect(await musicEventually { await denied.isClosed })
    #expect(await denied.snapshot().readCount == 0)
    let malformed = SyntheticPlaybackSource(bytes: Data(repeating: 0, count: 4_096), mimeType: "audio/mpeg")
    controller.load(source: malformed)
    #expect(await musicEventually { controller.failed })
    #expect(await musicEventually { await malformed.isClosed })
    let replacement = SyntheticPlaybackSource(bytes: try makeSyntheticAudio(format: "wav"), mimeType: "audio/wav")
    controller.load(source: replacement)
    controller.player?.isMuted = true
    #expect(await musicEventually { controller.isReady && controller.elapsedSeconds > 0.1 })
    #expect(!controller.failed)
    controller.stop()
    #expect(await musicEventually { await replacement.isClosed })
}

@MainActor private func musicEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

/// Native encoders create silence only; no fixture reads a user's audio.
/// 中文：仅编码合成静音，不读取用户音乐。
private func makeSyntheticAudio(format: String) throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-audio-\(UUID().uuidString).\(format)")
    defer { try? FileManager.default.removeItem(at: url) }
    let pcm = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 176_400))
    buffer.frameLength = buffer.frameCapacity
    let channel = try #require(buffer.floatChannelData?[0])
    channel.initialize(repeating: 0, count: Int(buffer.frameLength))
    var settings: [String: Any] = [AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
    if format == "m4a" {
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        settings[AVEncoderBitRateKey] = 64_000
    } else {
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
    }
    // The writer must close before the container header is consumed by AVPlayer.
    try {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }()
    return try Data(contentsOf: url)
}
