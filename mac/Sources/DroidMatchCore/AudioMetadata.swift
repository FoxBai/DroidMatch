import Foundation

/// Display-only labels. A track, album or artist label is never file identity.
/// 中文：音乐标签只用于展示，文件操作继续使用原文件名和 canonical path。
public struct AudioMetadata: Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil) {
        self.title = Self.label(title)
        self.artist = Self.label(artist)
        self.album = Self.label(album)
    }

    public var isEmpty: Bool { title == nil && artist == nil && album == nil }

    static func admits(path: String, kind: DirectoryEntryKind, mimeType: String?) -> Bool {
        let prefix = "dm://media-audio/media/"
        guard kind == .file, mimeType?.hasPrefix("audio/") == true,
              path.hasPrefix(prefix) else { return false }
        let token = path.dropFirst(prefix.count)
        return !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) }
            && Int64(token) != nil
    }

    private static func label(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 512,
              let visible = ProductDisplayText.value(raw),
              visible.caseInsensitiveCompare("<unknown>") != .orderedSame else { return nil }
        return visible
    }
}
