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
    let upload: () -> Void
    let allowsUpload: Bool
    let allowsTransferSubmission: Bool
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
                            .accessibilityHidden(true)
                    }
                }
                Text(FileEntryDisplayName.value(entry))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isUnreadableContainer {
                    Label(AppStrings.filePermissionRequired, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
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
        .disabled(isSelecting ? !canSelect : !canActivate)
        .accessibilityValue(selectionAccessibilityValue)
        .onAppear(perform: loadThumbnail)
        .contextMenu {
            if !isSelecting {
                if canDownload {
                    Button(AppStrings.download, action: download)
                }
                if canUploadWithoutOpening {
                    Button(AppStrings.upload, action: upload)
                }
                if entry.canWrite && (entry.kind == .file || entry.kind == .directory) {
                    Button(AppStrings.rename, action: rename)
                    Button(AppStrings.delete, role: .destructive, action: delete)
                }
            }
        }
        .accessibilityHint(
            isSelecting ? AppStrings.select
                : (entry.canBrowse ? AppStrings.openFolder
                    : (canUploadWithoutOpening ? AppStrings.upload
                        : (entry.canRead ? AppStrings.previewMedia
                            : (transferUploadUnavailable
                                ? AppStrings.transferSubmissionTemporarilyUnavailable
                                : AppStrings.filePermissionRequired))))
        )
    }

    private var selectionAccessibilityValue: String {
        guard isSelecting else { return "" }
        return isSelected ? AppStrings.selected : AppStrings.notSelected
    }

    private var canUploadWithoutOpening: Bool {
        allowsUpload
            && allowsTransferSubmission
            && entry.canAcceptUpload
            && !entry.canBrowse
    }

    private var canDownload: Bool {
        allowsTransferSubmission && entry.kind == .file && entry.canRead
    }

    private var transferUploadUnavailable: Bool {
        !allowsTransferSubmission
            && allowsUpload
            && entry.canAcceptUpload
            && !entry.canBrowse
    }

    private var isUnreadableContainer: Bool {
        !entry.canRead && (entry.kind == .directory || entry.kind == .virtual)
    }

    private var canSelect: Bool {
        (entry.kind == .file && (entry.canRead || entry.canWrite))
            || (entry.kind == .directory && entry.canWrite)
    }

    private var canActivate: Bool {
        entry.canBrowse
            || canUploadWithoutOpening
            || (entry.kind == .file && entry.canRead)
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
                .accessibilityHidden(true)
        } else {
            ZStack {
                Color.secondary.opacity(0.10)
                Image(systemName: entry.mimeType?.hasPrefix("video/") == true ? "video.fill" : "photo.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(height: 112)
        }
    }
}
