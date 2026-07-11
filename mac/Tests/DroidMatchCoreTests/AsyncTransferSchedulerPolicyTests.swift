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

@Test func schedulerTerminalPolicyPreservesAuthoritativeCancellation() {
    var record = schedulerPolicyRecord(state: .cancelled)
    record.retryDelayMilliseconds = 25
    record.failureDescription = "old retry"

    let outcome = AsyncTransferSchedulerPolicy.applyTerminalOutcome(
        .success(.download(downloadResult(
            "late-success",
            attemptCount: 9,
            totalBytes: 100,
            finalOffsetBytes: 100
        ))),
        to: &record,
        at: 1
    )

    assertCancelled(outcome)
    #expect(record.state == .cancelled)
    #expect(record.attemptNumber == 1)
    #expect(record.confirmedBytes == 0)
    #expect(record.totalBytes == nil)
    #expect(record.retryDelayMilliseconds == nil)
    #expect(record.failureDescription == "old retry")
    #expect(record.settled)
}

private func schedulerPolicyRecord(
    state: AsyncTransferJobState
) -> AsyncTransferSchedulerJobRecord {
    AsyncTransferSchedulerJobRecord(
        id: UUID(),
        sequence: 0,
        request: .download(downloadRequest("terminal-policy")),
        kind: .download,
        source: "terminal-policy",
        destination: "/tmp/terminal-policy.bin",
        supportsCheckpointPause: true,
        state: state
    )
}
