import Foundation
import Testing
@testable import DroidMatchCore

@Test func schedulerTerminalPolicyCalibratesSuccessfulDownloadResult() {
    var record = schedulerPolicyRecord(state: .running)
    record.attemptBase = 2
    record.attemptNumber = 3
    record.confirmedBytes = 4
    record.totalBytes = 10
    record.retryDelayMilliseconds = 25
    record.failureDescription = "retrying"

    let outcome = AsyncTransferSchedulerPolicy.applyTerminalOutcome(
        .success(.download(downloadResult(
            "terminal-policy",
            attemptCount: 2,
            totalBytes: 12,
            finalOffsetBytes: 12
        ))),
        to: &record,
        at: 1
    )

    assertSuccess(outcome)
    #expect(record.state == .completed)
    #expect(record.attemptNumber == 4)
    #expect(record.confirmedBytes == 12)
    #expect(record.totalBytes == 12)
    #expect(record.retryDelayMilliseconds == nil)
    #expect(record.failureDescription == nil)
    #expect(record.settled)
}

@Test func schedulerTerminalPolicyPreservesIrreversibleLateSuccess() {
    var record = schedulerPolicyRecord(state: .cancelled)
    record.retryDelayMilliseconds = 25
    record.failureDescription = "old retry"

    let outcome = AsyncTransferSchedulerPolicy.applyTerminalOutcome(
        .success(.download(downloadResult(
            "late-success",
            attemptCount: 9,
            totalBytes: 100,
            finalOffsetBytes: 100,
            completionIsIrreversible: true
        ))),
        to: &record,
        at: 1
    )

    assertSuccess(outcome)
    #expect(record.state == .completed)
    #expect(record.attemptNumber == 9)
    #expect(record.confirmedBytes == 100)
    #expect(record.totalBytes == 100)
    #expect(record.retryDelayMilliseconds == nil)
    #expect(record.failureDescription == nil)
    #expect(record.settled)
}

@Test func schedulerTerminalPolicyKeepsCancellationAuthoritativeForUploadSuccess() {
    var record = schedulerPolicyRecord(state: .cancelled)

    let outcome = AsyncTransferSchedulerPolicy.applyTerminalOutcome(
        .success(.upload(uploadResult("late-upload", attemptCount: 1))),
        to: &record,
        at: 1
    )

    assertCancelled(outcome)
    #expect(record.state == .cancelled)
    #expect(record.settled)
}

@Test func schedulerTerminalPolicyRejectsOverflowingExecutorAttemptCount() {
    var record = schedulerPolicyRecord(state: .running, maxAttempts: Int.max)
    record.attemptBase = 1
    record.attemptNumber = 2

    let outcome = AsyncTransferSchedulerPolicy.applyTerminalOutcome(
        .success(.download(downloadResult(
            "overflowing-terminal-attempt",
            attemptCount: Int.max,
            totalBytes: 1,
            finalOffsetBytes: 1,
            completionIsIrreversible: true
        ))),
        to: &record,
        at: 1
    )

    if case let .failure(description) = outcome {
        #expect(description == AsyncTransferSchedulerPolicy.attemptAccountingFailureDescription)
    } else {
        Issue.record("overflowing terminal attempt count must fail closed")
    }
    #expect(record.state == .failed)
    #expect(record.attemptNumber == 2)
    #expect(record.failureDescription
        == AsyncTransferSchedulerPolicy.attemptAccountingFailureDescription)
    #expect(record.settled)
}

@Test func schedulerPolicyRejectsOverflowingRetryOrdinalAfterPolicyAdmission() {
    let record = schedulerPolicyRecord(state: .running, maxAttempts: Int.max)

    #expect(AsyncTransferSchedulerPolicy.checkedRetryAttemptNumber(
        attemptBase: 0,
        retryAttempt: Int.max,
        for: record.request
    ) == nil)
}

