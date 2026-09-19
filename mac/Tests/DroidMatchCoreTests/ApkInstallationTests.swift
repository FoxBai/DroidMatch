import CryptoKit
import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func apkInstallationCodecRejectsMalformedAndContradictoryState() throws {
    var original = Droidmatch_V1_ApkInstallOperation()
    original.operationID = "11111111-1111-4111-8111-111111111111"
    original.displayName = "Fixture.apk"
    original.sizeBytes = 12
    original.state = .waitingForUpload
    #expect(try ApkInstallationCodec.operation(original).state == .waitingForUpload)
    var invalid = [Droidmatch_V1_ApkInstallOperation]()
    var value = original; value.displayName = "/private/Fixture.apk"; invalid.append(value)
    value = original; value.displayName = "Fixture\u{202e}.apk"; invalid.append(value)
    value = original; value.sizeBytes = UInt64.max; invalid.append(value)
    value = original; value.operationID = "not-an-operation"; invalid.append(value)
    value = original; value.uploadedBytes = 1; invalid.append(value)
    value = original; value.state = .succeeded; invalid.append(value)
    value = original; value.failureCode = .internal; invalid.append(value)
    value = original; value.state = .UNRECOGNIZED(100); invalid.append(value)
    for value in invalid {
        #expect(throws: ApkInstallationError.invalidResponse) { try ApkInstallationCodec.operation(value) }
    }
    var wire = Droidmatch_V1_ListApkInstallsResponse()
    wire.operations = [original, original]
    #expect(throws: ApkInstallationError.invalidResponse) { try ApkInstallationCodec.snapshot(wire) }
    wire.operations = [original]; wire.canStartInstall = true
    #expect(throws: ApkInstallationError.invalidResponse) { try ApkInstallationCodec.snapshot(wire) }
    #expect(throws: ApkInstallationError.invalidResponse) {
        try ApkInstallationCodec.response(Data(repeating: 0, count: 8193))
    }
    wire = .init(); wire.error.code = .permissionRequired
    let denied = try ApkInstallationCodec.response(wire.serializedData())
    #expect(throws: ApkInstallationError.permissionRequired) { try ApkInstallationCodec.snapshot(denied) }
}

@Test func apkInstallationUsesFreshPairedUploadAndNeverEquatesFinalAckWithInstallation() async throws {
    let fixture = ApkWireFixture()
    let pairingID = Data(repeating: 0x21, count: 16), key = Data(repeating: 0x35, count: 32)
    let credentials = try PairingCredentials(pairingID: pairingID, pairingKey: key,
        deviceIdentityFingerprint: LocalFrameTestServer.pairedDeviceIdentityFingerprint)
    let capabilities: [Droidmatch_V1_Capability] = [.apkInstall, .fileWrite, .resumableTransfer]
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
        pairingID: pairingID, pairingKey: key, grantedCapabilities: capabilities,
        afterAuthentication: { connection in fixture.connected(); fixture.read(on: connection) }))
    defer { server.cancel() }
    let transport = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 5)
    let control = AsyncRpcControlClient(session: transport, credentials: credentials,
                                       requestedCapabilities: capabilities, requestTimeoutSeconds: 5)
    let gate = ProductTransferSessionGate(lease: .init(deviceID: UUID(), host: "127.0.0.1", port: server.port),
        credentials: credentials, requestedCapabilities: capabilities)
    let client = ProductApkInstallationClient(control: control, gate: gate)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apk-wire-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Fixture.apk")
    let bytes = Data(repeating: 0x41, count: 3 * 1024 * 1024 + 17)
    try bytes.write(to: source)
    do {
        _ = try await control.handshake()
        #expect(try await client.installationSnapshot().canStartInstall)
        let result = try await client.uploadApk(sourceURL: source,
            operationID: "11111111-1111-4111-8111-111111111111", progress: { _ in })
        #expect(result.state == .waitingForAndroidApproval)
        #expect(result.uploadedBytes == Int64(bytes.count))
        #expect(fixture.receivedBytes == bytes)
        #expect(fixture.connectionCount == 2)
        #expect(try await client.installationSnapshot().operations.first?.state == .waitingForAndroidApproval)
        #expect(try await client.cancelInstallation(id: result.id).state == .cancelled)
        #expect(fixture.connectionCount == 3)
        await client.invalidate()
        await #expect(throws: CancellationError.self) { try await client.installationSnapshot() }
        await control.close()
    } catch {
        await client.invalidate(); await control.close()
        throw error
    }
}

