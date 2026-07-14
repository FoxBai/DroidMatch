import Foundation
@preconcurrency import Network
@testable import DroidMatchCore

extension LocalFrameTestServer {
    static func controlDeadlineHandler(on connection: NWConnection) {
        replyToHandshake(on: connection) { connection in
            receiveFrameBody(on: connection) { requestBody in
                guard let request = try? Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody),
                      request.payloadType == .heartbeatRequest,
                      (try? Droidmatch_V1_HeartbeatRequest(serializedBytes: request.payload)) != nil else {
                    connection.cancel()
                    return
                }
                holdOpenWithoutReply(on: connection)
            }
        }
    }

    static func transferOpenDeadlineHandler(
        direction: Droidmatch_V1_TransferDirection
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            replyToHandshake(on: connection) { connection in
                receiveFrameBody(on: connection) { requestBody in
                    guard let request = try? Droidmatch_V1_RpcEnvelope(
                        serializedBytes: requestBody
                    ),
                          request.payloadType == .openTransferRequest,
                          let open = try? Droidmatch_V1_OpenTransferRequest(
                              serializedBytes: request.payload
                          ),
                          open.direction == direction else {
                        connection.cancel()
                        return
                    }
                    holdOpenWithoutReply(on: connection)
                }
            }
        }
    }

    static func uploadAcknowledgementDeadlineHandler(on connection: NWConnection) {
        replyToHandshake(on: connection) { connection in
            receiveFrameBody(on: connection) { requestBody in
                guard let request = try? Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody),
                      request.payloadType == .openTransferRequest,
                      let open = try? Droidmatch_V1_OpenTransferRequest(
                          serializedBytes: request.payload
                      ),
                      open.direction == .upload,
                      let response = try? uploadOpenResponse(to: request, open: open) else {
                    connection.cancel()
                    return
                }
                send([response], on: connection) {
                    receiveFrameBody(on: connection) { chunkBody in
                        guard let envelope = try? Droidmatch_V1_RpcEnvelope(
                            serializedBytes: chunkBody
                        ),
                              envelope.payloadType == .transferChunk,
                              let chunk = try? Droidmatch_V1_TransferChunk(
                                  serializedBytes: envelope.payload
                              ),
                              chunk.transferID == open.transferID else {
                            connection.cancel()
                            return
                        }
                        holdOpenWithoutReply(on: connection)
                    }
                }
            }
        }
    }

    private static func replyToHandshake(
        on connection: NWConnection,
        next: @escaping @Sendable (NWConnection) -> Void
    ) {
        receiveFrameBody(on: connection) { requestBody in
            guard let response = try? handshakeResponse(to: requestBody) else {
                connection.cancel()
                return
            }
            send([response], on: connection) { next(connection) }
        }
    }

    private static func uploadOpenResponse(
        to request: Droidmatch_V1_RpcEnvelope,
        open: Droidmatch_V1_OpenTransferRequest
    ) throws -> Data {
        var payload = Droidmatch_V1_OpenTransferResponse()
        payload.transferID = open.transferID
        payload.streamID = request.requestID
        payload.acceptedOffsetBytes = open.requestedOffsetBytes
        payload.chunkSizeBytes = open.preferredChunkSizeBytes
        payload.totalSizeBytes = open.expectedSizeBytes

        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .openTransferResponse
        response.payload = try payload.serializedData()
        return try response.serializedData()
    }

    private static func holdOpenWithoutReply(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            data, _, isComplete, error in
            guard error == nil, !isComplete, data != nil else {
                connection.cancel()
                return
            }
            holdOpenWithoutReply(on: connection)
        }
    }
}
