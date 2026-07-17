import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func asyncUploadCoordinatorPersistsEachAckAndResumesAfterWindowDisconnect() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-recovery-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.bin")
    let sourceData = Data("abcdefghij".utf8)
    try sourceData.write(to: sourceURL)
    let sidecar = directory
        .appendingPathComponent("app-owned-recovery", isDirectory: true)
        .appendingPathComponent("upload.json")

    let server = try UploadRecoveryTestServer(
        sourcePath: TransferWireMetadata.localUploadSource,
        destinationPath: "dm://app-sandbox/recovered-upload.bin"
    )
    defer { server.cancel() }
    let coordinator = AsyncUploadCoordinator(
        clientFactory: { _ in
            let session = try await AsyncFramedTcpSession.connect(
                port: server.port,
                timeoutSeconds: 2
            )
            return AsyncRpcControlClient(
                session: session,
                requestedCapabilities: [.fileWrite, .resumableTransfer],
                requestTimeoutSeconds: 2
            )
        },
        sleeper: { _ in try Task.checkCancellation() }
    )
    let request = AsyncUploadCoordinatorRequest(
        sourceURL: sourceURL,
        destinationPath: "dm://app-sandbox/recovered-upload.bin",
        freshTransferID: "upload-recovery-transfer",
        preferredChunkSizeBytes: 2,
        recoveryPolicy: RecoveryPolicy(
            maxAttempts: 1,
            baseDelayMs: 0,
            maxDelayMs: 0,
            jitterFactor: 0
        ),
        resumeRecordURL: sidecar
    )
    let observedProgress = LockedValue<[
        (progress: AsyncTransferProgress, sidecarOffset: Int64?)
    ]>([])

    let upload = Task {
        try await coordinator.upload(
            request,
            onProgress: { progress in
                let sidecarOffset = (try? UploadResumeRecord.load(from: sidecar))?
                    .nextOffsetBytes
                observedProgress.update {
                    $0.append((progress: progress, sidecarOffset: sidecarOffset))
                }
            }
        )
    }
    #expect(await server.waitForFirstAcknowledgementSent())

    var acknowledgedCheckpoint: UploadResumeRecord?
    for _ in 0..<200 {
        acknowledgedCheckpoint = try UploadResumeRecord.load(from: sidecar)
        if acknowledgedCheckpoint?.nextOffsetBytes == 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let checkpoint = try #require(acknowledgedCheckpoint)
    #expect(checkpoint.transferID == "upload-recovery-transfer")
    #expect(checkpoint.sourcePath == sourceURL.path)
    #expect(checkpoint.nextOffsetBytes == 2)
    #expect(checkpoint.totalSizeBytes == 10)

    server.releaseFirstDisconnect()
    let result = try await upload.value

    #expect(result.attemptCount == 2)
    #expect(result.recovered)
    #expect(result.upload.chunkCount == 4)
    #expect(result.upload.bytesSent == 8)
    #expect(result.upload.finalOffsetBytes == 10)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    #expect(!FileManager.default.fileExists(
        atPath: UploadResumeRecord.sidecarURL(forSource: sourceURL).path
    ))
    #expect(server.waitForCompletion())
    #expect(server.firstAttemptBytes() == Data("abcdefgh".utf8))
    #expect(server.effectiveBytesAfterRollback() == sourceData)
    #expect(server.observedResumeRequest())

    let progress = observedProgress.value()
    #expect(progress.allSatisfy { $0.progress.totalBytes == 10 })
    #expect(progress.map(\.progress.confirmedBytes) ==
        progress.map(\.progress.confirmedBytes).sorted())
    #expect(progress.contains {
        $0.progress.confirmedBytes == 2 && $0.sidecarOffset == 2
    })
    #expect(progress.last?.progress.confirmedBytes == 10)
    #expect(progress.last?.sidecarOffset == nil)
}

