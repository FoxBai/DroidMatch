import Foundation

/// Actor-confined delivery state for transfer-queue consumers.
///
/// `AsyncTransferScheduler` remains the sole concurrency owner. This value only
/// groups terminal outcomes, completion continuations, and snapshot stream
/// continuations so queue execution and consumer delivery do not share storage
/// ownership. It never starts tasks, performs persistence, or mutates jobs.
struct AsyncTransferSchedulerConsumerState {
    typealias CompletionWaiter = CheckedContinuation<AsyncTransferJobOutcome, Error>
    typealias SnapshotObserver = AsyncStream<[AsyncTransferJobSnapshot]>.Continuation

    private var outcomes: [UUID: AsyncTransferJobOutcome] = [:]
    private var completionWaiters: [UUID: [CompletionWaiter]] = [:]
    private var snapshotObservers: [UUID: SnapshotObserver] = [:]

    func outcome(for id: UUID) -> AsyncTransferJobOutcome? { outcomes[id] }

    mutating func addCompletionWaiter(_ waiter: CompletionWaiter, for id: UUID) {
        completionWaiters[id, default: []].append(waiter)
    }

    mutating func settle(_ id: UUID, with outcome: AsyncTransferJobOutcome) {
        outcomes[id] = outcome
        let waiters = completionWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    /// Removes consumer-visible terminal state after scheduler eligibility checks.
    mutating func removeOutcome(for id: UUID) -> AsyncTransferJobOutcome? {
        assert(
            completionWaiters[id]?.isEmpty ?? true,
            "settled jobs cannot retain completion waiters"
        )
        completionWaiters.removeValue(forKey: id)
        return outcomes.removeValue(forKey: id)
    }

    mutating func restoreOutcome(_ outcome: AsyncTransferJobOutcome?, for id: UUID) {
        if let outcome {
            outcomes[id] = outcome
        } else {
            outcomes.removeValue(forKey: id)
        }
    }

    mutating func replaceOutcomes(with restored: [UUID: AsyncTransferJobOutcome]) {
        // A persistence retry may reload durable outcomes while an existing
        // caller is still awaiting an active job. Match the scheduler's prior
        // behavior by preserving those waiters until their job settles.
        outcomes = restored
    }

    mutating func addSnapshotObserver(_ observer: SnapshotObserver) -> UUID {
        let id = UUID()
        snapshotObservers[id] = observer
        return id
    }

    mutating func removeSnapshotObserver(_ id: UUID) {
        snapshotObservers.removeValue(forKey: id)
    }

    func broadcast(_ snapshots: [AsyncTransferJobSnapshot]) {
        for observer in snapshotObservers.values {
            observer.yield(snapshots)
        }
    }
}
