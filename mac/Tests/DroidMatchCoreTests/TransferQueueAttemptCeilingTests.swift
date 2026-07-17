import Foundation
import Testing
@testable import DroidMatchCore

@Test func restoredQueueCompletesRetryExactlyAtAttemptCeiling() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let jobID = UUID()
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/closed-attempt-boundary.bin",
        destinationURL: directory.appendingPathComponent("closed-attempt-boundary.bin"),
        freshTransferID: "closed-attempt-boundary",
        recoveryPolicy: .defaultSingleRetry
    )
    try store.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 0,
        request: PersistedTransferRequest(.download(request)),
        state: .queued,
        attemptNumber: PersistedTransferQueue.maximumAttemptNumber - 1,
        attemptBase: PersistedTransferQueue.maximumAttemptNumber - 2,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, retryObserver, _ in
            retryObserver?(1, 0, TransferQueuePersistenceTestError.retryable)
            return downloadResult(value.sourcePath, attemptCount: 2)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )

    guard case .success = try await scheduler.waitForCompletion(jobID) else {
        Issue.record("the closed retry boundary must remain executable")
        return
    }
    let completed = try await scheduler.snapshot(for: jobID)
    #expect(completed.state == .completed)
    #expect(completed.attemptNumber == PersistedTransferQueue.maximumAttemptNumber)
    #expect(await scheduler.persistenceStatus() == .healthy)
    #expect(try store.load().jobs.isEmpty)
}
