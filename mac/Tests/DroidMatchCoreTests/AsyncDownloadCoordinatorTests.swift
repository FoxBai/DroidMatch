import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func asyncDownloadCoordinatorReconnectsAndResumesFromDurableCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-download-recovery-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let destination = directory.appendingPathComponent("recovered.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    let sidecar = DownloadResumeRecord.sidecarURL(forDestination: destination)
    try Data("old-destination".utf8).write(to: destination)

    let server = try DownloadRecoveryTestServer()
    defer { server.cancel() }
    let coordinator = AsyncDownloadCoordinator(
        clientFactory: { _ in
            let session = try await AsyncFramedTcpSession.connect(
                port: server.port,
                timeoutSeconds: 2
            )
            return AsyncRpcControlClient(
                session: session,
                requestedCapabilities: [.fileRead, .resumableTransfer],
                requestTimeoutSeconds: 2
            )
        },
        sleeper: { _ in try Task.checkCancellation() }
    )
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/recovered.bin",
        destinationURL: destination,
        freshTransferID: "recovery-transfer",
        preferredChunkSizeBytes: 5,
        recoveryPolicy: RecoveryPolicy(
            maxAttempts: 1,
            baseDelayMs: 0,
            maxDelayMs: 0,
            jitterFactor: 0
        )
    )
    let observedProgress = LockedValue<[
        (progress: AsyncTransferProgress, partialSize: Int64?, sidecarExists: Bool)
    ]>([])

    let download = Task {
        try await coordinator.download(
            request,
            onProgress: { progress in
                let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path)
                let partialSize = (attributes?[.size] as? NSNumber)?.int64Value
                observedProgress.update {
                    $0.append((
                        progress: progress,
                        partialSize: partialSize,
                        sidecarExists: FileManager.default.fileExists(atPath: sidecar.path)
                    ))
                }
            }
        )
    }
    #expect(await server.waitForFirstAcknowledgement())
    #expect(try Data(contentsOf: destination) == Data("old-destination".utf8))
    #expect(try Data(contentsOf: partial) == Data("re".utf8))
    let loadedCheckpoint = try DownloadResumeRecord.load(from: sidecar)
    let checkpoint = try #require(loadedCheckpoint)
    #expect(checkpoint.transferID == "recovery-transfer")
    #expect(checkpoint.sourcePath == "dm://app-sandbox/recovered.bin")
    #expect(checkpoint.totalSizeBytes == 7)
    #expect(checkpoint.fingerprint == TransferFingerprintRecord(server.fingerprint))

    server.releaseFirstDisconnect()
    let result = try await download.value

    #expect(result.attemptCount == 2)
    #expect(result.recovered)
    #expect(result.download.bytesReceived == 5)
    #expect(result.download.finalOffsetBytes == 7)
    #expect(try Data(contentsOf: destination) == Data("recover".utf8))
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    #expect(server.waitForCompletion())
    #expect(server.observedResumeRequest())

    let progress = observedProgress.value()
    #expect(progress.allSatisfy { $0.progress.totalBytes == 7 })
    #expect(progress.map(\.progress.confirmedBytes) ==
        progress.map(\.progress.confirmedBytes).sorted())
    #expect(progress.contains {
        $0.progress.confirmedBytes == 2
            && $0.partialSize == 2
            && $0.sidecarExists
    })
    #expect(progress.last?.progress.confirmedBytes == 7)
    #expect(progress.last?.partialSize == nil)
    #expect(progress.last?.sidecarExists == false)
}

