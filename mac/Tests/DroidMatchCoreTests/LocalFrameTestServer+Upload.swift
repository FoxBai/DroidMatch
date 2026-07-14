import Foundation
import Network
@testable import DroidMatchCore

extension LocalFrameTestServer {
    static func readUploadRequest(
        on connection: NWConnection,
        received: Data,
        transferID: String?,
        expectedSizeBytes: Int64,
        streamID: UInt64?
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
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? uploadResponse(
                          to: body,
                          received: received,
                          transferID: transferID,
                          expectedSizeBytes: expectedSizeBytes,
                          streamID: streamID
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readUploadRequest(
                            on: connection,
                            received: response.received,
                            transferID: response.transferID,
                            expectedSizeBytes: response.expectedSizeBytes,
                            streamID: response.streamID
                        )
                    }
                }
            }
        }
    }

    /// 泛化版 readUploadRequest：接受任意 payload/transferID/destinationPath，
    /// 用于窗口化端到端测试。逻辑与 readUploadRequest 对称：收一帧 → 回 ACK → 续读。
    /// Test-target visibility lets the legacy RPC tests construct a resume
    /// server without making this fixture part of the production API.
    static func readUploadRequestEchoing(
        on connection: NWConnection,
        received: Data,
        transferID: String?,
        expectedSizeBytes: Int64,
        expectedTotalPayload: Data,
        expectedTransferID: String,
        expectedDestinationPath: String,
        streamID: UInt64?
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
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? uploadResponseEchoing(
                          to: body,
                          received: received,
                          transferID: transferID,
                          expectedSizeBytes: expectedSizeBytes,
                          streamID: streamID,
                          expectedPayload: expectedTotalPayload,
                          expectedTransferID: expectedTransferID,
                          expectedDestinationPath: expectedDestinationPath
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readUploadRequestEchoing(
                            on: connection,
                            received: response.received,
                            transferID: response.transferID,
                            expectedSizeBytes: response.expectedSizeBytes,
                            expectedTotalPayload: expectedTotalPayload,
                            expectedTransferID: expectedTransferID,
                            expectedDestinationPath: expectedDestinationPath,
                            streamID: response.streamID
                        )
                    }
                }
            }
        }
    }

    static func uploadResponse(
        to requestBody: Data,
        received: Data,
        transferID currentTransferID: String?,
        expectedSizeBytes: Int64,
        streamID currentStreamID: UInt64?
    ) throws -> LocalUploadResponse {
        try uploadResponse(
            to: requestBody,
            received: received,
            transferID: currentTransferID,
            expectedSizeBytes: expectedSizeBytes,
            streamID: currentStreamID,
            expectedPayload: Data("upload-bytes".utf8)
        )
    }

    /// 泛化版 upload 响应：支持任意 expectedPayload，用于窗口化端到端测试。
    /// 行为与 uploadResponse 一致：逐 chunk 校验 offset/CRC、追加到 received、
    /// 按顺序回 ACK，final chunk 校验总长度和内容。
    static func uploadResponse(
        to requestBody: Data,
        received: Data,
        transferID currentTransferID: String?,
        expectedSizeBytes: Int64,
        streamID currentStreamID: UInt64?,
        expectedPayload: Data
    ) throws -> LocalUploadResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalUploadResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false,
                received: received,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .upload,
                  openRequest.transferID == "loopback-upload",
                  openRequest.destinationPath == "dm://app-sandbox/upload-bytes.bin",
                  openRequest.expectedSizeBytes == Int64(expectedPayload.count),
                  openRequest.requestedOffsetBytes == Int64(received.count) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = openRequest.requestedOffsetBytes
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = openRequest.expectedSizeBytes
            openResponse.streamID = request.requestID
            response.kind = .response
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: false,
                received: received,
                transferID: openRequest.transferID,
                expectedSizeBytes: openRequest.expectedSizeBytes,
                streamID: request.requestID
            )
        case .transferChunk:
            guard let currentTransferID,
                  let currentStreamID,
                  request.streamID == currentStreamID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: request.payload)
            guard chunk.transferID == currentTransferID,
                  chunk.offsetBytes == Int64(received.count),
                  chunk.crc32 == Crc32.checksum(chunk.data) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var nextReceived = received
            nextReceived.append(chunk.data)
            if chunk.finalChunk {
                guard Int64(nextReceived.count) == expectedSizeBytes,
                      nextReceived == expectedPayload else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
            }
            var ack = Droidmatch_V1_TransferChunkAck()
            ack.transferID = currentTransferID
            ack.nextOffsetBytes = Int64(nextReceived.count)
            ack.finalAck = chunk.finalChunk
            response.kind = .stream
            response.streamID = currentStreamID
            response.payloadType = .transferChunkAck
            response.payload = try ack.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: chunk.finalChunk,
                received: nextReceived,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    /// 泛化 upload 响应：open 阶段校验参数化的 transferID/destinationPath，
    /// 其余逻辑与 uploadResponse 泛化版一致。用于窗口化端到端测试。
    static func uploadResponseEchoing(
        to requestBody: Data,
        received: Data,
        transferID currentTransferID: String?,
        expectedSizeBytes: Int64,
        streamID currentStreamID: UInt64?,
        expectedPayload: Data,
        expectedTransferID: String,
        expectedDestinationPath: String
    ) throws -> LocalUploadResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalUploadResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false,
                received: received,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .upload,
                  openRequest.transferID == expectedTransferID,
                  openRequest.destinationPath == expectedDestinationPath,
                  openRequest.expectedSizeBytes == Int64(expectedPayload.count),
                  openRequest.requestedOffsetBytes == Int64(received.count) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = openRequest.requestedOffsetBytes
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = openRequest.expectedSizeBytes
            openResponse.streamID = request.requestID
            response.kind = .response
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: false,
                received: received,
                transferID: openRequest.transferID,
                expectedSizeBytes: openRequest.expectedSizeBytes,
                streamID: request.requestID
            )
        case .transferChunk:
            guard let currentTransferID,
                  let currentStreamID,
                  request.streamID == currentStreamID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: request.payload)
            guard chunk.transferID == currentTransferID,
                  chunk.offsetBytes == Int64(received.count),
                  chunk.crc32 == Crc32.checksum(chunk.data) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var nextReceived = received
            nextReceived.append(chunk.data)
            if chunk.finalChunk {
                guard Int64(nextReceived.count) == expectedSizeBytes,
                      nextReceived == expectedPayload else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
            }
            var ack = Droidmatch_V1_TransferChunkAck()
            ack.transferID = currentTransferID
            ack.nextOffsetBytes = Int64(nextReceived.count)
            ack.finalAck = chunk.finalChunk
            response.kind = .stream
            response.streamID = currentStreamID
            response.payloadType = .transferChunkAck
            response.payload = try ack.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: chunk.finalChunk,
                received: nextReceived,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    static func uploadOpenUnsupportedResponse(to requestBody: Data) throws -> LocalControlPlaneResponse {
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
            guard openRequest.direction == .upload,
                  openRequest.transferID == "loopback-upload",
                  openRequest.destinationPath == "dm://media-images/upload-bytes.jpg",
                  openRequest.requestedOffsetBytes == 1 else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var error = Droidmatch_V1_DroidMatchError()
            error.code = .unsupportedCapability
            error.message = "MediaStore upload resume is not supported"
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
