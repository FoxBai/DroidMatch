import AVKit
import DroidMatchAppSupport
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct VideoPreviewSurface<Poster: View>: View {
    @ObservedObject var browser: DirectoryBrowserModel
    let target: DirectoryPreviewTarget
    @ViewBuilder let poster: () -> Poster
    @State private var playback: DirectoryPlaybackModel?

    var body: some View {
        Group {
            if let playback {
                VideoPlaybackSurface(model: playback, poster: poster)
            } else {
                poster()
            }
        }
        .onAppear { playback = browser.playback(for: target) }
        .onChange(of: browser.previewState(for: target.context)) { state in
            if state == .invalidated { playback?.invalidate() }
        }
        .onDisappear { playback?.invalidate() }
    }
}

private struct VideoPlaybackSurface<Poster: View>: View {
    @ObservedObject var model: DirectoryPlaybackModel
    @ViewBuilder let poster: () -> Poster
    @StateObject private var controller = VideoPlaybackController()

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                poster().overlay {
                    Button(action: model.start) {
                        Label(AppStrings.playVideo, systemImage: "play.fill")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .loading:
                ProgressView(AppStrings.loadingVideo)
            case .ready:
                if let player = controller.player {
                    NativeVideoPlayerView(player: player)
                        .accessibilityLabel(AppStrings.videoPlayback)
                } else {
                    ProgressView(AppStrings.loadingVideo)
                }
            case let .failed(failure):
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.largeTitle).accessibilityHidden(true)
                    Text(AppStrings.videoUnavailable).font(.headline)
                    Text(failure == .sourceChanged
                         ? AppStrings.videoSourceChanged : AppStrings.videoUnavailableDetail)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if failure == .unavailable { Button(AppStrings.tryAgain, action: model.start) }
                }
                .padding()
            case .invalidated:
                Text(AppStrings.previewUnavailable).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: synchronize)
        .onChange(of: model.phase) { _ in synchronize() }
        .onChange(of: controller.failed) { failed in
            if failed { model.reportPlaybackFailure() }
        }
        .onDisappear { controller.stop() }
    }

    private func synchronize() {
        if model.phase == .ready, let source = model.source {
            if controller.player == nil { controller.load(source: source) }
        } else {
            controller.stop()
        }
    }
}

/// Use AVKit's AppKit view directly. The SwiftUI VideoPlayer overlay's generic
/// superclass metadata aborts on the verified macOS 26.5.1 / Swift 6.3 runtime;
/// the public AVPlayerView retains the same native playback and seek controls.
/// 中文：绕开已复现的 SwiftUI VideoPlayer 元数据崩溃，保留 AppKit 原生播放控件。
private struct NativeVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
