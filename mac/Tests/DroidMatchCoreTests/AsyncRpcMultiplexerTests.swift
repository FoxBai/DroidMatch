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

private final class AsyncMixedTransferTestServer: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let completion = DispatchSemaphore(value: 0)
        private let uploadAcknowledgementRelease = DispatchSemaphore(value: 0)
        private let downloadRefillRelease = DispatchSemaphore(value: 0)
        private var finished = false
        private var successful = false
        private var uploadBytes = Data()
        private var openedUploadSourcePath = ""
        private var uploadChunkCount = 0
        private var cancellationUploadChunkReceived = false
        private var firstDownloadAcknowledgementReceived = false
        private var cancellationDownloadAcknowledgementReceived = false

        var downloadRequestID: UInt64 = 0
        var uploadRequestID: UInt64 = 0
        var cancellationUploadRequestID: UInt64 = 0
        var cancellationDownloadRequestID: UInt64 = 0
        var downloadAcknowledgementCount = 0

        func appendUpload(_ data: Data) -> Int {
            lock.lock()
            let index = uploadChunkCount
            uploadChunkCount += 1
            uploadBytes.append(data)
            lock.unlock()
            return index
        }

        func setUploadSourcePath(_ value: String) {
            lock.lock()
            openedUploadSourcePath = value
            lock.unlock()
        }

        func uploadSourcePath() -> String {
            lock.lock()
            defer { lock.unlock() }
            return openedUploadSourcePath
        }

        func currentUploadChunkCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return uploadChunkCount
        }

        func markCancellationUploadChunkReceived() {
            lock.lock()
            cancellationUploadChunkReceived = true
            lock.unlock()
        }

        func didReceiveCancellationUploadChunk() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationUploadChunkReceived
        }

        func markFirstDownloadAcknowledgementReceived() {
            lock.lock()
            firstDownloadAcknowledgementReceived = true
            lock.unlock()
        }

        func didReceiveFirstDownloadAcknowledgement() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstDownloadAcknowledgementReceived
        }

        func waitForDownloadRefillRelease() {
            downloadRefillRelease.wait()
        }

        func releaseDownloadRefill() {
            downloadRefillRelease.signal()
        }

        func markCancellationDownloadAcknowledgementReceived() {
            lock.lock()
            cancellationDownloadAcknowledgementReceived = true
            lock.unlock()
        }

        func didReceiveCancellationDownloadAcknowledgement() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationDownloadAcknowledgementReceived
        }

        func waitForUploadAcknowledgementRelease() {
            uploadAcknowledgementRelease.wait()
        }

        func releaseUploadAcknowledgements() {
            uploadAcknowledgementRelease.signal()
        }

        func uploadData() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return uploadBytes
        }

        func finish(success: Bool) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            successful = success
            lock.unlock()
            completion.signal()
        }

        func wait() -> Bool {
            guard completion.wait(timeout: .now() + 2) == .success else {
                return false
            }
            lock.lock()
            defer { lock.unlock() }
            return successful
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.droidmatch.tests.async-mixed-transfer")
    private let state = State()
    let port: Int

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { status in
            switch status {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue, state] connection in
            connection.start(queue: queue)
            Self.receiveHandshake(on: connection, state: state)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success,
              let rawPort = listener.port?.rawValue else {
            throw AsyncMixedTransferTestServerError.listenerDidNotBecomeReady
        }
        port = Int(rawPort)
    }

    func cancel() {
        state.releaseUploadAcknowledgements()
        state.releaseDownloadRefill()
        listener.cancel()
    }

    func waitForCompletion() -> Bool {
        state.wait()
    }

    func uploadedData() -> Data {
        state.uploadData()
    }

    func uploadSourcePath() -> String {
        state.uploadSourcePath()
    }

    func waitForUploadChunkCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<200 {
            if state.currentUploadChunkCount() >= expectedCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitForCancellationUploadChunk() async -> Bool {
        for _ in 0..<200 {
            if state.didReceiveCancellationUploadChunk() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitForFirstDownloadAcknowledgement() async -> Bool {
        for _ in 0..<200 {
            if state.didReceiveFirstDownloadAcknowledgement() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func releaseDownloadRefill() {
        state.releaseDownloadRefill()
    }

    func waitForCancellationDownloadAcknowledgement() async -> Bool {
        for _ in 0..<200 {
            if state.didReceiveCancellationDownloadAcknowledgement() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func releaseUploadAcknowledgements() {
        state.releaseUploadAcknowledgements()
    }

    private static func receiveHandshake(on connection: NWConnection, state: State) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request, envelope.payloadType == .clientHello else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let hello = try Droidmatch_V1_ClientHello(serializedBytes: envelope.payload)
            var response = Droidmatch_V1_ServerHello()
            response.serverName = "AsyncMixedTransferTestServer"
            response.serverVersion = "test"
            response.protocolMajor = 1
            response.protocolMinor = 0
            response.transport = .adb
            response.sessionNonce = hello.sessionNonce
            response.authenticationState = .correlated
            response.grantedCapabilities = [
                .fileRead,
                .fileWrite,
                .resumableTransfer,
                .diagnostics,
            ]
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .serverHello,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveDownloadOpen(on: connection, state: state)
            }
        }
    }

    private static func receiveDownloadOpen(on connection: NWConnection, state: State) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .download)
            guard request.transferID == "mixed-download" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.downloadRequestID = envelope.requestID
            let streamID = envelope.requestID
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 6
            response.streamID = streamID
            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = request.transferID
            chunk.offsetBytes = 0
            chunk.data = Data("do".utf8)
            chunk.crc32 = Crc32.checksum(chunk.data)
            chunk.finalChunk = false
            try send(
                [
                    responseEnvelope(
                        requestID: envelope.requestID,
                        payloadType: .openTransferResponse,
                        payload: response.serializedData()
                    ),
                    streamEnvelope(
                        requestID: envelope.requestID,
                        streamID: streamID,
                        payloadType: .transferChunk,
                        payload: chunk.serializedData()
                    ),
                ],
                on: connection,
                state: state
            ) {
                receiveUploadOpen(on: connection, state: state)
            }
        }
    }

    private static func receiveUploadOpen(on connection: NWConnection, state: State) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .upload)
            guard request.transferID == "mixed-upload" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.setUploadSourcePath(request.sourcePath)
            state.uploadRequestID = envelope.requestID
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 10
            response.streamID = envelope.requestID
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .openTransferResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveMixedFrames(remaining: 9, on: connection, state: state)
            }
        }
    }

    private static func receiveMixedFrames(
        remaining: Int,
        on connection: NWConnection,
        state: State
    ) {
        guard remaining > 0 else {
            receiveCancellationUploadOpen(on: connection, state: state)
            return
        }
        receiveEnvelope(on: connection, state: state) { envelope in
            switch envelope.payloadType {
            case .heartbeatRequest:
                let request = try Droidmatch_V1_HeartbeatRequest(serializedBytes: envelope.payload)
                var response = Droidmatch_V1_HeartbeatResponse()
                response.monotonicMillis = request.monotonicMillis
                try send(
                    [responseEnvelope(
                        requestID: envelope.requestID,
                        payloadType: .heartbeatResponse,
                        payload: response.serializedData()
                    )],
                    on: connection,
                    state: state
                ) {
                    receiveMixedFrames(
                        remaining: remaining - 1,
                        on: connection,
                        state: state
                    )
                }
            case .transferChunk:
                guard envelope.kind == .stream,
                      envelope.requestID == state.uploadRequestID,
                      envelope.streamID == state.uploadRequestID else {
                    throw AsyncMixedTransferTestServerError.unexpectedFrame
                }
                let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: envelope.payload)
                let uploadIndex = state.appendUpload(chunk.data)
                let expectedOffsets: [Int64] = [0, 2, 4, 6, 8]
                guard chunk.transferID == "mixed-upload",
                      uploadIndex < expectedOffsets.count,
                      chunk.offsetBytes == expectedOffsets[uploadIndex],
                      chunk.finalChunk == (uploadIndex == 4),
                      chunk.data.count == 2,
                      chunk.crc32 == Crc32.checksum(chunk.data) else {
                    throw AsyncMixedTransferTestServerError.unexpectedFrame
                }
                // Deliberately withhold ACKs until the four-chunk window is full.
                // The test attempts and rejects a fifth in-flight chunk before
                // releasing this server-side barrier.
                if uploadIndex < 3 {
                    receiveMixedFrames(
                        remaining: remaining - 1,
                        on: connection,
                        state: state
                    )
                    return
                }
                if uploadIndex == 4 {
                    var acknowledgement = Droidmatch_V1_TransferChunkAck()
                    acknowledgement.transferID = chunk.transferID
                    acknowledgement.nextOffsetBytes = 10
                    acknowledgement.finalAck = true
                    try send(
                        [streamEnvelope(
                            requestID: envelope.requestID,
                            streamID: envelope.streamID,
                            payloadType: .transferChunkAck,
                            payload: acknowledgement.serializedData()
                        )],
                        on: connection,
                        state: state
                    ) {
                        receiveMixedFrames(
                            remaining: remaining - 1,
                            on: connection,
                            state: state
                        )
                    }
                    return
                }
                state.waitForUploadAcknowledgementRelease()
                let acknowledgements = try [0, 1, 2, 3].map { index in
                    var acknowledgement = Droidmatch_V1_TransferChunkAck()
                    acknowledgement.transferID = chunk.transferID
                    acknowledgement.nextOffsetBytes = Int64((index + 1) * 2)
                    acknowledgement.finalAck = false
                    return try streamEnvelope(
                        requestID: envelope.requestID,
                        streamID: envelope.streamID,
                        payloadType: .transferChunkAck,
                        payload: acknowledgement.serializedData()
                    )
                }
                try send(acknowledgements, on: connection, state: state) {
                    receiveMixedFrames(
                        remaining: remaining - 1,
                        on: connection,
                        state: state
                    )
                }
            case .transferChunkAck:
                guard envelope.kind == .stream,
                      envelope.requestID == state.downloadRequestID,
                      envelope.streamID == state.downloadRequestID else {
                    throw AsyncMixedTransferTestServerError.unexpectedFrame
                }
                let acknowledgement = try Droidmatch_V1_TransferChunkAck(
                    serializedBytes: envelope.payload
                )
                let acknowledgementIndex = state.downloadAcknowledgementCount
                let expectedOffsets: [Int64] = [2, 4, 6]
                guard acknowledgement.transferID == "mixed-download",
                      acknowledgementIndex < expectedOffsets.count,
                      acknowledgement.nextOffsetBytes == expectedOffsets[acknowledgementIndex],
                      acknowledgement.finalAck == (acknowledgementIndex == 2) else {
                    throw AsyncMixedTransferTestServerError.unexpectedFrame
                }
                state.downloadAcknowledgementCount += 1
                if acknowledgementIndex == 0 {
                    state.markFirstDownloadAcknowledgementReceived()
                    state.waitForDownloadRefillRelease()
                    var second = Droidmatch_V1_TransferChunk()
                    second.transferID = "mixed-download"
                    second.offsetBytes = 2
                    second.data = Data("wn".utf8)
                    second.crc32 = Crc32.checksum(second.data)
                    var final = Droidmatch_V1_TransferChunk()
                    final.transferID = "mixed-download"
                    final.offsetBytes = 4
                    final.data = Data("!!".utf8)
                    final.crc32 = Crc32.checksum(final.data)
                    final.finalChunk = true
                    try send(
                        [
                            streamEnvelope(
                                requestID: envelope.requestID,
                                streamID: envelope.streamID,
                                payloadType: .transferChunk,
                                payload: second.serializedData()
                            ),
                            streamEnvelope(
                                requestID: envelope.requestID,
                                streamID: envelope.streamID,
                                payloadType: .transferChunk,
                                payload: final.serializedData()
                            ),
                        ],
                        on: connection,
                        state: state
                    ) {
                        receiveMixedFrames(
                            remaining: remaining - 1,
                            on: connection,
                            state: state
                        )
                    }
                } else {
                    receiveMixedFrames(
                        remaining: remaining - 1,
                        on: connection,
                        state: state
                    )
                }
            default:
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
        }
    }

    private static func receiveCancellationUploadOpen(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .upload)
            guard request.transferID == "cancel-upload" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.cancellationUploadRequestID = envelope.requestID
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 2
            response.streamID = envelope.requestID
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .openTransferResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveCancellationUploadChunk(on: connection, state: state)
            }
        }
    }

    private static func receiveCancellationUploadChunk(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .stream,
                  envelope.requestID == state.cancellationUploadRequestID,
                  envelope.streamID == state.cancellationUploadRequestID,
                  envelope.payloadType == .transferChunk else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: envelope.payload)
            guard chunk.transferID == "cancel-upload",
                  chunk.offsetBytes == 0,
                  chunk.data == Data("no".utf8),
                  chunk.finalChunk,
                  chunk.crc32 == Crc32.checksum(chunk.data) else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.markCancellationUploadChunkReceived()
            receiveCancellationRequest(on: connection, state: state)
        }
    }

    private static func receiveCancellationRequest(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .cancelTransferRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_CancelTransferRequest(
                serializedBytes: envelope.payload
            )
            guard request.transferID == "cancel-upload",
                  request.reason == "test-cancel-window" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            var response = Droidmatch_V1_CancelTransferResponse()
            response.transferID = request.transferID
            response.ok = true
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .cancelTransferResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receivePostCancellationHeartbeat(on: connection, state: state)
            }
        }
    }

    private static func receivePostCancellationHeartbeat(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .heartbeatRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_HeartbeatRequest(serializedBytes: envelope.payload)
            var response = Droidmatch_V1_HeartbeatResponse()
            response.monotonicMillis = request.monotonicMillis
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .heartbeatResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveCancellationDownloadOpen(on: connection, state: state)
            }
        }
    }

    private static func receiveCancellationDownloadOpen(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .download)
            guard request.transferID == "cancel-download" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.cancellationDownloadRequestID = envelope.requestID
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 4
            response.streamID = envelope.requestID
            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = request.transferID
            chunk.offsetBytes = 0
            chunk.data = Data("ke".utf8)
            chunk.crc32 = Crc32.checksum(chunk.data)
            try send(
                [
                    responseEnvelope(
                        requestID: envelope.requestID,
                        payloadType: .openTransferResponse,
                        payload: response.serializedData()
                    ),
                    streamEnvelope(
                        requestID: envelope.requestID,
                        streamID: envelope.requestID,
                        payloadType: .transferChunk,
                        payload: chunk.serializedData()
                    ),
                ],
                on: connection,
                state: state
            ) {
                receiveCancellationDownloadAcknowledgement(on: connection, state: state)
            }
        }
    }

    private static func receiveCancellationDownloadAcknowledgement(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .stream,
                  envelope.requestID == state.cancellationDownloadRequestID,
                  envelope.streamID == state.cancellationDownloadRequestID,
                  envelope.payloadType == .transferChunkAck else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let acknowledgement = try Droidmatch_V1_TransferChunkAck(
                serializedBytes: envelope.payload
            )
            guard acknowledgement.transferID == "cancel-download",
                  acknowledgement.nextOffsetBytes == 2,
                  !acknowledgement.finalAck else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.markCancellationDownloadAcknowledgementReceived()
            receiveCancellationDownloadRequest(on: connection, state: state)
        }
    }

    private static func receiveCancellationDownloadRequest(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .cancelTransferRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_CancelTransferRequest(
                serializedBytes: envelope.payload
            )
            guard request.transferID == "cancel-download",
                  request.reason == "test-cancel-download-file" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            var response = Droidmatch_V1_CancelTransferResponse()
            response.transferID = request.transferID
            response.ok = true
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .cancelTransferResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveFinalHeartbeat(on: connection, state: state)
            }
        }
    }

    private static func receiveFinalHeartbeat(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .heartbeatRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_HeartbeatRequest(serializedBytes: envelope.payload)
            var response = Droidmatch_V1_HeartbeatResponse()
            response.monotonicMillis = request.monotonicMillis
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .heartbeatResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveResumeMismatchDownloadOpen(on: connection, state: state)
            }
        }
    }

    private static func receiveResumeMismatchDownloadOpen(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .download)
            guard request.transferID == "resume-mismatch",
                  request.requestedOffsetBytes == 0 else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 4
            response.streamID = envelope.requestID
            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = request.transferID
            chunk.offsetBytes = 0
            chunk.data = Data("zz".utf8)
            chunk.crc32 = Crc32.checksum(chunk.data)
            try send(
                [
                    responseEnvelope(
                        requestID: envelope.requestID,
                        payloadType: .openTransferResponse,
                        payload: response.serializedData()
                    ),
                    streamEnvelope(
                        requestID: envelope.requestID,
                        streamID: envelope.requestID,
                        payloadType: .transferChunk,
                        payload: chunk.serializedData()
                    ),
                ],
                on: connection,
                state: state
            ) {
                receiveResumeMismatchCancellation(on: connection, state: state)
            }
        }
    }

    private static func receiveResumeMismatchCancellation(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .cancelTransferRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_CancelTransferRequest(
                serializedBytes: envelope.payload
            )
            guard request.transferID == "resume-mismatch",
                  request.reason == "mac-local-download-file-failure" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            var response = Droidmatch_V1_CancelTransferResponse()
            response.transferID = request.transferID
            response.ok = true
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .cancelTransferResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveResumeFailureHeartbeat(on: connection, state: state)
            }
        }
    }

    private static func receiveResumeFailureHeartbeat(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .heartbeatRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_HeartbeatRequest(serializedBytes: envelope.payload)
            var response = Droidmatch_V1_HeartbeatResponse()
            response.monotonicMillis = request.monotonicMillis
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .heartbeatResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                state.finish(success: true)
            }
        }
    }

    private static func openRequest(
        _ envelope: Droidmatch_V1_RpcEnvelope,
        direction: Droidmatch_V1_TransferDirection
    ) throws -> Droidmatch_V1_OpenTransferRequest {
        guard envelope.kind == .request,
              envelope.payloadType == .openTransferRequest else {
            throw AsyncMixedTransferTestServerError.unexpectedFrame
        }
        let request = try Droidmatch_V1_OpenTransferRequest(
            serializedBytes: envelope.payload
        )
        guard request.direction == direction else {
            throw AsyncMixedTransferTestServerError.unexpectedFrame
        }
        return request
    }

    private static func responseEnvelope(
        requestID: UInt64,
        payloadType: Droidmatch_V1_PayloadType,
        payload: Data
    ) -> Droidmatch_V1_RpcEnvelope {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .response
        envelope.requestID = requestID
        envelope.payloadType = payloadType
        envelope.payload = payload
        return envelope
    }

    private static func streamEnvelope(
        requestID: UInt64,
        streamID: UInt64,
        payloadType: Droidmatch_V1_PayloadType,
        payload: Data
    ) -> Droidmatch_V1_RpcEnvelope {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = requestID
        envelope.streamID = streamID
        envelope.payloadType = payloadType
        envelope.payload = payload
        return envelope
    }

    private static func receiveEnvelope(
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable (Droidmatch_V1_RpcEnvelope) throws -> Void
    ) {
        receiveFrameBody(on: connection) { body in
            do {
                try completion(Droidmatch_V1_RpcEnvelope(serializedBytes: body))
            } catch {
                fail(connection, state: state)
            }
        }
    }

    private static func send(
        _ envelopes: [Droidmatch_V1_RpcEnvelope],
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable () -> Void
    ) throws {
        var frames = Data()
        for envelope in envelopes {
            frames.append(try FrameCodec().encode(payload: envelope.serializedData()))
        }
        connection.send(content: frames, completion: .contentProcessed { error in
            guard error == nil else {
                fail(connection, state: state)
                return
            }
            completion()
        })
    }

    private static func receiveFrameBody(
        on connection: NWConnection,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                completion(body)
            }
        }
    }

    private static func fail(_ connection: NWConnection, state: State) {
        state.finish(success: false)
        connection.cancel()
    }
}

private enum AsyncMixedTransferTestServerError: Error {
    case listenerDidNotBecomeReady
    case unexpectedFrame
}
