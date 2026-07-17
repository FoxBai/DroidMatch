import Foundation
import Testing
@testable import DroidMatchCore

@Test func cancellingPreparedUploadWaitsForDurablePartialCleanup() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let cleanupIdentities = LockedValue<[AsyncUploadPartialIdentity]>([])
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, _ in
            persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            try await request.partialPreparationObserver?(
                AsyncUploadPartialIdentity(
                    transferID: request.freshTransferID,
                    destinationPath: request.destinationPath,
                    expectedSizeBytes: 6
                )
            )
            try await Task.sleep(nanoseconds: UInt64.max)
            return persistenceUploadResult(request, finalOffsetBytes: 6)
        },
        uploadCleanupExecutor: { _, identity in
            cleanupIdentities.update { $0.append(identity) }
        },
        persistenceStore: store
    )
    let request = uploadRequest("cleanup-success")
    let id = await scheduler.submit(.upload(request))
    #expect(await waitForPersistenceSnapshot(scheduler: scheduler, id: id) {
        $0.state == .running && $0.totalBytes == 6
    })

    #expect(await scheduler.cancel(id))
    let cleaning = try await scheduler.snapshot(for: id)
    #expect(cleaning.state == .cleaning || cleaning.state == .cancelled)
    assertCancelled(try await scheduler.waitForCompletion(id))

    let cancelled = try await scheduler.snapshot(for: id)
    #expect(cancelled.state == .cancelled)
    #expect(cancelled.canRemove)
    #expect(cleanupIdentities.value() == [AsyncUploadPartialIdentity(
        transferID: request.freshTransferID,
        destinationPath: request.destinationPath,
        expectedSizeBytes: 6
    )])
    #expect(try store.load().jobs.isEmpty)
}

@Test func failedUploadPartialCleanupPersistsAndCanBeRetried() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let cleanupAttempts = LockedValue(0)
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, _ in
            persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            try await request.partialPreparationObserver?(
                AsyncUploadPartialIdentity(
                    transferID: request.freshTransferID,
                    destinationPath: request.destinationPath,
                    expectedSizeBytes: 9
                )
            )
            try await Task.sleep(nanoseconds: UInt64.max)
            return persistenceUploadResult(request, finalOffsetBytes: 9)
        },
        uploadCleanupExecutor: { _, _ in
            cleanupAttempts.update { $0 += 1 }
            let attempt = cleanupAttempts.value()
            if attempt == 1 { throw SchedulerTestError.retryable }
        },
        persistenceStore: store
    )
    let id = await scheduler.submit(.upload(uploadRequest("cleanup-retry")))
    #expect(await waitForPersistenceSnapshot(scheduler: scheduler, id: id) {
        $0.state == .running && $0.totalBytes == 9
    })
    #expect(await scheduler.cancel(id))
    #expect(await waitForPersistenceSnapshot(scheduler: scheduler, id: id) {
        $0.state == .cleaning && $0.failureDescription != nil && $0.canCancel
    })

    let pending = try store.load()
    #expect(pending.jobs.count == 1)
    #expect(pending.jobs[0].state == .cleanupPending)
    #expect(pending.jobs[0].uploadPartialIdentity?.expectedSizeBytes == 9)

    #expect(await scheduler.cancel(id))
    assertCancelled(try await scheduler.waitForCompletion(id))
    #expect(cleanupAttempts.value() == 2)
    #expect(try store.load().jobs.isEmpty)
}

