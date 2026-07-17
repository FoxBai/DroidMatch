import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test
func asyncRpcCancellationBeforeSendAdmissionIsRequestLocal() async throws {
    let state = RpcCancellationServerState()
    let server = try LocalFrameTestServer(handler: state.accept)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let sendGate = AsyncRpcSendGate()
    let heldLease = try await sendGate.acquire()
    let multiplexer = AsyncRpcMultiplexer(
        session: session,
        requestTimeoutSeconds: 2,
        sendGate: sendGate
    )
    try await multiplexer.start()

    let cancelled = Task {
        try await sendHeartbeat(1, using: multiplexer)
    }
    for _ in 0..<200 {
        if await sendGate.pendingWaiterCount() == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await sendGate.pendingWaiterCount() == 1)
    cancelled.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await cancelled.value
    }
    #expect(await multiplexer.pendingControlRequestCount() == 0)

    await sendGate.release(heldLease)
    let response = try await sendHeartbeat(2, using: multiplexer)
    #expect(response.monotonicMillis == 2)
    #expect(state.heartbeatValues == [2])
    await multiplexer.close()
}

@Test
func asyncRpcCancelledReadOnlyRequestDrainsLateResponseAndKeepsSession() async throws {
    let state = RpcCancellationServerState(holdThumbnail: true)
    let server = try LocalFrameTestServer(handler: state.accept)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: [.fileList, .fileRead, .fileWrite, .diagnostics],
        requestTimeoutSeconds: 2
    )
    _ = try await client.handshake()

    let thumbnail = Task {
        try await client.thumbnail(
            path: "dm://media-images/media/42",
            maxDimensionPx: 96
        )
    }
    #expect(await waitForPayload(.thumbnailRequest, in: state))
    thumbnail.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await thumbnail.value
    }

    let heartbeat = try await client.heartbeat(monotonicMillis: 77)
    let listing = try await client.listDir(path: "dm://roots/")
    #expect(heartbeat.monotonicMillis == 77)
    #expect(listing.entries.isEmpty)

    state.releaseThumbnail()
    #expect(await waitForReleasedThumbnail(in: state))
    let finalHeartbeat = try await client.heartbeat(monotonicMillis: 88)
    #expect(finalHeartbeat.monotonicMillis == 88)
    await client.close()
}

@Test
func asyncRpcCancelledAdmittedMutationClosesAmbiguousSession() async throws {
    let state = RpcCancellationServerState(holdMutation: true)
    let server = try LocalFrameTestServer(handler: state.accept)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: [.fileList, .fileRead, .fileWrite],
        requestTimeoutSeconds: 2
    )
    _ = try await client.handshake()

    let mutation = Task {
        try await client.createDirectory(path: "dm://app-sandbox/Reports/")
    }
    #expect(await waitForPayload(.createDirectoryRequest, in: state))
    mutation.cancel()
    await #expect(throws: CancellationError.self) {
        try await mutation.value
    }
    await #expect(throws: AsyncRpcControlClientStateError.self) {
        _ = try await client.heartbeat(monotonicMillis: 99)
    }
}

@Test
func asyncRpcCancelledReadOnlyRequestRejectsMalformedLateResponse() async throws {
    let state = RpcCancellationServerState(
        holdThumbnail: true,
        malformedThumbnailResponse: true
    )
    let server = try LocalFrameTestServer(handler: state.accept)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: [.fileList, .fileRead],
        requestTimeoutSeconds: 2
    )
    _ = try await client.handshake()

    let thumbnail = Task {
        try await client.thumbnail(
            path: "dm://media-images/media/42",
            maxDimensionPx: 96
        )
    }
    #expect(await waitForPayload(.thumbnailRequest, in: state))
    thumbnail.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await thumbnail.value
    }

    state.releaseThumbnail()
    #expect(await waitForReleasedThumbnail(in: state))
    var rejectedMalformedResponse = false
    do {
        _ = try await client.heartbeat(monotonicMillis: 99)
    } catch {
        rejectedMalformedResponse = true
    }
    #expect(rejectedMalformedResponse)
    await #expect(throws: AsyncRpcControlClientStateError.closed) {
        _ = try await client.heartbeat(monotonicMillis: 100)
    }
}

@Test
func asyncRpcCancelledReadOnlyRequestStillEnforcesOriginalDeadline() async throws {
    let state = RpcCancellationServerState(holdThumbnail: true)
    let server = try LocalFrameTestServer(handler: state.accept)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: [.fileRead],
        requestTimeoutSeconds: 0.5
    )
    _ = try await client.handshake()

    let thumbnail = Task {
        try await client.thumbnail(
            path: "dm://media-images/media/42",
            maxDimensionPx: 96
        )
    }
    #expect(await waitForPayload(.thumbnailRequest, in: state))
    thumbnail.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await thumbnail.value
    }

    try await Task.sleep(for: .seconds(1))
    await #expect(throws: AsyncRpcControlClientStateError.closed) {
        _ = try await client.heartbeat(monotonicMillis: 101)
    }
}

