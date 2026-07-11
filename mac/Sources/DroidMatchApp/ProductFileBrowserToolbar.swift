import DroidMatchCore
import SwiftUI

/// Stateless toolbar boundary for the file browser.
///
/// Keeping enablement decisions in `State` makes this component easy to review
/// without moving navigation or mutation ownership out of the parent view.
struct ProductFileBrowserToolbar: ToolbarContent {
    struct State {
        let canGoBack: Bool
        let canRefreshAndSort: Bool
        let canUpload: Bool
        let canCreateFolder: Bool
        let canSelect: Bool
        let isSelecting: Bool
        let canToggleAll: Bool
        let allLoadedSelected: Bool
        let canDownloadSelection: Bool
        let canDeleteSelection: Bool
        let isMediaDirectory: Bool
        let prefersMediaGrid: Bool
        let sortField: DirectorySortField?
        let descending: Bool?
    }

    struct Actions {
        let goBack: () -> Void
        let refresh: () -> Void
        let changeSort: (DirectorySortField?, Bool?) -> Void
        let upload: () -> Void
        let createFolder: () -> Void
        let toggleSelecting: () -> Void
        let toggleAll: () -> Void
        let downloadSelection: () -> Void
        let deleteSelection: () -> Void
        let toggleMediaLayout: () -> Void
    }

    let state: State
    let actions: Actions

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: actions.goBack) {
                Label(AppStrings.back, systemImage: "chevron.left")
            }
            .disabled(!state.canGoBack)

            Button(action: actions.refresh) {
                Label(AppStrings.refresh, systemImage: "arrow.clockwise")
            }
            .disabled(!state.canRefreshAndSort)

            sortMenu

            Button(action: actions.upload) {
                Label(AppStrings.upload, systemImage: "arrow.up.doc")
            }
            .disabled(!state.canUpload)

            Button(action: actions.createFolder) {
                Label(AppStrings.newFolder, systemImage: "folder.badge.plus")
            }
            .disabled(!state.canCreateFolder)

            Button(action: actions.toggleSelecting) {
                Label(
                    state.isSelecting ? AppStrings.done : AppStrings.select,
                    systemImage: state.isSelecting ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .disabled(!state.canSelect)

            if state.isSelecting {
                selectionActions
            }

            if state.isMediaDirectory {
                Button(action: actions.toggleMediaLayout) {
                    Label(
                        state.prefersMediaGrid ? AppStrings.showAsList : AppStrings.showAsGrid,
                        systemImage: state.prefersMediaGrid ? "list.bullet" : "square.grid.2x2"
                    )
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            sortButton(AppStrings.sortByName, field: .name)
            sortButton(AppStrings.sortByDate, field: .modifiedTime)
            sortButton(AppStrings.sortBySize, field: .size)
            Divider()
            Button { actions.changeSort(nil, false) } label: {
                sortLabel(
                    AppStrings.ascending,
                    selected: state.sortField != .providerDefault && state.descending == false
                )
            }
            Button { actions.changeSort(nil, true) } label: {
                sortLabel(
                    AppStrings.descending,
                    selected: state.sortField != .providerDefault && state.descending == true
                )
            }
        } label: {
            Label(AppStrings.sort, systemImage: "arrow.up.arrow.down")
        }
        .disabled(!state.canRefreshAndSort)
    }

    @ViewBuilder
    private var selectionActions: some View {
        Button(action: actions.toggleAll) {
            Label(
                state.allLoadedSelected ? AppStrings.clearSelection : AppStrings.selectAllLoaded,
                systemImage: state.allLoadedSelected ? "square" : "checkmark.square"
            )
        }
        .disabled(!state.canToggleAll)

        Button(action: actions.downloadSelection) {
            Label(AppStrings.downloadSelected, systemImage: "arrow.down.doc")
        }
        .disabled(!state.canDownloadSelection)

        Button(role: .destructive, action: actions.deleteSelection) {
            Label(AppStrings.delete, systemImage: "trash")
        }
        .disabled(!state.canDeleteSelection)
    }

    private func sortButton(_ title: String, field: DirectorySortField) -> some View {
        Button { actions.changeSort(field, nil) } label: {
            sortLabel(title, selected: state.sortField == field)
        }
    }

    private func sortLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected { Image(systemName: "checkmark") }
        }
    }
}
