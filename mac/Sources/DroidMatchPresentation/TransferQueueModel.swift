import Combine
import DroidMatchCore
import Foundation

/// Main-actor state boundary for a future SwiftUI or AppKit transfer queue.
///
/// Observation is explicit so an owning scene/controller can align it with its
/// lifecycle. Stopping retains the last value to avoid UI flicker; restarting
/// opens a fresh full-snapshot stream. Core updates remain authoritative, so
/// actions never mutate `items` optimistically.
@MainActor
public final class TransferQueueModel: ObservableObject {
    @Published public private(set) var items: [TransferQueuePresentationItem] = []
    @Published public private(set) var isObserving = false
    @Published public private(set) var persistenceStatus:
        AsyncTransferQueuePersistenceStatus = .disabled

    private let dataSource: any TransferQueueDataSource
    private var observationTask: Task<Void, Never>?
    private var observationGeneration: UInt64 = 0

    public init(dataSource: any TransferQueueDataSource) {
        self.dataSource = dataSource
    }

    public convenience init(scheduler: AsyncTransferScheduler) {
        self.init(dataSource: AsyncTransferSchedulerDataSource(scheduler: scheduler))
    }

    deinit {
        observationTask?.cancel()
    }

    /// Starts one subscription. Repeated starts are intentionally idempotent.
    public func start() {
        guard observationTask == nil else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        let dataSource = dataSource
        isObserving = true
        observationTask = Task { [weak self] in
            let updates = await dataSource.updates()
            for await snapshots in updates {
                guard !Task.isCancelled else { break }
                let persistenceStatus = await dataSource.persistenceStatus()
                self?.apply(
                    snapshots,
                    persistenceStatus: persistenceStatus,
                    generation: generation
                )
            }
            guard !Task.isCancelled else { return }
            self?.finishObservation(generation: generation)
        }
    }

    /// Cancels the current stream but deliberately keeps the last UI snapshot.
    public func stop() {
        observationGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
        isObserving = false
    }

    @discardableResult
    public func pause(_ id: UUID) async -> Bool {
        await dataSource.pause(id)
    }

    @discardableResult
    public func resume(_ id: UUID) async -> Bool {
        await dataSource.resume(id)
    }

    @discardableResult
    public func cancel(_ id: UUID) async -> Bool {
        await dataSource.cancel(id)
    }

    @discardableResult
    public func remove(_ id: UUID) async -> Bool {
        await dataSource.remove(id)
    }

    private func apply(
        _ snapshots: [AsyncTransferJobSnapshot],
        persistenceStatus: AsyncTransferQueuePersistenceStatus,
        generation: UInt64
    ) {
        guard generation == observationGeneration else { return }
        items = snapshots.map(TransferQueuePresentationItem.init(snapshot:))
        self.persistenceStatus = persistenceStatus
    }

    private func finishObservation(generation: UInt64) {
        guard generation == observationGeneration else { return }
        observationTask = nil
        isObserving = false
    }
}
