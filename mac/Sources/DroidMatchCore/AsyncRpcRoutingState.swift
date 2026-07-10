import Foundation

enum AsyncRpcMultiplexerLifecycle: Equatable {
    case idle
    case active
    case closed
}

struct AsyncRpcRequestIDAllocator {
    private var nextRequestID: UInt64 = 1

    mutating func allocate(occupied: Set<UInt64>) throws -> UInt64 {
        for _ in 0..<64 {
            let requestID = nextRequestID
            nextRequestID = requestID == UInt64.max ? 1 : requestID + 1
            if !occupied.contains(requestID) {
                return requestID
            }
        }
        throw RpcControlClientError.invalidTransferState(
            "could not allocate a free request_id within the bounded in-flight window"
        )
    }
}

/// Correlation state for one pending control response.
struct AsyncRpcPendingResponse {
    let waiter: AsyncRpcOneShot<Data>
    var timeoutTask: Task<Void, Never>?
}

/// Actor-owned download routing state. This value never reads the socket.
struct AsyncRpcDownloadRoute {
    let requestID: UInt64
    let transferID: String
    let openWaiter: AsyncRpcOneShot<Data>
    let chunkQueue: AsyncDownloadChunkQueue
    var openTimeoutTask: Task<Void, Never>?
    var openResponse: Droidmatch_V1_OpenTransferResponse?
    var nextExpectedOffsetBytes: Int64 = 0
    var outstandingChunks: [Droidmatch_V1_TransferChunk] = []
    var finalChunkReceived = false
}

/// Metadata kept in exact wire-send order. Android processes upload chunks
/// sequentially, so acknowledgements must retire this queue from the head.
struct AsyncRpcPendingUploadAcknowledgement {
    let waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>
    var timeoutTask: Task<Void, Never>?
}

/// Actor-owned upload routing state. This value never sends a frame itself.
struct AsyncRpcUploadRoute {
    let requestID: UInt64
    let transferID: String
    let openWaiter: AsyncRpcOneShot<Data>
    var openTimeoutTask: Task<Void, Never>?
    var openResponse: Droidmatch_V1_OpenTransferResponse?
    var uploadWindow = UploadWindow(startingOffsetBytes: 0)
    var outstandingAcknowledgements: [AsyncRpcPendingUploadAcknowledgement] = []
}

/// Pure validation shared by the actor's send and single-reader routing paths.
/// It owns no task, waiter, socket, or mutable route table.
enum AsyncRpcTransferValidation {
    static let maxConcurrentTransfers = 2
    static let maxDownloadInFlightChunks = 4
    static let maxDownloadInFlightBytes = 2 * 1024 * 1024
    static let maxTransferChunkBytes = 1024 * 1024

