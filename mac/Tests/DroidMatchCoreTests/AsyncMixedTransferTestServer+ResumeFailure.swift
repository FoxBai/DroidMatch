import Foundation
@preconcurrency import Network
@testable import DroidMatchCore

// Owns the local-write resume-mismatch failure and reusable-session proof.
// 中文：集中拥有本地写入恢复偏移不匹配失败及后续会话复用证明。
extension AsyncMixedTransferTestServer {
    static func receiveResumeMismatchDownloadOpen(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .download)
            guard request.transferID == "resume-mismatch",
                  request.requestedOffsetBytes == 0 else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 4
            response.streamID = envelope.requestID
            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = request.transferID
            chunk.offsetBytes = 0
            chunk.data = Data("zz".utf8)
            chunk.crc32 = Crc32.checksum(chunk.data)
            try send(
                [
                    responseEnvelope(
                        requestID: envelope.requestID,
                        payloadType: .openTransferResponse,
                        payload: response.serializedData()
                    ),
                    streamEnvelope(
                        requestID: envelope.requestID,
                        streamID: envelope.requestID,
                        payloadType: .transferChunk,
                        payload: chunk.serializedData()
                    ),
                ],
                on: connection,
                state: state
            ) {
                receiveResumeMismatchCancellation(on: connection, state: state)
            }
        }
    }

    private static func receiveResumeMismatchCancellation(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .cancelTransferRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let request = try Droidmatch_V1_CancelTransferRequest(
                serializedBytes: envelope.payload
            )
            guard request.transferID == "resume-mismatch",
                  request.reason == "mac-local-download-file-failure" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            var response = Droidmatch_V1_CancelTransferResponse()
            response.transferID = request.transferID
            response.ok = true
            try send(
                [responseEnvelope(
                    requestID: envelope.requestID,
                    payloadType: .cancelTransferResponse,
                    payload: response.serializedData()
                )],
                on: connection,
                state: state
            ) {
                receiveResumeFailureHeartbeat(on: connection, state: state)
            }
        }
    }

    private static func receiveResumeFailureHeartbeat(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .request,
                  envelope.payloadType == .heartbeatRequest else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
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
                state.finish(success: true)
            }
        }
    }
}
