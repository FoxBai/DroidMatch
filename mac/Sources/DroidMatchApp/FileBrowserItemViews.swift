import AppKit
import DroidMatchPresentation
import SwiftUI

struct FileEntryRow: View {
    let entry: DirectoryBrowserItem
    let open: () -> Void
    let preview: () -> Void
    let download: () -> Void
    let upload: () -> Void
    let allowsUpload: Bool
    let rename: () -> Void
    let delete: () -> Void
    let isSelecting: Bool
    let isSelected: Bool
    let toggleSelection: () -> Void
    let thumbnailData: Data?
    let loadThumbnail: () -> Void

    var body: some View {
        Button(action: isSelecting ? toggleSelection : primaryAction) {
            HStack(spacing: 13) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(FileEntryDisplayName.value(entry))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let size = entry.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let mimeType = entry.mimeType {
                            Text(mimeType).lineLimit(1)
                        }
                        if let modified = entry.modifiedUnixMillis {
                            Text(
                                Date(timeIntervalSince1970: TimeInterval(modified) / 1_000),
                                format: .dateTime.year().month().day()
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if isUnreadableContainer {
                        Label(AppStrings.filePermissionRequired, systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer()
                trailingControls
                if canOpen {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else if canDownload {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .onAppear(perform: loadThumbnail)
        .contextMenu { contextMenu }
        .disabled(isSelecting ? !canSelect : !canActivate)
        .accessibilityHint(canOpen ? AppStrings.openFolder
            : (canPreview ? AppStrings.previewMedia
                : (canDownload ? AppStrings.downloadFile
                    : (canUploadWithoutOpening ? AppStrings.upload
                        : AppStrings.filePermissionRequired))))
    }

    @ViewBuilder
    private var trailingControls: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
        } else {
            if canUploadWithoutOpening {
                Button(action: upload) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .help(AppStrings.upload)
            }
            if entry.canWrite && (entry.kind == .file || entry.kind == .directory) {
                Button(action: rename) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help(AppStrings.rename)
                Button(action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help(AppStrings.delete)
            } else if entry.canWrite && !canUploadWithoutOpening {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .help(AppStrings.writable)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !isSelecting {
            if canOpen { Button(AppStrings.openFolder, action: open) }
            if canDownload { Button(AppStrings.download, action: download) }
            if canUploadWithoutOpening { Button(AppStrings.upload, action: upload) }
            if entry.canWrite && (entry.kind == .file || entry.kind == .directory) {
                Button(AppStrings.rename, action: rename)
                Button(AppStrings.delete, role: .destructive, action: delete)
            }
        }
    }

    private var canOpen: Bool { entry.canBrowse }
    private var canDownload: Bool { entry.kind == .file && entry.canRead }
    private var canPreview: Bool {
        entry.canRead && entry.kind == .file
            && (entry.path.hasPrefix("dm://media-images/media/")
            || entry.path.hasPrefix("dm://media-videos/media/"))
    }
    private var canUploadWithoutOpening: Bool {
        allowsUpload && entry.canAcceptUpload && !entry.canBrowse
    }
    private var isUnreadableContainer: Bool {
        !entry.canRead && (entry.kind == .directory || entry.kind == .virtual)
    }
    private var canActivate: Bool {
        canOpen || canPreview || canDownload || canUploadWithoutOpening
    }
    private var canSelect: Bool {
        (entry.kind == .file && (entry.canRead || entry.canWrite))
            || (entry.kind == .directory && entry.canWrite)
    }

    private func primaryAction() {
        if canOpen {
            open()
        } else if canPreview {
            preview()
        } else if canDownload {
            download()
        } else if canUploadWithoutOpening {
            upload()
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .virtual: return "externaldrive.fill"
        case .file: return "doc.fill"
        case .symlink: return "link"
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailData, let image = NSImage(data: thumbnailData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .directory: return .blue
        case .virtual: return .orange
        case .file, .symlink: return .secondary
        }
    }
}

struct MediaPreviewSheet: View {
    let entry: DirectoryBrowserItem
    @ObservedObject var model: DirectoryBrowserModel
    let download: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(FileEntryDisplayName.value(entry)).font(.headline).lineLimit(1)
                Spacer()
            }
            Group {
                if let data = model.preview?.encodedImage, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if model.previewFailed {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(AppStrings.previewUnavailable).font(.title3.weight(.semibold))
                    }
                } else {
                    ProgressView(AppStrings.loadingPreview)
                }
            }
            .frame(minWidth: 420, maxWidth: 720, minHeight: 320, maxHeight: 640)
            HStack {
                Spacer()
                Button(AppStrings.download, action: download)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!entry.canRead)
            }
        }
        .padding(20)
    }
}
