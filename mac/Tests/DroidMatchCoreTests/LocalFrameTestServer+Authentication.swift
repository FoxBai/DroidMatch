import Foundation
import Network
@testable import DroidMatchCore

extension LocalFrameTestServer {
    static func replyWithServerHello(on connection: NWConnection) {
        replyWithServerHello(on: connection, authenticationState: .correlated)
    }

    static func replyWithPairingRequiredServerHello(on connection: NWConnection) {
        replyWithServerHello(on: connection, authenticationState: .pairingRequired)
    }

    static func replyWithServerHello(
        on connection: NWConnection,
        authenticationState: Droidmatch_V1_AuthenticationState
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
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                guard let response = try? handshakeResponse(
                    to: body,
                    authenticationState: authenticationState
                ),
                      let frame = try? FrameCodec().encode(payload: response) else {
                    connection.cancel()
                    return
                }
                connection.send(content: frame, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// 回复 ServerHello 让 handshake 成功，然后立即断开连接。
    /// 用于端到端恢复队列测试：客户端 handshake 成功后，download 阶段
    /// 第一次 read 会遇到 `connectionClosed`（可重试错误）。
    static func replyWithServerHelloThenDrop(on connection: NWConnection) {
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
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                guard let response = try? handshakeResponse(to: body),
                      let frame = try? FrameCodec().encode(payload: response) else {
                    connection.cancel()
                    return
                }
                // 发完 ServerHello 立刻断连，模拟传输中断。
                connection.send(content: frame, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    static func pairedAuthenticationHandler(
        pairingID: Data,
        pairingKey: Data,
        corruptServerProof: Bool = false,
        allowMissingPairingID: Bool = false,
        grantedCapabilities: [Droidmatch_V1_Capability] = [.diagnostics],
        afterAuthentication: (@Sendable (NWConnection) -> Void)? = nil
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            readPairedClientHello(
                on: connection,
                pairingID: pairingID,
                pairingKey: pairingKey,
                corruptServerProof: corruptServerProof,
                allowMissingPairingID: allowMissingPairingID,
                grantedCapabilities: grantedCapabilities,
                afterAuthentication: afterAuthentication
            )
        }
    }

    static func readPairedClientHello(
        on connection: NWConnection,
        pairingID: Data,
        pairingKey: Data,
        corruptServerProof: Bool,
        allowMissingPairingID: Bool,
        grantedCapabilities: [Droidmatch_V1_Capability],
        afterAuthentication: (@Sendable (NWConnection) -> Void)?
    ) {
        receiveFrameBody(on: connection) { requestBody in
            do {
                let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
                guard request.payloadType == .clientHello else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                let clientHello = try Droidmatch_V1_ClientHello(serializedBytes: request.payload)
                guard clientHello.pairingID == pairingID
                        || (allowMissingPairingID && clientHello.pairingID.isEmpty) else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }

                let serverNonce = Data((0..<SessionAuthenticator.nonceLength).map {
                    UInt8(0x40 + $0)
                })
                var serverHello = Droidmatch_V1_ServerHello()
                serverHello.serverName = "PairedLocalFrameTestServer"
                serverHello.serverVersion = "test"
                serverHello.protocolMajor = 1
                serverHello.protocolMinor = min(clientHello.protocolMinor, 0)
                serverHello.transport = .adb
                serverHello.sessionNonce = clientHello.sessionNonce
                serverHello.serverNonce = serverNonce
                serverHello.deviceIdentityFingerprint = pairedDeviceIdentityFingerprint
                serverHello.authenticationState = .required

                var response = Droidmatch_V1_RpcEnvelope()
                response.frameVersion = 1
                response.kind = .response
                response.requestID = request.requestID
                response.payloadType = .serverHello
                response.payload = try serverHello.serializedData()
                send([try response.serializedData()], on: connection) {
                    readPairedProof(
                        on: connection,
                        pairingID: pairingID,
                        pairingKey: pairingKey,
                        clientNonce: clientHello.sessionNonce,
                        serverNonce: serverNonce,
                        corruptServerProof: corruptServerProof,
                        grantedCapabilities: grantedCapabilities,
                        afterAuthentication: afterAuthentication
                    )
                }
            } catch {
                connection.cancel()
            }
        }
    }

    static func readPairedProof(
        on connection: NWConnection,
        pairingID: Data,
        pairingKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        corruptServerProof: Bool,
        grantedCapabilities: [Droidmatch_V1_Capability],
        afterAuthentication: (@Sendable (NWConnection) -> Void)?
    ) {
        receiveFrameBody(on: connection) { requestBody in
            do {
                let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
                guard request.payloadType == .authenticateSessionRequest else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                let authentication = try Droidmatch_V1_AuthenticateSessionRequest(
                    serializedBytes: request.payload
                )
                let transcript = try SessionAuthenticator.transcript(
                    pairingID: pairingID,
                    clientNonce: clientNonce,
                    serverNonce: serverNonce,
                    protocolMajor: 1,
                    protocolMinor: 0,
                    transport: .adb
                )
                let transcriptHash = SessionAuthenticator.transcriptHash(transcript)
                let valid = try authentication.pairingID == pairingID
                    && SessionAuthenticator.verifyClientProof(
                        authentication.clientProof,
                        pairingKey: pairingKey,
                        transcriptHash: transcriptHash
                    )

                var authenticationResponse = Droidmatch_V1_AuthenticateSessionResponse()
                authenticationResponse.authenticated = valid
                if valid {
                    var serverProof = try SessionAuthenticator.serverProof(
                        pairingKey: pairingKey,
                        transcriptHash: transcriptHash
                    )
                    if corruptServerProof {
                        serverProof[serverProof.startIndex] ^= 0x01
                    }
                    authenticationResponse.serverProof = serverProof
                    authenticationResponse.grantedCapabilities = grantedCapabilities
                } else {
                    var error = Droidmatch_V1_DroidMatchError()
                    error.code = .unauthorized
                    error.message = "session authentication failed"
                    authenticationResponse.error = error
                }

                var response = Droidmatch_V1_RpcEnvelope()
                response.frameVersion = 1
                response.kind = .response
                response.requestID = request.requestID
                response.payloadType = .authenticateSessionResponse
                response.payload = try authenticationResponse.serializedData()
                send([try response.serializedData()], on: connection) {
                    if valid, let afterAuthentication {
                        afterAuthentication(connection)
                    } else {
                        connection.cancel()
                    }
                }
            } catch {
                connection.cancel()
            }
        }
    }

}
