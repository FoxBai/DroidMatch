import DroidMatchPresentation
import Foundation
import SwiftUI

/// Stateless list/grid rendering for the authenticated file browser.
///
/// The parent remains the sole owner of navigation, selection, native panels,
/// mutations, and transfer submission. This boundary receives one immutable
/// rendering snapshot and bounded actions, so it cannot create a second browser
/// or queue state machine.
struct ProductFileBrowserContent: View {
    struct State {
        let entries: [DirectoryBrowserItem]
        let phase: DirectoryBrowserPhase
        let isBusy: Bool
        let isSearching: Bool
        let isMediaDirectory: Bool
        let prefersMediaGrid: Bool
        let canLoadMore: Bool
        let allowsUpload: Bool
        let allowsTransferSubmission: Bool
        let isSelecting: Bool
        let selectedPaths: Set<String>
        let thumbnails: [String: Data]
    }

    struct Actions {
        let open: (DirectoryBrowserItem) -> Void
        let preview: (DirectoryBrowserItem) -> Void
        let download: (DirectoryBrowserItem) -> Void
        let upload: (DirectoryBrowserItem) -> Void
        let rename: (DirectoryBrowserItem) -> Void
        let delete: (DirectoryBrowserItem) -> Void
        let toggleSelection: (DirectoryBrowserItem) -> Void
        let loadThumbnail: (DirectoryBrowserItem) -> Void
        let loadMore: () -> Void
    }

    let state: State
    let actions: Actions

    @ViewBuilder
    var body: some View {
        if state.entries.isEmpty && state.isBusy {
            ProgressView(state.isMediaDirectory
                ? AppStrings.loadingMediaItems
                : AppStrings.loadingFiles)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.entries.isEmpty && state.phase == .failed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.entries.isEmpty {
            ProductFileBrowserEmptyState(
                isSearching: state.isSearching,
                isMediaDirectory: state.isMediaDirectory
            )
        } else if state.isMediaDirectory && state.prefersMediaGrid {
            mediaGrid
        } else {
            fileList
        }
    }

    private var fileList: some View {
        List {
            ForEach(state.entries) { entry in
                FileEntryRow(
                    entry: entry,
                    open: { actions.open(entry) },
                    preview: { actions.preview(entry) },
                    download: { actions.download(entry) },
                    upload: { actions.upload(entry) },
                    allowsUpload: state.allowsUpload,
                    allowsTransferSubmission: state.allowsTransferSubmission,
                    rename: { actions.rename(entry) },
                    delete: { actions.delete(entry) },
                    isSelecting: state.isSelecting,
                    isSelected: state.selectedPaths.contains(entry.path),
                    toggleSelection: { actions.toggleSelection(entry) },
                    thumbnailData: state.thumbnails[entry.path],
                    loadThumbnail: { actions.loadThumbnail(entry) }
                )
            }
            if state.canLoadMore {
                HStack {
                    Spacer()
                    Button(AppStrings.loadMore, action: actions.loadMore)
                        .disabled(state.isBusy)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.inset)
    }

    private var mediaGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 138, maximum: 190), spacing: 14)],
                spacing: 16
            ) {
                ForEach(state.entries) { entry in
                    MediaGridCard(
                        entry: entry,
                        thumbnailData: state.thumbnails[entry.path],
                        isSelecting: state.isSelecting,
                        isSelected: state.selectedPaths.contains(entry.path),
                        activate: { activate(entry) },
                        download: { actions.download(entry) },
                        upload: { actions.upload(entry) },
                        allowsUpload: state.allowsUpload,
                        allowsTransferSubmission: state.allowsTransferSubmission,
                        rename: { actions.rename(entry) },
                        delete: { actions.delete(entry) },
                        loadThumbnail: { actions.loadThumbnail(entry) }
                    )
                }
            }
            .padding(18)
            if state.canLoadMore {
                Button(AppStrings.loadMore, action: actions.loadMore)
                    .disabled(state.isBusy)
                    .padding(.bottom, 18)
            }
        }
    }

    private func activate(_ entry: DirectoryBrowserItem) {
        if state.isSelecting {
            actions.toggleSelection(entry)
        } else if entry.canBrowse {
            actions.open(entry)
        } else if state.allowsUpload && entry.canAcceptUpload {
            actions.upload(entry)
        } else {
            actions.preview(entry)
        }
    }
}
