import Foundation
@preconcurrency import Network
@testable import DroidMatchCore

// Keeps upload/download cancellation and post-cancellation reuse as one ordered scenario.
// 中文：上传/下载取消及取消后的会话复用属于同一条有序场景链。
extension AsyncMixedTransferTestServer {
    static func receiveCancellationUploadOpen(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .upload)
            guard request.transferID == "cancel-upload" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.cancellationUploadRequestID = envelope.requestID
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 2
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
                receiveCancellationUploadChunk(on: connection, state: state)
            }
        }
    }

    private static func receiveCancellationUploadChunk(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .stream,
                  envelope.requestID == state.cancellationUploadRequestID,
                  envelope.streamID == state.cancellationUploadRequestID,
                  envelope.payloadType == .transferChunk else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: envelope.payload)
            guard chunk.transferID == "cancel-upload",
                  chunk.offsetBytes == 0,
                  chunk.data == Data("no".utf8),
                  chunk.finalChunk,
                  chunk.crc32 == Crc32.checksum(chunk.data) else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.markCancellationUploadChunkReceived()
            receiveCancellationRequest(on: connection, state: state)
        }
    }

    private static func receiveCancellationRequest(
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
            guard request.transferID == "cancel-upload",
                  request.reason == "test-cancel-window" else {
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
                receivePostCancellationHeartbeat(on: connection, state: state)
            }
        }
    }

    private static func receivePostCancellationHeartbeat(
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
                receiveCancellationDownloadOpen(on: connection, state: state)
            }
        }
    }

    private static func receiveCancellationDownloadOpen(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            let request = try openRequest(envelope, direction: .download)
            guard request.transferID == "cancel-download" else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.cancellationDownloadRequestID = envelope.requestID
            var response = Droidmatch_V1_OpenTransferResponse()
            response.transferID = request.transferID
            response.acceptedOffsetBytes = 0
            response.chunkSizeBytes = 2
            response.totalSizeBytes = 4
            response.streamID = envelope.requestID
            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = request.transferID
            chunk.offsetBytes = 0
            chunk.data = Data("ke".utf8)
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
                receiveCancellationDownloadAcknowledgement(on: connection, state: state)
            }
        }
    }

    private static func receiveCancellationDownloadAcknowledgement(
        on connection: NWConnection,
        state: State
    ) {
        receiveEnvelope(on: connection, state: state) { envelope in
            guard envelope.kind == .stream,
                  envelope.requestID == state.cancellationDownloadRequestID,
                  envelope.streamID == state.cancellationDownloadRequestID,
                  envelope.payloadType == .transferChunkAck else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            let acknowledgement = try Droidmatch_V1_TransferChunkAck(
                serializedBytes: envelope.payload
            )
            guard acknowledgement.transferID == "cancel-download",
                  acknowledgement.nextOffsetBytes == 2,
                  !acknowledgement.finalAck else {
                throw AsyncMixedTransferTestServerError.unexpectedFrame
            }
            state.markCancellationDownloadAcknowledgementReceived()
            receiveCancellationDownloadRequest(on: connection, state: state)
        }
    }

    private static func receiveCancellationDownloadRequest(
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
            guard request.transferID == "cancel-download",
                  request.reason == "test-cancel-download-file" else {
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
                receiveFinalHeartbeat(on: connection, state: state)
            }
        }
    }

    private static func receiveFinalHeartbeat(
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
                receiveResumeMismatchDownloadOpen(on: connection, state: state)
            }
        }
    }
}