private func sendHeartbeat(
    _ value: Int64,
    using multiplexer: AsyncRpcMultiplexer
) async throws -> Droidmatch_V1_HeartbeatResponse {
    let requestID = try await multiplexer.allocateRequestID()
    var request = Droidmatch_V1_HeartbeatRequest()
    request.monotonicMillis = value
    let envelope = try RpcEnvelopeCodec.request(
        payload: request,
        payloadType: .heartbeatRequest,
        requestID: requestID
    )
    let bytes = try await multiplexer.sendRequest(
        envelope,
        expectedPayloadType: .heartbeatResponse,
        payloadValidator: { payload in
            _ = try Droidmatch_V1_HeartbeatResponse(serializedBytes: payload)
        },
        cancellationSafety: .drainReadOnlyResponse
    )
    let response = try RpcEnvelopeCodec.response(
        from: bytes,
        requestID: requestID,
        expectedPayloadType: .heartbeatResponse
    )
    return try Droidmatch_V1_HeartbeatResponse(serializedBytes: response.payload)
}

private func waitForPayload(
    _ type: Droidmatch_V1_PayloadType,
    in state: RpcCancellationServerState
) async -> Bool {
    for _ in 0..<200 {
        if state.receivedPayloadTypes.contains(type) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func waitForReleasedThumbnail(in state: RpcCancellationServerState) async -> Bool {
    for _ in 0..<200 {
        if state.thumbnailWasReleased { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private final class RpcCancellationServerState: @unchecked Sendable {
    private let lock = NSLock()
    private let holdThumbnail: Bool
    private let holdMutation: Bool
    private let malformedThumbnailResponse: Bool
    private var connection: NWConnection?
    private var payloadTypes: [Droidmatch_V1_PayloadType] = []
    private var observedHeartbeats: [Int64] = []
    private var heldThumbnailResponse: Data?
    private var releasedThumbnail = false

    init(
        holdThumbnail: Bool = false,
        holdMutation: Bool = false,
        malformedThumbnailResponse: Bool = false
    ) {
        self.holdThumbnail = holdThumbnail
        self.holdMutation = holdMutation
        self.malformedThumbnailResponse = malformedThumbnailResponse
    }

    var receivedPayloadTypes: [Droidmatch_V1_PayloadType] {
        lock.withLock { payloadTypes }
    }

    var heartbeatValues: [Int64] {
        lock.withLock { observedHeartbeats }
    }

    var thumbnailWasReleased: Bool {
        lock.withLock { releasedThumbnail }
    }

    func accept(_ connection: NWConnection) {
        lock.withLock { self.connection = connection }
        readNext(on: connection)
    }

    func releaseThumbnail() {
        let value = lock.withLock { () -> (NWConnection?, Data?) in
            let value = (connection, heldThumbnailResponse)
            heldThumbnailResponse = nil
            return value
        }
        guard let connection = value.0, let response = value.1 else {
            Issue.record("thumbnail response was not held")
            return
        }
        LocalFrameTestServer.send([response], on: connection) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.releasedThumbnail = true }
        }
    }

    private func readNext(on connection: NWConnection) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { [weak self] body in
            guard let self else { return }
            do {
                let responses = try self.responses(to: body)
                LocalFrameTestServer.send(responses, on: connection) {
                    self.readNext(on: connection)
                }
            } catch {
                Issue.record("RPC cancellation server rejected a frame: \(error)")
                connection.cancel()
            }
        }
    }

    private func responses(to body: Data) throws -> [Data] {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
        lock.withLock { payloadTypes.append(request.payloadType) }
        switch request.payloadType {
        case .clientHello:
            return [try LocalFrameTestServer.handshakeResponse(to: body)]
        case .heartbeatRequest:
            let heartbeat = try Droidmatch_V1_HeartbeatRequest(
                serializedBytes: request.payload
            )
            lock.withLock { observedHeartbeats.append(heartbeat.monotonicMillis) }
            var payload = Droidmatch_V1_HeartbeatResponse()
            payload.monotonicMillis = heartbeat.monotonicMillis
            return [try response(
                to: request,
                type: .heartbeatResponse,
                payload: payload.serializedData()
            )]
        case .listDirRequest:
            _ = try Droidmatch_V1_ListDirRequest(serializedBytes: request.payload)
            return [try response(
                to: request,
                type: .listDirResponse,
                payload: Droidmatch_V1_ListDirResponse().serializedData()
            )]
        case .thumbnailRequest:
            let thumbnailRequest = try Droidmatch_V1_ThumbnailRequest(
                serializedBytes: request.payload
            )
            var payload = Droidmatch_V1_ThumbnailResponse()
            payload.encodedImage = Data([1, 2, 3])
            payload.mimeType = "image/jpeg"
            payload.widthPx = min(80, thumbnailRequest.maxDimensionPx)
            payload.heightPx = min(60, thumbnailRequest.maxDimensionPx)
            let responsePayload: Data
            if malformedThumbnailResponse {
                responsePayload = Data([0x0a])
            } else {
                responsePayload = try payload.serializedData()
            }
            let encoded = try response(
                to: request,
                type: .thumbnailResponse,
                payload: responsePayload
            )
            if holdThumbnail {
                lock.withLock { heldThumbnailResponse = encoded }
                return []
            }
            return [encoded]
        case .createDirectoryRequest:
            _ = try Droidmatch_V1_CreateDirectoryRequest(serializedBytes: request.payload)
            if holdMutation { return [] }
            var payload = Droidmatch_V1_FileMutationResponse()
            payload.ok = true
            return [try response(
                to: request,
                type: .fileMutationResponse,
                payload: payload.serializedData()
            )]
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private func response(
        to request: Droidmatch_V1_RpcEnvelope,
        type: Droidmatch_V1_PayloadType,
        payload: Data
    ) throws -> Data {
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = type
        response.payload = payload
        return try response.serializedData()
    }
}