/// Synthetic peer: validates the new control/transfer contract, without an APK
/// parser or any system installation. Android's manager has separate JVM coverage.
private final class ApkWireFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Droidmatch_V1_ApkInstallOperation?
    private var digest = Data()
    private var bytes = Data()
    private var connections = 0
    var receivedBytes: Data { lock.withLock { bytes } }
    var connectionCount: Int { lock.withLock { connections } }
    func connected() { lock.withLock { connections += 1 } }

    func read(on connection: NWConnection) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { [self] body in
            do {
                let response = try lock.withLock { try reply(body) }
                LocalFrameTestServer.send([response], on: connection) { [self] in read(on: connection) }
            } catch { connection.cancel() }
        }
    }

    private func reply(_ body: Data) throws -> Data {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1; response.requestID = request.requestID; response.kind = .response
        switch request.payloadType {
        case .prepareApkInstallRequest:
            let prepared = try Droidmatch_V1_PrepareApkInstallRequest(serializedBytes: request.payload)
            guard operation == nil, prepared.sha256.count == 32 else { throw LocalEchoServerError.unexpectedPayloadType }
            var record = Droidmatch_V1_ApkInstallOperation()
            record.operationID = prepared.operationID; record.displayName = prepared.displayName
            record.sizeBytes = prepared.sizeBytes; record.state = .waitingForUpload
            operation = record; digest = prepared.sha256
            var result = Droidmatch_V1_PrepareApkInstallResponse()
            result.operation = record; result.uploadDestination = ApkInstallationPolicy.destination(record.operationID)
            response.payloadType = .prepareApkInstallResponse; response.payload = try result.serializedData()
        case .openTransferRequest:
            let open = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard let record = operation, record.state == .waitingForUpload,
                  open.transferID == record.operationID, open.direction == .upload,
                  open.sourcePath == TransferWireMetadata.localUploadSource,
                  open.destinationPath == ApkInstallationPolicy.destination(record.operationID),
                  open.requestedOffsetBytes == 0, open.expectedSizeBytes == Int64(record.sizeBytes) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var result = Droidmatch_V1_OpenTransferResponse()
            result.transferID = open.transferID; result.totalSizeBytes = open.expectedSizeBytes
            result.streamID = request.requestID; result.chunkSizeBytes = 512 * 1024
            operation?.state = .uploading
            response.payloadType = .openTransferResponse; response.payload = try result.serializedData()
        case .transferChunk:
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: request.payload)
            guard let record = operation, record.state == .uploading,
                  chunk.transferID == record.operationID, chunk.offsetBytes == Int64(bytes.count),
                  chunk.crc32 == Crc32.checksum(chunk.data), chunk.data.count <= 512 * 1024,
                  request.kind == .stream, request.streamID == request.requestID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            bytes.append(chunk.data); operation?.uploadedBytes = UInt64(bytes.count)
            if chunk.finalChunk {
                guard UInt64(bytes.count) == record.sizeBytes, Data(SHA256.hash(data: bytes)) == digest else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                operation?.state = .waitingForAndroidApproval
            }
            var ack = Droidmatch_V1_TransferChunkAck()
            ack.transferID = chunk.transferID; ack.nextOffsetBytes = Int64(bytes.count); ack.finalAck = chunk.finalChunk
            response.kind = .stream; response.streamID = request.streamID
            response.payloadType = .transferChunkAck; response.payload = try ack.serializedData()
        case .listApkInstallsRequest:
            var result = Droidmatch_V1_ListApkInstallsResponse()
            result.incomingRequestsEnabled = true; result.systemSourceTrusted = true
            if let operation { result.operations = [operation] }
            result.canStartInstall = operation == nil || operation?.state == .cancelled
            response.payloadType = .listApkInstallsResponse; response.payload = try result.serializedData()
        case .cancelApkInstallRequest:
            let cancel = try Droidmatch_V1_CancelApkInstallRequest(serializedBytes: request.payload)
            guard cancel.operationID == operation?.operationID else { throw LocalEchoServerError.unexpectedPayloadType }
            operation?.state = .cancelled; operation?.failureCode = .cancelled
            var result = Droidmatch_V1_CancelApkInstallResponse(); result.operation = operation!
            response.payloadType = .cancelApkInstallResponse; response.payload = try result.serializedData()
        default: throw LocalEchoServerError.unexpectedPayloadType
        }
        response.payloadCrc32 = Crc32.checksum(response.payload)
        return try response.serializedData()
    }
}
