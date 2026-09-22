import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

/// Labels are descriptive; the filename remains visible before downloading.
/// 中文：标签仅用于展示，下载前仍可看到原文件名。
struct FileEntryMetadataHeading: View {
    let entry: DirectoryBrowserItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let entry {
                Text(verbatim: entry.audioMetadata?.title ?? FileEntryDisplayName.value(entry))
                    .font(.headline).lineLimit(1)
                MusicMetadataSummary(metadata: entry.audioMetadata)
                if let title = entry.audioMetadata?.title,
                   title != FileEntryDisplayName.value(entry) {
                    Text(verbatim: "\(AppStrings.fileName): \(FileEntryDisplayName.value(entry))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(AppStrings.previewUnavailable).font(.headline)
            }
        }
    }
}

struct MusicMetadataSummary: View {
    let metadata: AudioMetadata?

    var body: some View {
        if let metadata, metadata.artist != nil || metadata.album != nil {
            HStack(spacing: 6) {
                if let artist = metadata.artist {
                    Text(verbatim: artist).lineLimit(1)
                        .accessibilityLabel("\(AppStrings.musicArtist): \(artist)")
                }
                if metadata.artist != nil && metadata.album != nil {
                    Text("·").accessibilityHidden(true)
                }
                if let album = metadata.album {
                    Text(verbatim: album).lineLimit(1)
                        .accessibilityLabel("\(AppStrings.musicAlbum): \(album)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
