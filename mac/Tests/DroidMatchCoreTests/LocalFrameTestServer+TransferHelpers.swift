import Foundation
@testable import DroidMatchCore

/// Pure fixture construction kept separate from the stateful local transfer server.
extension LocalFrameTestServer {
    static func chunkIndex(forOffset offset: Int64, chunks: [Data]) -> Int? {
        guard offset >= 0 else {
            return nil
        }
        var runningOffset: Int64 = 0
        for (index, chunk) in chunks.enumerated() {
            if runningOffset == offset {
                return index
            }
            runningOffset += Int64(chunk.count)
        }
        return runningOffset == offset ? chunks.count : nil
    }

    static func loopbackTransferFingerprint() -> Droidmatch_V1_TransferFingerprint {
        var fingerprint = Droidmatch_V1_TransferFingerprint()
        fingerprint.sizeBytes = 14
        fingerprint.modifiedUnixMillis = 1_700_000_000_000
        fingerprint.providerEtag = "loopback-etag"
        return fingerprint
    }

    static func transferChunkEnvelope(
        request: Droidmatch_V1_RpcEnvelope,
        transferID: String,
        offset: Int64,
        data: Data,
        finalChunk: Bool
    ) throws -> Data {
        var chunk = Droidmatch_V1_TransferChunk()
        chunk.transferID = transferID
        chunk.offsetBytes = offset
        chunk.data = data
        chunk.crc32 = Crc32.checksum(data)
        chunk.finalChunk = finalChunk
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = request.requestID
        envelope.streamID = request.streamID == 0 ? request.requestID : request.streamID
        envelope.payloadType = .transferChunk
        envelope.payload = try chunk.serializedData()
        return try envelope.serializedData()
    }

    static func localDiagnosticEvent(kind: String, code: String, message: String? = nil) -> String {
        let base = "1:local-frame-test:\(kind):\(code)"
        if let message, !message.isEmpty {
            return "\(base):\(message)"
        }
        return base
    }
}
