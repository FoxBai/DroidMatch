@_spi(DroidMatchAppSupport) import DroidMatchCore
import DroidMatchPresentation
import Foundation

/// Process-wide AppSupport composition for owner-scoped transfer authority.
///
/// The bookmark archive has one actor owner, and every device queue shares the
/// same consistency gate. This prevents a reconnect or another device's queue
/// from interleaving restoration/pruning with registration before enqueue.
public struct BookmarkingTransferQueueFactory: Sendable {
    private let store: SecurityScopedBookmarkStore?
    private let operationGate = BookmarkingTransferQueueOperationGate()

    public init(store: SecurityScopedBookmarkStore?) {
        self.store = store
    }

    public func localFileAccessProvider(
        for ownerID: LocalFileAccessOwnerID
    ) -> any LocalFileAccessProviding {
        guard let store else { return UnavailableLocalFileAccessProvider() }
        return OwnerScopedLocalFileAccessProvider(
            ownerID: ownerID,
            store: store,
            operationGate: operationGate
        )
    }

    public func transferQueueDataSource(
        for scheduler: AsyncTransferScheduler
    ) -> any TransferQueueDataSource {
        BookmarkingTransferQueueDataSource(
            scheduler: scheduler,
            store: store,
            operationGate: operationGate
        )
    }
}

/// Binds Core's platform-neutral access surface to one authenticated device.
/// Owner selection is intentionally impossible at individual call sites.
private struct OwnerScopedLocalFileAccessProvider: LocalFileAccessProviding {
    let ownerID: LocalFileAccessOwnerID
    let store: SecurityScopedBookmarkStore
    let operationGate: BookmarkingTransferQueueOperationGate

    func isReadyForTransferExecution() async -> Bool {
        await store.isReadyForTransferExecution(owner: ownerID, targetURLs: [])
    }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        await store.isReadyForTransferExecution(owner: ownerID, targetURLs: targetURLs)
    }

    func withTransferExecutionPreparation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard await operationGate.acquire() else { throw CancellationError() }
        do {
            let result = try await operation()
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        try await store.acquireAccess(owner: ownerID, to: url)
    }
}
