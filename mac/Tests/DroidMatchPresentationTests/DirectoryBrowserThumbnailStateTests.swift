import Foundation
import Testing
@testable import DroidMatchPresentation

@Test
func thumbnailStateCountsDrainingOldGenerationAgainstConcurrency() throws {
    var state = DirectoryBrowserThumbnailState(maximumActiveRequests: 2)
    let acceptedOldA = state.enqueue(path: "old-a")
    let acceptedOldB = state.enqueue(path: "old-b")
    let acceptedOldC = state.enqueue(path: "old-c")
    #expect(acceptedOldA)
    #expect(acceptedOldB)
    #expect(acceptedOldC)
    let firstCandidate = state.nextRequest(visiblePaths: ["old-a", "old-b", "old-c"])
    let secondCandidate = state.nextRequest(visiblePaths: ["old-a", "old-b", "old-c"])
    let first = try #require(firstCandidate)
    let second = try #require(secondCandidate)
    #expect(state.activeRequestCount == 2)

    state.invalidate(clearCache: true)
    let acceptedNew = state.enqueue(path: "new")
    #expect(acceptedNew)
    let blockedReplacement = state.nextRequest(visiblePaths: ["new"])
    #expect(blockedReplacement == nil)

    state.finish(first)
    let replacementCandidate = state.nextRequest(visiblePaths: ["new"])
    let replacement = try #require(replacementCandidate)
    #expect(replacement.path == "new")
    #expect(replacement.generation == state.generation)
    #expect(state.activeRequestCount == 2)
    state.finish(second)
    state.finish(replacement)
}

@Test
func thumbnailStateDeduplicatesAndDropsInvisibleOrFailedWork() throws {
    var state = DirectoryBrowserThumbnailState(maximumActiveRequests: 1)
    let acceptedVisible = state.enqueue(path: "visible")
    let acceptedDuplicate = state.enqueue(path: "visible")
    let acceptedHidden = state.enqueue(path: "hidden")
    #expect(acceptedVisible)
    #expect(!acceptedDuplicate)
    #expect(acceptedHidden)

    let visibleCandidate = state.nextRequest(visiblePaths: ["visible"])
    let visible = try #require(visibleCandidate)
    state.finish(visible)
    let recordedFailure = state.recordFailure(for: visible)
    let acceptedFailedPath = state.enqueue(path: "visible")
    #expect(recordedFailure)
    #expect(!acceptedFailedPath)
    let invisibleQueueResult = state.nextRequest(visiblePaths: ["visible"])
    #expect(invisibleQueueResult == nil)

    state.invalidate(clearCache: false)
    let acceptedAfterInvalidation = state.enqueue(path: "visible")
    #expect(acceptedAfterInvalidation)
}

@Test
func thumbnailStateBoundsAndSelectivelyRetainsCachedBytes() throws {
    var state = DirectoryBrowserThumbnailState(
        maximumCachedCount: 2,
        maximumCachedBytes: 4
    )
    for path in ["a", "b", "c"] {
        let accepted = state.enqueue(path: path)
        #expect(accepted)
        let keyCandidate = state.nextRequest(visiblePaths: [path])
        let key = try #require(keyCandidate)
        state.finish(key)
        let stored = state.store(Data(repeating: 1, count: 2), for: key)
        #expect(stored)
    }
    #expect(state.images == [
        "b": Data(repeating: 1, count: 2),
        "c": Data(repeating: 1, count: 2),
    ])

    state.invalidate(clearCache: false)
    #expect(state.images.count == 2)
    state.retainImages(for: ["c"])
    #expect(state.images == ["c": Data(repeating: 1, count: 2)])
    state.invalidate(clearCache: true)
    #expect(state.images.isEmpty)
}
