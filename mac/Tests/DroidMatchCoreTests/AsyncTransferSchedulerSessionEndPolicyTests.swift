import Foundation
import Testing
@testable import DroidMatchCore

@Test func schedulerShutdownPolicySeparatesRunningAndImmediateCancellation() throws {
    let runningID = UUID()
    let queuedID = UUID()
    let completedID = UUID()
    var records = [
        runningID: sessionEndRecord(id: runningID, state: .running),
        queuedID: sessionEndRecord(id: queuedID, state: .queued),
        completedID: sessionEndRecord(id: completedID, state: .completed),
    ]
    var queue = [queuedID]

    let actions = AsyncTransferSchedulerSessionEndPolicy.prepareShutdown(
        records: &records,
        queue: &queue,
        runningJobIDs: [runningID]
    )

    #expect(queue.isEmpty)
    #expect(records[runningID]?.state == .cancelled)
    #expect(records[runningID]?.settled == false)
    #expect(records[queuedID]?.state == .cancelled)
    #expect(records[queuedID]?.settled == true)
    #expect(records[completedID]?.state == .completed)

    let runningAction = try #require(actions.first { $0.jobID == runningID })
    #expect(runningAction.shouldCancelExecutor)
    #expect(runningAction.immediateOutcome == nil)
    let queuedAction = try #require(actions.first { $0.jobID == queuedID })
    #expect(!queuedAction.shouldCancelExecutor)
    assertCancelled(try #require(queuedAction.immediateOutcome))
    #expect(actions.allSatisfy { $0.jobID != completedID })
}

@Test func schedulerSuspensionPolicyPreservesCheckpointResumeAttempts() throws {
    let queuedID = UUID()
    let runningID = UUID()
    let retryingID = UUID()
    var queued = sessionEndRecord(id: queuedID, state: .queued)
    queued.pauseRequiresResume = true
    var running = sessionEndRecord(id: runningID, state: .running)
    running.attemptNumber = 2
    running.confirmedBytes = 5
    running.totalBytes = 10
    var retrying = sessionEndRecord(id: retryingID, state: .retrying)
    retrying.attemptNumber = 4
    retrying.confirmedBytes = 5
    retrying.totalBytes = 10
    retrying.retryDelayMilliseconds = 25
    var records = [queuedID: queued, runningID: running, retryingID: retrying]
    var queue = [queuedID]

    let actions = AsyncTransferSchedulerSessionEndPolicy.prepareSuspension(
        records: &records,
        queue: &queue
    )

    #expect(queue.isEmpty)
    #expect(records[queuedID]?.state == .paused)
    #expect(records[queuedID]?.pauseRequiresResume == false)
    #expect(records[runningID]?.state == .pausing)
    #expect(records[runningID]?.resumeAttemptBase == 2)
    #expect(records[runningID]?.pauseRequiresResume == true)
    #expect(records[retryingID]?.state == .pausing)
    #expect(records[retryingID]?.resumeAttemptBase == 3)
    #expect(records[retryingID]?.retryDelayMilliseconds == nil)

    let queuedAction = try #require(actions.first { $0.jobID == queuedID })
    #expect(!queuedAction.shouldCancelExecutor)
    let runningAction = try #require(actions.first { $0.jobID == runningID })
    #expect(runningAction.shouldCancelExecutor)
    #expect(runningAction.immediateOutcome == nil)
    let retryingAction = try #require(actions.first { $0.jobID == retryingID })
    #expect(retryingAction.shouldCancelExecutor)
    #expect(retryingAction.immediateOutcome == nil)
}

@Test func schedulerSuspensionPolicyInterruptsUnsafeActiveWork() throws {
    let id = UUID()
    var records = [id: sessionEndRecord(
        id: id,
        state: .running,
        supportsCheckpointPause: false
    )]
    var queue: [UUID] = []

    let actions = AsyncTransferSchedulerSessionEndPolicy.prepareSuspension(
        records: &records,
        queue: &queue
    )

    let record = try #require(records[id])
    #expect(record.state == .interrupted)
    #expect(record.failureDescription == AsyncTransferSchedulerPolicy.interruptedFailureDescription)
    #expect(record.settled)
    let action = try #require(actions.first)
    #expect(action.jobID == id)
    #expect(action.shouldCancelExecutor)
    guard case let .failure(description) = try #require(action.immediateOutcome) else {
        Issue.record("expected an immediate interrupted outcome")
        return
    }
    #expect(description == AsyncTransferSchedulerPolicy.interruptedFailureDescription)
}

private func sessionEndRecord(
    id: UUID,
    state: AsyncTransferJobState,
    supportsCheckpointPause: Bool = true
) -> AsyncTransferSchedulerJobRecord {
    AsyncTransferSchedulerJobRecord(
        id: id,
        sequence: 0,
        request: .download(downloadRequest("session-end-policy")),
        kind: .download,
        source: "session-end-policy",
        destination: "/tmp/session-end-policy.bin",
        supportsCheckpointPause: supportsCheckpointPause,
        state: state
    )
}
