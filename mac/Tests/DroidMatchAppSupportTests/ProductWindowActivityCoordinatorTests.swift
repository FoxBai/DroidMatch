import Foundation
import Testing
@testable import DroidMatchAppSupport

@Test @MainActor
func windowActivityCoordinatorKeepsSharedDiscoveryUntilLastWindowLeaves() {
    var starts = 0
    var stops = 0
    let coordinator = ProductWindowActivityCoordinator(
        onFirstActiveWindow: { starts += 1 },
        onLastActiveWindow: { stops += 1 }
    )
    let first = UUID()
    let second = UUID()

    coordinator.setActive(true, windowID: first)
    coordinator.setActive(true, windowID: first)
    coordinator.setActive(true, windowID: second)
    #expect(starts == 1)
    coordinator.setActive(false, windowID: first)
    #expect(stops == 0)
    coordinator.setActive(false, windowID: second)
    #expect(stops == 1)

    coordinator.setActive(true, windowID: first)
    #expect(starts == 2)
    coordinator.invalidateForRuntimeReplacement()
    coordinator.invalidateForRuntimeReplacement()
    #expect(stops == 2)
    coordinator.setActive(true, windowID: second)
    #expect(starts == 2)
}
