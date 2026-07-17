import DroidMatchCore

/// Main-actor single-flight executor for admitted remote directory mutations.
///
/// The runner owns only the active Task and its operation identity. It never
/// owns published presentation state, listing generations, navigation, or
/// refresh policy; `DirectoryBrowserModel` applies each typed outcome against
/// the currently visible path.
///
/// 中文：该边界只持有远端 mutation 的单飞 Task 与操作身份；展示状态、listing
/// generation、导航和刷新策略仍由 `DirectoryBrowserModel` 唯一持有。
@MainActor
final class DirectoryBrowserMutationRunner {
    enum Outcome {
        case completed(query: DirectoryListingQuery)
        case failed(query: DirectoryListingQuery, error: any Error)
        case batchFailed(
            query: DirectoryListingQuery,
            deletedCount: Int,
            error: any Error
        )
    }

    typealias Completion = @MainActor (Outcome) -> Void

    private let client: any DirectoryBrowserClient
    private var task: Task<Void, Never>?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?

    init(client: any DirectoryBrowserClient) {
        self.client = client
    }

    deinit {
        task?.cancel()
    }

    @discardableResult
    func createDirectory(
        path: String,
        query: DirectoryListingQuery,
        completion: @escaping Completion
    ) -> Bool {
        startSingle(query: query, completion: completion) { [client] in
            try await client.createDirectory(path: path)
        }
    }

    @discardableResult
    func rename(
        sourcePath: String,
        destinationPath: String,
        query: DirectoryListingQuery,
        completion: @escaping Completion
    ) -> Bool {
        startSingle(query: query, completion: completion) { [client] in
            try await client.renamePath(
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        }
    }

    @discardableResult
    func delete(
        path: String,
        recursive: Bool,
        query: DirectoryListingQuery,
        completion: @escaping Completion
    ) -> Bool {
        startSingle(query: query, completion: completion) { [client] in
            try await client.deletePath(path, recursive: recursive)
        }
    }

    @discardableResult
    func delete(
        _ items: [DirectoryBrowserItem],
        query: DirectoryListingQuery,
        completion: @escaping Completion
    ) -> Bool {
        guard let operationID = beginOperation() else { return false }
        let client = self.client
        task = Task { [weak self] in
            var deletedCount = 0
            do {
                for item in items {
                    try await client.deletePath(
                        item.path,
                        recursive: item.kind == .directory
                    )
                    deletedCount += 1
                }
                self?.finish(
                    operationID: operationID,
                    outcome: .completed(query: query),
                    completion: completion
                )
            } catch {
                self?.finish(
                    operationID: operationID,
                    outcome: .batchFailed(
                        query: query,
                        deletedCount: deletedCount,
                        error: error
                    ),
                    completion: completion
                )
            }
        }
        return true
    }

    private func startSingle(
        query: DirectoryListingQuery,
        completion: @escaping Completion,
        operation: @escaping @MainActor () async throws -> Void
    ) -> Bool {
        guard let operationID = beginOperation() else { return false }
        task = Task { [weak self] in
            do {
                try await operation()
                self?.finish(
                    operationID: operationID,
                    outcome: .completed(query: query),
                    completion: completion
                )
            } catch {
                self?.finish(
                    operationID: operationID,
                    outcome: .failed(query: query, error: error),
                    completion: completion
                )
            }
        }
        return true
    }

    private func beginOperation() -> UInt64? {
        guard activeOperationID == nil else { return nil }
        nextOperationID &+= 1
        activeOperationID = nextOperationID
        return nextOperationID
    }

    private func finish(
        operationID: UInt64,
        outcome: Outcome,
        completion: Completion
    ) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        task = nil
        completion(outcome)
    }
}
