import Foundation
import Dispatch

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
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

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

/// Bridges the recovery executor's synchronous retry callback into the
/// scheduler actor without allowing a later progress/final event to overtake it.
private final class AsyncTransferSchedulerRetryRelay: @unchecked Sendable {
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

/// Process-local product transfer queue.
///
/// The scheduler exposes state snapshots suitable for a future SwiftUI/AppKit
/// binding, while coordinators continue to own protocol, sidecar, and file-I/O
/// invariants. It deliberately does not persist queued intent across app restarts.
public actor AsyncTransferScheduler {
    private struct JobRecord {
        let id: UUID
        let sequence: UInt64
        let request: AsyncTransferJobRequest
        let kind: AsyncTransferJobKind
        let source: String
        let destination: String
        var state: AsyncTransferJobState = .queued
        var attemptNumber = 1
        var confirmedBytes: Int64 = 0
        var totalBytes: Int64?
        var rateEstimator = AsyncTransferRateEstimator()
        var rateSampleGeneration: UInt64 = 0
        var retryDelayMilliseconds: Int64?
        var failureDescription: String?

        var snapshot: AsyncTransferJobSnapshot {
            AsyncTransferJobSnapshot(
                id: id,
                kind: kind,
                state: state,
                source: source,
                destination: destination,
                attemptNumber: attemptNumber,
                confirmedBytes: confirmedBytes,
                totalBytes: totalBytes,
                recentBytesPerSecond: rateEstimator.bytesPerSecond,
                retryDelayMilliseconds: retryDelayMilliseconds,
                failureDescription: failureDescription
            )
        }
    }

    private let maxConcurrentJobs: Int
    private let downloadExecutor: AsyncDownloadJobExecutor
    private let uploadExecutor: AsyncUploadJobExecutor
    private let monotonicNow: AsyncTransferMonotonicNow
    private let rateExpirySleeper: AsyncTransferRateExpirySleeper

    private var nextSequence: UInt64 = 0
    private var records: [UUID: JobRecord] = [:]
    private var queue: [UUID] = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var rateExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var outcomes: [UUID: AsyncTransferJobOutcome] = [:]
    private var waiters: [UUID: [CheckedContinuation<AsyncTransferJobOutcome, Error>]] = [:]
    private var observers: [UUID: AsyncStream<[AsyncTransferJobSnapshot]>.Continuation] = [:]

    public init(
        downloadCoordinator: AsyncDownloadCoordinator,
        uploadCoordinator: AsyncUploadCoordinator,
        maxConcurrentJobs: Int = 2
    ) {
        precondition(maxConcurrentJobs > 0, "maxConcurrentJobs must be positive")
        self.maxConcurrentJobs = maxConcurrentJobs
        self.monotonicNow = { DispatchTime.now().uptimeNanoseconds }
        self.rateExpirySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        self.downloadExecutor = { request, retryObserver, progressObserver in
            try await downloadCoordinator.download(
                request,
                onRetry: retryObserver,
                onProgress: progressObserver
            )
        }
        self.uploadExecutor = { request, retryObserver, progressObserver in
            try await uploadCoordinator.upload(
                request,
                onRetry: retryObserver,
                onProgress: progressObserver
            )
        }
    }

    init(
        maxConcurrentJobs: Int,
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor,
        monotonicNow: @escaping AsyncTransferMonotonicNow = {
            DispatchTime.now().uptimeNanoseconds
        },
        rateExpirySleeper: @escaping AsyncTransferRateExpirySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        precondition(maxConcurrentJobs > 0, "maxConcurrentJobs must be positive")
        self.maxConcurrentJobs = maxConcurrentJobs
        self.downloadExecutor = downloadExecutor
        self.uploadExecutor = uploadExecutor
        self.monotonicNow = monotonicNow
        self.rateExpirySleeper = rateExpirySleeper
    }

    @discardableResult
    public func submit(_ request: AsyncTransferJobRequest) -> UUID {
        let id = UUID()
        let metadata = Self.metadata(for: request)
        records[id] = JobRecord(
            id: id,
            sequence: nextSequence,
            request: request,
            kind: metadata.kind,
            source: metadata.source,
            destination: metadata.destination
        )
        nextSequence &+= 1
        queue.append(id)
        startJobsIfPossible()
        broadcastSnapshots()
        return id
    }

    public func snapshot(for id: UUID) throws -> AsyncTransferJobSnapshot {
        guard let record = records[id] else {
            throw AsyncTransferSchedulerError.unknownJob(id)
        }
        return record.snapshot
    }

    public func snapshots() -> [AsyncTransferJobSnapshot] {
        orderedSnapshots()
    }

    /// Emits an immediate full snapshot followed by every queue state change.
    public func updates() -> AsyncStream<[AsyncTransferJobSnapshot]> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[observerID] = continuation
            continuation.yield(orderedSnapshots())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    public func waitForCompletion(_ id: UUID) async throws -> AsyncTransferJobOutcome {
        guard records[id] != nil else {
            throw AsyncTransferSchedulerError.unknownJob(id)
        }
        if let outcome = outcomes[id] {
            return outcome
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    /// Cancels queued work immediately or requests cancellation of a running job.
    /// Returns false for unknown or already-terminal jobs.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        guard var record = records[id], !record.state.isTerminal else {
            return false
        }
        if record.state == .queued {
            queue.removeAll { $0 == id }
            record.state = .cancelled
            records[id] = record
            finishWaiters(id: id, outcome: .cancelled)
            startJobsIfPossible()
        } else {
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            records[id] = record
            runningTasks[id]?.cancel()
        }
        stopRateExpiry(id: id)
        broadcastSnapshots()
        return true
    }

    /// Removes terminal history after consumers no longer need it.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        guard let record = records[id],
              record.state.isTerminal,
              outcomes[id] != nil,
              runningTasks[id] == nil else {
            return false
        }
        records.removeValue(forKey: id)
        outcomes.removeValue(forKey: id)
        waiters.removeValue(forKey: id)
        stopRateExpiry(id: id)
        broadcastSnapshots()
        return true
    }

