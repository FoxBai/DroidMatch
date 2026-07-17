import Foundation
import Testing
@testable import DroidMatchCore

@Test func restoredFinalOrAmbiguousCheckpointsAreInterruptedIncludingZeroBytes() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fullDownload = directory.appendingPathComponent("full-download.bin")
    let emptyDownload = directory.appendingPathComponent("empty-download.bin")
    let unknownDownload = directory.appendingPathComponent("unknown-download.bin")
    try saveDownloadCheckpoint(destination: fullDownload, bytes: Data("abc".utf8))
    try saveDownloadCheckpoint(
        destination: emptyDownload,
        bytes: Data(),
        reportedTotalSizeBytes: -1
    )
    try saveDownloadCheckpoint(
        destination: unknownDownload,
        bytes: Data(),
        reportedTotalSizeBytes: -1,
        fingerprintSizeBytes: -1
    )

    let fullUpload = directory.appendingPathComponent("full-upload.bin")
    let emptyUpload = directory.appendingPathComponent("empty-upload.bin")
    try Data("abc".utf8).write(to: fullUpload)
    try Data().write(to: emptyUpload)
    let fullUploadRequest = try await saveUploadCheckpoint(
        source: fullUpload,
        destinationPath: "dm://app-sandbox/full-upload.bin",
        directory: directory,
        nextOffsetBytes: 3
    )
    let emptyUploadRequest = try await saveUploadCheckpoint(
        source: emptyUpload,
        destinationPath: "dm://app-sandbox/empty-upload.bin",
        directory: directory,
        nextOffsetBytes: 0
    )

    let requests: [AsyncTransferJobRequest] = [
        .download(AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/full-download.bin",
            destinationURL: fullDownload,
            freshTransferID: "full-download"
        )),
        .download(AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/empty-download.bin",
            destinationURL: emptyDownload,
            freshTransferID: "empty-download"
        )),
        .download(AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/unknown-download.bin",
            destinationURL: unknownDownload,
            freshTransferID: "unknown-download"
        )),
        .upload(fullUploadRequest),
        .upload(emptyUploadRequest),
    ]
    let ids = requests.map { _ in UUID() }
    let jobs = zip(ids, requests).enumerated().map { index, value in
        activeCheckpointJob(id: value.0, sequence: UInt64(index), request: value.1)
    }

    let restored = try AsyncTransferSchedulerPersistence.restore(
        PersistedTransferQueue(jobs: jobs)
    )

    #expect(restored.queue.isEmpty)
    #expect(Set(restored.records.keys) == Set(ids))
    #expect(ids.allSatisfy { restored.records[$0]?.state == .interrupted })
    #expect(ids.allSatisfy { restored.records[$0]?.snapshot.canResume == false })
    #expect(ids.allSatisfy {
        if case .failure = restored.outcomes[$0] { return true }
        return false
    })
}

@Test func restoredDownloadCommitMarkerAlwaysInterruptsAutomaticResume() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("commit-window.bin")
    try saveDownloadCheckpoint(
        destination: destination,
        bytes: Data("a".utf8),
        reportedTotalSizeBytes: 3,
        fingerprintSizeBytes: 3
    )
    let marker = AtomicDownloadWriter.commitMarkerURL(for: destination)
    try Data("DroidMatch download commit v1\n".utf8).write(to: marker)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: marker.path
    )
    let id = UUID()

    let restored = try AsyncTransferSchedulerPersistence.restore(
        PersistedTransferQueue(jobs: [activeCheckpointJob(
            id: id,
            sequence: 0,
            request: .download(AsyncDownloadCoordinatorRequest(
                sourcePath: "dm://app-sandbox/commit-window.bin",
                destinationURL: destination,
                freshTransferID: "commit-window"
            ))
        )])
    )

    #expect(restored.records[id]?.state == .interrupted)
    #expect(restored.records[id]?.snapshot.canResume == false)
}

@Test func restoredActiveCheckpointWithoutAttemptHeadroomIsInterrupted() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("attempt-ceiling.bin")
    try saveDownloadCheckpoint(
        destination: destination,
        bytes: Data("a".utf8),
        reportedTotalSizeBytes: 2,
        fingerprintSizeBytes: 2
    )
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/attempt-ceiling.bin",
        destinationURL: destination,
        freshTransferID: "attempt-ceiling",
        recoveryPolicy: .defaultSingleRetry
    )
    #expect(AsyncTransferSchedulerPolicy.hasValidResumeCheckpoint(
        for: .download(request)
    ))
    let id = UUID()

    let restored = try AsyncTransferSchedulerPersistence.restore(
        PersistedTransferQueue(jobs: [activeCheckpointJob(
            id: id,
            sequence: 0,
            request: .download(request),
            attemptNumber: PersistedTransferQueue.maximumAttemptNumber,
            attemptBase: PersistedTransferQueue.maximumAttemptNumber - 1
        )])
    )

    #expect(restored.records[id]?.state == .interrupted)
    #expect(restored.records[id]?.snapshot.canResume == false)
    guard case let .failure(description)? = restored.outcomes[id] else {
        Issue.record("attempt exhaustion must restore a stable failure outcome")
        return
    }
    #expect(description == AsyncTransferSchedulerPolicy.interruptedFailureDescription)
}

