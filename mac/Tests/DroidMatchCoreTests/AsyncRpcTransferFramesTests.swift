import Foundation
import Testing
@testable import DroidMatchCore

@Test func transferFrameFactoryEncodesDownloadOpenWithoutOwningRouteState() throws {
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 42
    fingerprint.modifiedUnixMillis = 7

    let bytes = try AsyncRpcTransferFrames.openDownload(
        requestID: 11,
        sourcePath: "dm://app-sandbox/report.bin",
        transferID: "download-11",
        requestedOffsetBytes: 9,
        sourceFingerprint: fingerprint,
        preferredChunkSizeBytes: 65_536
    )

    let envelope = try RpcEnvelopeCodec.parse(bytes)
    let request = try Droidmatch_V1_OpenTransferRequest(serializedBytes: envelope.payload)
    #expect(envelope.kind == .request)
    #expect(envelope.requestID == 11)
    #expect(envelope.payloadType == .openTransferRequest)
    #expect(request.direction == .download)
    #expect(request.sourcePath == "dm://app-sandbox/report.bin")
    #expect(request.transferID == "download-11")
    #expect(request.requestedOffsetBytes == 9)
    #expect(request.sourceFingerprint == fingerprint)
    #expect(request.preferredChunkSizeBytes == 65_536)
}

@Test func transferFrameFactoryEncodesUploadChunkChecksumAndRoutingIdentity() throws {
    let data = Data("bounded-upload".utf8)

    let bytes = try AsyncRpcTransferFrames.uploadChunk(
        requestID: 12,
        streamID: 91,
        transferID: "upload-12",
        offsetBytes: 4,
        data: data,
        finalChunk: true
    )

    let envelope = try RpcEnvelopeCodec.parse(bytes)
    let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: envelope.payload)
    #expect(envelope.kind == .stream)
    #expect(envelope.requestID == 12)
    #expect(envelope.streamID == 91)
    #expect(envelope.payloadType == .transferChunk)
    #expect(chunk.transferID == "upload-12")
    #expect(chunk.offsetBytes == 4)
    #expect(chunk.data == data)
    #expect(chunk.crc32 == Crc32.checksum(data))
    #expect(chunk.finalChunk)
}

@Test func transferFrameFactoryRejectsResumeWithoutFingerprint() {
    #expect(throws: RpcControlClientError.self) {
        try AsyncRpcTransferFrames.openDownload(
            requestID: 1,
            sourcePath: "dm://app-sandbox/report.bin",
            transferID: "download-1",
            requestedOffsetBytes: 1,
            sourceFingerprint: nil,
            preferredChunkSizeBytes: 65_536
        )
    }
}
