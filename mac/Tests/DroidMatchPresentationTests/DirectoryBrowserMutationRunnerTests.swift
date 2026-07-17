@testable import DroidMatchCore
@testable import DroidMatchPresentation
import Testing

@Test
@MainActor
func directoryBrowserMutationRunnerIsSingleFlightAndReopensAfterCompletion() async throws {
    let client = DirectoryListingClientProbe()
    await client.setCreateHold(true)
    let runner = DirectoryBrowserMutationRunner(client: client)
    let query = DirectoryListingQuery(path: "dm://app-sandbox/")
    var completedCount = 0

    let completion: DirectoryBrowserMutationRunner.Completion = { outcome in
        if case .completed = outcome {
            completedCount += 1
        }
    }

    #expect(runner.createDirectory(
        path: "dm://app-sandbox/first/",
        query: query,
        completion: completion
    ))
    for _ in 0..<200 {
        if await client.lastCreatedPath() != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await client.lastCreatedPath() == "dm://app-sandbox/first/")

    #expect(!runner.delete(
        path: "dm://app-sandbox/must-not-run",
        recursive: false,
        query: query,
        completion: completion
    ))
    #expect(await client.deletes().isEmpty)

    await client.completeCreate()
    for _ in 0..<200 where completedCount == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(completedCount == 1)

    #expect(runner.delete(
        path: "dm://app-sandbox/second",
        recursive: false,
        query: query,
        completion: completion
    ))
    for _ in 0..<200 where completedCount < 2 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await client.deletes().map(\.0) == ["dm://app-sandbox/second"])
    #expect(completedCount == 2)
}
