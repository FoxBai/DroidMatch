import Foundation
@preconcurrency import Network
@testable import DroidMatchCore

final class AsyncMixedTransferTestServer: @unchecked Sendable {
    typealias State = AsyncMixedTransferTestServerState

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
                    let acknowledgements = try [1, 2, 3, 4].map { index in
                        var acknowledgement = Droidmatch_V1_TransferChunkAck()
                        acknowledgement.transferID = chunk.transferID
                        acknowledgement.nextOffsetBytes = Int64((index + 1) * 2)
                        acknowledgement.finalAck = index == 4
                        return try streamEnvelope(
                            requestID: envelope.requestID,
                            streamID: envelope.streamID,
                            payloadType: .transferChunkAck,
                            payload: acknowledgement.serializedData()
                        )
                    }
                    try send(
                        acknowledgements,
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
                // Release only the oldest ACK. A continuously sliding sender
                // must use that single free slot to send the final chunk before
                // this server releases the other three ACKs. Batch-drain upload
                // implementations deadlock here, making the throughput bubble
                // regression deterministic instead of timing-dependent.
                var acknowledgement = Droidmatch_V1_TransferChunkAck()
                acknowledgement.transferID = chunk.transferID
                acknowledgement.nextOffsetBytes = 2
                acknowledgement.finalAck = false
                try send([streamEnvelope(
                    requestID: envelope.requestID,
                    streamID: envelope.streamID,
                    payloadType: .transferChunkAck,
                    payload: acknowledgement.serializedData()
                )], on: connection, state: state) {
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

}

enum AsyncMixedTransferTestServerError: Error {
    case listenerDidNotBecomeReady
    case unexpectedFrame
}
