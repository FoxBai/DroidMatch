import DroidMatchCore

/// Pure debounce/admission state for product file and media search.
///
/// A debounce deadline may arrive while listing, mutation, or transfer work has
/// disabled the browser. The latest edit remains pending until that shared busy
/// state clears, while a directory or sort change invalidates the old context.
package struct ProductFileBrowserSearchState {
    package struct Token: Equatable {
        fileprivate let value: UInt64
    }

    private struct Context: Equatable {
        let path: String
        let pageSize: UInt32
        let sortField: DirectorySortField
        let descending: Bool

        init(_ query: DirectoryListingQuery) {
            path = query.path
            pageSize = query.pageSize
            sortField = query.sortField
            descending = query.descending
        }
    }

    private struct Pending {
        let token: Token
        let text: String
        let context: Context
        var debounceElapsed: Bool
    }

    private var nextToken: UInt64 = 0
    private var pending: Pending?

    package init() {}

    package mutating func edit(
        _ text: String,
        currentQuery: DirectoryListingQuery?
    ) -> Token? {
        invalidateToken()
        guard let currentQuery, text != currentQuery.searchQuery else {
            pending = nil
            return nil
        }
        let token = Token(value: nextToken)
        pending = Pending(
            token: token,
            text: text,
            context: Context(currentQuery),
            debounceElapsed: false
        )
        return token
    }

    package mutating func debounceFinished(
        token: Token,
        currentQuery: DirectoryListingQuery?,
        isBusy: Bool
    ) -> DirectoryListingQuery? {
        guard pending?.token == token else { return nil }
        pending?.debounceElapsed = true
        return consumeIfReady(currentQuery: currentQuery, isBusy: isBusy)
    }

    package mutating func becameAvailable(
        currentQuery: DirectoryListingQuery?,
        isBusy: Bool
    ) -> DirectoryListingQuery? {
        consumeIfReady(currentQuery: currentQuery, isBusy: isBusy)
    }

    /// Reconciles an externally changed query without overwriting a newer edit
    /// when only the active search term changed in the same directory context.
    package mutating func synchronize(to query: DirectoryListingQuery?) -> String {
        guard let query else {
            cancel()
            return ""
        }
        guard let pending else { return query.searchQuery }
        guard pending.context == Context(query) else {
            cancel()
            return query.searchQuery
        }
        return pending.text
    }

    package mutating func cancel() {
        invalidateToken()
        pending = nil
    }

    private mutating func consumeIfReady(
        currentQuery: DirectoryListingQuery?,
        isBusy: Bool
    ) -> DirectoryListingQuery? {
        guard !isBusy, let pending, pending.debounceElapsed else { return nil }
        guard let currentQuery, pending.context == Context(currentQuery) else {
            cancel()
            return nil
        }
        self.pending = nil
        guard pending.text != currentQuery.searchQuery else { return nil }
        return DirectoryListingQuery(
            path: currentQuery.path,
            pageSize: currentQuery.pageSize,
            sortField: currentQuery.sortField,
            descending: currentQuery.descending,
            searchQuery: pending.text
        )
    }

    private mutating func invalidateToken() {
        nextToken &+= 1
    }
}
