import AVFoundation
import Combine
import DroidMatchCore
import Foundation

/// Native decoding is restricted to the one opaque, in-memory resource. External
/// media references and alias resolution are forbidden, including local files.
/// 中文：只解码本次内存资源；禁止外部媒体引用和本地文件 alias 解析。
@MainActor
public final class VideoPlaybackController: ObservableObject {
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var failed = false
    private var loader: VideoAssetResourceLoader?
    private var observation: NSKeyValueObservation?
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
        let loader = VideoAssetResourceLoader(source: source)
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
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.failed = true
                self.player?.pause()
                self.loader?.close()
            }
        }
        self.loader = loader
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = true
        self.player = player
        player.play()
    }

    public func stop() {
        generation = UUID()
        observation?.invalidate()
        observation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader?.close()
        loader = nil
        failed = false
    }
}
