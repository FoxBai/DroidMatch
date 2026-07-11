import Foundation
import Network
@testable import DroidMatchCore

extension LocalFrameTestServer {
    /// Reads one bounded download control/ACK frame and continues until final.
    static func readMultiChunkDownloadRequest(
        on connection: NWConnection,
        chunks: [Data],
        nextChunkIndex: Int,
        transferID: String?
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
                      let response = try? multiChunkDownloadResponse(
                          to: body,
                          chunks: chunks,
                          nextChunkIndex: nextChunkIndex,
                          transferID: transferID
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readMultiChunkDownloadRequest(
                            on: connection,
                            chunks: chunks,
                            nextChunkIndex: response.nextChunkIndex,
                            transferID: response.transferID
                        )
                    }
                }
            }
        }
    }
}
