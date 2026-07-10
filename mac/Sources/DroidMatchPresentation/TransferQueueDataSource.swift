import DroidMatchCore
import Foundation

/// Testable action and snapshot seam between native presentation state and Core.
///
/// Snapshot values contain Core-owned paths. Consumers should bind UI through
/// `TransferQueueModel`, whose item mapping removes Mac absolute paths.
public protocol TransferQueueDataSource: Sendable {
    func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]>
    func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus
    func pause(_ id: UUID) async -> Bool
    func resume(_ id: UUID) async -> Bool
    func cancel(_ id: UUID) async -> Bool
    func remove(_ id: UUID) async -> Bool
}

/// Thin adapter that preserves `AsyncTransferScheduler` as the only authority
/// for ordering, lifecycle transitions, retry state, and action admission.
public struct AsyncTransferSchedulerDataSource: TransferQueueDataSource, Sendable {
    private let scheduler: AsyncTransferScheduler

    public init(scheduler: AsyncTransferScheduler) {
        self.scheduler = scheduler
    }

    public func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]> {
        await scheduler.updates()
    }

    public func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus {
        await scheduler.persistenceStatus()
    }

    public func pause(_ id: UUID) async -> Bool {
        await scheduler.pause(id)
    }

    public func resume(_ id: UUID) async -> Bool {
        await scheduler.resume(id)
    }

    public func cancel(_ id: UUID) async -> Bool {
        await scheduler.cancel(id)
    }

    public func remove(_ id: UUID) async -> Bool {
        await scheduler.remove(id)
    }
}
