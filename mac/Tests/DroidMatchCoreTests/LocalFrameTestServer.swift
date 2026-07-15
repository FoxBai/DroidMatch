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

    static func replyToM1SmokeRequests(on connection: NWConnection) {
        readM1SmokeRequest(on: connection)
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
