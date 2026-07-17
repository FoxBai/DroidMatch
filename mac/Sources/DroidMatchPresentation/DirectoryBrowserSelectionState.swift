import Foundation

/// Pure, view-owned selection state for one directory-browser surface.
///
/// The SwiftUI parent still owns panels and side effects. This value only keeps
/// selection-mode/path invariants, preserves model row order when projecting
/// selected entries, and reconciles accepted batch work without observing or
/// mutating the browser model itself.
public struct DirectoryBrowserSelectionState: Sendable, Equatable {
    public private(set) var isSelecting = false
    public private(set) var selectedPaths = Set<String>()

    public init() {}

    public mutating func toggleMode() {
        isSelecting.toggle()
        if !isSelecting { selectedPaths.removeAll() }
    }

    public mutating func clear() {
        isSelecting = false
        selectedPaths.removeAll()
    }

    public mutating func synchronize(visibleEntries: [DirectoryBrowserItem]) {
        selectedPaths.formIntersection(Set(visibleEntries.map(\.path)))
    }

    @discardableResult
    public mutating func toggle(_ entry: DirectoryBrowserItem) -> Bool {
        guard Self.isSelectable(entry) else { return false }
        if !selectedPaths.insert(entry.path).inserted {
            selectedPaths.remove(entry.path)
        }
        return true
    }

    public func selectableEntries(
        in entries: [DirectoryBrowserItem]
    ) -> [DirectoryBrowserItem] {
        entries.filter(Self.isSelectable)
    }

    public func selectedEntries(
        in entries: [DirectoryBrowserItem]
    ) -> [DirectoryBrowserItem] {
        entries.filter { selectedPaths.contains($0.path) }
    }

    public func allLoadedSelectableEntriesAreSelected(
        in entries: [DirectoryBrowserItem]
    ) -> Bool {
        let selectable = selectableEntries(in: entries)
        return !selectable.isEmpty
            && selectable.allSatisfy { selectedPaths.contains($0.path) }
    }

    public mutating func toggleAllLoaded(in entries: [DirectoryBrowserItem]) {
        let selectable = selectableEntries(in: entries)
        if !selectable.isEmpty
            && selectable.allSatisfy({ selectedPaths.contains($0.path) }) {
            selectedPaths.removeAll()
        } else {
            selectedPaths.formUnion(selectable.map(\.path))
        }
    }

    public func canDeleteSelection(in entries: [DirectoryBrowserItem]) -> Bool {
        let selected = selectedEntries(in: entries)
        return !selected.isEmpty && selected.allSatisfy {
            $0.canWrite && ($0.kind == .file || $0.kind == .directory)
        }
    }

    public func canDownloadSelection(in entries: [DirectoryBrowserItem]) -> Bool {
        let selected = selectedEntries(in: entries)
        return !selected.isEmpty && selected.allSatisfy {
            $0.kind == .file && $0.canRead
        }
    }

    /// Removes only work actually accepted by a partial batch submission.
    /// Unaccepted or newly selected paths remain available for retry.
    public mutating func removeAcceptedPaths(_ paths: Set<String>) {
        selectedPaths.subtract(paths)
        if selectedPaths.isEmpty { isSelecting = false }
    }

    private static func isSelectable(_ entry: DirectoryBrowserItem) -> Bool {
        (entry.kind == .file && (entry.canRead || entry.canWrite))
            || (entry.kind == .directory && entry.canWrite)
    }
}
