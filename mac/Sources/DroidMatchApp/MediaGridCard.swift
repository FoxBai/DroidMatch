import AppKit
import DroidMatchPresentation
import SwiftUI

/// A compact media-first browser cell. It deliberately consumes the same
/// privacy-bounded row and thumbnail state as the list, rather than introducing
/// a second media cache or bypassing the authenticated browser model.
struct MediaGridCard: View {
    let entry: DirectoryBrowserItem
    let thumbnailData: Data?
    let isSelecting: Bool
    let isSelected: Bool
    let activate: () -> Void
    let download: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let loadThumbnail: () -> Void

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    preview
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? .blue : .white)
                            .shadow(radius: 2)
                            .padding(8)
                    }
                }
                Text(FileEntryDisplayName.value(entry))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let size = entry.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let modified = entry.modifiedUnixMillis {
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(modified) / 1_000),
                        format: .dateTime.year().month().day()
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onAppear(perform: loadThumbnail)
        .contextMenu {
            if !isSelecting {
                if entry.kind == .file && entry.canRead {
                    Button(AppStrings.download, action: download)
                }
                if entry.canWrite {
                    Button(AppStrings.rename, action: rename)
                    Button(AppStrings.delete, role: .destructive, action: delete)
                }
            }
        }
        .accessibilityHint(
            isSelecting ? AppStrings.select
                : (entry.kind == .directory ? AppStrings.openFolder : AppStrings.previewMedia)
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnailData, let image = NSImage(data: thumbnailData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .clipped()
        } else {
            ZStack {
                Color.secondary.opacity(0.10)
                Image(systemName: entry.mimeType?.hasPrefix("video/") == true ? "video.fill" : "photo.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 112)
        }
    }
}
