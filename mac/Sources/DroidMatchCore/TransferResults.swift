public struct DownloadResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunkCount: Int
    public let bytesReceived: Int64
    public let finalOffsetBytes: Int64

    public init(
        openResponse: Droidmatch_V1_OpenTransferResponse,
        chunkCount: Int,
        bytesReceived: Int64,
        finalOffsetBytes: Int64
    ) {
        self.openResponse = openResponse
        self.chunkCount = chunkCount
        self.bytesReceived = bytesReceived
        self.finalOffsetBytes = finalOffsetBytes
    }
}

public struct UploadResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunkCount: Int
    public let bytesSent: Int64
    public let finalOffsetBytes: Int64

    public init(
        openResponse: Droidmatch_V1_OpenTransferResponse,
        chunkCount: Int,
        bytesSent: Int64,
        finalOffsetBytes: Int64
    ) {
        self.openResponse = openResponse
        self.chunkCount = chunkCount
        self.bytesSent = bytesSent
        self.finalOffsetBytes = finalOffsetBytes
    }
}
