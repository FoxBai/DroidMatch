import DroidMatchCore
import Foundation

extension HarnessCommand {
    static func listDir(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let path = try options.value("--path") ?? "dm://roots/"
            return try await withAsyncControlClient(
                host: host,
                port: port,
                timeout: timeout
            ) { client in
                // Preserve the historical metric: connect is excluded, while
                // handshake plus the listing request are included.
                let startedMilliseconds = monotonicMilliseconds()
                _ = try await client.handshake()
                let response = try await client.listDir(path: path)
                let elapsedMilliseconds = max(
                    1,
                    monotonicMilliseconds() - startedMilliseconds
                )
                if response.hasError {
                    fputs(
                        "list-dir failed: \(response.error.code): \(response.error.message)\n",
                        stderr
                    )
                    return 1
                }

                let nextPageToken = response.nextPageToken.isEmpty
                    ? "<none>"
                    : response.nextPageToken
                print(
                    "list-dir passed path=\(path) entries=\(response.entries.count) "
                        + "next_page_token=\(nextPageToken) elapsed_ms=\(elapsedMilliseconds)"
                )
                for entry in response.entries {
                    print(
                        "\(entry.kind) \(entry.path) name=\"\(entry.name)\" "
                            + "size=\(entry.sizeBytes) read=\(entry.canRead) write=\(entry.canWrite)"
                    )
                }
                return 0
            }
        } catch {
            fputs("list-dir failed: \(error)\n", stderr)
            return 1
        }
    }

    /// Exhausts provider-owned pagination without printing opaque cursors or
    /// directory contents. Cross-page identity and cursor checks make this an
    /// evidence probe rather than a second product browser implementation.
    static func listDirAll(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let path = try options.requiredValue("--path")
            let pageSize = try options.uint32("--page-size") ?? 1_000
            let expectedTotal = try options.int("--expected-total")
            if let expectedTotal, expectedTotal < 0 {
                throw HarnessError.invalidOptionCombination("--expected-total must not be negative")
            }

            return try await withAsyncControlClient(
                host: host,
                port: port,
                timeout: timeout
            ) { client in
                let startedMilliseconds = monotonicMilliseconds()
                _ = try await client.handshake()
                let query = DirectoryListingQuery(
                    path: path,
                    pageSize: pageSize,
                    sortField: .name
                )
                var pageToken: String?
                var traversal = DirectoryListingTraversal()

                repeat {
                    let page = try await client.listDirectoryPage(
                        query: query,
                        pageToken: pageToken
                    )
                    pageToken = try traversal.accept(page)
                } while pageToken != nil

                if let expectedTotal, traversal.entryCount != expectedTotal {
                    throw HarnessError.invalidOptionCombination(
                        "listed \(traversal.entryCount) entries, expected \(expectedTotal)"
                    )
                }
                let elapsedMilliseconds = max(
                    1,
                    monotonicMilliseconds() - startedMilliseconds
                )
                print(
                    "list-dir-all passed pages=\(traversal.pageCounts.count) "
                        + "page_counts=\(traversal.pageCounts.map(String.init).joined(separator: ",")) "
                        + "entries=\(traversal.entryCount) elapsed_ms=\(elapsedMilliseconds)"
                )
                return 0
            }
        } catch {
            fputs("list-dir-all failed: \(error)\n", stderr)
            return 1
        }
    }

    static func listDirExpectError(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let path = try options.requiredValue("--path")
            let expectedErrorCode = try errorCode(from: options.requiredValue("--expected-error-code"))
            let expectedMessage = try options.value("--expected-message-contains")
            return try await withAsyncControlClient(
                host: host,
                port: port,
                timeout: timeout
            ) { client in
                _ = try await client.handshake()
                let response = try await client.listDir(path: path)
                guard response.hasError else {
                    throw HarnessError.expectedListDirErrorNotReceived(path)
                }
                guard response.error.code == expectedErrorCode else {
                    throw HarnessError.unexpectedRemoteErrorCode(
                        expected: expectedErrorCode,
                        actual: response.error.code,
                        message: response.error.message
                    )
                }
                if let expectedMessage, !response.error.message.contains(expectedMessage) {
                    throw HarnessError.unexpectedRemoteErrorMessage(
                        expectedSubstring: expectedMessage,
                        actual: response.error.message
                    )
                }
                print(
                    "list-dir error passed code=\(response.error.code) "
                        + "path=\(path) message=\"\(response.error.message)\""
                )
                return 0
            }
        } catch {
            fputs("list-dir-expect-error failed: \(error)\n", stderr)
            return 1
        }
    }
}