@Test func schedulerExecutionPolicyMakesRetryPersistenceExplicit() {
    var record = schedulerPolicyRecord(state: .running, maxAttempts: 3)
    record.attemptBase = 2
    record.attemptNumber = 3
    record.rateSampleGeneration = 4
    _ = record.rateEstimator.record(confirmedBytes: 1, at: 1)
    _ = record.rateEstimator.record(confirmedBytes: 2, at: 1_000_000_001)

    let resolution = AsyncTransferSchedulerExecutionPolicy.applyRetry(
        retryAttempt: 2,
        delayMilliseconds: 250,
        failureDescription: "transport",
        to: &record
    )

    guard case let .persist(previousRecord) = resolution else {
        Issue.record("a valid retry must cross persistence")
        return
    }
    #expect(previousRecord.state == .running)
    #expect(previousRecord.attemptNumber == 3)
    #expect(record.state == .retrying)
    #expect(record.attemptNumber == 5)
    #expect(record.retryDelayMilliseconds == 250)
    #expect(record.failureDescription == "transport")
    #expect(record.rateEstimator.bytesPerSecond == nil)
    #expect(record.rateSampleGeneration == 5)

    AsyncTransferSchedulerExecutionPolicy.applyRetryPersistenceFailure(
        previousRecord: previousRecord,
        to: &record
    )
    #expect(record.state == .interrupted)
    #expect(record.attemptNumber == 3)
    #expect(record.failureDescription
        == AsyncTransferSchedulerPolicy.retryPersistenceFailureDescription)
    #expect(!record.settled)
}

@Test func schedulerExecutionPolicyFailsStoppedOnInvalidRetryAccounting() {
    var record = schedulerPolicyRecord(state: .running, maxAttempts: 1)

    let resolution = AsyncTransferSchedulerExecutionPolicy.applyRetry(
        retryAttempt: 2,
        delayMilliseconds: 0,
        failureDescription: "must not escape",
        to: &record
    )

    guard case .failStop = resolution else {
        Issue.record("an invalid retry ordinal must fail stopped")
        return
    }
    #expect(record.state == .interrupted)
    #expect(record.failureDescription
        == AsyncTransferSchedulerPolicy.attemptAccountingFailureDescription)
    #expect(!record.settled)
}

@Test func schedulerExecutionPolicyValidatesProgressAndRecoversRetryState() {
    var record = schedulerPolicyRecord(state: .retrying)
    record.retryDelayMilliseconds = 250
    record.failureDescription = "transport"

    let baseline = AsyncTransferSchedulerExecutionPolicy.applyProgress(
        AsyncTransferProgress(confirmedBytes: 100, totalBytes: 1_000),
        to: &record,
        at: 1
    )
    #expect(baseline == .init(
        acceptedRateSample: true,
        rateSampleGeneration: 1,
        hasRecentRate: false
    ))
    #expect(record.state == .running)
    #expect(record.retryDelayMilliseconds == nil)
    #expect(record.failureDescription == nil)

    let rate = AsyncTransferSchedulerExecutionPolicy.applyProgress(
        AsyncTransferProgress(confirmedBytes: 300, totalBytes: 1_000),
        to: &record,
        at: 1_000_000_001
    )
    #expect(rate == .init(
        acceptedRateSample: true,
        rateSampleGeneration: 2,
        hasRecentRate: true
    ))
    #expect(record.confirmedBytes == 300)
    #expect(record.totalBytes == 1_000)
    #expect(record.rateEstimator.bytesPerSecond == 200)

    let previousGeneration = record.rateSampleGeneration
    #expect(AsyncTransferSchedulerExecutionPolicy.applyProgress(
        AsyncTransferProgress(confirmedBytes: 299, totalBytes: 1_000),
        to: &record,
        at: 2_000_000_001
    ) == nil)
    #expect(record.confirmedBytes == 300)
    #expect(record.rateSampleGeneration == previousGeneration)
    #expect(AsyncTransferSchedulerExecutionPolicy.applyProgress(
        AsyncTransferProgress(confirmedBytes: 400, totalBytes: 999),
        to: &record,
        at: 2_000_000_001
    ) == nil)
    #expect(record.confirmedBytes == 300)
    #expect(record.totalBytes == 1_000)
}