@Test func asyncDownloadCoordinatorRequiresSidecarForExplicitResume() async throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
        "missing-download-sidecar-\(UUID().uuidString).bin"
    )
    let factoryCalls = LockedCounter()
    let coordinator = AsyncDownloadCoordinator(clientFactory: { _ in
        factoryCalls.increment()
        throw FramedTcpClientError.connectionClosed(stage: "unexpected factory call")
    })

    do {
        _ = try await coordinator.download(AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/missing.bin",
            destinationURL: destination,
            resume: true
        ))
        Issue.record("expected explicit resume without a sidecar to fail")
    } catch let error as AsyncDownloadCoordinatorError {
        guard case .missingResumeRecord = error else {
            Issue.record("unexpected coordinator error: \(error)")
            return
        }
    }
    #expect(factoryCalls.value == 0)
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class DownloadRecoveryTestServer: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let firstDisconnectRelease = DispatchSemaphore(value: 0)
        private let completion = DispatchSemaphore(value: 0)
        private var connectionCount = 0
        private var firstAcknowledged = false
        private var resumeRequestObserved = false
        private var finished = false
        private var successful = false

        func nextAttemptIndex() -> Int {
            lock.withLock {
                defer { connectionCount += 1 }
                return connectionCount
            }
        }

        func markFirstAcknowledged() {
            lock.withLock { firstAcknowledged = true }
        }

        func didAcknowledgeFirst() -> Bool {
            lock.withLock { firstAcknowledged }
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
    private let queue = DispatchQueue(label: "app.droidmatch.tests.download-recovery")
    private let state = State()
    let port: Int
    let fingerprint: Droidmatch_V1_TransferFingerprint

    init() throws {
        var fingerprint = Droidmatch_V1_TransferFingerprint()
        fingerprint.sizeBytes = 7
        fingerprint.modifiedUnixMillis = 1_725_000_000_000
        fingerprint.providerEtag = "recovery-etag"
        fingerprint.sha256 = "recovery-sha256"
        self.fingerprint = fingerprint

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
        listener.newConnectionHandler = { [queue, state, fingerprint] connection in
            let attemptIndex = state.nextAttemptIndex()
            connection.start(queue: queue)
            Self.receiveHandshake(
                on: connection,
                attemptIndex: attemptIndex,
                fingerprint: fingerprint,
                state: state
            )
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success,
              let rawPort = listener.port?.rawValue else {
            throw DownloadRecoveryTestServerError.listenerDidNotBecomeReady
        }
        port = Int(rawPort)
    }

    func cancel() {
        state.releaseFirstDisconnect()
        listener.cancel()
    }

    func waitForFirstAcknowledgement() async -> Bool {
        for _ in 0..<200 {
            if state.didAcknowledgeFirst() { return true }
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

    func observedResumeRequest() -> Bool {
        state.didObserveResumeRequest()
    }

    private static func receiveHandshake(
        on connection: NWConnection,
        attemptIndex: Int,
        fingerprint: Droidmatch_V1_TransferFingerprint,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request, envelope.payloadType == .clientHello else {
                throw DownloadRecoveryTestServerError.unexpectedFrame
            }
            let hello = try Droidmatch_V1_ClientHello(serializedBytes: envelope.payload)
            var response = Droidmatch_V1_ServerHello()
            response.serverName = "DownloadRecoveryTestServer"
            response.serverVersion = "test"
            response.protocolMajor = 1
            response.protocolMinor = 0
            response.transport = .adb
            response.sessionNonce = hello.sessionNonce
            response.authenticationState = .correlated
            response.grantedCapabilities = [.fileRead, .resumableTransfer]
            try send(
                responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .serverHello,
                    payload: response.serializedData()
                ),
                on: connection,
                state: state
            ) {
                receiveOpen(
                    on: connection,
                    attemptIndex: attemptIndex,
                    fingerprint: fingerprint,
                    state: state
                )
            }
        }
    }

    private static func receiveOpen(
        on connection: NWConnection,
        attemptIndex: Int,
        fingerprint: Droidmatch_V1_TransferFingerprint,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .openTransferRequest else {
                throw DownloadRecoveryTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_OpenTransferRequest(serializedBytes: envelope.payload)
            let isFresh = attemptIndex == 0
            guard request.direction == .download,
                  request.transferID == "recovery-transfer",
                  request.sourcePath == "dm://app-sandbox/recovered.bin",
                  request.requestedOffsetBytes == (isFresh ? 0 : 2),
                  request.hasSourceFingerprint == !isFresh,
                  isFresh || request.sourceFingerprint == fingerprint else {
                throw DownloadRecoveryTestServerError.unexpectedFrame
            }
            if !isFresh { state.markResumeRequestObserved() }

            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = request.requestedOffsetBytes
            response.chunkSizeBytes = 5
            response.totalSizeBytes = 7
            response.streamID = envelope.requestID
            response.acceptedSourceFingerprint = fingerprint

            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = request.transferID
            chunk.offsetBytes = request.requestedOffsetBytes
            chunk.data = Data((isFresh ? "re" : "cover").utf8)
            chunk.crc32 = Crc32.checksum(chunk.data)
            chunk.finalChunk = !isFresh
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
                receiveAcknowledgement(
                    on: connection,
                    attemptIndex: attemptIndex,
                    requestID: envelope.requestID,
                    state: state
                )
            }
        }
    }

    private static func receiveAcknowledgement(
        on connection: NWConnection,
        attemptIndex: Int,
        requestID: UInt64,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let acknowledgement = try Droidmatch_V1_TransferChunkAck(
                serializedBytes: envelope.payload
            )
            let isFresh = attemptIndex == 0
            guard envelope.kind == .stream,
                  envelope.payloadType == .transferChunkAck,
                  envelope.requestID == requestID,
                  envelope.streamID == requestID,
                  acknowledgement.transferID == "recovery-transfer",
                  acknowledgement.nextOffsetBytes == (isFresh ? 2 : 7),
                  acknowledgement.finalAck == !isFresh else {
                throw DownloadRecoveryTestServerError.unexpectedFrame
            }
            if isFresh {
                state.markFirstAcknowledged()
                state.waitForFirstDisconnectRelease()
                connection.cancel()
            } else {
                state.finish(success: true)
                connection.cancel()
            }
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
                state.finish(success: false)
                connection.cancel()
            }
        }
    }

    private static func send(
        _ envelope: Droidmatch_V1_RpcEnvelope,
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable () -> Void
    ) throws {
        try send([envelope], on: connection, state: state, completion: completion)
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

private enum DownloadRecoveryTestServerError: Error {
    case listenerDidNotBecomeReady
    case unexpectedFrame
}
