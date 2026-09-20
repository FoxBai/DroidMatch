import Foundation

/// Playback consumes bounded ranges; it never publishes a device path as an asset URL.
/// 中文：播放只消费有界字节段，设备路径不会成为播放器 URL。
public struct MediaPlaybackContent: Sendable, Equatable {
    public let byteCount: Int64
    public let mimeType: String

    public init(byteCount: Int64, mimeType: String) {
        self.byteCount = byteCount
        self.mimeType = mimeType
    }
}

public enum MediaPlaybackError: Error, Sendable, Equatable {
    case invalidRequest
    case unsupported
    case permissionRequired
    case sourceChanged
    case unavailable
    case closed
    case busy
}

public protocol MediaPlaybackSource: Sendable {
    var content: MediaPlaybackContent { get }
    func read(offset: Int64, length: Int) async throws -> Data
    func close() async
}

public protocol MediaPlaybackClient: Sendable {
    func openMediaPlayback(path: String, mimeType: String) async throws -> any MediaPlaybackSource
}

public extension MediaPlaybackClient {
    func openMediaPlayback(path: String, mimeType: String) async throws -> any MediaPlaybackSource {
        throw MediaPlaybackError.unsupported
    }
}

public enum MediaPlaybackPolicy {
    public static let maximumReadBytes = 1_048_576

    public static func supports(mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return videoTypes.contains(mimeType) || audioTypes.contains(mimeType)
    }

    /// The MIME category cannot authorize a different provider namespace.
    /// 中文：音频/视频类型必须匹配各自的 MediaStore 来源。
    public static func supports(path: String, mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return (videoTypes.contains(mimeType) && mediaPath(path, root: "media-videos"))
            || (audioTypes.contains(mimeType) && isAudioPath(path))
    }

    public static func isAudioPath(_ path: String) -> Bool { mediaPath(path, root: "media-audio") }

    private static let videoTypes = ["video/mp4", "video/quicktime", "video/x-m4v", "video/3gpp"]
    private static let audioTypes = [
        "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/aac-adts",
        "audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav", "audio/vnd.wave",
        "audio/aiff", "audio/x-aiff"
    ]

    private static func mediaPath(_ path: String, root: String) -> Bool {
        let prefix = "dm://\(root)/media/"
        guard path.hasPrefix(prefix) else { return false }
        let token = path.dropFirst(prefix.count)
        return !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) }
            && Int64(token) != nil
    }

    public static func readLength(offset: Int64, requested: Int, total: Int64) throws -> Int {
        guard total > 0, offset >= 0, offset <= total,
              requested > 0, requested <= maximumReadBytes else {
            throw MediaPlaybackError.invalidRequest
        }
        return Int(min(Int64(requested), total - offset))
    }
}