@Test func asyncUploadCoordinatorPersistsIdentityBeforeFirstRemoteOpen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-write-ahead-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.bin")
    try Data("write-ahead".utf8).write(to: sourceURL)
    let sidecar = directory.appendingPathComponent("managed-transfer.json")
    let factoryCalls = UploadFactoryCounter()
    let observedRecord = LockedValue<UploadResumeRecord?>(nil)
    let coordinator = AsyncUploadCoordinator(clientFactory: { _ in
        factoryCalls.increment()
        throw FramedTcpClientError.connectionClosed(stage: "unexpected factory call")
    })
    let baseRequest = AsyncUploadCoordinatorRequest(
        sourceURL: sourceURL,
        destinationPath: "dm://app-sandbox/write-ahead.bin",
        freshTransferID: "write-ahead-transfer",
        resumeRecordURL: sidecar
    )
    let request = baseRequest.observingPartialPreparation { identity in
        #expect(identity == AsyncUploadPartialIdentity(
            transferID: "write-ahead-transfer",
            destinationPath: "dm://app-sandbox/write-ahead.bin",
            expectedSizeBytes: 11
        ))
        observedRecord.update { $0 = try? UploadResumeRecord.load(from: sidecar) }
        throw SchedulerTestError.retryable
    }

    var rejectedByObserver = false
    do {
        _ = try await coordinator.upload(request)
    } catch SchedulerTestError.retryable {
        rejectedByObserver = true
    }

    #expect(rejectedByObserver)
    #expect(factoryCalls.value == 0)
    #expect(observedRecord.value()?.transferID == "write-ahead-transfer")
    #expect(observedRecord.value()?.nextOffsetBytes == 0)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
}

@Test func asyncUploadCoordinatorRejectsSameMillisecondReplacementBeforeConnecting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-mutation-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.bin")
    try Data("before".utf8).write(to: sourceURL)
    let source = AsyncUploadFileSource(sourceURL: sourceURL)
    let snapshot = try await source.snapshot()
    await source.close()
    let record = UploadResumeRecord(
        transferID: "changed-upload",
        sourcePath: sourceURL.path,
        destinationPath: "dm://app-sandbox/changed.bin",
        sourceIdentity: UploadSourceIdentityRecord(snapshot),
        nextOffsetBytes: 2
    )
    try record.save(to: UploadResumeRecord.sidecarURL(forSource: sourceURL))
    let replacementURL = directory.appendingPathComponent("replacement.bin")
    try Data("after!".utf8).write(to: replacementURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(
            timeIntervalSince1970: Double(snapshot.modifiedUnixMillis) / 1_000
        )],
        ofItemAtPath: replacementURL.path
    )
    _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: replacementURL)
    let replacedSource = AsyncUploadFileSource(sourceURL: sourceURL)
    let replacementSnapshot = try await replacedSource.snapshot()
    await replacedSource.close()
    #expect(replacementSnapshot.sizeBytes == snapshot.sizeBytes)
    #expect(replacementSnapshot.modifiedUnixMillis == snapshot.modifiedUnixMillis)
    #expect(
        replacementSnapshot.fileSystemNumber != snapshot.fileSystemNumber
            || replacementSnapshot.fileNumber != snapshot.fileNumber
    )

    let factoryCalls = UploadFactoryCounter()
    let coordinator = AsyncUploadCoordinator(clientFactory: { _ in
        factoryCalls.increment()
        throw FramedTcpClientError.connectionClosed(stage: "unexpected factory call")
    })
    do {
        _ = try await coordinator.upload(AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: "dm://app-sandbox/changed.bin",
            resume: true
        ))
        Issue.record("expected changed upload source metadata to reject resume")
    } catch let error as AsyncUploadCoordinatorError {
        guard case .sourceMetadataChanged = error else {
            Issue.record("unexpected coordinator error: \(error)")
            return
        }
    }
    #expect(factoryCalls.value == 0)
}

