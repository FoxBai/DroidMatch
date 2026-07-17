import Foundation
import Network
@testable import DroidMatchCore

extension LocalFrameTestServer {
    static func readDiscardUploadPartialRequest(on connection: NWConnection) {
        receiveFrameBody(on: connection) { requestBody in
            do {
                let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
                guard request.payloadType == .discardUploadPartialRequest else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                let discard = try Droidmatch_V1_DiscardUploadPartialRequest(
                    serializedBytes: request.payload
                )
                guard discard.transferID == "discard-wire-transfer",
                      discard.destinationPath == "dm://app-sandbox/discard-wire.bin",
                      discard.expectedSizeBytes == 42 else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                var payload = Droidmatch_V1_DiscardUploadPartialResponse()
                payload.transferID = discard.transferID
                payload.ok = true
                var response = Droidmatch_V1_RpcEnvelope()
                response.frameVersion = 1
                response.kind = .response
                response.requestID = request.requestID
                response.payloadType = .discardUploadPartialResponse
                response.payload = try payload.serializedData()
                send([try response.serializedData()], on: connection) {
                    connection.cancel()
                }
            } catch {
                connection.cancel()
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
        case .createDirectoryRequest, .renamePathRequest, .deletePathRequest:
            return try browserMutationResponse(to: request)
        case .thumbnailRequest:
            return try browserThumbnailResponse(to: request)
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
}
