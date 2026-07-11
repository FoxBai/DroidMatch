import Foundation
@preconcurrency import Network
@testable import DroidMatchCore

extension AsyncMixedTransferTestServer {
    static func openRequest(
        _ envelope: Droidmatch_V1_RpcEnvelope,
        direction: Droidmatch_V1_TransferDirection
    ) throws -> Droidmatch_V1_OpenTransferRequest {
        guard envelope.kind == .request,
              envelope.payloadType == .openTransferRequest else {
            throw AsyncMixedTransferTestServerError.unexpectedFrame
        }
        let request = try Droidmatch_V1_OpenTransferRequest(
            serializedBytes: envelope.payload
        )
        guard request.direction == direction else {
            throw AsyncMixedTransferTestServerError.unexpectedFrame
        }
        return request
    }

    static func responseEnvelope(
        requestID: UInt64,
        payloadType: Droidmatch_V1_PayloadType,
        payload: Data
    ) -> Droidmatch_V1_RpcEnvelope {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .response
        envelope.requestID = requestID
        envelope.payloadType = payloadType
        envelope.payload = payload
        return envelope
    }

    static func streamEnvelope(
        requestID: UInt64,
        streamID: UInt64,
        payloadType: Droidmatch_V1_PayloadType,
        payload: Data
    ) -> Droidmatch_V1_RpcEnvelope {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = requestID
        envelope.streamID = streamID
        envelope.payloadType = payloadType
        envelope.payload = payload
        return envelope
    }

    static func receiveEnvelope(
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable (Droidmatch_V1_RpcEnvelope) throws -> Void
    ) {
        receiveFrameBody(on: connection) { body in
            do {
                try completion(Droidmatch_V1_RpcEnvelope(serializedBytes: body))
            } catch {
                fail(connection, state: state)
            }
        }
    }

    static func send(
        _ envelopes: [Droidmatch_V1_RpcEnvelope],
        on connection: NWConnection,
        state: State,
        completion: @escaping @Sendable () -> Void
    ) throws {
        var frames = Data()
        for envelope in envelopes {
            frames.append(try FrameCodec().encode(payload: envelope.serializedData()))
        }
        connection.send(content: frames, completion: .contentProcessed { error in
            guard error == nil else {
                fail(connection, state: state)
                return
            }
            completion()
        })
    }

    private static func receiveFrameBody(
        on connection: NWConnection,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                completion(body)
            }
        }
    }

    static func fail(_ connection: NWConnection, state: State) {
        state.finish(success: false)
        connection.cancel()
    }
}
