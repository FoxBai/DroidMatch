import Foundation
@preconcurrency import Network
import SwiftProtobuf
import Testing
@testable import DroidMatchCore

@Test func mediaPlaybackReadsExactSeekRangesAndPreservesSharedControl() async throws {
    let fixture = try MediaPlaybackFixture()
    defer { fixture.server.cancel() }
    let client = try await fixture.connect()
    let source = try await client.openMediaPlayback(path: fixture.path, mimeType: "video/mp4")
    #expect(source.content.byteCount == Int64(fixture.state.bytes.count))
    for (offset, length) in [(0, 5), (11, 3), (2, 12), (28, 10)] {
        let bytes = try await source.read(offset: Int64(offset), length: length)
        #expect(bytes == fixture.state.bytes.subdata(in: offset..<min(32, offset + length)))
    }
    #expect(try await source.read(offset: 32, length: 1).isEmpty)
    await #expect(throws: MediaPlaybackError.invalidRequest) {
        _ = try await source.read(offset: Int64.max, length: 1)
    }
    await #expect(throws: MediaPlaybackError.invalidRequest) {
        _ = try await source.read(offset: 0, length: MediaPlaybackPolicy.maximumReadBytes + 1)
    }
    await source.close()
    await #expect(throws: MediaPlaybackError.closed) { _ = try await source.read(offset: 0, length: 1) }
    #expect(try await client.heartbeat(monotonicMillis: 42).monotonicMillis == 42)
    #expect(fixture.state.snapshot().offsets == [0, 0, 11, 2, 28])
    #expect(fixture.state.snapshot().fingerprints == [false, true, true, true, true])
    #expect(fixture.state.snapshot().cancels == 4)
    await client.close()
}

@Test func mediaPlaybackRejectsChangedSourcePermissionFailureAndCorruptChunks() async throws {
    for mode in [MediaPlaybackServer.Mode.changed, .permission, .permissionChunk, .corrupt] {
        let fixture = try MediaPlaybackFixture(mode: mode)
        defer { fixture.server.cancel() }
        let client = try await fixture.connect()
        let source = try await client.openMediaPlayback(path: fixture.path, mimeType: "video/mp4")
        let expected: MediaPlaybackError = mode == .changed ? .sourceChanged
            : (mode == .permission || mode == .permissionChunk ? .permissionRequired : .unavailable)
        await #expect(throws: expected) { _ = try await source.read(offset: 8, length: 8) }
        await #expect(throws: MediaPlaybackError.closed) { _ = try await source.read(offset: 0, length: 4) }
        if mode != .corrupt {
            #expect(try await client.heartbeat(monotonicMillis: 43).monotonicMillis == 43)
        }
        await source.close()
        await client.close()
    }
}

@Test func mediaPlaybackCloseDrainsAdmittedOpenWithoutRevivingOrClosingControl() async throws {
    let fixture = try MediaPlaybackFixture(mode: .held)
    defer { fixture.server.cancel() }
    let client = try await fixture.connect()
    let source = try await client.openMediaPlayback(path: fixture.path, mimeType: "video/mp4")
    let reading = Task { try await source.read(offset: 4, length: 5) }
    for _ in 0..<200 {
        if fixture.state.snapshot().offsets.count == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.state.snapshot().offsets.count == 2)
    await #expect(throws: MediaPlaybackError.busy) { _ = try await source.read(offset: 0, length: 1) }
    await source.close()
    fixture.state.release()
    await #expect(throws: MediaPlaybackError.closed) { _ = try await reading.value }
    #expect(fixture.state.snapshot().cancels == 2)
    #expect(try await client.heartbeat(monotonicMillis: 44).monotonicMillis == 44)
    await client.close()
}

@Test func mediaPlaybackRequiresAuthenticationAndReadResumeCapabilitiesBeforeAnyOpen() async throws {
    let fixture = try MediaPlaybackFixture(capabilities: [.diagnostics, .fileRead])
    defer { fixture.server.cancel() }
    let client = try await fixture.connect()
    await #expect(throws: (any Error).self) {
        _ = try await client.openMediaPlayback(path: fixture.path, mimeType: "video/mp4")
    }
    await #expect(throws: MediaPlaybackError.unsupported) {
        _ = try await client.openMediaPlayback(path: "https://example.invalid/video", mimeType: "video/mp4")
    }
    #expect(fixture.state.snapshot().offsets.isEmpty)
    #expect(try await client.heartbeat(monotonicMillis: 45).monotonicMillis == 45)
    await client.close()
    let unpaired = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer { unpaired.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: unpaired.port, timeoutSeconds: 5)
    let diagnosticClient = AsyncRpcControlClient(
        session: session, requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities
    )
    #expect(try await diagnosticClient.handshake().authenticationState == .correlated)
    await #expect(throws: (any Error).self) {
        _ = try await diagnosticClient.openMediaPlayback(path: fixture.path, mimeType: "video/mp4")
    }
    await diagnosticClient.close()
}

private struct MediaPlaybackFixture {
    let path = "dm://media-videos/media/1"
    let state: MediaPlaybackServer
    let server: LocalFrameTestServer
    let credentials: PairingCredentials

