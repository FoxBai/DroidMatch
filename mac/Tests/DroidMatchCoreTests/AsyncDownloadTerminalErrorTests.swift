import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func downloadAckPreservesTransportTerminationAfterChunkDelivery() async throws {
    let state = DownloadTerminalErrorServerState()
    let server = try LocalFrameTestServer { connection in
        state.accept(connection)
    }
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
        requestTimeoutSeconds: 2
    )

    _ = try await client.handshake()
    let transfer = try await client.openDownload(
        sourcePath: "dm://app-sandbox/transport-race.bin",
        transferID: "transport-race",
        preferredChunkSizeBytes: 4
    )
    let chunk = try #require(await transfer.nextChunk())
    #expect(chunk.data == Data("race".utf8))

    state.terminateTransport()
    let terminalDescription: String
    do {
        _ = try await transfer.nextChunk()
        Issue.record("expected transport termination to finish the download queue")
        terminalDescription = ""
    } catch {
        terminalDescription = String(describing: error)
        #expect(isRetryableTransferError(error))
        if case RpcControlClientError.invalidTransferState = error {
            Issue.record("transport termination was replaced by invalid transfer state")
        }
    }

    await #expect(throws: (any Error).self) {
        _ = try await client.heartbeat(monotonicMillis: 101)
    }
    do {
        try await transfer.acknowledge(chunk)
        Issue.record("expected ACK after transport termination to fail")
    } catch {
        #expect(String(describing: error) == terminalDescription)
        if case RpcControlClientError.invalidTransferState = error {
            Issue.record("late ACK hid the transport termination")
        }
    }
    #expect(state.lateAcknowledgementCount == 0)
    await client.close()
}

@Test func downloadAckPreservesTypedRemoteErrorAndReleasesRoute() async throws {
    let state = DownloadTerminalErrorServerState()
    let server = try LocalFrameTestServer { connection in
        state.accept(connection)
    }
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
        requestTimeoutSeconds: 2
    )

    _ = try await client.handshake()
    let failed = try await client.openDownload(
        sourcePath: "dm://media-images/race.bin",
        transferID: "remote-race",
        preferredChunkSizeBytes: 4
    )
    let chunk = try #require(await failed.nextChunk())
    _ = try await client.openDownload(
        sourcePath: "dm://app-sandbox/sibling.bin",
        transferID: "sibling",
        preferredChunkSizeBytes: 4
    )

    state.sendPermissionRequired()
    do {
        _ = try await failed.nextChunk()
        Issue.record("expected the transfer-scoped remote error")
    } catch let RpcControlClientError.remoteError(error) {
        #expect(error.code == .permissionRequired)
    } catch {
        Issue.record("unexpected queue terminal error: \(error)")
    }

    do {
        try await failed.acknowledge(chunk)
        Issue.record("expected ACK after remote failure to fail")
    } catch let RpcControlClientError.remoteError(error) {
        #expect(error.code == .permissionRequired)
    } catch {
        Issue.record("late ACK hid the typed remote error: \(error)")
    }

    // The failed route must release its half of the two-stream quota while the
    // sibling remains active. A transfer-scoped error must not poison control.
    _ = try await client.openDownload(
        sourcePath: "dm://app-sandbox/replacement.bin",
        transferID: "replacement",
        preferredChunkSizeBytes: 4
    )
    let heartbeat = try await client.heartbeat(monotonicMillis: 202)
    #expect(heartbeat.monotonicMillis == 202)
    #expect(state.lateAcknowledgementCount == 0)
    await client.close()
}

private final class DownloadTerminalErrorServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var failedRequestID: UInt64?
    private var failedStreamID: UInt64?
    private var acknowledgementCount = 0

    var lateAcknowledgementCount: Int {
        lock.withLock { acknowledgementCount }
    }

    func accept(_ connection: NWConnection) {
        lock.withLock { self.connection = connection }
        readNext(on: connection)
    }

    func terminateTransport() {
        lock.withLock { connection }?.cancel()
    }

    func sendPermissionRequired() {
        let route = lock.withLock { (connection, failedRequestID, failedStreamID) }
        guard let connection = route.0,
              let requestID = route.1,
              let streamID = route.2 else {
            Issue.record("failure route was not ready")
            return
        }
        do {
            var error = Droidmatch_V1_DroidMatchError()
            error.code = .permissionRequired
            error.message = "media permission is required"
            var envelope = Droidmatch_V1_RpcEnvelope()
            envelope.frameVersion = 1
            envelope.kind = .error
            envelope.requestID = requestID
            envelope.streamID = streamID
            envelope.payloadType = .droidmatchError
            envelope.error = error
            LocalFrameTestServer.send(
                [try envelope.serializedData()],
                on: connection,
                completion: {}
            )
        } catch {
            Issue.record("could not encode remote failure: \(error)")
        }
    }

    private func readNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
            [weak self] header, _, _, _ in
            guard let self,
                  let header,
                  header.count == 4 else {
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0,
                  length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { [weak self] body, _, _, _ in
                guard let self,
                      let body,
                      body.count == Int(length) else {
                    return
                }
                do {
                    let responses = try self.responses(to: body)
                    LocalFrameTestServer.send(responses, on: connection) {
                        self.readNext(on: connection)
                    }
                } catch {
                    Issue.record("download failure server rejected a frame: \(error)")
                    connection.cancel()
                }
            }
        }
    }

    private func responses(to body: Data) throws -> [Data] {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
        switch request.payloadType {
        case .clientHello:
            return [try LocalFrameTestServer.handshakeResponse(to: body)]
        case .openTransferRequest:
            return try openResponses(to: request)
        case .heartbeatRequest:
            let heartbeat = try Droidmatch_V1_HeartbeatRequest(
                serializedBytes: request.payload
            )
            var payload = Droidmatch_V1_HeartbeatResponse()
            payload.monotonicMillis = heartbeat.monotonicMillis
            var response = Droidmatch_V1_RpcEnvelope()
            response.frameVersion = 1
            response.kind = .response
            response.requestID = request.requestID
            response.payloadType = .heartbeatResponse
            response.payload = try payload.serializedData()
            return [try response.serializedData()]
        case .transferChunkAck:
            lock.withLock { acknowledgementCount += 1 }
            return []
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private func openResponses(
        to request: Droidmatch_V1_RpcEnvelope
    ) throws -> [Data] {
        let open = try Droidmatch_V1_OpenTransferRequest(
            serializedBytes: request.payload
        )
        guard open.direction == .download else {
            throw LocalEchoServerError.unexpectedPayloadType
        }
        var payload = Droidmatch_V1_OpenTransferResponse()
        payload.transferID = open.transferID
        payload.acceptedOffsetBytes = 0
        payload.chunkSizeBytes = max(1, open.preferredChunkSizeBytes)
        payload.totalSizeBytes = open.transferID == "remote-race"
            || open.transferID == "transport-race" ? 4 : 8
        payload.streamID = request.requestID
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .openTransferResponse
        response.payload = try payload.serializedData()

        guard open.transferID == "remote-race"
                || open.transferID == "transport-race" else {
            return [try response.serializedData()]
        }
        lock.withLock {
            failedRequestID = request.requestID
            failedStreamID = request.requestID
        }
        let chunk = try LocalFrameTestServer.transferChunkEnvelope(
            request: request,
            transferID: open.transferID,
            offset: 0,
            data: Data("race".utf8),
            finalChunk: true
        )
        return [try response.serializedData(), chunk]
    }
}
