import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

// Shared test-target recovery server owns wire timing and fixture state for upload coordinator evidence.
// 中文：共享测试 target 恢复服务器统一持有上传 coordinator 证据的 wire 时序与 fixture 状态。

final class UploadFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

final class UploadRecoveryTestServer: @unchecked Sendable {
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
