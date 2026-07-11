import Foundation
import SwiftProtobuf

/// Pure protobuf frame construction for multiplexed transfers.
///
/// This namespace validates caller-controlled scalar input and serializes wire
/// values, but owns no socket, request ID allocation, route, waiter, or task.
enum AsyncRpcTransferFrames {
    static func openDownload(
        requestID: UInt64,
        sourcePath: String,
        transferID: String,
        requestedOffsetBytes: Int64,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint?,
        preferredChunkSizeBytes: UInt32
    ) throws -> Data {
        guard !sourcePath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "download source path must be non-empty"
            )
        }
        guard requestedOffsetBytes >= 0 else {
            throw RpcControlClientError.invalidTransferState(
                "download requested offset must be non-negative"
            )
        }
        if requestedOffsetBytes > 0, sourceFingerprint == nil {
            throw RpcControlClientError.invalidTransferState(
                "download resume requires a source fingerprint"
            )
        }

        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .download
        request.sourcePath = sourcePath
        request.requestedOffsetBytes = requestedOffsetBytes
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        if let sourceFingerprint {
            request.sourceFingerprint = sourceFingerprint
        }
        return try RpcEnvelopeCodec.request(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        ).serializedData()
    }

    static func openUpload(
        requestID: UInt64,
        sourcePath: String,
        destinationPath: String,
        transferID: String,
        requestedOffsetBytes: Int64,
        expectedSizeBytes: Int64,
        preferredChunkSizeBytes: UInt32
    ) throws -> Data {
        guard !destinationPath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "upload destination path must be non-empty"
            )
        }
        guard requestedOffsetBytes >= 0, expectedSizeBytes >= -1 else {
            throw RpcControlClientError.invalidTransferState(
                "upload offsets or expected size are invalid"
            )
        }

        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .upload
        request.sourcePath = sourcePath
        request.destinationPath = destinationPath
        request.requestedOffsetBytes = requestedOffsetBytes
        request.expectedSizeBytes = expectedSizeBytes
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        return try RpcEnvelopeCodec.request(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        ).serializedData()
    }

    static func downloadAcknowledgement(
        requestID: UInt64,
        streamID: UInt64,
        transferID: String,
        chunk: Droidmatch_V1_TransferChunk
    ) throws -> Data {
        var acknowledgement = Droidmatch_V1_TransferChunkAck()
        acknowledgement.transferID = transferID
        acknowledgement.nextOffsetBytes = try AsyncRpcTransferValidation.validatedEndOffset(chunk)
        acknowledgement.finalAck = chunk.finalChunk
        return try streamEnvelope(
            requestID: requestID,
            streamID: streamID,
            payloadType: .transferChunkAck,
            payload: acknowledgement
        )
    }

    static func uploadChunk(
        requestID: UInt64,
        streamID: UInt64,
        transferID: String,
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) throws -> Data {
        var chunk = Droidmatch_V1_TransferChunk()
        chunk.transferID = transferID
        chunk.offsetBytes = offsetBytes
        chunk.data = data
        chunk.crc32 = Crc32.checksum(data)
        chunk.finalChunk = finalChunk
        return try streamEnvelope(
            requestID: requestID,
            streamID: streamID,
            payloadType: .transferChunk,
            payload: chunk
        )
    }

    private static func streamEnvelope<Message: SwiftProtobuf.Message>(
        requestID: UInt64,
        streamID: UInt64,
        payloadType: Droidmatch_V1_PayloadType,
        payload: Message
    ) throws -> Data {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = requestID
        envelope.streamID = streamID
        envelope.payloadType = payloadType
        envelope.payload = try payload.serializedData()
        return try envelope.serializedData()
    }
}