    static func preflightUploadWindow(
        route: AsyncRpcUploadRoute?,
        chunks: [AsyncUploadChunk]
    ) throws {
        guard !chunks.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "an upload window must contain at least one chunk"
            )
        }
        guard let route, let open = route.openResponse else {
            throw RpcControlClientError.invalidTransferState("upload stream is not active")
        }
        var window = route.uploadWindow
        for chunk in chunks {
            try validateUploadChunk(
                open: open,
                window: window,
                offsetBytes: chunk.offsetBytes,
                data: chunk.data,
                finalChunk: chunk.finalChunk
            )
            window.recordSent(
                offsetBytes: chunk.offsetBytes,
                dataLength: chunk.data.count,
                finalChunk: chunk.finalChunk
            )
        }
    }

    static func validateUploadChunk(
        open: Droidmatch_V1_OpenTransferResponse,
        window: UploadWindow,
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) throws {
        guard !window.finalChunkSent else {
            throw RpcControlClientError.invalidTransferState(
                "upload stream already sent its final chunk"
            )
        }
        guard offsetBytes == window.nextSendOffsetBytes else {
            throw RpcControlClientError.offsetMismatch(
                expected: window.nextSendOffsetBytes,
                actual: offsetBytes
            )
        }
        guard data.count <= Int(open.chunkSizeBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "upload chunk exceeds negotiated chunk size"
            )
        }
        guard !data.isEmpty || finalChunk else {
            throw RpcControlClientError.invalidTransferState(
                "empty upload chunks must be final"
            )
        }
        guard !data.isEmpty || window.outstandingChunkCount == 0 else {
            throw RpcControlClientError.invalidTransferState(
                "an empty final upload chunk must wait for earlier chunks to be acknowledged"
            )
        }
        let nextOffset = try validatedEndOffset(
            offsetBytes: offsetBytes,
            dataCount: data.count
        )
        if open.totalSizeBytes >= 0 {
            guard nextOffset <= open.totalSizeBytes,
                  !finalChunk || nextOffset == open.totalSizeBytes else {
                throw RpcControlClientError.invalidTransferState(
                    "upload chunk does not match negotiated total size"
                )
            }
        }
        guard window.outstandingChunkCount < UploadWindow.maxInFlightChunks else {
            throw RpcControlClientError.invalidTransferState(
                "upload stream reached the four-chunk in-flight limit; await an ACK before sending more"
            )
        }
        guard window.outstandingByteCount + Int64(data.count)
                <= UploadWindow.maxInFlightBytes else {
            throw RpcControlClientError.invalidTransferState(
                "upload stream reached the 2 MiB in-flight limit; await an ACK before sending more"
            )
        }
    }

    static func validateTransferReservation(
        transferID: String,
        downloads: [UInt64: AsyncRpcDownloadRoute],
        uploads: [UInt64: AsyncRpcUploadRoute]
    ) throws {
        guard !transferID.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "transfer_id must be non-empty"
            )
        }
        guard downloads.count + uploads.count < maxConcurrentTransfers else {
            throw RpcControlClientError.invalidTransferState(
                "at most two transfer streams may be active in one session"
            )
        }
        let duplicateDownload = downloads.values.contains { $0.transferID == transferID }
        let duplicateUpload = uploads.values.contains { $0.transferID == transferID }
        guard !duplicateDownload, !duplicateUpload else {
            throw RpcControlClientError.invalidTransferState(
                "transfer_id is already active in this session"
            )
        }
    }

    static func validateOpenResponse(
        _ response: Droidmatch_V1_OpenTransferResponse,
        requestID: UInt64,
        transferID: String
    ) throws {
        guard response.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: response.transferID
            )
        }
        guard response.streamID != 0 else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned stream_id=0 for an active transfer"
            )
        }
        guard response.chunkSizeBytes > 0,
              response.chunkSizeBytes <= UInt32(maxTransferChunkBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned an invalid chunk_size_bytes"
            )
        }
        guard response.acceptedOffsetBytes >= 0,
              response.totalSizeBytes >= -1,
              (response.totalSizeBytes < 0
                || response.acceptedOffsetBytes <= response.totalSizeBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned invalid transfer offsets for request_id \(requestID)"
            )
        }
    }

    static func validateUniqueStreamID(
        _ streamID: UInt64,
        excludingRequestID: UInt64,
        downloads: [UInt64: AsyncRpcDownloadRoute],
        uploads: [UInt64: AsyncRpcUploadRoute]
    ) throws {
        let downloadCollision = downloads.values.contains {
            $0.requestID != excludingRequestID && $0.openResponse?.streamID == streamID
        }
        let uploadCollision = uploads.values.contains {
            $0.requestID != excludingRequestID && $0.openResponse?.streamID == streamID
        }
        guard !downloadCollision, !uploadCollision else {
            throw RpcControlClientError.invalidTransferState(
                "remote reused an active stream_id"
            )
        }
    }

    static func validatedEndOffset(
        _ chunk: Droidmatch_V1_TransferChunk
    ) throws -> Int64 {
        try validatedEndOffset(
            offsetBytes: chunk.offsetBytes,
            dataCount: chunk.data.count
        )
    }

    static func validatedEndOffset(
        offsetBytes: Int64,
        dataCount: Int
    ) throws -> Int64 {
        let (endOffset, overflow) = offsetBytes.addingReportingOverflow(Int64(dataCount))
        guard !overflow else {
            throw RpcControlClientError.invalidTransferState(
                "transfer chunk end offset overflowed Int64"
            )
        }
        return endOffset
    }

    static func isRemoteApplicationError(_ error: any Error) -> Bool {
        guard let rpcError = error as? RpcControlClientError else { return false }
        if case .remoteError = rpcError { return true }
        return false
    }
}
