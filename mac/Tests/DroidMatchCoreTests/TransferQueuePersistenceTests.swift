import Foundation
import Testing
@testable import DroidMatchCore

@Test func schedulerRetriesCorruptStartupManifestWithoutOverwritingIt() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("queue.json")
    let corrupt = Data("not-a-queue-manifest".utf8)
    try corrupt.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { request, _, _ in
            persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            persistenceUploadResult(request, finalOffsetBytes: 0)
        }
    )

    #expect(await scheduler.persistenceStatus() == .writeFailed)
    #expect(await scheduler.snapshots().isEmpty)
    #expect(try Data(contentsOf: fileURL) == corrupt)
    #expect(!(await scheduler.retryPersistence()))
    #expect(try Data(contentsOf: fileURL) == corrupt)

    try FileManager.default.removeItem(at: fileURL)
    let repairedID = UUID()
    try store.save(PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: repairedID,
        sequence: 4,
        label: "repaired-startup",
        state: .paused
    )]))
    #expect(await scheduler.retryPersistence())
    #expect(await scheduler.persistenceStatus() == .healthy)
    let snapshots = await scheduler.snapshots()
    #expect(snapshots.map(\.id) == [repairedID])
    #expect(snapshots.map(\.state) == [.paused])
}

@Test func restoredTransferQueueKeepsIdentityOrderAndInterruptsFreshOnlyActiveUpload() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let queuedID = UUID()
    let secondQueuedID = UUID()
    let pausedID = UUID()
    let mediaID = UUID()
    try store.save(PersistedTransferQueue(jobs: [
        persistedDownloadJob(
            id: queuedID,
            sequence: 10,
            label: "queued",
            state: .queued
        ),
        persistedUploadJob(
            id: secondQueuedID,
            sequence: 11,
            label: "second-queued",
            destinationPath: "dm://app-sandbox/second-queued.bin",
            state: .queued
        ),
        persistedUploadJob(
            id: pausedID,
            sequence: 12,
            label: "paused",
            destinationPath: "dm://app-sandbox/paused.bin",
            state: .paused
        ),
        persistedUploadJob(
            id: mediaID,
            sequence: 13,
            label: "media",
            destinationPath: "dm://media-images/media.jpg",
            state: .active
        ),
    ]))

    let gate = AsyncRpcOneShot<Void>()
    let started = LockedValue<[String]>([])
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { request, _, _ in
            started.update { $0.append(request.sourcePath) }
            try await gate.wait(onCancel: {})
            return persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            started.update { $0.append(request.sourceURL.path) }
            return persistenceUploadResult(request, finalOffsetBytes: 0)
        }
    )

    #expect(await waitForPersistenceCondition {
        started.value() == ["dm://app-sandbox/queued.bin"]
    })
    let snapshots = await scheduler.snapshots()
    #expect(snapshots.map(\.id) == [queuedID, secondQueuedID, pausedID, mediaID])
    #expect(snapshots.map(\.state) == [.running, .queued, .paused, .interrupted])
    #expect(snapshots[3].canRemove)
    #expect(!snapshots[3].canResume)
    #expect(await scheduler.persistenceStatus() == .healthy)

    let canonical = try store.load()
    #expect(canonical.jobs.map(\.id) == [queuedID, secondQueuedID, pausedID, mediaID])
    #expect(canonical.jobs.map(\.state) == [.active, .queued, .paused, .interrupted])

    gate.resolve(.success(()))
    _ = try await scheduler.waitForCompletion(queuedID)
    _ = try await scheduler.waitForCompletion(secondQueuedID)
    #expect(started.value() == [
        "dm://app-sandbox/queued.bin",
        "/tmp/second-queued.bin",
    ])
    #expect(await scheduler.cancel(pausedID))
    #expect(await scheduler.remove(pausedID))
    #expect(await scheduler.remove(mediaID))
}