    private func startJobsIfPossible() {
        while runningTasks.count < maxConcurrentJobs, !queue.isEmpty {
            let id = queue.removeFirst()
            guard var record = records[id], record.state == .queued else {
                continue
            }
            record.state = .running
            records[id] = record
            let request = record.request
            let task = Task { [weak self] in
                guard let self else { return }
                await self.execute(id: id, request: request)
            }
            runningTasks[id] = task
        }
    }

    private func execute(id: UUID, request: AsyncTransferJobRequest) async {
        let retryRelay = AsyncTransferSchedulerRetryRelay()
        let retryObserver: AsyncTransferRetryObserver = { [weak self] retry, delay, error in
            guard let scheduler = self else { return }
            retryRelay.enqueue { [weak scheduler] in
                await scheduler?.markRetry(
                    id: id,
                    retryAttempt: retry,
                    delayMilliseconds: delay,
                    error: error
                )
            }
        }
        let progressObserver: AsyncTransferProgressObserver = { [weak self] progress in
            await retryRelay.drain()
            await self?.markProgress(id: id, progress: progress)
        }

        do {
            let result: AsyncTransferJobResult
            switch request {
            case let .download(downloadRequest):
                result = .download(try await downloadExecutor(
                    downloadRequest,
                    retryObserver,
                    progressObserver
                ))
            case let .upload(uploadRequest):
                result = .upload(try await uploadExecutor(
                    uploadRequest,
                    retryObserver,
                    progressObserver
                ))
            }
            await retryRelay.drain()
            finish(id: id, outcome: .success(result))
        } catch is CancellationError {
            await retryRelay.drain()
            finish(id: id, outcome: .cancelled)
        } catch {
            await retryRelay.drain()
            finish(id: id, outcome: .failure(String(describing: error)))
        }
    }

    private func markRetry(
        id: UUID,
        retryAttempt: Int,
        delayMilliseconds: Int64,
        error: Error
    ) {
        guard var record = records[id],
              record.state == .running || record.state == .retrying else {
            return
        }
        record.state = .retrying
        record.attemptNumber = retryAttempt + 1
        record.retryDelayMilliseconds = delayMilliseconds
        record.failureDescription = String(describing: error)
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        records[id] = record
        stopRateExpiry(id: id)
        broadcastSnapshots()
    }

