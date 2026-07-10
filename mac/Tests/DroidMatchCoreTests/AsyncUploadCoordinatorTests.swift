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
    let sidecar = UploadResumeRecord.sidecarURL(forSource: sourceURL)

    let server = try UploadRecoveryTestServer(
        sourcePath: sourceURL.path,
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
        )
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
        sourcePath: sourceURL.path,
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

private final class UploadFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class UploadRecoveryTestServer: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let firstDisconnectRelease = DispatchSemaphore(value: 0)
        private let completion = DispatchSemaphore(value: 0)
        private var connectionCount = 0
        private var firstAcknowledgementSent = false
        private var resumeRequestObserved = false
        private var firstBytes = Data()
        private var resumedBytes = Data()
        private var finished = false
        private var successful = false

        func nextAttemptIndex() -> Int {
            lock.withLock {
                defer { connectionCount += 1 }
                return connectionCount
            }
        }

        func storeBytes(_ data: Data, attemptIndex: Int) {
            lock.withLock {
                if attemptIndex == 0 { firstBytes = data } else { resumedBytes = data }
            }
        }

        func bytesForFirstAttempt() -> Data {
            lock.withLock { firstBytes }
        }

        func effectiveBytes() -> Data {
            lock.withLock { firstBytes.prefix(2) + resumedBytes }
        }

        func markFirstAcknowledgementSent() {
            lock.withLock { firstAcknowledgementSent = true }
        }

        func didSendFirstAcknowledgement() -> Bool {
            lock.withLock { firstAcknowledgementSent }
        }

        func waitForFirstDisconnectRelease() {
            firstDisconnectRelease.wait()
        }

        func releaseFirstDisconnect() {
            firstDisconnectRelease.signal()
        }

        func markResumeRequestObserved() {
            lock.withLock { resumeRequestObserved = true }
        }

        func didObserveResumeRequest() -> Bool {
            lock.withLock { resumeRequestObserved }
        }

        func finish(success: Bool) {
            let shouldSignal = lock.withLock {
                guard !finished else { return false }
                finished = true
                successful = success
                return true
            }
            if shouldSignal { completion.signal() }
        }

        func wait() -> Bool {
            guard completion.wait(timeout: .now() + 3) == .success else { return false }
            return lock.withLock { successful }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.droidmatch.tests.upload-recovery")
    private let state = State()
    let port: Int

    init(sourcePath: String, destinationPath: String) throws {
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
            let attemptIndex = state.nextAttemptIndex()
            connection.start(queue: queue)
            Self.receiveHandshake(
                on: connection,
                attemptIndex: attemptIndex,
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                state: state
            )
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success,
              let rawPort = listener.port?.rawValue else {
            throw UploadRecoveryTestServerError.listenerDidNotBecomeReady
        }
        port = Int(rawPort)
    }

    func cancel() {
        state.releaseFirstDisconnect()
        listener.cancel()
    }

    func waitForFirstAcknowledgementSent() async -> Bool {
        for _ in 0..<200 {
            if state.didSendFirstAcknowledgement() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func releaseFirstDisconnect() {
        state.releaseFirstDisconnect()
    }

    func waitForCompletion() -> Bool {
        state.wait()
    }

    func firstAttemptBytes() -> Data {
        state.bytesForFirstAttempt()
    }

    func effectiveBytesAfterRollback() -> Data {
        state.effectiveBytes()
    }

    func observedResumeRequest() -> Bool {
        state.didObserveResumeRequest()
    }

    private static func receiveHandshake(
        on connection: NWConnection,
        attemptIndex: Int,
        sourcePath: String,
        destinationPath: String,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request, envelope.payloadType == .clientHello else {
                throw UploadRecoveryTestServerError.unexpectedFrame
            }
            let hello = try Droidmatch_V1_ClientHello(serializedBytes: envelope.payload)
            var response = Droidmatch_V1_ServerHello()
            response.serverName = "UploadRecoveryTestServer"
            response.serverVersion = "test"
            response.protocolMajor = 1
            response.protocolMinor = 0
            response.transport = .adb
            response.sessionNonce = hello.sessionNonce
            response.authenticationState = .correlated
            response.grantedCapabilities = [.fileWrite, .resumableTransfer]
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .serverHello,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveOpen(
                    on: connection,
                    attemptIndex: attemptIndex,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    state: state
                )
            }
        }
    }

    private static func receiveOpen(
        on connection: NWConnection,
        attemptIndex: Int,
        sourcePath: String,
        destinationPath: String,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .openTransferRequest else {
                throw UploadRecoveryTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_OpenTransferRequest(serializedBytes: envelope.payload)
            let requestedOffset: Int64 = attemptIndex == 0 ? 0 : 2
            guard request.direction == .upload,
                  request.transferID == "upload-recovery-transfer",
                  request.sourcePath == sourcePath,
                  request.destinationPath == destinationPath,
                  request.expectedSizeBytes == 10,
                  request.requestedOffsetBytes == requestedOffset else {
                throw UploadRecoveryTestServerError.unexpectedFrame
            }
            if attemptIndex == 1 { state.markResumeRequestObserved() }

            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = requestedOffset
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
                receiveChunks(
                    on: connection,
                    attemptIndex: attemptIndex,
                    requestID: envelope.requestID,
                    chunkIndex: 0,
                    bytes: Data(),
                    state: state
                )
            }
        }
    }

    private static func receiveChunks(
        on connection: NWConnection,
        attemptIndex: Int,
        requestID: UInt64,
        chunkIndex: Int,
        bytes: Data,
        state: State
    ) {
        let expectedOffsets: [Int64] = attemptIndex == 0 ? [0, 2, 4, 6] : [2, 4, 6, 8]
        guard chunkIndex < expectedOffsets.count else {
            state.storeBytes(bytes, attemptIndex: attemptIndex)
            if attemptIndex == 0 {
                var acknowledgement = Droidmatch_V1_TransferChunkAck()
                acknowledgement.transferID = "upload-recovery-transfer"
                acknowledgement.nextOffsetBytes = 2
                acknowledgement.finalAck = false
                do {
                    try send(
                        [streamEnvelope(
                            requestID: requestID,
                            streamID: requestID,
                            payloadType: .transferChunkAck,
                            payload: acknowledgement.serializedData()
                        )],
                        on: connection,
                        state: state
                    ) {
                        state.markFirstAcknowledgementSent()
                        state.waitForFirstDisconnectRelease()
                        connection.cancel()
                    }
                } catch {
                    state.finish(success: false)
                    connection.cancel()
                }
                return
            }

            do {
                let acknowledgements = try [4, 6, 8, 10].enumerated().map { index, offset in
                    var acknowledgement = Droidmatch_V1_TransferChunkAck()
                    acknowledgement.transferID = "upload-recovery-transfer"
                    acknowledgement.nextOffsetBytes = Int64(offset)
                    acknowledgement.finalAck = index == 3
                    return try streamEnvelope(
                        requestID: requestID,
                        streamID: requestID,
                        payloadType: .transferChunkAck,
                        payload: acknowledgement.serializedData()
                    )
                }
                try send(acknowledgements, on: connection, state: state) {
                    state.finish(success: true)
                }
            } catch {
                state.finish(success: false)
                connection.cancel()
            }
            return
        }

        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .stream,
                  envelope.payloadType == .transferChunk,
                  envelope.requestID == requestID,
                  envelope.streamID == requestID else {
                throw UploadRecoveryTestServerError.unexpectedFrame
            }
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: envelope.payload)
            guard chunk.transferID == "upload-recovery-transfer",
                  chunk.offsetBytes == expectedOffsets[chunkIndex],
                  chunk.data.count == 2,
                  chunk.data == Data("abcdefghij".utf8)[
                    Int(chunk.offsetBytes)..<Int(chunk.offsetBytes + 2)
                  ],
                  chunk.crc32 == Crc32.checksum(chunk.data),
                  chunk.finalChunk == (attemptIndex == 1 && chunkIndex == 3) else {
                throw UploadRecoveryTestServerError.unexpectedFrame
            }
            var nextBytes = bytes
            nextBytes.append(chunk.data)
            receiveChunks(
                on: connection,
                attemptIndex: attemptIndex,
                requestID: requestID,
                chunkIndex: chunkIndex + 1,
                bytes: nextBytes,
                state: state
            )
        }
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
    ) throws -> Droidmatch_V1_RpcEnvelope {
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
                state.finish(success: false)
                connection.cancel()
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
                state.finish(success: false)
                connection.cancel()
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
}

private enum UploadRecoveryTestServerError: Error {
    case listenerDidNotBecomeReady
    case unexpectedFrame
}