@Test func restoredDuplicateDownloadDestinationsStayVisibleAndNeverReplay() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("collision.bin")
    let lexicalAlias = URL(
        fileURLWithPath: directory.path + "/nested/../collision.bin"
    )
    let firstID = UUID()
    let secondID = UUID()
    let firstRequest = AsyncTransferJobRequest.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/first-collision.bin",
            destinationURL: lexicalAlias,
            freshTransferID: "first-collision"
        )
    )
    let secondRequest = AsyncTransferJobRequest.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/second-collision.bin",
            destinationURL: destination,
            freshTransferID: "second-collision"
        )
    )
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    try store.save(PersistedTransferQueue(jobs: [
        PersistedTransferJob(
            id: firstID,
            sequence: 0,
            request: PersistedTransferRequest(firstRequest),
            state: .queued,
            attemptNumber: 1,
            attemptBase: 0,
            resumeAttemptBase: nil,
            pauseRequiresResume: false
        ),
        PersistedTransferJob(
            id: secondID,
            sequence: 1,
            request: PersistedTransferRequest(secondRequest),
            state: .queued,
            attemptNumber: 1,
            attemptBase: 0,
            resumeAttemptBase: nil,
            pauseRequiresResume: false
        ),
    ]))
    let starts = LockedValue(0)
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 2,
        persistenceStore: store,
        downloadExecutor: { request, _, _ in
            starts.update { $0 += 1 }
            return persistenceDownloadResult(request, finalOffsetBytes: 0)
        },
        uploadExecutor: { request, _, _ in
            persistenceUploadResult(request, finalOffsetBytes: 0)
        }
    )

    let snapshots = await scheduler.snapshots()
    #expect(snapshots.map(\.id) == [firstID, secondID])
    #expect(snapshots.map(\.state) == [.interrupted, .interrupted])
    #expect(snapshots.allSatisfy { $0.canRemove && !$0.canResume })
    #expect(snapshots.allSatisfy {
        $0.failureDescription
            == AsyncTransferSchedulerPolicy
                .restoredDuplicateDownloadDestinationFailureDescription
    })
    #expect(starts.value() == 0)
    #expect(try store.load().jobs.map(\.state) == [.interrupted, .interrupted])

    // Restored terminal history must not reserve the destination forever.
    let replacement = try await scheduler.submitValidated(.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/replacement.bin",
            destinationURL: destination,
            freshTransferID: "replacement"
        )
    ))
    _ = try await scheduler.waitForCompletion(replacement)
    #expect(starts.value() == 1)
}

@Test func restoredActiveDownloadRequiresCheckpointAndResumesWithStableIdentity() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queueURL = directory.appendingPathComponent("queue.json")
    let destinationURL = directory.appendingPathComponent("download.bin")
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/resume.bin",
        destinationURL: destinationURL,
        freshTransferID: "stable-transfer"
    )
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 4
    fingerprint.modifiedUnixMillis = 1
    try DownloadResumeRecord(
        transferID: "stable-transfer",
        sourcePath: request.sourcePath,
        totalSizeBytes: 4,
        fingerprint: TransferFingerprintRecord(fingerprint)
    ).save(to: DownloadResumeRecord.sidecarURL(forDestination: destinationURL))
    try Data("abc".utf8).write(
        to: AtomicDownloadWriter.partialURL(for: destinationURL)
    )

    let jobID = UUID()
    let store = try TransferQueuePersistenceStore(fileURL: queueURL)
    try store.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 2,
        request: PersistedTransferRequest(.download(request)),
        state: .active,
        attemptNumber: 2,
        attemptBase: 1,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let observed = LockedValue<[(resume: Bool, transferID: String)]>([])
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            observed.update { $0.append((value.resume, value.freshTransferID)) }
            return persistenceDownloadResult(value, finalOffsetBytes: 4)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )

    let restored = try await scheduler.snapshot(for: jobID)
    #expect(restored.state == .paused)
    #expect(restored.canResume)
    #expect(await scheduler.resume(jobID))
    _ = try await scheduler.waitForCompletion(jobID)

    #expect(observed.value().map(\.resume) == [true])
    #expect(observed.value().map(\.transferID) == ["stable-transfer"])
    let completed = try await scheduler.snapshot(for: jobID)
    #expect(completed.state == .completed)
    #expect(completed.attemptNumber == 3)
    #expect(try store.load().jobs.isEmpty)
}

@Test func corruptSidecarInterruptsOnlyItsActiveJobAndRemainsVisible() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destinationURL = directory.appendingPathComponent("corrupt.bin")
    try Data("not-json".utf8).write(
        to: DownloadResumeRecord.sidecarURL(forDestination: destinationURL)
    )
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/corrupt.bin",
        destinationURL: destinationURL,
        freshTransferID: "corrupt-transfer"
    )
    let jobID = UUID()
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    try store.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 0,
        request: PersistedTransferRequest(.download(request)),
        state: .active,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let starts = LockedValue(0)
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            starts.update { $0 += 1 }
            return persistenceDownloadResult(value, finalOffsetBytes: 0)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )

    let interrupted = try await scheduler.snapshot(for: jobID)
    #expect(interrupted.state == .interrupted)
    #expect(interrupted.canRemove)
    #expect(!(await scheduler.resume(jobID)))
    #expect(starts.value() == 0)
    #expect(try store.load().jobs.map(\.state) == [.interrupted])

    #expect(await scheduler.remove(jobID))
    #expect(try store.load().jobs.isEmpty)
}

