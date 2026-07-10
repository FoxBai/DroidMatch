import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductFileBrowserView: View {
    @ObservedObject var model: DirectoryBrowserModel
    @State private var history: [DirectoryListingQuery] = []

    var body: some View {
        VStack(spacing: 0) {
            browserHeader
            Divider()
            if model.phase == .failed {
                failureBanner
            }
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(AppStrings.files)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    goBack()
                } label: {
                    Label(AppStrings.back, systemImage: "chevron.left")
                }
                .disabled(history.isEmpty || isBusy)

                Button {
                    model.refresh()
                } label: {
                    Label(AppStrings.refresh, systemImage: "arrow.clockwise")
                }
                .disabled(model.query == nil || isBusy)
            }
        }
    }

    private var browserHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.authenticatedFiles)
                    .font(.headline)
                Text(model.query?.path ?? "dm://roots/")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && isBusy {
            ProgressView(AppStrings.loadingFiles)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(AppStrings.folderIsEmpty)
                    .font(.title3.weight(.semibold))
                Text(AppStrings.folderIsEmptyDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.entries) { entry in
                    FileEntryRow(entry: entry) {
                        open(entry)
                    }
                }
                if model.canLoadMore {
                    HStack {
                        Spacer()
                        Button(AppStrings.loadMore) {
                            model.loadMore()
                        }
                        .disabled(isBusy)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(.inset)
        }
    }

    private var failureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(failureText)
                .font(.subheadline)
            Spacer()
            Button(AppStrings.tryAgain) {
                if model.query != nil {
                    model.refresh()
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    private var isBusy: Bool {
        switch model.phase {
        case .loading, .refreshing, .loadingMore: return true
        case .idle, .loaded, .failed: return false
        }
    }

    private var failureText: String {
        switch model.failure {
        case .permissionRequired: return AppStrings.filePermissionRequired
        case .notFound: return AppStrings.fileLocationUnavailable
        case .unsupported: return AppStrings.fileOperationUnsupported
        case .invalidRequest, .invalidResponse: return AppStrings.fileResponseInvalid
        case .unavailable, .none: return AppStrings.fileConnectionUnavailable
        }
    }

    private func open(_ entry: DirectoryBrowserItem) {
        guard entry.kind == .directory || entry.kind == .virtual,
              let current = model.query else { return }
        history.append(current)
        model.load(
            DirectoryListingQuery(
                path: entry.path,
                pageSize: current.pageSize,
                sortField: current.sortField,
                descending: current.descending
            )
        )
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        model.load(previous)
    }
}

private struct FileEntryRow: View {
    let entry: DirectoryBrowserItem
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name ?? AppStrings.unnamedItem)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let size = entry.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let mimeType = entry.mimeType {
                            Text(mimeType)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.canWrite {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                        .help(AppStrings.writable)
                }
                if canOpen {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityHint(canOpen ? AppStrings.openFolder : "")
    }

    private var canOpen: Bool {
        entry.kind == .directory || entry.kind == .virtual
    }

    private var symbol: String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .virtual: return "externaldrive.fill"
        case .file: return "doc.fill"
        case .symlink: return "link"
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
