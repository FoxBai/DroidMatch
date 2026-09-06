import Combine
import DroidMatchCore
import Foundation

public enum DirectoryPlaybackPhase: Sendable, Equatable {
    case idle
    case loading
    case ready
    case failed(MediaPlaybackError)
    case invalidated
}

/// The browser owns admission; this per-preview model owns playback lifetime.
/// A late open is drained and closed, never published into a replacement sheet.
/// 中文：浏览器准入，单个预览模型管理播放生命周期；迟到 open 只会排空并关闭。
@MainActor
public final class DirectoryPlaybackModel: ObservableObject {
    @Published public private(set) var phase: DirectoryPlaybackPhase = .idle
    public private(set) var source: (any MediaPlaybackSource)?
    private let client: any MediaPlaybackClient
    private let path: String
    private let mimeType: String
    private let onFailure: (MediaPlaybackError) -> Void
    private var operationID = UUID()
    private var opening = false

    init(client: any MediaPlaybackClient, path: String, mimeType: String,
         onFailure: @escaping (MediaPlaybackError) -> Void) {
        self.client = client
        self.path = path
        self.mimeType = mimeType
        self.onFailure = onFailure
    }

    public func start() {
        guard !opening, phase != .ready, phase != .invalidated else { return }
        let operation = UUID()
        operationID = operation
        opening = true
        phase = .loading
        let client = self.client, path = self.path, mimeType = self.mimeType
        Task { [weak self] in
            do {
                let source = try await client.openMediaPlayback(path: path, mimeType: mimeType)
                guard let self, self.operationID == operation, self.phase == .loading else {
                    await source.close()
                    return
                }
                self.opening = false
                self.source = DirectoryBoundPlaybackSource(source: source, owner: self)
                self.phase = .ready
            } catch {
                guard let self else { return }
                let failure = error as? MediaPlaybackError ?? .unavailable
                self.onFailure(failure)
                guard self.operationID == operation, self.phase == .loading else { return }
                self.opening = false
                self.phase = .failed(failure)
            }
        }
    }

    public func invalidate() {
        operationID = UUID()
        phase = .invalidated
        closeSource()
    }

    public func reportPlaybackFailure() {
        guard phase == .ready else { return }
        fail(.unsupported)
    }

    fileprivate func fail(_ failure: MediaPlaybackError) {
        onFailure(failure)
        guard phase == .ready else { return }
        phase = .failed(failure)
        closeSource()
    }

    private func closeSource() {
        let source = self.source
        self.source = nil
        Task { await source?.close() }
    }
}

@MainActor
final class DirectoryPlaybackState {
    private var context: DirectoryPreviewContext?
    private var playback: DirectoryPlaybackModel?

    func model(for target: DirectoryPreviewTarget, client: any MediaPlaybackClient,
               onFailure: @escaping (MediaPlaybackError) -> Void) -> DirectoryPlaybackModel {
        if context == target.context, let playback { return playback }
        invalidate()
        let model = DirectoryPlaybackModel(
            client: client, path: target.item.path, mimeType: target.item.mimeType ?? "",
            onFailure: onFailure
        )
        context = target.context
        playback = model
        return model
    }

    func invalidate() {
        playback?.invalidate()
        playback = nil
        context = nil
    }
}

/// No buffered read can escape after its preview was invalidated on MainActor.
@MainActor
private final class DirectoryBoundPlaybackSource: MediaPlaybackSource {
    nonisolated let content: MediaPlaybackContent
    private let source: any MediaPlaybackSource
    private weak var owner: DirectoryPlaybackModel?

    init(source: any MediaPlaybackSource, owner: DirectoryPlaybackModel) {
        self.source = source
        self.owner = owner
        content = source.content
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard owner?.phase == .ready else { throw MediaPlaybackError.closed }
        do {
            let bytes = try await source.read(offset: offset, length: length)
            guard owner?.phase == .ready else { throw MediaPlaybackError.closed }
            return bytes
        } catch {
            let failure = error as? MediaPlaybackError ?? .unavailable
            if failure != .closed { owner?.fail(failure) }
            throw failure
        }
    }

    func close() async { await source.close() }
}
