import Foundation
import Testing
@testable import DroidMatchCore

@Test func schedulerPersistenceRestoresOrderAndCanonicalizesInterruptedState() throws {
    let queuedID = UUID()
    let interruptedID = UUID()
    let queuedRequest = AsyncTransferJobRequest.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/queued.bin",
            destinationURL: URL(fileURLWithPath: "/tmp/queued.bin"),
            freshTransferID: "queued-transfer"
        )
    )
    let interruptedRequest = AsyncTransferJobRequest.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/interrupted.bin",
            destinationURL: URL(fileURLWithPath: "/tmp/interrupted.bin"),
            freshTransferID: "interrupted-transfer"
        )
    )
    let manifest = PersistedTransferQueue(jobs: [
        PersistedTransferJob(
            id: queuedID,
            sequence: 4,
            request: PersistedTransferRequest(queuedRequest),
            state: .queued,
            attemptNumber: 1,
            attemptBase: 0,
            resumeAttemptBase: nil,
            pauseRequiresResume: false
        ),
        PersistedTransferJob(
            id: interruptedID,
            sequence: 3,
            request: PersistedTransferRequest(interruptedRequest),
            state: .interrupted,
            attemptNumber: 2,
            attemptBase: 1,
            resumeAttemptBase: nil,
            pauseRequiresResume: false
        ),
    ])

    let restored = try AsyncTransferSchedulerPersistence.restore(manifest)

    #expect(restored.queue == [queuedID])
    #expect(restored.nextSequence == 5)
    #expect(restored.records[queuedID]?.state == .queued)
    #expect(restored.records[interruptedID]?.state == .interrupted)
    #expect(restored.records[interruptedID]?.settled == true)
    if case let .failure(description) = restored.outcomes[interruptedID] {
        #expect(description == AsyncTransferSchedulerPolicy.interruptedFailureDescription)
    } else {
        Issue.record("restored interrupted job must expose a stable failure outcome")
    }

    let canonical = try AsyncTransferSchedulerPersistence.manifest(for: restored.records)
    #expect(canonical.jobs.map(\.id) == [interruptedID, queuedID])
    #expect(canonical.jobs.map(\.state) == [.interrupted, .queued])
}
