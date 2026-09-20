import AVKit
import DroidMatchAppSupport
import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct MediaPlaybackPreviewSurface<Poster: View>: View {
    @ObservedObject var browser: DirectoryBrowserModel
    let target: DirectoryPreviewTarget
    var artworkData: Data? = nil
    @ViewBuilder let poster: () -> Poster
    @State private var playback: DirectoryPlaybackModel?

    var body: some View {
        Group {
            if let playback {
                PlaybackSurface(model: playback,
                                isAudio: MediaPlaybackPolicy.isAudioPath(target.item.path),
                                permissionRequired: browser.failure == .permissionRequired,
                                artworkData: artworkData,
                                poster: poster)
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

private struct PlaybackSurface<Poster: View>: View {
    @ObservedObject var model: DirectoryPlaybackModel
    let isAudio: Bool
    let permissionRequired: Bool
    let artworkData: Data?
    @ViewBuilder let poster: () -> Poster
    @StateObject private var controller = MediaPlaybackController()

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                poster().overlay(alignment: isAudio ? .bottom : .center) {
                    Button(action: model.start) {
                        Label(isAudio ? AppStrings.playMusic : AppStrings.playVideo,
                              systemImage: "play.fill")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                    .padding(.bottom, isAudio ? 40 : 0)
                }
            case .loading:
                ProgressView(isAudio ? AppStrings.loadingMusic : AppStrings.loadingVideo)
            case .ready:
                if let player = controller.player {
                    if isAudio {
                        NativeAudioPlayerControls(controller: controller, artworkData: artworkData)
                    } else {
                        NativeVideoPlayerView(player: player)
                            .accessibilityLabel(AppStrings.videoPlayback)
                    }
                } else {
                    ProgressView(isAudio ? AppStrings.loadingMusic : AppStrings.loadingVideo)
                }
            case let .failed(failure):
                VStack(spacing: 12) {
                    Image(systemName: isAudio ? "music.note" : "video.slash")
                        .font(.largeTitle).accessibilityHidden(true)
                    Text(isAudio ? AppStrings.musicUnavailable : AppStrings.videoUnavailable)
                        .font(.headline)
                    Text(failure == .sourceChanged
                         ? (isAudio ? AppStrings.musicSourceChanged : AppStrings.videoSourceChanged)
                         : (isAudio ? AppStrings.musicUnavailableDetail : AppStrings.videoUnavailableDetail))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if failure == .unavailable { Button(AppStrings.tryAgain, action: model.start) }
                }
                .padding()
            case .invalidated:
                Text(isAudio && permissionRequired
                     ? AppStrings.mediaMusicAccessRequiredDetail : AppStrings.previewUnavailable)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
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

private struct NativeAudioPlayerControls: View {
    @ObservedObject var controller: MediaPlaybackController
    let artworkData: Data?

    var body: some View {
        VStack(spacing: 24) {
            MusicArtworkView(data: artworkData, size: 160)
            if controller.isReady {
                Button {
                    if controller.isPlaying { controller.pause() } else { controller.play() }
                } label: {
                    Label(controller.isPlaying ? AppStrings.pause : AppStrings.playMusic,
                          systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isSeeking)
                .keyboardShortcut(.space, modifiers: [])
                progressControls
            } else {
                ProgressView(AppStrings.loadingMusic)
            }
        }
        .padding(32).frame(maxWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppStrings.musicPlayback)
    }

    private var progressControls: some View {
        VStack(spacing: 8) {
            NativePlaybackSlider(
                elapsed: controller.elapsedSeconds, duration: controller.durationSeconds,
                enabled: controller.durationSeconds > 0 && !controller.isSeeking,
                seek: controller.seek
            )
            .frame(height: 22)
            HStack {
                Text(timeText(controller.elapsedSeconds))
                Spacer()
                if controller.isSeeking { ProgressView().controlSize(.small) }
                Text(timeText(controller.durationSeconds))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(min(seconds, Double(Int.max / 2)))
        return whole < 3_600
            ? "\(whole / 60):" + String(format: "%02d", whole % 60)
            : "\(whole / 3_600):" + String(format: "%02d:%02d", whole / 60 % 60, whole % 60)
    }
}

/// A native slider commits one seek when dragging ends and uses the same action
/// for keyboard/accessibility changes. Progress updates never replace a value
/// while AppKit is tracking a mouse gesture.
/// 中文：原生滑块在拖动结束时跳转；跟踪鼠标期间不被播放进度刷新覆盖。
private struct NativePlaybackSlider: NSViewRepresentable {
    let elapsed: Double
    let duration: Double
    let enabled: Bool
    let seek: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(seek: seek) }

    func makeNSView(context: Context) -> TrackingPlaybackSlider {
        let slider = TrackingPlaybackSlider(value: 0, minValue: 0, maxValue: max(1, duration),
                                            target: context.coordinator,
                                            action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = false
        slider.setAccessibilityLabel(AppStrings.playbackPosition)
        return slider
    }

    func updateNSView(_ slider: TrackingPlaybackSlider, context: Context) {
        context.coordinator.seek = seek
        guard !slider.isTrackingPointer else { return }
        slider.maxValue = max(1, duration)
        slider.doubleValue = min(elapsed, duration)
        slider.isEnabled = enabled
    }

    @MainActor final class Coordinator: NSObject {
        var seek: (Double) -> Void
        init(seek: @escaping (Double) -> Void) { self.seek = seek }
        @objc func changed(_ sender: NSSlider) { seek(sender.doubleValue) }
    }
}

private final class TrackingPlaybackSlider: NSSlider {
    private(set) var isTrackingPointer = false
    override func mouseDown(with event: NSEvent) {
        isTrackingPointer = true
        defer { isTrackingPointer = false }
        super.mouseDown(with: event)
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
