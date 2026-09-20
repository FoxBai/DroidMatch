import AVFoundation
import Combine
import DroidMatchCore
import Foundation

/// Native decoding is restricted to the one opaque, in-memory resource. External
/// media references and alias resolution are forbidden, including local files.
/// 中文：只解码本次内存资源；禁止外部媒体引用和本地文件 alias 解析。
@MainActor
public final class MediaPlaybackController: ObservableObject {
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var failed = false
    @Published public private(set) var isReady = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isSeeking = false
    @Published public private(set) var elapsedSeconds = 0.0
    @Published public private(set) var durationSeconds = 0.0
    private var loader: MediaAssetResourceLoader?
    private var observation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var playAfterSeek = false
    private var generation = UUID()

    public init() {}

    public func load(source: any MediaPlaybackSource) {
        stop()
        guard MediaPlaybackPolicy.supports(mimeType: source.content.mimeType),
              source.content.byteCount > 0 else {
            failed = true
            Task { await source.close() }
            return
        }
        let loader = MediaAssetResourceLoader(source: source)
        var options: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetShouldSupportAliasDataReferencesKey: false,
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetAllowsExpensiveNetworkAccessKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: false
        ]
        if #available(macOS 14, *) {
            options[AVURLAssetOverrideMIMETypeKey] = source.content.mimeType
        }
        let asset = AVURLAsset(url: loader.resourceURL, options: options)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        let current = generation
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current,
                      let status = self.player?.currentItem?.status else { return }
                self.isReady = status == .readyToPlay
                self.updateTime()
                if status == .failed {
                    self.failed = true
                    self.pause()
                    self.loader?.close()
                }
            }
        }
        self.loader = loader
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = source.content.mimeType.hasPrefix("video/")
        self.player = player
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] _, _ in
            // Waiting still represents a play request; the button must allow pausing it.
            // 中文：缓冲等待仍可暂停，按钮不能误显示为尚未开始播放。
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, let player = self.player else { return }
                // Read current state after the hop; queued callbacks can arrive late.
                // 中文：切回主线程后读取当前状态，迟到回调不能覆盖最新播放状态。
                self.isPlaying = player.timeControlStatus != .paused
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.updateTime()
            }
        }
        player.play()
    }

    public func play() {
        guard !failed, !isSeeking, let player else { return }
        if durationSeconds > 0, elapsedSeconds >= durationSeconds - 0.05 {
            seek(to: 0, playWhenFinished: true)
        } else {
            player.play()
        }
    }

    public func pause() {
        playAfterSeek = false
        player?.pause()
    }

    public func seek(to seconds: Double) { seek(to: seconds, playWhenFinished: false) }

    private func seek(to seconds: Double, playWhenFinished: Bool) {
        guard isReady, !failed, !isSeeking, seconds.isFinite, durationSeconds > 0,
              let player else { return }
        let position = min(max(0, seconds), durationSeconds)
        let current = generation
        isSeeking = true
        playAfterSeek = playWhenFinished
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.isSeeking = false
                self.updateTime()
                if finished, self.playAfterSeek { self.player?.play() }
                self.playAfterSeek = false
            }
        }
    }

    private func updateTime() {
        guard let player else { return }
        let position = player.currentTime().seconds
        if position.isFinite, position >= 0 { elapsedSeconds = position }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            durationSeconds = duration
        }
    }

    public func stop() {
        generation = UUID()
        observation?.invalidate()
        observation = nil
        playbackObservation?.invalidate()
        playbackObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader?.close()
        loader = nil
        failed = false
        isReady = false
        isPlaying = false
        isSeeking = false
        playAfterSeek = false
        elapsedSeconds = 0
        durationSeconds = 0
    }
}
