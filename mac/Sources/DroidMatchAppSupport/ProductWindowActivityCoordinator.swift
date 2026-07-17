import Combine
import Foundation

/// Process-owned lease set for a shared discovery model used by every window.
/// Closing or backgrounding one window cannot stop another active window.
@MainActor
package final class ProductWindowActivityCoordinator: ObservableObject {
    private let onFirstActiveWindow: @MainActor () -> Void
    private let onLastActiveWindow: @MainActor () -> Void
    private var activeWindowIDs: Set<UUID> = []
    private var runtimeInvalidated = false

    package init(
        onFirstActiveWindow: @escaping @MainActor () -> Void,
        onLastActiveWindow: @escaping @MainActor () -> Void
    ) {
        self.onFirstActiveWindow = onFirstActiveWindow
        self.onLastActiveWindow = onLastActiveWindow
    }

    package func setActive(_ active: Bool, windowID: UUID) {
        guard !runtimeInvalidated else { return }
        if active {
            let wasEmpty = activeWindowIDs.isEmpty
            guard activeWindowIDs.insert(windowID).inserted else { return }
            if wasEmpty { onFirstActiveWindow() }
        } else {
            guard activeWindowIDs.remove(windowID) != nil else { return }
            if activeWindowIDs.isEmpty { onLastActiveWindow() }
        }
    }

    package func invalidateForRuntimeReplacement() {
        guard !runtimeInvalidated else { return }
        runtimeInvalidated = true
        let hadActiveWindow = !activeWindowIDs.isEmpty
        activeWindowIDs.removeAll()
        if hadActiveWindow { onLastActiveWindow() }
    }
}
