import CryptoKit
import Foundation
@preconcurrency import Network
@testable import DroidMatchCore

/// Synthetic paired peer with multiple sequential download routes. No APK parser
/// or installed Android package is implied by these arbitrary byte fixtures.
final class ApkExportWireFixture: @unchecked Sendable {
    let id = "22222222-2222-4222-8222-222222222222"
    let contents: [Data]
    let sourceChanged: Bool
    private let lock = NSLock()
    private var validated = false
    private var current: Int?
    private var offset = 0
    private var transferID = ""
    private var stream: UInt64 = 0
    var didValidate: Bool { lock.withLock { validated } }

    init(split: Bool, sourceChanged: Bool = false) {
        self.sourceChanged = sourceChanged
        contents = split ? [Data(repeating: 0x41, count: 130_017), Data(repeating: 0x62, count: 270_113)]
            : [Data(repeating: 0x41, count: 130_017)]
    }
    func digest(_ index: Int) -> String { SHA256.hash(data: contents[index]).map { String(format: "%02x", $0) }.joined() }

    var manifest: Droidmatch_V1_PrepareApkExportResponse {
        var value = Droidmatch_V1_PrepareApkExportResponse()
        value.exportID = id; value.packageIdentifier = "fixture.app"; value.versionCode = 4; value.updatedMillis = 123
        value.components = contents.enumerated().map { index, bytes in
            var part = Droidmatch_V1_ApkExportComponent()
            part.index = UInt32(index); part.sizeBytes = UInt64(bytes.count)
            part.splitName = index == 0 ? "" : "config.arm64_v8a"
            return part
        }
        return value
    }

    func makeClient() throws -> (LocalFrameTestServer, ProductApkExportClient) {
        let pairingID = Data(repeating: 0x23, count: 16), key = Data(repeating: 0x46, count: 32)
        let credentials = try PairingCredentials(pairingID: pairingID, pairingKey: key,
            deviceIdentityFingerprint: LocalFrameTestServer.pairedDeviceIdentityFingerprint)
        let capabilities: [Droidmatch_V1_Capability] = [.apkExport, .fileRead]
        let server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
            pairingID: pairingID, pairingKey: key, grantedCapabilities: capabilities,
            afterAuthentication: { [self] in read(on: $0) }))
        let gate = ProductTransferSessionGate(lease: .init(deviceID: UUID(), host: "127.0.0.1", port: server.port),
            credentials: credentials, requestedCapabilities: capabilities)
        return (server, ProductApkExportClient(gate: gate))
    }

    private func read(on connection: NWConnection) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { [self] body in
            do {
                let frames = try lock.withLock { try reply(body) }
                LocalFrameTestServer.send(frames, on: connection) { [self] in read(on: connection) }
            } catch { connection.cancel() }
        }
    }

    private func reply(_ bytes: Data) throws -> [Data] {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: bytes)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1; response.kind = .response; response.requestID = request.requestID
        switch request.payloadType {
        case .prepareApkExportRequest:
            let value = try Droidmatch_V1_PrepareApkExportRequest(serializedBytes: request.payload)
            guard value.packageIdentifier == "fixture.app" else { throw LocalEchoServerError.unexpectedPayloadType }
            response.payloadType = .prepareApkExportResponse; response.payload = try manifest.serializedData()
        case .openTransferRequest:
            let value = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard current == nil, value.direction == .download, value.requestedOffsetBytes == 0,
                  let index = contents.indices.first(where: { value.sourcePath == "dm://apk-export/\(id)/\($0).apk" }) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            current = index; offset = 0; transferID = value.transferID; stream = request.requestID
            var opened = Droidmatch_V1_OpenTransferResponse()
            opened.transferID = transferID; opened.streamID = stream; opened.chunkSizeBytes = 65_536
            opened.totalSizeBytes = Int64(contents[index].count)
            opened.acceptedSourceFingerprint.sizeBytes = opened.totalSizeBytes
            opened.acceptedSourceFingerprint.providerEtag = "\(id):\(index)"
            response.payloadType = .openTransferResponse; response.payload = try opened.serializedData()
            return [try response.serializedData(), try chunk(request: request, index: index)]
        case .transferChunkAck:
            let ack = try Droidmatch_V1_TransferChunkAck(serializedBytes: request.payload)
            guard let index = current, ack.transferID == transferID, ack.nextOffsetBytes == Int64(offset),
                  ack.finalAck == (offset == contents[index].count), request.streamID == stream else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            if ack.finalAck { current = nil; return [] }
            return [try chunk(request: request, index: index)]
        case .validateApkExportRequest:
            let value = try Droidmatch_V1_ValidateApkExportRequest(serializedBytes: request.payload)
            guard value.exportID == id, current == nil else { throw LocalEchoServerError.unexpectedPayloadType }
            validated = true
            var valueResponse = Droidmatch_V1_ValidateApkExportResponse()
            if sourceChanged { valueResponse.error.code = .invalidArgument }
            else { valueResponse.exportID = id }
            response.payloadType = .validateApkExportResponse; response.payload = try valueResponse.serializedData()
        default: throw LocalEchoServerError.unexpectedPayloadType
        }
        return [try response.serializedData()]
    }

    private func chunk(request: Droidmatch_V1_RpcEnvelope, index: Int) throws -> Data {
        let end = min(offset + 65_536, contents[index].count)
        let bytes = contents[index].subdata(in: offset..<end)
        let start = offset; offset = end
        return try LocalFrameTestServer.transferChunkEnvelope(request: request, transferID: transferID,
            offset: Int64(start), data: bytes, finalChunk: end == contents[index].count)
    }
}
