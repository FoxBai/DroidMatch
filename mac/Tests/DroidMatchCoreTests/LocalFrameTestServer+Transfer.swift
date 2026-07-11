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

    static func send(_ payloads: [Data], on connection: NWConnection, completion: @escaping @Sendable () -> Void) {
        guard let payload = payloads.first,
              let frame = try? FrameCodec().encode(payload: payload) else {
            completion()
            return
        }
        connection.send(content: frame, completion: .contentProcessed { _ in
            send(Array(payloads.dropFirst()), on: connection, completion: completion)
        })
    }

    static func handshakeResponse(
        to requestBody: Data,
        authenticationState: Droidmatch_V1_AuthenticationState = .correlated
    ) throws -> Data {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        let clientHello = try Droidmatch_V1_ClientHello(serializedBytes: request.payload)

        var serverHello = Droidmatch_V1_ServerHello()
        serverHello.serverName = "LocalFrameTestServer"
        serverHello.serverVersion = "test"
        serverHello.protocolMajor = 1
        serverHello.protocolMinor = min(clientHello.protocolMinor, 0)
        serverHello.transport = .adb
        serverHello.sessionNonce = clientHello.sessionNonce
        serverHello.authenticationState = authenticationState
        if authenticationState == .pairingRequired {
            serverHello.deviceIdentityFingerprint = pairedDeviceIdentityFingerprint
        }
        let supportedCapabilities: Set<Droidmatch_V1_Capability> = [
            .fileList,
            .fileRead,
            .fileWrite,
            .resumableTransfer,
            .diagnostics,
        ]
        serverHello.grantedCapabilities = clientHello.requestedCapabilities.filter {
            supportedCapabilities.contains($0)
        }

        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .serverHello
        response.payload = try serverHello.serializedData()
        return try response.serializedData()
    }

    static func m1SmokeResponse(
        to requestBody: Data,
        corruptDownloadCrc: Bool = false
    ) throws -> LocalControlPlaneResponse {
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
        case .deviceInfoRequest:
            _ = try Droidmatch_V1_DeviceInfoRequest(serializedBytes: request.payload)
            var deviceInfo = Droidmatch_V1_DeviceInfoResponse()
            deviceInfo.deviceID = "loopback-test"
            deviceInfo.manufacturer = "DroidMatch"
            deviceInfo.model = "Loopback"
            deviceInfo.androidVersion = "15"
            deviceInfo.sdkInt = 35
            deviceInfo.totalStorageBytes = 1024
            deviceInfo.freeStorageBytes = 512
            deviceInfo.batteryPercent = 87
            deviceInfo.permissions = ["media_read": .granted]
            response.payloadType = .deviceInfoResponse
            response.payload = try deviceInfo.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: false)
        case .heartbeatRequest:
            let heartbeat = try Droidmatch_V1_HeartbeatRequest(serializedBytes: request.payload)
            var heartbeatResponse = Droidmatch_V1_HeartbeatResponse()
            heartbeatResponse.monotonicMillis = heartbeat.monotonicMillis
            response.payloadType = .heartbeatResponse
            response.payload = try heartbeatResponse.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: false)
        case .listDirRequest:
            let listDirRequest = try Droidmatch_V1_ListDirRequest(serializedBytes: request.payload)
            guard listDirRequest.path == "dm://roots/" else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var rootEntry = Droidmatch_V1_FileEntry()
            rootEntry.path = "dm://media-images/"
            rootEntry.name = "Images"
            rootEntry.kind = .virtual
            rootEntry.canRead = true
            rootEntry.canWrite = false
            rootEntry.mimeType = "vnd.droidmatch.root"
            var listDirResponse = Droidmatch_V1_ListDirResponse()
            listDirResponse.entries = [rootEntry]
            response.payloadType = .listDirResponse
            response.payload = try listDirResponse.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: false)
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .download else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = 0
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = 14
            openResponse.streamID = request.requestID
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()

            let data = Data("download-bytes".utf8)
            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = openRequest.transferID
            chunk.offsetBytes = 0
            chunk.data = data
            chunk.crc32 = corruptDownloadCrc ? 0 : Crc32.checksum(data)
            chunk.finalChunk = true
            var chunkEnvelope = Droidmatch_V1_RpcEnvelope()
            chunkEnvelope.frameVersion = 1
            chunkEnvelope.kind = .stream
            chunkEnvelope.requestID = request.requestID
            chunkEnvelope.streamID = request.requestID
            chunkEnvelope.payloadType = .transferChunk
            chunkEnvelope.payload = try chunk.serializedData()
            return LocalControlPlaneResponse(
                payloads: [try response.serializedData(), try chunkEnvelope.serializedData()],
                isFinal: false
            )
        case .transferChunkAck:
            let ack = try Droidmatch_V1_TransferChunkAck(serializedBytes: request.payload)
            guard ack.transferID == "loopback-transfer", ack.finalAck else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            return LocalControlPlaneResponse(payloads: [], isFinal: true)
        case .diagnosticsRequest:
            _ = try Droidmatch_V1_DiagnosticsRequest(serializedBytes: request.payload)
            var diagnostics = Droidmatch_V1_DiagnosticsResponse()
            diagnostics.transport = .adb
            diagnostics.serviceState = "rpc.session.open"
            diagnostics.recentErrors = [
                localDiagnosticEvent(
                    kind: "error",
                    code: "rpc.envelope.invalid:InvalidProtocolBufferException",
                    message: "bad wire payload"
                )
            ]
            diagnostics.counters = ["rpc.frames.received": "4"]
            diagnostics.recentEvents = [
                localDiagnosticEvent(kind: "state", code: "rpc.session.open"),
                localDiagnosticEvent(kind: "state", code: "permission.media_read:GRANTED")
            ]
            response.payloadType = .diagnosticsResponse
            response.payload = try diagnostics.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: true)
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    static func listDirPermissionRequiredResponse(
        to requestBody: Data,
        didHandshake: Bool
    ) throws -> LocalControlPlaneResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        if !didHandshake {
            guard request.payloadType == .clientHello else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            return LocalControlPlaneResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false
            )
        }

        guard request.payloadType == .listDirRequest else {
            throw LocalEchoServerError.unexpectedPayloadType
        }
        let listDirRequest = try Droidmatch_V1_ListDirRequest(serializedBytes: request.payload)
        guard listDirRequest.path == "dm://media-images/" else {
            throw LocalEchoServerError.unexpectedPayloadType
        }

        var error = Droidmatch_V1_DroidMatchError()
        error.code = .permissionRequired
        error.message = "media permission is required"
        var listDirResponse = Droidmatch_V1_ListDirResponse()
        listDirResponse.error = error
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .listDirResponse
        response.payload = try listDirResponse.serializedData()
        return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: true)
    }

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
