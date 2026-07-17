import DroidMatchCore
import Testing
@testable import DroidMatchPresentation

@Test func directoryBrowserSelectionTracksOnlyEligibleVisibleEntries() {
    let readableFile = selectionItem(path: "dm://root/read", canRead: true)
    let writableFile = selectionItem(path: "dm://root/write", canWrite: true)
    let readOnlyDirectory = selectionItem(
        path: "dm://root/read-only/",
        kind: .directory,
        canRead: true
    )
    let writableDirectory = selectionItem(
        path: "dm://root/write/",
        kind: .directory,
        canWrite: true
    )
    var state = DirectoryBrowserSelectionState()

    state.toggleMode()
    let acceptedReadableFile = state.toggle(readableFile)
    let acceptedWritableFile = state.toggle(writableFile)
    let acceptedReadOnlyDirectory = state.toggle(readOnlyDirectory)
    let acceptedWritableDirectory = state.toggle(writableDirectory)
    #expect(acceptedReadableFile)
    #expect(acceptedWritableFile)
    #expect(!acceptedReadOnlyDirectory)
    #expect(acceptedWritableDirectory)
    #expect(state.selectedPaths == [
        readableFile.path,
        writableFile.path,
        writableDirectory.path,
    ])

    state.synchronize(visibleEntries: [readableFile, readOnlyDirectory])
    #expect(state.selectedPaths == [readableFile.path])
    #expect(state.isSelecting)
}

@Test func directoryBrowserSelectionPreservesRowOrderAndBulkCapabilities() {
    let readableFile = selectionItem(path: "dm://root/read", canRead: true)
    let writableFile = selectionItem(
        path: "dm://root/write",
        canRead: true,
        canWrite: true
    )
    let writableDirectory = selectionItem(
        path: "dm://root/folder/",
        kind: .directory,
        canWrite: true
    )
    let entries = [writableDirectory, readableFile, writableFile]
    var state = DirectoryBrowserSelectionState()

    state.toggleMode()
    state.toggle(readableFile)
    state.toggle(writableFile)
    #expect(state.selectedEntries(in: entries).map(\.path)
        == [readableFile.path, writableFile.path])
    #expect(state.canDownloadSelection(in: entries))
    #expect(!state.canDeleteSelection(in: entries))

    state.toggleAllLoaded(in: entries)
    #expect(state.allLoadedSelectableEntriesAreSelected(in: entries))
    #expect(!state.canDownloadSelection(in: entries))
    #expect(!state.canDeleteSelection(in: entries))
    state.toggleAllLoaded(in: entries)
    #expect(state.selectedPaths.isEmpty)
    #expect(state.isSelecting)
}

@Test func directoryBrowserSelectionRemovesOnlyAcceptedBatchPaths() {
    let first = selectionItem(path: "dm://root/first", canRead: true)
    let second = selectionItem(path: "dm://root/second", canRead: true)
    var state = DirectoryBrowserSelectionState()
    state.toggleMode()
    state.toggle(first)
    state.toggle(second)

    state.removeAcceptedPaths([first.path])
    #expect(state.selectedPaths == [second.path])
    #expect(state.isSelecting)

    state.removeAcceptedPaths([second.path])
    #expect(state.selectedPaths.isEmpty)
    #expect(!state.isSelecting)
}

private func selectionItem(
    path: String,
    kind: DirectoryEntryKind = .file,
    canRead: Bool = false,
    canWrite: Bool = false
) -> DirectoryBrowserItem {
    DirectoryBrowserItem(DirectoryListingEntry(
        path: path,
        name: path,
        kind: kind,
        sizeBytes: nil,
        modifiedUnixMillis: nil,
        mimeType: nil,
        canRead: canRead,
        canWrite: canWrite
    ))
}
