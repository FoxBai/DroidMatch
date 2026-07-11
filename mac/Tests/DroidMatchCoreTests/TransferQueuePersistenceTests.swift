import Foundation
import Testing
@testable import DroidMatchCore

@Test func transferQueueStoreRoundTripsWithPrivatePermissions() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("state/queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let job = persistedDownloadJob(
        id: UUID(),
        sequence: 4,
        label: "round-trip",
        state: .paused
    )
    let manifest = PersistedTransferQueue(jobs: [job])

    try store.save(manifest)

    #expect(try store.load() == manifest)
    let fileMode = try #require(
        FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
            as? NSNumber
    )
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber
    )
    #expect(fileMode.intValue & 0o777 == 0o600)
    #expect(directoryMode.intValue & 0o777 == 0o700)

    try store.save(PersistedTransferQueue(jobs: []))
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func transferQueueStoreKeepsPrivateFilesInsideExistingBroadDirectory() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateDirectory = directory.appendingPathComponent("existing-state", isDirectory: true)
    try FileManager.default.createDirectory(
        at: stateDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: stateDirectory.path
    )
    let fileURL = stateDirectory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let first = PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: UUID(),
        sequence: 1,
        label: "first-private-replacement",
        state: .paused
    )])
    let second = PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: UUID(),
        sequence: 2,
        label: "second-private-replacement",
        state: .paused
    )])

    try store.save(first)
    try store.save(second)

    #expect(try store.load() == second)
    let fileMode = try #require(
        FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
            as? NSNumber
    )
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: stateDirectory.path)[.posixPermissions]
            as? NSNumber
    )
    #expect(fileMode.intValue & 0o777 == 0o600)
    #expect(directoryMode.intValue & 0o777 == 0o755)
    #expect(try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path) == [
        "queue.json",
    ])
}

@Test func transferQueueStorePreservesCorruptAndUnknownVersionFiles() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)

    let corrupt = Data("not-json".utf8)
    try corrupt.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )
    do {
        _ = try store.load()
        Issue.record("expected corrupt queue data to be rejected")
    } catch let error as TransferQueuePersistenceStoreError {
        #expect(error == .invalidData)
    }
    #expect(try Data(contentsOf: fileURL) == corrupt)

    let unknownVersion = Data(#"{"schemaVersion":999,"jobs":[]}"#.utf8)
    try unknownVersion.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )
    do {
        _ = try store.load()
        Issue.record("expected unknown queue schema to be rejected")
    } catch let error as TransferQueuePersistenceStoreError {
        #expect(error == .unsupportedSchemaVersion(999))
    }
    #expect(try Data(contentsOf: fileURL) == unknownVersion)

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)],
        ofItemAtPath: fileURL.path
    )
    do {
        _ = try store.load()
        Issue.record("expected permissive queue file mode to be rejected")
    } catch let error as TransferQueuePersistenceStoreError {
        #expect(error == .invalidLocation)
    }
    #expect(try Data(contentsOf: fileURL) == unknownVersion)
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
    fingerprint.sizeBytes = 3
    fingerprint.modifiedUnixMillis = 1
    try DownloadResumeRecord(
        transferID: "stable-transfer",
        sourcePath: request.sourcePath,
        totalSizeBytes: 3,
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
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let observed = LockedValue<[(resume: Bool, transferID: String)]>([])
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: { value, _, _ in
            observed.update { $0.append((value.resume, value.freshTransferID)) }
            return persistenceDownloadResult(value, finalOffsetBytes: 3)
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
    try UploadResumeRecord(
        transferID: "stable-upload",
        sourcePath: sourceURL.path,
        destinationPath: request.destinationPath,
        totalSizeBytes: 3,
        sourceModifiedUnixMillis: 1,
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

@Test func staleActiveManifestAfterRetryAndFinishWriteFailuresNeverAutoReplays() async throws {
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
        freshTransferID: "stale-active"
    )))
    #expect(await waitForPersistenceCondition { started.value() })

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o500)],
        ofItemAtPath: stateDirectory.path
    )
    release.resolve(.success(()))
    let outcome = try await scheduler.waitForCompletion(jobID)
    guard case .success = outcome else {
        Issue.record("expected the in-memory executor to finish")
        return
    }
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

private func persistedDownloadJob(
    id: UUID,
    sequence: UInt64,
    label: String,
    state: PersistedTransferJobState
) -> PersistedTransferJob {
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/\(label).bin",
        destinationURL: URL(fileURLWithPath: "/tmp/\(label).bin"),
        freshTransferID: "download-\(label)"
    )
    return PersistedTransferJob(
        id: id,
        sequence: sequence,
        request: PersistedTransferRequest(.download(request)),
        state: state,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )
}

private func persistedUploadJob(
    id: UUID,
    sequence: UInt64,
    label: String,
    destinationPath: String,
    state: PersistedTransferJobState
) -> PersistedTransferJob {
    let request = AsyncUploadCoordinatorRequest(
        sourceURL: URL(fileURLWithPath: "/tmp/\(label).bin"),
        destinationPath: destinationPath,
        freshTransferID: "upload-\(label)"
    )
    return PersistedTransferJob(
        id: id,
        sequence: sequence,
        request: PersistedTransferRequest(.upload(request)),
        state: state,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )
}

private func persistenceDownloadResult(
    _ request: AsyncDownloadCoordinatorRequest,
    finalOffsetBytes: Int64
) -> AsyncDownloadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = request.freshTransferID
    response.totalSizeBytes = finalOffsetBytes
    return AsyncDownloadCoordinatorResult(
        download: DownloadResult(
            openResponse: response,
            chunkCount: 0,
            bytesReceived: finalOffsetBytes,
            finalOffsetBytes: finalOffsetBytes
        ),
        attemptCount: 1
    )
}

private func persistenceUploadResult(
    _ request: AsyncUploadCoordinatorRequest,
    finalOffsetBytes: Int64
) -> AsyncUploadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = request.freshTransferID
    response.totalSizeBytes = finalOffsetBytes
    return AsyncUploadCoordinatorResult(
        upload: UploadResult(
            openResponse: response,
            chunkCount: 0,
            bytesSent: finalOffsetBytes,
            finalOffsetBytes: finalOffsetBytes
        ),
        attemptCount: 1
    )
}

private func makeTransferQueueTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-transfer-queue-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func waitForPersistenceCondition(
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func waitForPersistenceSnapshot(
    scheduler: AsyncTransferScheduler,
    id: UUID,
    matching predicate: (AsyncTransferJobSnapshot) -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if let snapshot = try? await scheduler.snapshot(for: id),
           predicate(snapshot) {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private enum TransferQueuePersistenceTestError: Error {
    case retryable
}
