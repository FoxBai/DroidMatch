import Foundation

/// Value-only response fixtures shared by the local framed transfer server.
struct LocalControlPlaneResponse {
    let payloads: [Data]
    let isFinal: Bool
}

struct LocalMultiChunkDownloadResponse {
    let payloads: [Data]
    let isFinal: Bool
    let nextChunkIndex: Int
    let transferID: String?
}

struct LocalUploadResponse {
    let payloads: [Data]
    let isFinal: Bool
    let received: Data
    let transferID: String?
    let expectedSizeBytes: Int64
    let streamID: UInt64?
}
