import Foundation
import Network
@testable import DroidMatchCore

extension LocalFrameTestServer {
    static func multiChunkDownloadResponse(
        to requestBody: Data,
        chunks: [Data],
        nextChunkIndex: Int,
        transferID currentTransferID: String?
    ) throws -> LocalMultiChunkDownloadResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalMultiChunkDownloadResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false,
                nextChunkIndex: nextChunkIndex,
                transferID: currentTransferID
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .download, nextChunkIndex == 0 else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            if openRequest.hasSourceFingerprint,
               openRequest.sourceFingerprint != loopbackTransferFingerprint() {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            guard let startIndex = chunkIndex(forOffset: openRequest.requestedOffsetBytes, chunks: chunks),
                  startIndex < chunks.count else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = openRequest.requestedOffsetBytes
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = chunks.reduce(Int64(0)) { $0 + Int64($1.count) }
            openResponse.streamID = request.requestID
            openResponse.acceptedSourceFingerprint = loopbackTransferFingerprint()
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()

            return LocalMultiChunkDownloadResponse(
                payloads: [
                    try response.serializedData(),
                    try transferChunkEnvelope(
                        request: request,
                        transferID: openRequest.transferID,
                        offset: openRequest.requestedOffsetBytes,
                        data: chunks[startIndex],
                        finalChunk: startIndex == chunks.count - 1
                    )
                ],
                isFinal: false,
                nextChunkIndex: startIndex + 1,
                transferID: openRequest.transferID
            )
        case .transferChunkAck:
            guard let currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let ack = try Droidmatch_V1_TransferChunkAck(serializedBytes: request.payload)
            let expectedOffset = chunks.prefix(nextChunkIndex).reduce(Int64(0)) { $0 + Int64($1.count) }
            guard ack.transferID == currentTransferID, ack.nextOffsetBytes == expectedOffset else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            if ack.finalAck {
                guard nextChunkIndex == chunks.count else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                return LocalMultiChunkDownloadResponse(
                    payloads: [],
                    isFinal: true,
                    nextChunkIndex: nextChunkIndex,
                    transferID: currentTransferID
                )
            }
            guard nextChunkIndex < chunks.count else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            return LocalMultiChunkDownloadResponse(
                payloads: [
                    try transferChunkEnvelope(
                        request: request,
                        transferID: currentTransferID,
                        offset: expectedOffset,
                        data: chunks[nextChunkIndex],
                        finalChunk: nextChunkIndex == chunks.count - 1
                    )
                ],
                isFinal: false,
                nextChunkIndex: nextChunkIndex + 1,
                transferID: currentTransferID
            )
        case .cancelTransferRequest:
            guard let currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let cancelRequest = try Droidmatch_V1_CancelTransferRequest(serializedBytes: request.payload)
            guard cancelRequest.transferID == currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var cancelResponse = Droidmatch_V1_CancelTransferResponse()
            cancelResponse.transferID = currentTransferID
            cancelResponse.ok = true
            response.payloadType = .cancelTransferResponse
            response.payload = try cancelResponse.serializedData()
            return LocalMultiChunkDownloadResponse(
                payloads: [try response.serializedData()],
                isFinal: true,
                nextChunkIndex: nextChunkIndex,
                transferID: currentTransferID
            )
        case .pauseTransferRequest:
            guard let currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let pauseRequest = try Droidmatch_V1_PauseTransferRequest(serializedBytes: request.payload)
            guard pauseRequest.transferID == currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var pauseResponse = Droidmatch_V1_PauseTransferResponse()
            pauseResponse.transferID = currentTransferID
            pauseResponse.ok = true
            // No TransferChunkAck was sent before this control request, so zero
            // is the only safe resume boundary even though one chunk was received.
            pauseResponse.resumableOffsetBytes = 0
            response.payloadType = .pauseTransferResponse
            response.payload = try pauseResponse.serializedData()
            return LocalMultiChunkDownloadResponse(
                payloads: [try response.serializedData()],
                isFinal: true,
                nextChunkIndex: nextChunkIndex,
                transferID: currentTransferID
            )
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    static func downloadOpenNotFoundResponse(to requestBody: Data) throws -> LocalControlPlaneResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalControlPlaneResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .download,
                  openRequest.transferID == "missing-download",
                  openRequest.sourcePath == "dm://app-sandbox/missing-download.bin" else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var error = Droidmatch_V1_DroidMatchError()
            error.code = .notFound
            error.message = "download source is not available"
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.streamID = request.requestID
            openResponse.error = error
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: true)
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }
}