@Test func restoredIncompleteUploadDefersStaleSourceCheckUntilCoordinator() async throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("stale-source.bin")
    try Data("abc".utf8).write(to: sourceURL)
    let request = try await saveUploadCheckpoint(
        source: sourceURL,
        destinationPath: "dm://app-sandbox/stale-source.bin",
        directory: directory,
        nextOffsetBytes: 1
    )
    try FileManager.default.removeItem(at: sourceURL)
    try Data("xyz".utf8).write(to: sourceURL)

    let id = UUID()
    let restored = try AsyncTransferSchedulerPersistence.restore(
        PersistedTransferQueue(jobs: [activeCheckpointJob(
            id: id,
            sequence: 0,
            request: .upload(request)
        )])
    )

    // Scheduler restore owns structural/path admission only because product
    // bookmark access is acquired by the execution boundary. The coordinator
    // must still reject the stale strong identity before opening a connection.
    #expect(restored.records[id]?.state == .paused)
    #expect(restored.records[id]?.snapshot.canResume == true)

    let factoryCalls = UploadFactoryCounter()
    let coordinator = AsyncUploadCoordinator(clientFactory: { _ in
        factoryCalls.increment()
        throw FramedTcpClientError.connectionClosed(stage: "unexpected factory call")
    })
    do {
        _ = try await coordinator.upload(AsyncUploadCoordinatorRequest(
            sourceURL: request.sourceURL,
            destinationPath: request.destinationPath,
            resume: true,
            freshTransferID: request.freshTransferID,
            resumeRecordURL: request.resumeRecordURL
        ))
        Issue.record("stale upload source identity must fail before connection")
    } catch let error as AsyncUploadCoordinatorError {
        guard case .sourceMetadataChanged = error else {
            Issue.record("unexpected coordinator error: \(error)")
            return
        }
    }
    #expect(factoryCalls.value == 0)
}

private func saveDownloadCheckpoint(
    destination: URL,
    bytes: Data,
    reportedTotalSizeBytes: Int64? = nil,
    fingerprintSizeBytes: Int64? = nil
) throws {
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = fingerprintSizeBytes ?? Int64(bytes.count)
    fingerprint.modifiedUnixMillis = 1
    let sourcePath = "dm://app-sandbox/\(destination.lastPathComponent)"
    try DownloadResumeRecord(
        transferID: destination.lastPathComponent,
        sourcePath: sourcePath,
        totalSizeBytes: reportedTotalSizeBytes ?? Int64(bytes.count),
        fingerprint: TransferFingerprintRecord(fingerprint)
    ).save(to: DownloadResumeRecord.sidecarURL(forDestination: destination))
    try bytes.write(to: AtomicDownloadWriter.partialURL(for: destination))
}

private func saveUploadCheckpoint(
    source: URL,
    destinationPath: String,
    directory: URL,
    nextOffsetBytes: Int64
) async throws -> AsyncUploadCoordinatorRequest {
    let transferID = UUID().uuidString
    let sidecar = directory
        .appendingPathComponent("UploadResumeRecords", isDirectory: true)
        .appendingPathComponent("\(transferID).json")
    let sourceReader = AsyncUploadFileSource(sourceURL: source)
    let snapshot = try await sourceReader.snapshot()
    await sourceReader.close()
    try UploadResumeRecord(
        transferID: transferID,
        sourcePath: source.path,
        destinationPath: destinationPath,
        sourceIdentity: UploadSourceIdentityRecord(snapshot),
        nextOffsetBytes: nextOffsetBytes
    ).save(to: sidecar)
    return AsyncUploadCoordinatorRequest(
        sourceURL: source,
        destinationPath: destinationPath,
        freshTransferID: transferID,
        resumeRecordURL: sidecar
    )
}

private func activeCheckpointJob(
    id: UUID,
    sequence: UInt64,
    request: AsyncTransferJobRequest,
    attemptNumber: Int = 1,
    attemptBase: Int = 0
) -> PersistedTransferJob {
    PersistedTransferJob(
        id: id,
        sequence: sequence,
        request: PersistedTransferRequest(request),
        state: .active,
        attemptNumber: attemptNumber,
        attemptBase: attemptBase,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )
}