@Test func schedulerExecutionPolicyExpiresOnlyTheCurrentRunningRate() {
    var record = schedulerPolicyRecord(state: .running)
    _ = record.rateEstimator.record(confirmedBytes: 100, at: 1)
    _ = record.rateEstimator.record(confirmedBytes: 300, at: 1_000_000_001)
    record.rateSampleGeneration = 7

    #expect(!AsyncTransferSchedulerExecutionPolicy.expireRecentRate(
        generation: 6,
        in: &record
    ))
    #expect(record.rateEstimator.bytesPerSecond == 200)
    #expect(record.rateSampleGeneration == 7)

    #expect(AsyncTransferSchedulerExecutionPolicy.expireRecentRate(
        generation: 7,
        in: &record
    ))
    #expect(record.rateEstimator.bytesPerSecond == nil)
    #expect(record.rateSampleGeneration == 8)
}

@Test func schedulerCompletionPolicySeparatesPauseInterruptionAndCommittedDownload() {
    var pausing = schedulerPolicyRecord(state: .pausing)
    pausing.retryDelayMilliseconds = 25
    pausing.failureDescription = "retrying"
    pausing.rateSampleGeneration = 4
    _ = pausing.rateEstimator.record(confirmedBytes: 1, at: 1)
    _ = pausing.rateEstimator.record(confirmedBytes: 2, at: 2)

    let paused = AsyncTransferSchedulerCompletionPolicy.reconcile(
        .failure("non-cooperative executor failure"),
        with: &pausing,
        at: 3
    )

    guard case .paused = paused else {
        Issue.record("ordinary executor unwind must preserve the requested pause")
        return
    }
    #expect(pausing.state == .paused)
    #expect(pausing.retryDelayMilliseconds == nil)
    #expect(pausing.failureDescription == nil)
    #expect(pausing.rateEstimator.bytesPerSecond == nil)
    #expect(pausing.rateSampleGeneration == 5)
    #expect(!pausing.settled)
    #expect(paused.outcomeToSettle == nil)

    var interrupted = schedulerPolicyRecord(state: .interrupted)
    interrupted.failureDescription = "session ended"
    let preserved = AsyncTransferSchedulerCompletionPolicy.reconcile(
        .cancelled,
        with: &interrupted,
        at: 3
    )
    guard case let .interrupted(.failure(description)) = preserved else {
        Issue.record("ordinary executor unwind must settle the interrupted record")
        return
    }
    #expect(description == "session ended")
    #expect(interrupted.state == .interrupted)
    #expect(interrupted.settled)

    var committed = schedulerPolicyRecord(state: .interrupted)
    let completed = AsyncTransferSchedulerCompletionPolicy.reconcile(
        .success(.download(downloadResult(
            "committed-after-session-end",
            attemptCount: 1,
            totalBytes: 10,
            finalOffsetBytes: 10,
            completionIsIrreversible: true
        ))),
        with: &committed,
        at: 3
    )
    guard case let .terminal(outcome) = completed else {
        Issue.record("an irreversible local commit must become the terminal result")
        return
    }
    assertSuccess(outcome)
    #expect(committed.state == .completed)
    #expect(committed.confirmedBytes == 10)
    #expect(committed.totalBytes == 10)
    #expect(committed.settled)
}

func schedulerPolicyRecord(
    state: AsyncTransferJobState,
    maxAttempts: Int = 8
) -> AsyncTransferSchedulerJobRecord {
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "terminal-policy",
        destinationURL: URL(fileURLWithPath: "/tmp/terminal-policy.bin"),
        freshTransferID: "terminal-policy",
        recoveryPolicy: RecoveryPolicy(
            maxAttempts: maxAttempts,
            baseDelayMs: 0,
            maxDelayMs: 0,
            jitterFactor: 0
        )
    )
    return AsyncTransferSchedulerJobRecord(
        id: UUID(),
        sequence: 0,
        request: .download(request),
        kind: .download,
        source: "terminal-policy",
        destination: "/tmp/terminal-policy.bin",
        supportsCheckpointPause: true,
        state: state
    )
}
