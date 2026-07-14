import Foundation

/// Actor-confined ownership of the scheduler's short-lived rate-expiry tasks.
///
/// The scheduler remains the only owner of job records and decides whether an
/// expiry generation is still current. This value only replaces, cancels, and
/// forgets timer tasks, so task lifetime cannot become a second source of job
/// state or publish snapshots independently.
struct AsyncTransferSchedulerRateExpiryState {
    private let sleeper: AsyncTransferRateExpirySleeper
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        sleeper: @escaping AsyncTransferRateExpirySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleeper = sleeper
    }

    mutating func replace(
        id: UUID,
        when shouldSchedule: Bool,
        onExpiry: @escaping @Sendable () async -> Void
    ) {
        cancel(id: id)
        guard shouldSchedule else { return }
        let sleeper = sleeper
        tasks[id] = Task {
            do {
                try await sleeper(AsyncTransferRateEstimator.defaultWindowNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await onExpiry()
        }
    }

    mutating func cancel(id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    /// Drops a task that has already delivered its accepted expiry callback.
    /// Cancellation belongs to replacement and terminal transitions instead.
    mutating func forget(id: UUID) {
        tasks.removeValue(forKey: id)
    }
}
