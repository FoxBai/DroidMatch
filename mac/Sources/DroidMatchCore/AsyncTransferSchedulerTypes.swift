import Foundation

public enum AsyncTransferJobKind: String, Sendable, Equatable {
    case download
    case upload
}

public enum AsyncTransferJobRequest: Sendable {
    case download(AsyncDownloadCoordinatorRequest)
    case upload(AsyncUploadCoordinatorRequest)
}

public enum AsyncTransferJobState: String, Sendable, Equatable {
    case queued
    case running
    case retrying
    case pausing
    case paused
    case completed
    case failed
    case cancelled
    /// A previously active persisted job could not be proven safe to replay.
    case interrupted

    public var isTerminal: Bool {
        self == .completed
            || self == .failed
            || self == .cancelled
            || self == .interrupted
    }
}

/// Immutable product-facing transfer state.
///
/// The scheduler actor owns lifecycle transitions; presentation consumers only
/// observe these snapshots and must not infer new transfer state from progress.
public struct AsyncTransferJobSnapshot: Sendable, Equatable {
    public let id: UUID
    public let kind: AsyncTransferJobKind
    public let state: AsyncTransferJobState
    public let source: String
    public let destination: String
    public let attemptNumber: Int
    public let confirmedBytes: Int64
    public let totalBytes: Int64?
    /// Time-weighted rate over the most recent receiver-confirmed intervals.
    /// It is nil until two valid samples exist and is reset for every retry.
    public let recentBytesPerSecond: Double?
    public let retryDelayMilliseconds: Int64?
    public let failureDescription: String?
    /// Whether the scheduler can accept a pause request in this state.
    /// A queued job is only held; a running job requires a durable checkpoint.
    public let canPause: Bool
    /// Pausing is asynchronous while the coordinator closes its private session.
    public let canResume: Bool
    /// Cancellation remains available until the job reaches a terminal state.
    public let canCancel: Bool
    /// Removal is safe only after the terminal outcome and task unwind settle.
    public let canRemove: Bool

    public init(
        id: UUID,
        kind: AsyncTransferJobKind,
        state: AsyncTransferJobState,
        source: String,
        destination: String,
        attemptNumber: Int,
        confirmedBytes: Int64,
        totalBytes: Int64?,
        recentBytesPerSecond: Double?,
        retryDelayMilliseconds: Int64?,
        failureDescription: String?,
        canPause: Bool,
        canResume: Bool,
        canCancel: Bool,
        canRemove: Bool
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.source = source
        self.destination = destination
        self.attemptNumber = attemptNumber
        self.confirmedBytes = confirmedBytes
        self.totalBytes = totalBytes
        self.recentBytesPerSecond = recentBytesPerSecond
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.failureDescription = failureDescription
        self.canPause = canPause
        self.canResume = canResume
        self.canCancel = canCancel
        self.canRemove = canRemove
    }

    /// Completion state disambiguates a valid empty transfer from a running
    /// transfer whose total is still unknown.
    public var fractionCompleted: Double? {
        if state == .completed { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(confirmedBytes) / Double(totalBytes)
    }
}

public enum AsyncTransferJobResult: Sendable {
    case download(AsyncDownloadCoordinatorResult)
    case upload(AsyncUploadCoordinatorResult)
}

public enum AsyncTransferJobOutcome: Sendable {
    case success(AsyncTransferJobResult)
    case failure(String)
    case cancelled
}

public enum AsyncTransferSchedulerError: Error, CustomStringConvertible, Sendable, Equatable {
    case unknownJob(UUID)

    public var description: String {
        switch self {
        case let .unknownJob(id):
            return "transfer scheduler has no job \(id)"
        }
    }
}

public typealias AsyncTransferRetryObserver = @Sendable (
    _ retryAttempt: Int,
    _ delayMilliseconds: Int64,
    _ error: Error
) -> Void

typealias AsyncDownloadJobExecutor = @Sendable (
    AsyncDownloadCoordinatorRequest,
    AsyncTransferRetryObserver?,
    AsyncTransferProgressObserver?
) async throws -> AsyncDownloadCoordinatorResult

typealias AsyncUploadJobExecutor = @Sendable (
    AsyncUploadCoordinatorRequest,
    AsyncTransferRetryObserver?,
    AsyncTransferProgressObserver?
) async throws -> AsyncUploadCoordinatorResult

typealias AsyncTransferMonotonicNow = @Sendable () -> UInt64
typealias AsyncTransferRateExpirySleeper = @Sendable (UInt64) async throws -> Void

/// Adapts product coordinators to the scheduler's injected execution boundary.
/// This wiring owns no queue state and keeps both public construction paths
/// from duplicating retry/progress forwarding closures inside the actor.
struct AsyncTransferSchedulerExecutors {
    let download: AsyncDownloadJobExecutor
    let upload: AsyncUploadJobExecutor

    init(
        downloadCoordinator: AsyncDownloadCoordinator,
        uploadCoordinator: AsyncUploadCoordinator
    ) {
        download = { request, retryObserver, progressObserver in
            try await downloadCoordinator.download(
                request,
                onRetry: retryObserver,
                onProgress: progressObserver
            )
        }
        upload = { request, retryObserver, progressObserver in
            try await uploadCoordinator.upload(
                request,
                onRetry: retryObserver,
                onProgress: progressObserver
            )
        }
    }
}

/// Serializes a synchronous recovery callback with later actor progress and
/// terminal events. Keeping this bridge outside the actor makes the actor file
/// describe queue transitions rather than callback plumbing.
final class AsyncTransferSchedulerRetryRelay: @unchecked Sendable {
    private let tail = LockedValue<Task<Void, Never>?>(nil)

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        tail.update { current in
            let previous = current
            current = Task {
                await previous?.value
                await operation()
            }
        }
    }

    func drain() async {
        await tail.value()?.value
    }
}