@Test func restoredCleanupPendingUploadRunsBeforeOrdinaryQueuedWork() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let cleanupID = UUID()
    let queuedID = UUID()
    let cleanupRequest = uploadRequest("restored-cleanup")
    try store.save(PersistedTransferQueue(jobs: [
        PersistedTransferJob(
            id: cleanupID,
            sequence: 0,
            request: PersistedTransferRequest(.upload(cleanupRequest)),
            state: .cleanupPending,
            attemptNumber: 1,
            attemptBase: 0,
            resumeAttemptBase: nil,
            pauseRequiresResume: false,
            uploadPartialIdentity: PersistedUploadPartialIdentity(
                AsyncUploadPartialIdentity(
                    transferID: cleanupRequest.freshTransferID,
                    destinationPath: cleanupRequest.destinationPath,
                    expectedSizeBytes: 4
                )
            )
        ),
        persistedDownloadJob(
            id: queuedID,
            sequence: 1,
            label: "after-cleanup",
            state: .queued
        ),
    ]))
    let order = LockedValue<[String]>([])
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { request, _, _ in
            order.update { $0.append("download") }
            return persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            persistenceUploadResult(request, finalOffsetBytes: 0)
        },
        uploadCleanupExecutor: { _, _ in
            order.update { $0.append("cleanup") }
        }
    )

    assertCancelled(try await scheduler.waitForCompletion(cleanupID))
    assertSuccess(try await scheduler.waitForCompletion(queuedID))
    #expect(order.value() == ["cleanup", "download"])
}

@Test func removingFailedUploadCleansPartialBeforeForgettingHistory() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let cleanupGate = AsyncRpcOneShot<Void>()
    let cleanupIdentities = LockedValue<[AsyncUploadPartialIdentity]>([])
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, _ in
            persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            try await request.partialPreparationObserver?(
                AsyncUploadPartialIdentity(
                    transferID: request.freshTransferID,
                    destinationPath: request.destinationPath,
                    expectedSizeBytes: 7
                )
            )
            throw SchedulerTestError.retryable
        },
        uploadCleanupExecutor: { _, identity in
            cleanupIdentities.update { $0.append(identity) }
            try await cleanupGate.wait(onCancel: {})
        },
        persistenceStore: store
    )
    let request = uploadRequest("failed-remove-cleanup")
    let id = await scheduler.submit(.upload(request))
    let outcome = try await scheduler.waitForCompletion(id)
    guard case .failure = outcome else {
        Issue.record("expected failed upload outcome")
        return
    }

    let retained = try store.load()
    #expect(retained.jobs.map(\.state) == [.interrupted])
    #expect(retained.jobs[0].uploadPartialIdentity?.expectedSizeBytes == 7)
    #expect(await scheduler.remove(id))
    #expect(await waitForPersistenceCondition {
        cleanupIdentities.value().count == 1
    })
    let cleaning = try store.load()
    #expect(cleaning.jobs.map(\.state) == [.cleanupPending])
    #expect(cleaning.jobs[0].removeAfterUploadCleanup == true)
    #expect((try? await scheduler.snapshot(for: id).state) == .cleaning)

    cleanupGate.resolve(.success(()))
    #expect(await waitForPersistenceCondition {
        (try? store.load().jobs.isEmpty) == true
    })
    #expect((await scheduler.snapshots()).allSatisfy { $0.id != id })
}

@Test func shutdownPersistsPreparedUploadCleanupForNextAuthenticatedSession() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, _ in
            persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            try await request.partialPreparationObserver?(
                AsyncUploadPartialIdentity(
                    transferID: request.freshTransferID,
                    destinationPath: request.destinationPath,
                    expectedSizeBytes: 8
                )
            )
            try await Task.sleep(nanoseconds: UInt64.max)
            return persistenceUploadResult(request, finalOffsetBytes: 8)
        },
        uploadCleanupExecutor: { _, _ in
            Issue.record("shutdown must not start new cleanup on a closing session")
        },
        persistenceStore: store
    )
    let id = await scheduler.submit(.upload(uploadRequest("shutdown-cleanup")))
    #expect(await waitForPersistenceSnapshot(scheduler: scheduler, id: id) {
        $0.state == .running && $0.totalBytes == 8
    })

    await scheduler.shutdown()
    let pending = try store.load()
    #expect(pending.jobs.map(\.state) == [.cleanupPending])
    #expect(pending.jobs[0].uploadPartialIdentity?.expectedSizeBytes == 8)

    let cleanupCount = LockedValue(0)
    let restored = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { request, _, _ in
            persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            persistenceUploadResult(request, finalOffsetBytes: 0)
        },
        uploadCleanupExecutor: { _, _ in
            cleanupCount.update { $0 += 1 }
        }
    )
    assertCancelled(try await restored.waitForCompletion(id))
    #expect(cleanupCount.value() == 1)
    #expect(try store.load().jobs.isEmpty)
}
