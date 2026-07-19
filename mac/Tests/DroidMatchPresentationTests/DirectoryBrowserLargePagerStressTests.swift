@testable import DroidMatchCore
@testable import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func directoryBrowserAppliesTenMaximumPagesWithinOfflineSmokeBudget() async throws {
    let pageSize = 1_000
    let pageCount = 10
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    let clock = ContinuousClock()
    let started = clock.now

    model.load(DirectoryListingQuery(
        path: "dm://app-sandbox/",
        pageSize: UInt32(pageSize)
    ))
    for pageIndex in 0..<pageCount {
        let callNumber = pageIndex + 1
        #expect(await waitForDirectoryCallCount(client, callNumber))
        let expectedToken = pageIndex == 0 ? nil : "page-\(callNumber)"
        #expect(await client.call(callNumber)?.pageToken == expectedToken)

        let lowerBound = pageIndex * pageSize
        let nextToken = pageIndex + 1 < pageCount
            ? "page-\(callNumber + 1)"
            : nil
        await client.succeed(
            callNumber,
            largeDirectoryPage(
                lowerBound..<(lowerBound + pageSize),
                next: nextToken
            )
        )
        #expect(await waitForDirectoryPhase(model, .loaded))
        if nextToken != nil {
            #expect(model.loadMore())
        }
    }

    let elapsed = started.duration(to: clock.now)
    let expectedPaths = (0..<(pageSize * pageCount)).map {
        String(format: "dm://app-sandbox/file-%04d.bin", $0)
    }
    #expect(elapsed < .seconds(5))
    #expect(model.entries.map(\.path) == expectedPaths)
    #expect(Set(model.entries.map(\.path)).count == expectedPaths.count)
    #expect(!model.canLoadMore)
    #expect(await client.count() == pageCount)
}