@Test func asyncUploadCoordinatorRejectsLegacyNonzeroResumeBeforeConnecting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-legacy-resume-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.bin")
    try Data("abcdef".utf8).write(to: sourceURL)
    let source = AsyncUploadFileSource(sourceURL: sourceURL)
    let snapshot = try await source.snapshot()
    await source.close()
    let sidecar = UploadResumeRecord.sidecarURL(forSource: sourceURL)
    let legacyJSON: [String: Any] = [
        "transferID": "legacy-upload",
        "sourcePath": sourceURL.path,
        "destinationPath": "dm://app-sandbox/legacy.bin",
        "totalSizeBytes": snapshot.sizeBytes,
        "sourceModifiedUnixMillis": snapshot.modifiedUnixMillis,
        "nextOffsetBytes": 2
    ]
    try JSONSerialization.data(withJSONObject: legacyJSON).write(to: sidecar)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: sidecar.path
    )
    #expect(try UploadResumeRecord.load(from: sidecar)?.formatVersion == 1)

    let factoryCalls = UploadFactoryCounter()
    let coordinator = AsyncUploadCoordinator(clientFactory: { _ in
        factoryCalls.increment()
        throw FramedTcpClientError.connectionClosed(stage: "unexpected factory call")
    })
    do {
        _ = try await coordinator.upload(AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: "dm://app-sandbox/legacy.bin",
            resume: true
        ))
        Issue.record("expected a weak nonzero resume checkpoint to fail closed")
    } catch let error as AsyncUploadCoordinatorError {
        #expect(error == .weakResumeSourceIdentity)
        #expect(!error.description.contains(directory.path))
    }
    #expect(factoryCalls.value == 0)
}

@Test func asyncUploadCoordinatorFreshUploadPreservesUnsafeSidecarBeforeConnecting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-unsafe-sidecar-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.bin")
    try Data("source".utf8).write(to: sourceURL)
    let sidecar = UploadResumeRecord.sidecarURL(forSource: sourceURL)
    try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
    let sentinel = sidecar.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)

    let factoryCalls = UploadFactoryCounter()
    let coordinator = AsyncUploadCoordinator(clientFactory: { _ in
        factoryCalls.increment()
        throw FramedTcpClientError.connectionClosed(stage: "unexpected factory call")
    })
    do {
        _ = try await coordinator.upload(AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: "dm://app-sandbox/fresh.bin"
        ))
        Issue.record("expected unsafe upload sidecar cleanup to fail closed")
    } catch {
        #expect(error as? TransferResumeRecordError == .unsafeArtifact)
    }
    #expect(factoryCalls.value == 0)
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
}

@Test func asyncUploadCoordinatorCancellationKeepsLastAcknowledgedCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-cancel-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.bin")
    try Data("abcdefghij".utf8).write(to: sourceURL)
    let sidecar = UploadResumeRecord.sidecarURL(forSource: sourceURL)

    let server = try UploadRecoveryTestServer(
        sourcePath: TransferWireMetadata.localUploadSource,
        destinationPath: "dm://app-sandbox/cancelled-upload.bin"
    )
    defer { server.cancel() }
    let coordinator = AsyncUploadCoordinator(
        clientFactory: { _ in
            let session = try await AsyncFramedTcpSession.connect(
                port: server.port,
                timeoutSeconds: 2
            )
            return AsyncRpcControlClient(
                session: session,
                requestedCapabilities: [.fileWrite, .resumableTransfer],
                requestTimeoutSeconds: 2
            )
        },
        sleeper: { _ in try Task.checkCancellation() }
    )
    let upload = Task {
        try await coordinator.upload(AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: "dm://app-sandbox/cancelled-upload.bin",
            freshTransferID: "upload-recovery-transfer",
            preferredChunkSizeBytes: 2,
            recoveryPolicy: RecoveryPolicy(
                maxAttempts: 1,
                baseDelayMs: 0,
                maxDelayMs: 0,
                jitterFactor: 0
            )
        ))
    }
    #expect(await server.waitForFirstAcknowledgementSent())

    var checkpoint: UploadResumeRecord?
    for _ in 0..<200 {
        checkpoint = try UploadResumeRecord.load(from: sidecar)
        if checkpoint?.nextOffsetBytes == 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(checkpoint?.nextOffsetBytes == 2)

    upload.cancel()
    var observedCancellation = false
    do {
        _ = try await upload.value
    } catch is CancellationError {
        observedCancellation = true
    }
    server.releaseFirstDisconnect()

    #expect(observedCancellation)
    #expect(try UploadResumeRecord.load(from: sidecar)?.nextOffsetBytes == 2)
    #expect(!server.observedResumeRequest())
}