@Test func restoredActiveResumableUploadUsesSidecarAndKeepsTransferIdentity() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("upload.bin")
    try Data("abc".utf8).write(to: sourceURL)
    let managedSidecar = directory
        .appendingPathComponent("UploadResumeRecords", isDirectory: true)
        .appendingPathComponent("stable-upload.json")
    let request = AsyncUploadCoordinatorRequest(
        sourceURL: sourceURL,
        destinationPath: "dm://app-sandbox/upload.bin",
        freshTransferID: "stable-upload",
        resumeRecordURL: managedSidecar
    )
    let uploadSource = AsyncUploadFileSource(sourceURL: sourceURL)
    let sourceSnapshot = try await uploadSource.snapshot()
    await uploadSource.close()
    try UploadResumeRecord(
        transferID: "stable-upload",
        sourcePath: sourceURL.path,
        destinationPath: request.destinationPath,
        sourceIdentity: UploadSourceIdentityRecord(sourceSnapshot),
        nextOffsetBytes: 2
    ).save(to: managedSidecar)

    let jobID = UUID()
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    try store.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 1,
        request: PersistedTransferRequest(.upload(request)),
        state: .active,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let observed = LockedValue<[(resume: Bool, transferID: String, recordURL: URL?)]>([])
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            persistenceDownloadResult(value, finalOffsetBytes: 0)
        },
        uploadExecutor: { value, _, _ in
            observed.update {
                $0.append((value.resume, value.freshTransferID, value.resumeRecordURL))
            }
            return persistenceUploadResult(value, finalOffsetBytes: 3)
        }
    )

    #expect(try await scheduler.snapshot(for: jobID).state == .paused)
    #expect(await scheduler.resume(jobID))
    _ = try await scheduler.waitForCompletion(jobID)
    #expect(observed.value().map(\.resume) == [true])
    #expect(observed.value().map(\.transferID) == ["stable-upload"])
    #expect(observed.value().map(\.recordURL) == [managedSidecar])
    #expect(try store.load().jobs.isEmpty)
}

@Test func restoredUploadRejectsLegacyNonzeroCheckpointBeforeExecution() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("legacy-upload.bin")
    try Data("abc".utf8).write(to: sourceURL)
    let transferID = UUID().uuidString
    let sidecarURL = directory
        .appendingPathComponent("UploadResumeRecords", isDirectory: true)
        .appendingPathComponent("\(transferID).json")
    let request = AsyncUploadCoordinatorRequest(
        sourceURL: sourceURL,
        destinationPath: "dm://app-sandbox/legacy-upload.bin",
        freshTransferID: transferID,
        resumeRecordURL: sidecarURL
    )
    try UploadResumeRecord(
        transferID: transferID,
        sourcePath: sourceURL.path,
        destinationPath: request.destinationPath,
        totalSizeBytes: 3,
        sourceModifiedUnixMillis: 1,
        nextOffsetBytes: 2
    ).save(to: sidecarURL)

    let jobID = UUID()
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    try store.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 1,
        request: PersistedTransferRequest(.upload(request)),
        state: .active,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let starts = LockedValue(0)
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            persistenceDownloadResult(value, finalOffsetBytes: 0)
        },
        uploadExecutor: { value, _, _ in
            starts.update { $0 += 1 }
            return persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )

    let snapshot = try await scheduler.snapshot(for: jobID)
    #expect(snapshot.state == .interrupted)
    #expect(!snapshot.canResume)
    #expect(snapshot.canRemove)
    #expect(starts.value() == 0)
    #expect(try UploadResumeRecord.load(from: sidecarURL)?.nextOffsetBytes == 2)
}

@Test func restoredCheckpointPauseInterruptsWhenItsSidecarDisappeared() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/missing-paused-sidecar.bin",
        destinationURL: directory.appendingPathComponent("missing.bin"),
        freshTransferID: "missing-paused-sidecar"
    )
    let jobID = UUID()
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    try store.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 0,
        request: PersistedTransferRequest(.download(request)),
        state: .paused,
        attemptNumber: 2,
        attemptBase: 1,
        resumeAttemptBase: 2,
        pauseRequiresResume: true
    )]))
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            persistenceDownloadResult(value, finalOffsetBytes: 0)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )

    let interrupted = try await scheduler.snapshot(for: jobID)
    #expect(interrupted.state == .interrupted)
    #expect(!interrupted.canResume)
    #expect(try store.load().jobs.map(\.state) == [.interrupted])
}

