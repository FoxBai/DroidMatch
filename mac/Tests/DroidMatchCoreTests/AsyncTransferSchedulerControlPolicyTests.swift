import Foundation
import Testing
@testable import DroidMatchCore

@Test func schedulerControlPolicyPausesQueuedRecordAndRollsBackAtomically() throws {
    let id = UUID()
    let before = UUID()
    let after = UUID()
    var records = [id: makeControlPolicyRecord(id: id, label: "queued")]
    var queue = [before, id, after]

    let action = try #require(AsyncTransferSchedulerControlPolicy.preparePause(
        id: id,
        records: &records,
        queue: &queue
    ))

    #expect(records[id]?.state == .paused)
    #expect(records[id]?.pauseRequiresResume == false)
    #expect(queue == [before, after])
    #expect(action.effects == [.startJobs])

    action.rollback(records: &records, queue: &queue)
    #expect(records[id]?.state == .queued)
    #expect(queue == [before, id, after])
}

@Test func schedulerControlPolicyPausesRetryWithoutConsumingAttempt() throws {
    let id = UUID()
    var record = makeControlPolicyRecord(id: id, label: "retrying")
    record.state = .retrying
    record.attemptNumber = 3
    record.confirmedBytes = 2
    record.totalBytes = 10
    record.retryDelayMilliseconds = 250
    record.failureDescription = "retryable"
    var records = [id: record]
    var queue: [UUID] = []

    let action = try #require(AsyncTransferSchedulerControlPolicy.preparePause(
        id: id,
        records: &records,
        queue: &queue
    ))

    let paused = try #require(records[id])
    #expect(paused.state == .pausing)
    #expect(paused.resumeAttemptBase == 2)
    #expect(paused.pauseRequiresResume)
    #expect(paused.retryDelayMilliseconds == nil)
    #expect(paused.failureDescription == nil)
    #expect(action.effects == [.cancelRateExpiry, .cancelExecutor])
}

@Test func schedulerControlPolicyResumesAtTailWithStableIdentity() throws {
    let id = UUID()
    let preceding = UUID()
    var record = makeControlPolicyRecord(id: id, label: "resume")
    record.state = .paused
    record.pauseRequiresResume = true
    record.resumeAttemptBase = 1
    record.attemptNumber = 2
    record.rateSampleGeneration = 7
    _ = record.rateEstimator.record(confirmedBytes: 1, at: 1)
    _ = record.rateEstimator.record(
        confirmedBytes: 2,
        at: 1_000_000_001
    )
    #expect(record.rateEstimator.bytesPerSecond != nil)
    var records = [id: record]
    var queue = [preceding]

    let action = try #require(AsyncTransferSchedulerControlPolicy.prepareResume(
        id: id,
        records: &records,
        queue: &queue
    ))

    let resumed = try #require(records[id])
    #expect(resumed.state == .queued)
    #expect(resumed.attemptBase == 1)
    #expect(resumed.attemptNumber == 2)
    #expect(resumed.resumeAttemptBase == nil)
    #expect(!resumed.pauseRequiresResume)
    #expect(resumed.rateEstimator.bytesPerSecond == nil)
    #expect(resumed.rateSampleGeneration == 8)
    #expect(queue == [preceding, id])
    #expect(action.effects == [.startJobs])
    guard case let .download(request) = resumed.request else {
        Issue.record("expected resumed download request")
        return
    }
    #expect(request.resume)
    #expect(request.freshTransferID == "download-resume")
}

@Test func schedulerControlPolicyRejectsOverflowingResumeAttempt() {
    let id = UUID()
    let before = UUID()
    var record = makeControlPolicyRecord(id: id, label: "overflow-resume")
    record.state = .paused
    record.pauseRequiresResume = true
    record.resumeAttemptBase = Int.max
    record.attemptNumber = Int.max
    var records = [id: record]
    var queue = [before]

    #expect(AsyncTransferSchedulerControlPolicy.prepareResume(
        id: id,
        records: &records,
        queue: &queue
    ) == nil)
    #expect(records[id]?.state == .paused)
    #expect(records[id]?.attemptNumber == Int.max)
    #expect(records[id]?.resumeAttemptBase == Int.max)
    #expect(queue == [before])
}

@Test func schedulerControlPolicyRejectsResumeWithoutFullRetryHeadroom() {
    let id = UUID()
    var record = makeControlPolicyRecord(id: id, label: "ceiling-resume")
    record.state = .paused
    record.pauseRequiresResume = true
    record.attemptBase = PersistedTransferQueue.maximumAttemptNumber - 2
    record.resumeAttemptBase = PersistedTransferQueue.maximumAttemptNumber - 1
    record.attemptNumber = PersistedTransferQueue.maximumAttemptNumber
    var records = [id: record]
    var queue: [UUID] = []

    #expect(AsyncTransferSchedulerControlPolicy.prepareResume(
        id: id,
        records: &records,
        queue: &queue
    ) == nil)
    #expect(records[id]?.state == .paused)
    #expect(records[id]?.attemptBase == PersistedTransferQueue.maximumAttemptNumber - 2)
    #expect(records[id]?.attemptNumber == PersistedTransferQueue.maximumAttemptNumber)
    #expect(queue.isEmpty)
}

@Test func schedulerControlPolicyOrdersImmediateAndActiveCancellationEffects() throws {
    let queuedID = UUID()
    var queuedRecords = [
        queuedID: makeControlPolicyRecord(id: queuedID, label: "queued-cancel"),
    ]
    var queue = [queuedID]
    let queuedAction = try #require(
        AsyncTransferSchedulerControlPolicy.prepareCancel(
            id: queuedID,
            records: &queuedRecords,
            queue: &queue
        )
    )
    #expect(queuedRecords[queuedID]?.state == .cancelled)
    #expect(queuedRecords[queuedID]?.settled == true)
    #expect(queue.isEmpty)
    #expect(queuedAction.effects == [
        .settleCancelled,
        .startJobs,
        .cancelRateExpiry,
    ])

    let runningID = UUID()
    var runningRecord = makeControlPolicyRecord(id: runningID, label: "active-cancel")
    runningRecord.state = .running
    var runningRecords = [runningID: runningRecord]
    var emptyQueue: [UUID] = []
    let runningAction = try #require(
        AsyncTransferSchedulerControlPolicy.prepareCancel(
            id: runningID,
            records: &runningRecords,
            queue: &emptyQueue
        )
    )
    #expect(runningRecords[runningID]?.state == .cancelled)
    #expect(runningRecords[runningID]?.settled == false)
    #expect(runningAction.effects == [.cancelExecutor, .cancelRateExpiry])
}

private func makeControlPolicyRecord(
    id: UUID,
    label: String
) -> AsyncTransferSchedulerJobRecord {
    let request = downloadRequest(label)
    return AsyncTransferSchedulerJobRecord(
        id: id,
        sequence: 0,
        request: .download(request),
        kind: .download,
        source: request.sourcePath,
        destination: request.destinationURL.path,
        supportsCheckpointPause: true
    )
}
