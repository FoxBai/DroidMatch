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

@Test func asyncUploadCoordinatorRejectsChangedResumeSourceBeforeConnecting() async throws {
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
        totalSizeBytes: snapshot.sizeBytes,
        sourceModifiedUnixMillis: snapshot.modifiedUnixMillis,
        nextOffsetBytes: 2
    )
    try record.save(to: UploadResumeRecord.sidecarURL(forSource: sourceURL))
    try Data("after-is-larger".utf8).write(to: sourceURL)

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