    init(mode: MediaPlaybackServer.Mode = .ordinary,
         capabilities: [Droidmatch_V1_Capability] = [.diagnostics, .fileRead, .resumableTransfer]) throws {
        let pairingID = Data(repeating: 0xa0, count: SessionAuthenticator.pairingIDLength)
        let pairingKey = Data(repeating: 0x42, count: 32)
        credentials = try PairingCredentials(
            pairingID: pairingID, pairingKey: pairingKey,
            deviceIdentityFingerprint: LocalFrameTestServer.pairedDeviceIdentityFingerprint
        )
        let state = MediaPlaybackServer(mode: mode)
        self.state = state
        server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
            pairingID: pairingID, pairingKey: pairingKey,
            grantedCapabilities: capabilities, afterAuthentication: { state.read(on: $0) }
        ))
    }

    func connect() async throws -> AsyncRpcControlClient {
        let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 5)
        let client = AsyncRpcControlClient(
            session: session, credentials: credentials,
            requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
            requestTimeoutSeconds: 2
        )
        _ = try await client.handshake()
        return client
    }
}

/// Synthetic bytes and paired loopback protocol only; no device or user media.
private final class MediaPlaybackServer: @unchecked Sendable {
    enum Mode { case ordinary, changed, permission, permissionChunk, corrupt, held }
    struct Snapshot {
        var offsets: [Int64] = []
        var fingerprints: [Bool] = []
        var cancels = 0
    }
    let bytes = Data("0123456789abcdefghijklmnopqrstuv".utf8)
    private let mode: Mode
    private let lock = NSLock()
    private var value = Snapshot()
    private var held: (@Sendable () -> Void)?
    private var active: (Droidmatch_V1_RpcEnvelope, String)?

    init(mode: Mode) { self.mode = mode }
    func snapshot() -> Snapshot { lock.withLock { value } }
    func release() { lock.withLock { let call = held; held = nil; return call }?() }

    func read(on connection: NWConnection) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { [self] bytes in
            do {
                let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: bytes)
                let payloads = try reply(to: request)
                let respond: @Sendable () -> Void = {
                    LocalFrameTestServer.send(payloads, on: connection) { self.read(on: connection) }
                }
                let shouldHold = lock.withLock {
                    if mode == .held, request.payloadType == .openTransferRequest,
                       value.offsets.count == 2 {
                        held = respond
                        return true
                    }
                    return false
                }
                if !shouldHold { respond() }
            } catch { connection.cancel() }
        }
    }

    private func reply(to request: Droidmatch_V1_RpcEnvelope) throws -> [Data] {
        switch request.payloadType {
        case .openTransferRequest:
            let open = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            let count = lock.withLock {
                value.offsets.append(open.requestedOffsetBytes)
                value.fingerprints.append(open.hasSourceFingerprint)
                return value.offsets.count
            }
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = open.transferID
            response.streamID = request.requestID
            response.chunkSizeBytes = 4
            response.totalSizeBytes = Int64(bytes.count)
            response.acceptedOffsetBytes = open.requestedOffsetBytes
            response.acceptedSourceFingerprint.sizeBytes = Int64(bytes.count)
            response.acceptedSourceFingerprint.modifiedUnixMillis = 1
            response.acceptedSourceFingerprint.providerEtag = count > 1 && mode == .changed
                ? "synthetic-v2" : "synthetic-v1"
            if count > 1 && mode == .permission {
                response.error.code = .permissionRequired
                return [try envelope(response, type: .openTransferResponse, request: request)]
            }
            active = (request, open.transferID)
            return [try envelope(response, type: .openTransferResponse, request: request),
                    try chunk(offset: open.requestedOffsetBytes, corrupt: count > 1 && mode == .corrupt)]
        case .cancelTransferRequest:
            let cancel = try Droidmatch_V1_CancelTransferRequest(serializedBytes: request.payload)
            lock.withLock { value.cancels += 1 }
            active = nil
            var response = Droidmatch_V1_CancelTransferResponse()
            response.transferID = cancel.transferID
            response.ok = true
            return [try envelope(response, type: .cancelTransferResponse, request: request)]
        case .transferChunkAck:
            let ack = try Droidmatch_V1_TransferChunkAck(serializedBytes: request.payload)
            if ack.finalAck { active = nil; return [] }
            if mode == .permissionChunk, let (open, _) = active {
                active = nil
                var error = Droidmatch_V1_RpcEnvelope()
                error.frameVersion = 1
                error.kind = .error
                error.requestID = open.requestID
                error.streamID = open.requestID
                error.payloadType = .droidmatchError
                error.error.code = .permissionRequired
                return [try error.serializedData()]
            }
            return [try chunk(offset: ack.nextOffsetBytes)]
        case .heartbeatRequest:
            let heartbeat = try Droidmatch_V1_HeartbeatRequest(serializedBytes: request.payload)
            var response = Droidmatch_V1_HeartbeatResponse()
            response.monotonicMillis = heartbeat.monotonicMillis
            return [try envelope(response, type: .heartbeatResponse, request: request)]
        default: throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private func chunk(offset: Int64, corrupt: Bool = false) throws -> Data {
        guard let (request, id) = active else { throw LocalEchoServerError.unexpectedPayloadType }
        let end = min(bytes.count, Int(offset) + 4)
        let body = try LocalFrameTestServer.transferChunkEnvelope(
            request: request, transferID: id, offset: offset,
            data: bytes.subdata(in: Int(offset)..<end), finalChunk: end == bytes.count
        )
        guard corrupt else { return body }
        var frame = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
        var value = try Droidmatch_V1_TransferChunk(serializedBytes: frame.payload)
        value.crc32 ^= 1
        frame.payload = try value.serializedData()
        return try frame.serializedData()
    }

    private func envelope<M: SwiftProtobuf.Message>(
        _ payload: M, type: Droidmatch_V1_PayloadType, request: Droidmatch_V1_RpcEnvelope
    ) throws -> Data {
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = type
        response.payload = try payload.serializedData()
        return try response.serializedData()
    }
}
