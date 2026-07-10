import Foundation
import Network
@testable import DroidMatchCore

enum LocalEchoServerError: Error {
    case listenerDidNotBecomeReady
    case missingPort
    case unexpectedPayloadType
}

enum LocalUploadStop: Error {
    case stopAfterLimit
}

final class LocalFrameTestServer: @unchecked Sendable {
    static let pairedDeviceIdentityFingerprint = Data(
        repeating: 0x5a,
        count: PairingAuthenticator.digestLength
    )
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.droidmatch.tests.local-framed-echo")

    let port: Int

    init(handler: @escaping @Sendable (NWConnection) -> Void) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            handler(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            throw LocalEchoServerError.listenerDidNotBecomeReady
        }
        guard let rawPort = listener.port?.rawValue else {
            throw LocalEchoServerError.missingPort
        }
        port = Int(rawPort)
    }

    func cancel() {
        listener.cancel()
    }

    static func echoOneFrame(on connection: NWConnection) {
        echoFrames(1, on: connection)
    }

    static func echoFrames(
        _ remaining: Int,
        delayBeforeResponse: TimeInterval = 0,
        on connection: NWConnection
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
                var frame = Data()
                frame.append(header)
                frame.append(body)
                let responseFrame = frame
                let sendResponse: @Sendable () -> Void = {
                    connection.send(content: responseFrame, completion: .contentProcessed { error in
                        guard error == nil, remaining > 1 else {
                            connection.cancel()
                            return
                        }
                        echoFrames(remaining - 1, on: connection)
                    })
                }
                if delayBeforeResponse > 0 {
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + delayBeforeResponse,
                        execute: sendResponse
                    )
                } else {
                    sendResponse()
                }
            }
        }
    }

    static func sendTwoFramesTogether(on connection: NWConnection) {
        guard let first = try? FrameCodec().encode(payload: Data("first".utf8)),
              let second = try? FrameCodec().encode(payload: Data("second".utf8)) else {
            connection.cancel()
            return
        }
        var combined = Data()
        combined.append(first)
        combined.append(second)
        connection.send(content: combined, completion: .contentProcessed { _ in })
    }

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

    static func replyToM1SmokeRequests(on connection: NWConnection) {
        readM1SmokeRequest(on: connection)
    }

    static func pairedAuthenticationHandler(
        pairingID: Data,
        pairingKey: Data,
        corruptServerProof: Bool = false,
        allowMissingPairingID: Bool = false
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            readPairedClientHello(
                on: connection,
                pairingID: pairingID,
                pairingKey: pairingKey,
                corruptServerProof: corruptServerProof,
                allowMissingPairingID: allowMissingPairingID
            )
        }
    }

    static func replyToBadChecksumDownloadRequests(on connection: NWConnection) {
        readM1SmokeRequest(on: connection, corruptDownloadCrc: true)
    }

    static func replyToMultiChunkDownloadRequests(on connection: NWConnection) {
        readMultiChunkDownloadRequest(
            on: connection,
            chunks: [Data("download".utf8), Data("-bytes".utf8)],
            nextChunkIndex: 0,
            transferID: nil
        )
    }

    static func replyToUploadRequests(on connection: NWConnection) {
        readUploadRequest(
            on: connection,
            received: Data(),
            transferID: nil,
            expectedSizeBytes: 0,
            streamID: nil
        )
    }

    /// 泛化 upload echo 服务器：接受任意 payload 和 transfer id，逐 chunk
    /// 校验 offset/CRC、按顺序回 ACK。用于窗口化端到端测试（payload 大到
    /// 需要多于 maxInFlightChunks 个 chunk，触发"窗口满 → ACK → 补发"路径）。
    static func replyToUploadRequestsEchoing(
        payload: Data,
        transferID: String,
        destinationPath: String,
        chunkSize: Int
    ) -> (@Sendable (NWConnection) -> Void) {
        { connection in
            readUploadRequestEchoing(
                on: connection,
                received: Data(),
                transferID: nil,
                expectedSizeBytes: Int64(payload.count),
                expectedTotalPayload: payload,
                expectedTransferID: transferID,
                expectedDestinationPath: destinationPath,
                streamID: nil
            )
        }
    }

    static func replyToUploadResumeRequests(on connection: NWConnection) {
        readUploadRequest(
            on: connection,
            received: Data("upload-".utf8),
            transferID: nil,
            expectedSizeBytes: Int64(Data("upload-bytes".utf8).count),
            streamID: nil
        )
    }

    static func replyToUploadOpenUnsupportedRequests(on connection: NWConnection) {
        readUploadOpenUnsupportedRequest(on: connection)
    }

    static func replyToDownloadOpenNotFoundRequests(on connection: NWConnection) {
        readDownloadOpenNotFoundRequest(on: connection)
    }

    static func replyToListDirPermissionRequiredRequests(on connection: NWConnection) {
        readListDirPermissionRequiredRequest(on: connection, didHandshake: false)
    }

    static func sendEmptyFrameHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
            connection.send(content: Data([0, 0, 0, 0]), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    static func readListDirPermissionRequiredRequest(on connection: NWConnection, didHandshake: Bool) {
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
                      let response = try? listDirPermissionRequiredResponse(
                          to: body,
                          didHandshake: didHandshake
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readListDirPermissionRequiredRequest(on: connection, didHandshake: true)
                    }
                }
            }
        }
    }

    static func readDownloadOpenNotFoundRequest(on connection: NWConnection) {
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
                      let response = try? downloadOpenNotFoundResponse(to: body) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readDownloadOpenNotFoundRequest(on: connection)
                    }
                }
            }
        }
    }

    static func readUploadOpenUnsupportedRequest(on connection: NWConnection) {
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
                      let response = try? uploadOpenUnsupportedResponse(to: body) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readUploadOpenUnsupportedRequest(on: connection)
                    }
                }
            }
        }
    }

    static func readM1SmokeRequest(
        on connection: NWConnection,
        corruptDownloadCrc: Bool = false
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
                guard let response = try? m1SmokeResponse(
                    to: body,
                    corruptDownloadCrc: corruptDownloadCrc
                ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readM1SmokeRequest(on: connection, corruptDownloadCrc: corruptDownloadCrc)
                    }
                }
            }
        }
    }

    static func readPairedClientHello(
        on connection: NWConnection,
        pairingID: Data,
        pairingKey: Data,
        corruptServerProof: Bool,
        allowMissingPairingID: Bool
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
                        corruptServerProof: corruptServerProof
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
        corruptServerProof: Bool
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
                    authenticationResponse.grantedCapabilities = [.diagnostics]
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
                    connection.cancel()
                }
            } catch {
                connection.cancel()
            }
        }
    }

    static func receiveFrameBody(
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


}
