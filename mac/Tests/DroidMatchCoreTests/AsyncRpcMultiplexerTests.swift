import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func asyncRpcMultiplexerRoutesWindowedMixedTransfersAndCancellation() async throws {
    let downloadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-async-download-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: downloadDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: downloadDirectory) }
    let downloadDestination = downloadDirectory.appendingPathComponent("mixed-download.bin")
    try Data("old-destination".utf8).write(to: downloadDestination)
    let cancelledDownloadDestination = downloadDirectory.appendingPathComponent(
        "cancelled-download.bin"
    )
    try Data("keep-existing".utf8).write(to: cancelledDownloadDestination)
    let resumeMismatchDestination = downloadDirectory.appendingPathComponent(
        "resume-mismatch.bin"
    )
    try Data("keep-resume-target".utf8).write(to: resumeMismatchDestination)
    let resumeMismatchPartial = AtomicDownloadWriter.partialURL(
        for: resumeMismatchDestination
    )
    try Data("xx".utf8).write(to: resumeMismatchPartial)

    let server = try AsyncMixedTransferTestServer()
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: [
            .fileRead,
            .fileWrite,
            .resumableTransfer,
            .diagnostics,
        ],
        requestTimeoutSeconds: 2
    )

    do {
        _ = try await client.handshake()
        let download = try await client.openDownload(
            sourcePath: "dm://app-sandbox/mixed-download.bin",
            transferID: "mixed-download",
            preferredChunkSizeBytes: 4
        )
        let upload = try await client.openUpload(
            sourcePath: "/tmp/mixed-upload.bin",
            destinationPath: "dm://app-sandbox/mixed-upload.bin",
            transferID: "mixed-upload",
            expectedSizeBytes: 10,
            preferredChunkSizeBytes: 2
        )
        let fileDownload = Task {
            try await download.receive(to: downloadDestination)
        }

        var rejectedThirdStream = false
        do {
            _ = try await client.openDownload(
                sourcePath: "dm://app-sandbox/third.bin",
                transferID: "third-transfer"
            )
        } catch let RpcControlClientError.invalidTransferState(message) {
            rejectedThirdStream = message.contains("at most two")
        }

        #expect(await server.waitForFirstDownloadAcknowledgement())
        #expect(try Data(contentsOf: downloadDestination) == Data("old-destination".utf8))
        #expect(try Data(
            contentsOf: AtomicDownloadWriter.partialURL(for: downloadDestination)
        ) == Data("do".utf8))
        server.releaseDownloadRefill()

        async let heartbeat = client.heartbeat(monotonicMillis: 44_321)
        let firstWindow = [
            AsyncUploadChunk(
                offsetBytes: 0,
                data: Data("up".utf8),
                finalChunk: false
            ),
            AsyncUploadChunk(
                offsetBytes: 2,
                data: Data("lo".utf8),
                finalChunk: false
            ),
            AsyncUploadChunk(
                offsetBytes: 4,
                data: Data("ad".utf8),
                finalChunk: false
            ),
            AsyncUploadChunk(
                offsetBytes: 6,
                data: Data("-w".utf8),
                finalChunk: false
            ),
        ]

        var rejectedFifthInFlightChunk = false
        do {
            _ = try await upload.sendWindow(firstWindow + [AsyncUploadChunk(
                offsetBytes: 8,
                data: Data("in".utf8),
                finalChunk: true
            )])
        } catch let RpcControlClientError.invalidTransferState(message) {
            rejectedFifthInFlightChunk = message.contains("four-chunk")
        }

        let windowUpload = Task {
            try await upload.sendWindow(firstWindow)
        }
        #expect(await server.waitForUploadChunkCount(4))
        server.releaseUploadAcknowledgements()
        let downloadResult = try await fileDownload.value
        let heartbeatResponse = try await heartbeat
        let uploadResponses = try await windowUpload.value
        let finalUploadResponse = try await upload.sendChunk(
            offsetBytes: 8,
            data: Data("in".utf8),
            finalChunk: true
        )

        #expect(rejectedThirdStream)
        #expect(download.openResponse.streamID != upload.openResponse.streamID)
        #expect(downloadResult.chunkCount == 3)
        #expect(downloadResult.bytesReceived == 6)
        #expect(downloadResult.finalOffsetBytes == 6)
        #expect(try Data(contentsOf: downloadDestination) == Data("down!!".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: AtomicDownloadWriter.partialURL(for: downloadDestination).path
        ))
        #expect(rejectedFifthInFlightChunk)
        #expect(uploadResponses.map(\.nextOffsetBytes) == [2, 4, 6, 8])
        #expect(uploadResponses.allSatisfy { !$0.finalAck })
        #expect(finalUploadResponse.nextOffsetBytes == 10)
        #expect(finalUploadResponse.finalAck)
        #expect(heartbeatResponse.monotonicMillis == 44_321)

        let cancellationUpload = try await client.openUpload(
            sourcePath: "/tmp/cancel-upload.bin",
            destinationPath: "dm://app-sandbox/cancel-upload.bin",
            transferID: "cancel-upload",
            expectedSizeBytes: 2,
            preferredChunkSizeBytes: 2
        )
        var rejectedEmptyFinalBehindOutstandingData = false
        do {
            _ = try await cancellationUpload.sendWindow([
                AsyncUploadChunk(
                    offsetBytes: 0,
                    data: Data("no".utf8),
                    finalChunk: false
                ),
                AsyncUploadChunk(
                    offsetBytes: 2,
                    data: Data(),
                    finalChunk: true
                ),
            ])
        } catch let RpcControlClientError.invalidTransferState(message) {
            rejectedEmptyFinalBehindOutstandingData = message.contains("empty final")
        }
        let pendingCancelledSend = Task {
            try await cancellationUpload.sendChunk(
                offsetBytes: 0,
                data: Data("no".utf8),
                finalChunk: true
            )
        }
        #expect(await server.waitForCancellationUploadChunk())
        try await cancellationUpload.cancel(reason: "test-cancel-window")
        var sendObservedCancellation = false
        do {
            _ = try await pendingCancelledSend.value
        } catch is CancellationError {
            sendObservedCancellation = true
        }
        let postCancelHeartbeat = try await client.heartbeat(monotonicMillis: 55_678)

        let cancelledDownload = try await client.openDownload(
            sourcePath: "dm://app-sandbox/cancel-download.bin",
            transferID: "cancel-download",
            preferredChunkSizeBytes: 2
        )
        let pendingCancelledDownload = Task {
            try await cancelledDownload.receive(to: cancelledDownloadDestination)
        }
        #expect(await server.waitForCancellationDownloadAcknowledgement())
        try await cancelledDownload.cancel(reason: "test-cancel-download-file")
        var downloadObservedCancellation = false
        do {
            _ = try await pendingCancelledDownload.value
        } catch is CancellationError {
            downloadObservedCancellation = true
        }
        let finalHeartbeat = try await client.heartbeat(monotonicMillis: 66_789)

        let resumeMismatchDownload = try await client.openDownload(
            sourcePath: "dm://app-sandbox/resume-mismatch.bin",
            transferID: "resume-mismatch",
            requestedOffsetBytes: 0,
            preferredChunkSizeBytes: 2
        )
        let resumeMismatchProgress = LockedValue<[AsyncTransferProgress]>([])
        var rejectedChangedResumeBoundary = false
        do {
            _ = try await resumeMismatchDownload.receive(
                to: resumeMismatchDestination,
                resume: true,
                onProgress: { progress in
                    resumeMismatchProgress.update { $0.append(progress) }
                }
            )
        } catch let error as AsyncDownloadFileError {
            rejectedChangedResumeBoundary = error == .acceptedOffsetMismatch(
                local: 2,
                remote: 0
            )
        }
        var rejectedBufferedChunkAfterCancellation = false
        do {
            _ = try await resumeMismatchDownload.nextChunk()
        } catch is CancellationError {
            rejectedBufferedChunkAfterCancellation = true
        }
        let resumeFailureHeartbeat = try await client.heartbeat(monotonicMillis: 77_890)

        #expect(rejectedEmptyFinalBehindOutstandingData)
        #expect(sendObservedCancellation)
        #expect(postCancelHeartbeat.monotonicMillis == 55_678)
        #expect(downloadObservedCancellation)
        #expect(try Data(contentsOf: cancelledDownloadDestination) == Data("keep-existing".utf8))
        #expect(try Data(
            contentsOf: AtomicDownloadWriter.partialURL(for: cancelledDownloadDestination)
        ) == Data("ke".utf8))
        #expect(finalHeartbeat.monotonicMillis == 66_789)
        #expect(rejectedChangedResumeBoundary)
        #expect(resumeMismatchProgress.value().isEmpty)
        #expect(rejectedBufferedChunkAfterCancellation)
        #expect(try Data(contentsOf: resumeMismatchDestination)
            == Data("keep-resume-target".utf8))
        #expect(try Data(contentsOf: resumeMismatchPartial) == Data("xx".utf8))
        #expect(resumeFailureHeartbeat.monotonicMillis == 77_890)
        #expect(server.waitForCompletion())
        #expect(server.uploadedData() == Data("upload-win".utf8))
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}
@Test func asyncMixedTransferSmokeCompletesTwoStreamsAndHeartbeat() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-mixed-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let uploadSource = directory.appendingPathComponent("mixed-upload-source.bin")
    try Data("upload-win".utf8).write(to: uploadSource)
    let downloadDestination = directory.appendingPathComponent("mixed-download.bin")
    try Data("old-destination".utf8).write(to: downloadDestination)

    let server = try AsyncMixedTransferTestServer()
    defer { server.cancel() }
    let smoke = Task {
        try await AsyncMixedTransferSmokeClient().run(
            port: server.port,
            timeoutSeconds: 2,
            request: AsyncMixedTransferSmokeRequest(
                downloadSourcePath: "dm://app-sandbox/mixed-download.bin",
                downloadDestinationURL: downloadDestination,
                uploadSourceURL: uploadSource,
                uploadDestinationPath: "dm://app-sandbox/mixed-upload.bin",
                downloadTransferID: "mixed-download",
                uploadTransferID: "mixed-upload",
                preferredChunkSizeBytes: 4,
                heartbeatMonotonicMillis: 44_321
            )
        )
    }
    // This server also drives lower-level barrier tests. Releasing both gates
    // up front lets the product smoke choose any valid cross-stream frame order.
    server.releaseDownloadRefill()
    server.releaseUploadAcknowledgements()
    let result = try await smoke.value

    #expect(result.handshake.serverName == "AsyncMixedTransferTestServer")
    #expect(result.download.openResponse.streamID != result.upload.openResponse.streamID)
    #expect(result.download.chunkCount == 3)
    #expect(result.download.bytesReceived == 6)
    #expect(result.download.finalOffsetBytes == 6)
    #expect(result.upload.chunkCount == 5)
    #expect(result.upload.bytesSent == 10)
    #expect(result.upload.finalOffsetBytes == 10)
    #expect(result.heartbeatMonotonicMillis == 44_321)
    #expect(result.elapsedMilliseconds > 0)
    #expect(try Data(contentsOf: downloadDestination) == Data("down!!".utf8))
    #expect(server.uploadedData() == Data("upload-win".utf8))
    #expect(server.uploadSourcePath() == TransferWireMetadata.localUploadSource)
}

@Test func asyncMixedTransferSmokeRejectsDuplicateIdentityBeforeConnecting() async throws {
    do {
        _ = try await AsyncMixedTransferSmokeClient().run(
            port: -1,
            request: AsyncMixedTransferSmokeRequest(
                downloadSourcePath: "dm://app-sandbox/download.bin",
                downloadDestinationURL: URL(fileURLWithPath: "/tmp/download.bin"),
                uploadSourceURL: URL(fileURLWithPath: "/tmp/upload.bin"),
                uploadDestinationPath: "dm://app-sandbox/upload.bin",
                downloadTransferID: "duplicate",
                uploadTransferID: "duplicate"
            )
        )
        Issue.record("expected duplicate mixed transfer identity to fail")
    } catch let error as AsyncMixedTransferSmokeError {
        #expect(error == .duplicateTransferID("duplicate"))
    }
}