    private func markProgress(id: UUID, progress: AsyncTransferProgress) {
        guard var record = records[id],
              record.state == .running || record.state == .retrying,
              progress.totalBytes >= 0,
              progress.confirmedBytes >= record.confirmedBytes,
              progress.confirmedBytes <= progress.totalBytes,
              record.totalBytes == nil || record.totalBytes == progress.totalBytes else {
            return
        }
        record.confirmedBytes = progress.confirmedBytes
        record.totalBytes = progress.totalBytes
        let acceptedRateSample = record.rateEstimator.record(
            confirmedBytes: progress.confirmedBytes,
            at: monotonicNow()
        )
        if acceptedRateSample {
            record.rateSampleGeneration &+= 1
        }
        if record.state == .retrying {
            record.state = .running
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
        }
        let rateGeneration = record.rateSampleGeneration
        let hasRecentRate = record.rateEstimator.bytesPerSecond != nil
        records[id] = record
        if acceptedRateSample {
            updateRateExpiry(
                id: id,
                generation: rateGeneration,
                hasRecentRate: hasRecentRate
            )
        }
        broadcastSnapshots()
    }

    private func finish(id: UUID, outcome: AsyncTransferJobOutcome) {
        runningTasks.removeValue(forKey: id)
        guard var record = records[id] else {
            startJobsIfPossible()
            return
        }
        // Cancellation is authoritative even if an injected/non-cooperative
        // executor returns success while unwinding after Task.cancel().
        let finalOutcome: AsyncTransferJobOutcome = record.state == .cancelled
            ? .cancelled
            : outcome
        switch finalOutcome {
        case let .success(result):
            record.state = .completed
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
            switch result {
            case let .download(value):
                record.attemptNumber = value.attemptCount
                // Coordinators normally emitted the final checkpoint already;
                // this result calibration intentionally tolerates a duplicate.
                _ = record.rateEstimator.record(
                    confirmedBytes: value.download.finalOffsetBytes,
                    at: monotonicNow()
                )
                record.confirmedBytes = value.download.finalOffsetBytes
                record.totalBytes = value.download.openResponse.totalSizeBytes
            case let .upload(value):
                record.attemptNumber = value.attemptCount
                _ = record.rateEstimator.record(
                    confirmedBytes: value.upload.finalOffsetBytes,
                    at: monotonicNow()
                )
                record.confirmedBytes = value.upload.finalOffsetBytes
                record.totalBytes = value.upload.openResponse.totalSizeBytes
            }
        case let .failure(description):
            record.state = .failed
            record.retryDelayMilliseconds = nil
            record.failureDescription = description
        case .cancelled:
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
        }
        records[id] = record
        // Running samples expire automatically, but a terminal transition
        // freezes any still-valid value for result/diagnostics presentation.
        stopRateExpiry(id: id)
        finishWaiters(id: id, outcome: finalOutcome)
        startJobsIfPossible()
        broadcastSnapshots()
    }

    private func finishWaiters(id: UUID, outcome: AsyncTransferJobOutcome) {
        outcomes[id] = outcome
        let continuations = waiters.removeValue(forKey: id) ?? []
        for continuation in continuations {
            continuation.resume(returning: outcome)
        }
    }

    private func orderedSnapshots() -> [AsyncTransferJobSnapshot] {
        records.values
            .sorted { $0.sequence < $1.sequence }
            .map(\.snapshot)
    }

    private func broadcastSnapshots() {
        let current = orderedSnapshots()
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func updateRateExpiry(
        id: UUID,
        generation: UInt64,
        hasRecentRate: Bool
    ) {
        stopRateExpiry(id: id)
        guard hasRecentRate else { return }
        let sleeper = rateExpirySleeper
        rateExpiryTasks[id] = Task { [weak self] in
            do {
                try await sleeper(AsyncTransferRateEstimator.defaultWindowNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireRecentRate(id: id, generation: generation)
        }
    }

    private func stopRateExpiry(id: UUID) {
        rateExpiryTasks.removeValue(forKey: id)?.cancel()
    }

    private func expireRecentRate(id: UUID, generation: UInt64) {
        guard var record = records[id],
              record.state == .running,
              record.rateSampleGeneration == generation,
              record.rateEstimator.bytesPerSecond != nil else {
            return
        }
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        records[id] = record
        rateExpiryTasks.removeValue(forKey: id)
        broadcastSnapshots()
    }

    private static func metadata(
        for request: AsyncTransferJobRequest
    ) -> (kind: AsyncTransferJobKind, source: String, destination: String) {
        switch request {
        case let .download(value):
            return (.download, value.sourcePath, value.destinationURL.path)
        case let .upload(value):
            return (.upload, value.sourceURL.path, value.destinationPath)
        }
    }
}
