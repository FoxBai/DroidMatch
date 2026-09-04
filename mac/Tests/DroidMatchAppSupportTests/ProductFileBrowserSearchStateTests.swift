import DroidMatchCore
import Testing
@testable import DroidMatchAppSupport

@Test
func fileBrowserSearchWaitsForBusyWorkThenUsesLatestQueryContext() throws {
    var state = ProductFileBrowserSearchState()
    let current = DirectoryListingQuery(
        path: "dm://app-sandbox/",
        pageSize: 500,
        sortField: .modifiedTime,
        descending: true
    )
    let edited = state.edit("report", currentQuery: current)
    let token = try #require(edited)

    let busyDeadline = state.debounceFinished(
        token: token,
        currentQuery: current,
        isBusy: true
    )
    #expect(busyDeadline == nil)
    let available = state.becameAvailable(currentQuery: current, isBusy: false)
    let query = try #require(available)
    #expect(query == DirectoryListingQuery(
        path: current.path,
        pageSize: current.pageSize,
        sortField: current.sortField,
        descending: current.descending,
        searchQuery: "report"
    ))
    let repeatedAvailability = state.becameAvailable(currentQuery: current, isBusy: false)
    #expect(repeatedAvailability == nil)
}

@Test
func fileBrowserSearchRejectsStaleDebounceAndKeepsNewestEdit() throws {
    var state = ProductFileBrowserSearchState()
    let current = DirectoryListingQuery(path: "dm://media-images/media/")
    let oldEdit = state.edit("a", currentQuery: current)
    let oldToken = try #require(oldEdit)
    let latestEdit = state.edit("album", currentQuery: current)
    let latestToken = try #require(latestEdit)

    let staleQuery = state.debounceFinished(
        token: oldToken,
        currentQuery: current,
        isBusy: false
    )
    #expect(staleQuery == nil)
    let latestQuery = state.debounceFinished(
        token: latestToken,
        currentQuery: current,
        isBusy: false
    )
    let query = try #require(latestQuery)
    #expect(query.searchQuery == "album")
}

@Test
func fileBrowserSearchSynchronizesAndRejectsChangedContext() throws {
    var state = ProductFileBrowserSearchState()
    let current = DirectoryListingQuery(path: "dm://app-sandbox/", searchQuery: "a")
    let edited = state.edit("ab", currentQuery: current)
    let token = try #require(edited)
    let inFlight = DirectoryListingQuery(path: current.path, searchQuery: "a")

    let synchronizedText = state.synchronize(to: inFlight)
    #expect(synchronizedText == "ab")
    let busyDeadline = state.debounceFinished(
        token: token,
        currentQuery: inFlight,
        isBusy: true
    )
    #expect(busyDeadline == nil)

    let navigated = DirectoryListingQuery(path: "dm://app-sandbox/other/")
    let navigatedText = state.synchronize(to: navigated)
    #expect(navigatedText == "")
    let staleAvailability = state.becameAvailable(currentQuery: navigated, isBusy: false)
    #expect(staleAvailability == nil)

    let cancelEdit = state.edit("old", currentQuery: navigated)
    let cancelToken = try #require(cancelEdit)
    state.cancel()
    let cancelledQuery = state.debounceFinished(
        token: cancelToken,
        currentQuery: navigated,
        isBusy: false
    )
    #expect(cancelledQuery == nil)
}