@Test func persistentSchedulerDoesNotStartWhenManifestWriteFails() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateDirectory = directory.appendingPathComponent("state")
    let store = try TransferQueuePersistenceStore(
        fileURL: stateDirectory.appendingPathComponent("queue.json")
    )
    let starts = LockedValue(0)
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            starts.update { $0 += 1 }
            return persistenceDownloadResult(value, finalOffsetBytes: 0)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )

    try FileManager.default.removeItem(at: stateDirectory)
    try Data("blocks-directory".utf8).write(to: stateDirectory)
    let jobID = await scheduler.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/write-failure.bin",
        destinationURL: directory.appendingPathComponent("write-failure.bin"),
        freshTransferID: "write-failure"
    )))

    let failed = try await scheduler.snapshot(for: jobID)
    #expect(failed.state == .failed)
    #expect(failed.canRemove)
    #expect(starts.value() == 0)
    #expect(await scheduler.persistenceStatus() == .writeFailed)
}

@Test func persistenceFailureRejectsPauseAndCancelBeforeTaskSideEffects() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateDirectory = directory.appendingPathComponent("state")
    let store = try TransferQueuePersistenceStore(
        fileURL: stateDirectory.appendingPathComponent("queue.json")
    )
    let gate = AsyncRpcOneShot<Void>()
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 1,
                totalBytes: 10
            ))
            try await gate.wait(onCancel: {
                gate.resolve(.failure(CancellationError()))
            })
            return persistenceDownloadResult(value, finalOffsetBytes: 10)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )
    let jobID = await scheduler.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/write-before-side-effect.bin",
        destinationURL: directory.appendingPathComponent("destination.bin"),
        freshTransferID: "write-before-side-effect"
    )))
    #expect(await waitForPersistenceSnapshot(
        scheduler: scheduler,
        id: jobID,
        matching: { $0.canPause }
    ))

    try FileManager.default.removeItem(at: stateDirectory)
    try Data("blocks-directory".utf8).write(to: stateDirectory)
    #expect(!(await scheduler.pause(jobID)))
    #expect(try await scheduler.snapshot(for: jobID).state == .running)
    #expect(!(await scheduler.cancel(jobID)))
    #expect(try await scheduler.snapshot(for: jobID).state == .running)
    #expect(await scheduler.persistenceStatus() == .writeFailed)

    try FileManager.default.removeItem(at: stateDirectory)
    #expect(await scheduler.retryPersistence())
    #expect(await scheduler.cancel(jobID))
    let outcome = try await scheduler.waitForCompletion(jobID)
    guard case .cancelled = outcome else {
        Issue.record("expected cancellation after persistence recovered")
        return
    }
}

@Test func retryWriteFailureStopsRuntimeAndStaleActiveManifestNeverAutoReplays() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateDirectory = directory.appendingPathComponent("state")
    let store = try TransferQueuePersistenceStore(
        fileURL: stateDirectory.appendingPathComponent("queue.json")
    )
    let release = AsyncRpcOneShot<Void>()
    let started = LockedValue(false)
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, retryObserver, _ in
            started.set(true)
            try await release.wait(onCancel: {})
            retryObserver?(1, 250, TransferQueuePersistenceTestError.retryable)
            return persistenceDownloadResult(value, finalOffsetBytes: 0)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )
    let jobID = await scheduler.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/stale-active.bin",
        destinationURL: directory.appendingPathComponent("stale-active.bin"),
        freshTransferID: "stale-active",
        recoveryPolicy: .defaultSingleRetry
    )))
    #expect(await waitForPersistenceCondition { started.value() })

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o500)],
        ofItemAtPath: stateDirectory.path
    )
    release.resolve(.success(()))
    let outcome = try await scheduler.waitForCompletion(jobID)
    guard case let .failure(description) = outcome else {
        Issue.record("retry persistence failure must stop the in-memory executor")
        return
    }
    #expect(description == AsyncTransferSchedulerPolicy.retryPersistenceFailureDescription)
    let stopped = try await scheduler.snapshot(for: jobID)
    #expect(stopped.state == .interrupted)
    #expect(stopped.canRemove)
    #expect(await scheduler.persistenceStatus() == .writeFailed)

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: stateDirectory.path
    )
    #expect(try store.load().jobs.map(\.state) == [.active])
    let replayStarts = LockedValue(0)
    let restored = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            replayStarts.update { $0 += 1 }
            return persistenceDownloadResult(value, finalOffsetBytes: 0)
        },
        uploadExecutor: { value, _, _ in
            persistenceUploadResult(value, finalOffsetBytes: 0)
        }
    )

    let interrupted = try await restored.snapshot(for: jobID)
    #expect(interrupted.state == .interrupted)
    #expect(!interrupted.canResume)
    #expect(replayStarts.value() == 0)
}
