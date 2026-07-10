import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func dualDownloadSmokeRoutesInterleavedStreamsAndKeepsControlResponsive() async throws {
    let server = try DualDownloadTestServer()
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(session: session, requestTimeoutSeconds: 2)
    let received = LockedValue<[Int: Data]>([:])

    let result = try await AsyncDualDownloadSmokeClient(client: client).run(
        firstSourcePath: "dm://app-sandbox/dual-a.bin",
        secondSourcePath: "dm://app-sandbox/dual-b.bin",
        firstTransferID: "dual-a",
        secondTransferID: "dual-b",
        preferredChunkSizeBytes: 2
    ) { index, chunk in
        received.update { values in
            values[index, default: Data()].append(chunk.data)
        }
    }

    #expect(result.first.openResponse.streamID != result.second.openResponse.streamID)
    #expect(result.first.chunkCount == 3)
    #expect(result.second.chunkCount == 3)
    #expect(result.first.bytesReceived == 6)
    #expect(result.second.bytesReceived == 6)
    #expect(received.value()[0] == Data("aabbcc".utf8))
    #expect(received.value()[1] == Data("112233".utf8))
    #expect(result.heartbeat.monotonicMillis > 0)
    #expect(server.waitForCompletion())
    await client.close()
}

private final class DualDownloadTestServer: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        struct Stream {
            let requestID: UInt64
            let streamID: UInt64
            let transferID: String
            let chunks: [Data]
        }

        private let lock = NSLock()
        private let completion = DispatchSemaphore(value: 0)
        private var finished = false
        private var successful = false

        var first: Stream?
        var second: Stream?

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
    private let queue = DispatchQueue(label: "app.droidmatch.tests.dual-download")
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
            throw DualDownloadTestServerError.listenerDidNotBecomeReady
        }
        port = Int(rawPort)
    }

    func waitForCompletion() -> Bool {
        state.wait()
    }

    func cancel() {
        listener.cancel()
    }

    private static func receiveHandshake(on connection: NWConnection, state: State) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.payloadType == .clientHello else {
                throw DualDownloadTestServerError.unexpectedFrame
            }
            let hello = try Droidmatch_V1_ClientHello(serializedBytes: envelope.payload)
            var response = Droidmatch_V1_ServerHello()
            response.serverName = "DualDownloadTestServer"
            response.serverVersion = "test"
            response.protocolMajor = 1
            response.protocolMinor = 0
            response.transport = .adb
            response.sessionNonce = hello.sessionNonce
            response.authenticationState = .correlated
            response.grantedCapabilities = [.fileRead, .resumableTransfer, .diagnostics]
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .serverHello,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveFirstOpen(on: connection, state: state)
            }
        }
    }

    private static func receiveFirstOpen(on connection: NWConnection, state: State) {
        receiveOpen(on: connection, state: state) { envelope, request in
            let stream = try register(envelope: envelope, request: request, state: state)
            try sendOpenAndInitialChunk(stream, on: connection, state: state) {
                receiveSecondOpen(on: connection, state: state)
            }
        }
    }

    private static func receiveSecondOpen(on connection: NWConnection, state: State) {
        receiveOpen(on: connection, state: state) { envelope, request in
            let stream = try register(envelope: envelope, request: request, state: state)
            try sendOpenAndInitialChunk(stream, on: connection, state: state) {
                // Heartbeat must be the next client frame. If an ACK appears first,
                // the test fails: both streams were not control-responsive together.
                receiveHeartbeat(on: connection, state: state)
            }
        }
    }

    private static func register(
        envelope: Droidmatch_V1_RpcEnvelope,
        request: Droidmatch_V1_OpenTransferRequest,
        state: State
    ) throws -> State.Stream {
        let chunks: [Data]
        switch request.sourcePath {
        case "dm://app-sandbox/dual-a.bin":
            chunks = [Data("aa".utf8), Data("bb".utf8), Data("cc".utf8)]
        case "dm://app-sandbox/dual-b.bin":
            chunks = [Data("11".utf8), Data("22".utf8), Data("33".utf8)]
        default:
            throw DualDownloadTestServerError.unexpectedFrame
        }
        let stream = State.Stream(
            requestID: envelope.requestID,
            streamID: envelope.requestID,
            transferID: request.transferID,
            chunks: chunks
        )
        if request.sourcePath.hasSuffix("dual-a.bin") {
            guard state.first == nil else { throw DualDownloadTestServerError.unexpectedFrame }
            state.first = stream
        } else {
            guard state.second == nil else { throw DualDownloadTestServerError.unexpectedFrame }
            state.second = stream
        }
        return stream
    }

    private static func receiveHeartbeat(on connection: NWConnection, state: State) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.payloadType == .heartbeatRequest else {
                throw DualDownloadTestServerError.unexpectedFrame
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
                receiveInitialAcknowledgement(
                    expected: state.first,
                    then: state.second,
                    on: connection,
                    state: state
                )
            }
        }
    }

    private static func receiveInitialAcknowledgement(
        expected first: State.Stream?,
        then second: State.Stream?,
        on connection: NWConnection,
        state: State
    ) {
        guard let first, let second else {
            fail(connection, state: state)
            return
        }
        receiveAcknowledgement(
            expected: first,
            nextOffset: 2,
            final: false,
            on: connection,
            state: state
        ) {
            receiveAcknowledgement(
                expected: second,
                nextOffset: 2,
                final: false,
                on: connection,
                state: state
            ) {
                do {
                    // Force actual cross-stream routing rather than two sequential
                    // downloads: A2, B2, A3, B3 share one TCP write.
                    try send(
                        [
                            chunkEnvelope(first, index: 1),
                            chunkEnvelope(second, index: 1),
                            chunkEnvelope(first, index: 2),
                            chunkEnvelope(second, index: 2),
                        ],
                        on: connection,
                        state: state
                    ) {
                        receiveRemainingAcknowledgements(
                            expected: [
                                (first, 4, false),
                                (second, 4, false),
                                (first, 6, true),
                                (second, 6, true),
                            ],
                            index: 0,
                            on: connection,
                            state: state
                        )
                    }
                } catch {
                    fail(connection, state: state)
                }
            }
        }
    }

    private static func receiveRemainingAcknowledgements(
        expected: [(State.Stream, Int64, Bool)],
        index: Int,
        on connection: NWConnection,
        state: State
    ) {
        guard index < expected.count else {
            state.finish(success: true)
            connection.cancel()
            return
        }
        let item = expected[index]
        receiveAcknowledgement(
            expected: item.0,
            nextOffset: item.1,
            final: item.2,
            on: connection,
            state: state
        ) {
            receiveRemainingAcknowledgements(
                expected: expected,
                index: index + 1,
                on: connection,
                state: state
            )
        }
    }

    private static func receiveOpen(
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable (
            Droidmatch_V1_RpcEnvelope,
            Droidmatch_V1_OpenTransferRequest
        ) throws -> Void
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.payloadType == .openTransferRequest else {
                throw DualDownloadTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_OpenTransferRequest(serializedBytes: envelope.payload)
            guard request.direction == .download else {
                throw DualDownloadTestServerError.unexpectedFrame
            }
            try completion(envelope, request)
        }
    }

    private static func receiveAcknowledgement(
        expected stream: State.Stream,
        nextOffset: Int64,
        final: Bool,
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable () -> Void
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .stream,
                  envelope.payloadType == .transferChunkAck,
                  envelope.requestID == stream.requestID,
                  envelope.streamID == stream.streamID else {
                throw DualDownloadTestServerError.unexpectedFrame
            }
            let acknowledgement = try Droidmatch_V1_TransferChunkAck(
                serializedBytes: envelope.payload
            )
            guard acknowledgement.transferID == stream.transferID,
                  acknowledgement.nextOffsetBytes == nextOffset,
                  acknowledgement.finalAck == final else {
                throw DualDownloadTestServerError.unexpectedFrame
            }
            completion()
        }
    }

    private static func sendOpenAndInitialChunk(
        _ stream: State.Stream,
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable () -> Void
    ) throws {
        var response = Droidmatch_V1_OpenTransferResponse()
        response.transferID = stream.transferID
        response.acceptedOffsetBytes = 0
        response.chunkSizeBytes = 2
        response.totalSizeBytes = Int64(stream.chunks.reduce(0) { $0 + $1.count })
        response.streamID = stream.streamID
        try send(
            [
                responseEnvelope(
                    requestID: stream.requestID,
                    payloadType: .openTransferResponse,
                    payload: response.serializedData()
                ),
                chunkEnvelope(stream, index: 0),
            ],
            on: connection,
            state: state,
            completion: completion
        )
    }

    private static func chunkEnvelope(
        _ stream: State.Stream,
        index: Int
    ) throws -> Droidmatch_V1_RpcEnvelope {
        let offset = stream.chunks.prefix(index).reduce(0) { $0 + $1.count }
        let data = stream.chunks[index]
        var chunk = Droidmatch_V1_TransferChunk()
        chunk.transferID = stream.transferID
        chunk.offsetBytes = Int64(offset)
        chunk.data = data
        chunk.crc32 = Crc32.checksum(data)
        chunk.finalChunk = index == stream.chunks.count - 1
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = stream.requestID
        envelope.streamID = stream.streamID
        envelope.payloadType = .transferChunk
        envelope.payload = try chunk.serializedData()
        return envelope
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

    private static func receiveEnvelope(
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable (Droidmatch_V1_RpcEnvelope) throws -> Void
    ) {
        receiveFrameBody(on: connection) { body in
            do {
                let envelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
                try completion(envelope)
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

private enum DualDownloadTestServerError: Error {
    case listenerDidNotBecomeReady
    case unexpectedFrame
}
