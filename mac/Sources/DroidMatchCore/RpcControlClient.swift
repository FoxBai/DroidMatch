import Foundation
import SwiftProtobuf

public struct DownloadOnceResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunk: Droidmatch_V1_TransferChunk
}

public struct DownloadResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunkCount: Int
    public let bytesReceived: Int64
    public let finalOffsetBytes: Int64
}

public struct UploadResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunkCount: Int
    public let bytesSent: Int64
    public let finalOffsetBytes: Int64
}

public struct CancelDownloadResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunk: Droidmatch_V1_TransferChunk
    public let cancelResponse: Droidmatch_V1_CancelTransferResponse
}

public struct PauseDownloadResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunk: Droidmatch_V1_TransferChunk
    public let pauseResponse: Droidmatch_V1_PauseTransferResponse
}

public final class RpcControlClient {
    private let session: FramedTcpSession
    private var nextRequestID: UInt64 = 1

    public init(session: FramedTcpSession) {
        self.session = session
    }

    public func handshake() throws -> HandshakeSmokeResult {
        let requestID = allocateRequestID()
        let handshakeClient = HandshakeSmokeClient(
            requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities
        )
        let envelope = try handshakeClient.clientHelloEnvelope(requestID: requestID)
        let response = try session.roundTrip(payload: envelope.serializedData())
        return try handshakeClient.parseServerHelloResponse(response, expectedRequestID: requestID)
    }

    public func deviceInfo() throws -> Droidmatch_V1_DeviceInfoResponse {
        let requestID = allocateRequestID()
        let envelope = try requestEnvelope(
            payload: Droidmatch_V1_DeviceInfoRequest(),
            payloadType: .deviceInfoRequest,
            requestID: requestID
        )
        let response = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .deviceInfoResponse
        )
        return try Droidmatch_V1_DeviceInfoResponse(serializedBytes: response.payload)
    }

    public func heartbeat(monotonicMillis: Int64) throws -> Droidmatch_V1_HeartbeatResponse {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_HeartbeatRequest()
        request.monotonicMillis = monotonicMillis
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .heartbeatRequest,
            requestID: requestID
        )
        let response = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .heartbeatResponse
        )
        return try Droidmatch_V1_HeartbeatResponse(serializedBytes: response.payload)
    }

    public func diagnostics() throws -> Droidmatch_V1_DiagnosticsResponse {
        let requestID = allocateRequestID()
        let envelope = try requestEnvelope(
            payload: Droidmatch_V1_DiagnosticsRequest(),
            payloadType: .diagnosticsRequest,
            requestID: requestID
        )
        let response = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .diagnosticsResponse
        )
        return try Droidmatch_V1_DiagnosticsResponse(serializedBytes: response.payload)
    }

    public func listDir(path: String) throws -> Droidmatch_V1_ListDirResponse {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_ListDirRequest()
        request.path = path
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .listDirRequest,
            requestID: requestID
        )
        let response = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .listDirResponse
        )
        return try Droidmatch_V1_ListDirResponse(serializedBytes: response.payload)
    }

    public func downloadFirstChunk(
        sourcePath: String,
        destinationPath: String = "",
        transferID: String = UUID().uuidString,
        requestedOffsetBytes: Int64 = 0,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint? = nil,
        preferredChunkSizeBytes: UInt32 = 256 * 1024
    ) throws -> DownloadOnceResult {
        let opened = try openDownload(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            transferID: transferID,
            requestedOffsetBytes: requestedOffsetBytes,
            sourceFingerprint: sourceFingerprint,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let chunk = try receiveTransferChunk(
            requestID: opened.requestID,
            openResponse: opened.response,
            expectedOffsetBytes: opened.response.acceptedOffsetBytes
        )
        try sendTransferAck(
            transferID: chunk.transferID,
            requestID: opened.requestID,
            streamID: opened.response.streamID,
            nextOffsetBytes: chunk.offsetBytes + Int64(chunk.data.count),
            finalAck: chunk.finalChunk
        )

        return DownloadOnceResult(openResponse: opened.response, chunk: chunk)
    }

    public func download(
        sourcePath: String,
        destinationPath: String = "",
        transferID: String = UUID().uuidString,
        requestedOffsetBytes: Int64 = 0,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint? = nil,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        didOpen: ((Droidmatch_V1_OpenTransferResponse) throws -> Void)? = nil,
        receiveChunk: (Droidmatch_V1_TransferChunk) throws -> Void
    ) throws -> DownloadResult {
        let opened = try openDownload(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            transferID: transferID,
            requestedOffsetBytes: requestedOffsetBytes,
            sourceFingerprint: sourceFingerprint,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        try didOpen?(opened.response)

        var expectedOffset = opened.response.acceptedOffsetBytes
        var chunkCount = 0
        var bytesReceived: Int64 = 0

        while true {
            let chunk = try receiveTransferChunk(
                requestID: opened.requestID,
                openResponse: opened.response,
                expectedOffsetBytes: expectedOffset
            )
            try receiveChunk(chunk)

            let nextOffset = chunk.offsetBytes + Int64(chunk.data.count)
            try sendTransferAck(
                transferID: chunk.transferID,
                requestID: opened.requestID,
                streamID: opened.response.streamID,
                nextOffsetBytes: nextOffset,
                finalAck: chunk.finalChunk
            )

            chunkCount += 1
            bytesReceived += Int64(chunk.data.count)
            expectedOffset = nextOffset

            if chunk.finalChunk {
                return DownloadResult(
                    openResponse: opened.response,
                    chunkCount: chunkCount,
                    bytesReceived: bytesReceived,
                    finalOffsetBytes: expectedOffset
                )
            }
        }
    }

    public func downloadFirstChunkThenCancel(
        sourcePath: String,
        destinationPath: String = "",
        transferID: String = UUID().uuidString,
        requestedOffsetBytes: Int64 = 0,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint? = nil,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        reason: String = "mac-client-cancel"
    ) throws -> CancelDownloadResult {
        let opened = try openDownload(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            transferID: transferID,
            requestedOffsetBytes: requestedOffsetBytes,
            sourceFingerprint: sourceFingerprint,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let chunk = try receiveTransferChunk(
            requestID: opened.requestID,
            openResponse: opened.response,
            expectedOffsetBytes: opened.response.acceptedOffsetBytes
        )
        let cancelResponse = try cancelTransfer(
            transferID: chunk.transferID,
            reason: reason
        )

        return CancelDownloadResult(
            openResponse: opened.response,
            chunk: chunk,
            cancelResponse: cancelResponse
        )
    }

    public func downloadFirstChunkThenPause(
        sourcePath: String,
        destinationPath: String = "",
        transferID: String = UUID().uuidString,
        requestedOffsetBytes: Int64 = 0,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint? = nil,
        preferredChunkSizeBytes: UInt32 = 256 * 1024
    ) throws -> PauseDownloadResult {
        let opened = try openDownload(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            transferID: transferID,
            requestedOffsetBytes: requestedOffsetBytes,
            sourceFingerprint: sourceFingerprint,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let chunk = try receiveTransferChunk(
            requestID: opened.requestID,
            openResponse: opened.response,
            expectedOffsetBytes: opened.response.acceptedOffsetBytes
        )
        let pauseResponse = try pauseTransfer(transferID: chunk.transferID)

        return PauseDownloadResult(
            openResponse: opened.response,
            chunk: chunk,
            pauseResponse: pauseResponse
        )
    }

    public func upload(
        sourcePath: String,
        destinationPath: String,
        expectedSizeBytes: Int64,
        transferID: String = UUID().uuidString,
        requestedOffsetBytes: Int64 = 0,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        sendLimitBytes: Int64? = nil,
        didOpen: ((Droidmatch_V1_OpenTransferResponse) throws -> Void)? = nil,
        didAck: ((Droidmatch_V1_TransferChunkAck) throws -> Void)? = nil,
        readChunk: (Int64, Int) throws -> Data
    ) throws -> UploadResult {
        guard expectedSizeBytes >= 0 else {
            throw RpcControlClientError.invalidTransferState(
                "upload requires a known non-negative expected_size_bytes"
            )
        }
        guard requestedOffsetBytes >= 0, requestedOffsetBytes <= expectedSizeBytes else {
            throw RpcControlClientError.invalidTransferState(
                "upload requested_offset_bytes must be within expected_size_bytes"
            )
        }
        if let sendLimitBytes {
            guard sendLimitBytes >= requestedOffsetBytes, sendLimitBytes <= expectedSizeBytes else {
                throw RpcControlClientError.invalidTransferState(
                    "upload send_limit_bytes must be within requested_offset_bytes...expected_size_bytes"
                )
            }
        }
        let opened = try openUpload(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            transferID: transferID,
            requestedOffsetBytes: requestedOffsetBytes,
            expectedSizeBytes: expectedSizeBytes,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        try didOpen?(opened.response)
        guard opened.response.chunkSizeBytes > 0 else {
            throw RpcControlClientError.invalidTransferState("remote returned chunk_size_bytes=0")
        }
        guard opened.response.acceptedOffsetBytes >= 0,
              opened.response.acceptedOffsetBytes <= expectedSizeBytes else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned accepted_offset_bytes outside expected_size_bytes"
            )
        }
        let effectiveSendLimitBytes = sendLimitBytes ?? expectedSizeBytes
        guard effectiveSendLimitBytes >= opened.response.acceptedOffsetBytes else {
            throw RpcControlClientError.invalidTransferState(
                "upload send_limit_bytes is before accepted_offset_bytes"
            )
        }
        if effectiveSendLimitBytes == opened.response.acceptedOffsetBytes,
           effectiveSendLimitBytes < expectedSizeBytes {
            throw RpcControlClientError.invalidTransferState(
                "upload send_limit_bytes must advance beyond accepted_offset_bytes"
            )
        }

        let chunkSize = Int(opened.response.chunkSizeBytes)
        // 滑动窗口：从 accepted offset 起算，对称 Android DownloadTransfer。
        // 之前是 stop-and-wait（每发一个 chunk 阻塞等 ACK），现在允许最多
        // maxInFlightChunks 个 chunk 在途，ACK 到达后补发新 chunk 填满窗口。
        var window = UploadWindow(startingOffsetBytes: opened.response.acceptedOffsetBytes)
        var chunkCount = 0
        var bytesSent: Int64 = 0

        while true {
            // `sendLimitBytes` lets the harness stop after an acknowledged partial
            // boundary without pretending the local file ended early.
            // `sendLimitBytes` 用于 partial/resume 测试：到边界后等 ACK，
            // 由调用方在 didAck 中抛出“故意中断”的错误。
            // 补满窗口：在窗口未满且源文件未读完时连续发送 chunk。
            // sendTransferChunk 是同步的（发完才返回），所以单线程内即可
            // 把多个 chunk 推入管道，不需要并发线程。
            while window.canSendMore(
                chunkSizeBytes: chunkSize,
                remainingBytes: effectiveSendLimitBytes - window.nextSendOffsetBytes
            ) {
                let offset = window.nextSendOffsetBytes
                let remainingExpectedBytes = expectedSizeBytes - offset
                let remainingSendBytes = effectiveSendLimitBytes - offset
                let requestedBytes = Int(min(Int64(chunkSize), remainingExpectedBytes, remainingSendBytes))
                let data = try readChunk(offset, requestedBytes)
                if data.count > chunkSize {
                    throw RpcControlClientError.invalidTransferState(
                        "local upload chunk exceeds negotiated chunk size"
                    )
                }
                if Int64(data.count) > remainingExpectedBytes {
                    throw RpcControlClientError.invalidTransferState(
                        "local upload source returned more bytes than expected"
                    )
                }
                if Int64(data.count) > remainingSendBytes {
                    throw RpcControlClientError.invalidTransferState(
                        "local upload source returned more bytes than send_limit_bytes"
                    )
                }
                let finalChunk = Int64(data.count) == remainingExpectedBytes
                if data.isEmpty && !finalChunk {
                    throw RpcControlClientError.invalidTransferState(
                        "local upload source ended before expected_size_bytes"
                    )
                }

                try sendTransferChunk(
                    transferID: opened.response.transferID,
                    requestID: opened.requestID,
                    streamID: opened.response.streamID,
                    offsetBytes: offset,
                    data: data,
                    finalChunk: finalChunk
                )
                window.recordSent(offsetBytes: offset, dataLength: data.count, finalChunk: finalChunk)
                chunkCount += 1
                bytesSent += Int64(data.count)
            }

            // 窗口已满或源文件已读完，阻塞等一个 ACK。
            // ACK 按发送顺序到达（Android 顺序处理 + 顺序回 ACK），
            // 由 UploadWindow.recordAck 按队首校验。
            let ack = try receiveTransferAck(
                requestID: opened.requestID,
                streamID: opened.response.streamID,
                transferID: opened.response.transferID
            )
            let result = try window.recordAck(
                nextOffsetBytes: ack.nextOffsetBytes,
                finalAck: ack.finalAck
            )
            try didAck?(ack)

            if result.finalAcknowledged {
                return UploadResult(
                    openResponse: opened.response,
                    chunkCount: chunkCount,
                    bytesSent: bytesSent,
                    finalOffsetBytes: ack.nextOffsetBytes
                )
            }
            if window.outstandingChunkCount == 0,
               window.nextSendOffsetBytes >= effectiveSendLimitBytes,
               effectiveSendLimitBytes < expectedSizeBytes {
                throw RpcControlClientError.invalidTransferState(
                    "upload send_limit_bytes reached before final acknowledgement"
                )
            }
        }
    }

    public func cancelTransfer(
        transferID: String,
        reason: String = ""
    ) throws -> Droidmatch_V1_CancelTransferResponse {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_CancelTransferRequest()
        request.transferID = transferID
        request.reason = reason
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .cancelTransferRequest,
            requestID: requestID
        )
        let responseEnvelope = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .cancelTransferResponse
        )
        let response = try Droidmatch_V1_CancelTransferResponse(serializedBytes: responseEnvelope.payload)
        if response.hasError {
            throw RpcControlClientError.remoteError(response.error)
        }
        guard response.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: response.transferID
            )
        }
        return response
    }

    public func pauseTransfer(
        transferID: String
    ) throws -> Droidmatch_V1_PauseTransferResponse {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_PauseTransferRequest()
        request.transferID = transferID
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .pauseTransferRequest,
            requestID: requestID
        )
        let responseEnvelope = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .pauseTransferResponse
        )
        let response = try Droidmatch_V1_PauseTransferResponse(serializedBytes: responseEnvelope.payload)
        if response.hasError {
            throw RpcControlClientError.remoteError(response.error)
        }
        guard response.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: response.transferID
            )
        }
        return response
    }

    private func openDownload(
        sourcePath: String,
        destinationPath: String,
        transferID: String,
        requestedOffsetBytes: Int64,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint?,
        preferredChunkSizeBytes: UInt32
    ) throws -> (requestID: UInt64, response: Droidmatch_V1_OpenTransferResponse) {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .download
        request.sourcePath = sourcePath
        request.destinationPath = destinationPath
        request.requestedOffsetBytes = requestedOffsetBytes
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        if let sourceFingerprint {
            request.sourceFingerprint = sourceFingerprint
        }
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        )
        try session.sendPayload(envelope.serializedData())

        let responseEnvelope = try parseEnvelope(try session.receivePayload())
        if responseEnvelope.kind == .error {
            throw RpcControlClientError.remoteError(try errorPayload(from: responseEnvelope))
        }
        guard responseEnvelope.kind == .response, responseEnvelope.payloadType == .openTransferResponse else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: responseEnvelope.kind,
                payloadType: responseEnvelope.payloadType
            )
        }
        guard responseEnvelope.requestID == requestID else {
            throw RpcControlClientError.requestIDMismatch(expected: requestID, actual: responseEnvelope.requestID)
        }
        let openResponse = try Droidmatch_V1_OpenTransferResponse(serializedBytes: responseEnvelope.payload)
        if openResponse.hasError {
            throw RpcControlClientError.remoteError(openResponse.error)
        }
        guard openResponse.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: openResponse.transferID
            )
        }
        return (requestID: requestID, response: openResponse)
    }

    private func openUpload(
        sourcePath: String,
        destinationPath: String,
        transferID: String,
        requestedOffsetBytes: Int64,
        expectedSizeBytes: Int64,
        preferredChunkSizeBytes: UInt32
    ) throws -> (requestID: UInt64, response: Droidmatch_V1_OpenTransferResponse) {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .upload
        request.sourcePath = sourcePath
        request.destinationPath = destinationPath
        request.requestedOffsetBytes = requestedOffsetBytes
        request.expectedSizeBytes = expectedSizeBytes
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        )
        try session.sendPayload(envelope.serializedData())

        let responseEnvelope = try parseEnvelope(try session.receivePayload())
        if responseEnvelope.kind == .error {
            throw RpcControlClientError.remoteError(try errorPayload(from: responseEnvelope))
        }
        guard responseEnvelope.kind == .response, responseEnvelope.payloadType == .openTransferResponse else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: responseEnvelope.kind,
                payloadType: responseEnvelope.payloadType
            )
        }
        guard responseEnvelope.requestID == requestID else {
            throw RpcControlClientError.requestIDMismatch(expected: requestID, actual: responseEnvelope.requestID)
        }
        let openResponse = try Droidmatch_V1_OpenTransferResponse(serializedBytes: responseEnvelope.payload)
        if openResponse.hasError {
            throw RpcControlClientError.remoteError(openResponse.error)
        }
        guard openResponse.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: openResponse.transferID
            )
        }
        guard openResponse.streamID != 0 else {
            throw RpcControlClientError.invalidTransferState("remote returned stream_id=0 for upload")
        }
        return (requestID: requestID, response: openResponse)
    }

    private func receiveTransferChunk(
        requestID: UInt64,
        openResponse: Droidmatch_V1_OpenTransferResponse,
        expectedOffsetBytes: Int64
    ) throws -> Droidmatch_V1_TransferChunk {
        let chunkEnvelope = try parseEnvelope(try session.receivePayload())
        if chunkEnvelope.kind == .error {
            throw RpcControlClientError.remoteError(try errorPayload(from: chunkEnvelope))
        }
        guard chunkEnvelope.kind == .stream, chunkEnvelope.payloadType == .transferChunk else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: chunkEnvelope.kind,
                payloadType: chunkEnvelope.payloadType
            )
        }
        guard chunkEnvelope.requestID == requestID else {
            throw RpcControlClientError.requestIDMismatch(expected: requestID, actual: chunkEnvelope.requestID)
        }
        guard chunkEnvelope.streamID == openResponse.streamID else {
            throw RpcControlClientError.streamIDMismatch(
                expected: openResponse.streamID,
                actual: chunkEnvelope.streamID
            )
        }
        let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: chunkEnvelope.payload)
        guard chunk.transferID == openResponse.transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: openResponse.transferID,
                actual: chunk.transferID
            )
        }
        guard chunk.offsetBytes == expectedOffsetBytes else {
            throw RpcControlClientError.offsetMismatch(expected: expectedOffsetBytes, actual: chunk.offsetBytes)
        }
        let actualCrc = Crc32.checksum(chunk.data)
        guard actualCrc == chunk.crc32 else {
            throw RpcControlClientError.checksumMismatch(expected: chunk.crc32, actual: actualCrc)
        }
        return chunk
    }

    private func sendTransferAck(
        transferID: String,
        requestID: UInt64,
        streamID: UInt64,
        nextOffsetBytes: Int64,
        finalAck: Bool
    ) throws {
        var ack = Droidmatch_V1_TransferChunkAck()
        ack.transferID = transferID
        ack.nextOffsetBytes = nextOffsetBytes
        ack.finalAck = finalAck
        var ackEnvelope = Droidmatch_V1_RpcEnvelope()
        ackEnvelope.frameVersion = 1
        ackEnvelope.kind = .stream
        ackEnvelope.requestID = requestID
        ackEnvelope.streamID = streamID
        ackEnvelope.payloadType = .transferChunkAck
        ackEnvelope.payload = try ack.serializedData()
        try session.sendPayload(ackEnvelope.serializedData())
    }

    private func sendTransferChunk(
        transferID: String,
        requestID: UInt64,
        streamID: UInt64,
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) throws {
        var chunk = Droidmatch_V1_TransferChunk()
        chunk.transferID = transferID
        chunk.offsetBytes = offsetBytes
        chunk.data = data
        chunk.crc32 = Crc32.checksum(data)
        chunk.finalChunk = finalChunk
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = requestID
        envelope.streamID = streamID
        envelope.payloadType = .transferChunk
        envelope.payload = try chunk.serializedData()
        try session.sendPayload(envelope.serializedData())
    }

    private func receiveTransferAck(
        requestID: UInt64,
        streamID: UInt64,
        transferID: String,
        expectedNextOffsetBytes: Int64,
        expectedFinalAck: Bool
    ) throws -> Droidmatch_V1_TransferChunkAck {
        let ack = try receiveTransferAck(
            requestID: requestID,
            streamID: streamID,
            transferID: transferID
        )
        guard ack.nextOffsetBytes == expectedNextOffsetBytes else {
            throw RpcControlClientError.offsetMismatch(
                expected: expectedNextOffsetBytes,
                actual: ack.nextOffsetBytes
            )
        }
        guard ack.finalAck == expectedFinalAck else {
            throw RpcControlClientError.invalidTransferState(
                "transfer ack final_ack mismatch: expected \(expectedFinalAck), got \(ack.finalAck)"
            )
        }
        return ack
    }

    /// 收一个 transfer ACK，只做 envelope/requestID/streamID/transferID 校验，
    /// 不预校验 offset/finalAck —— 这两项交给 `UploadWindow.recordAck` 按
    /// outstanding 队首校验，支持窗口化 upload。
    private func receiveTransferAck(
        requestID: UInt64,
        streamID: UInt64,
        transferID: String
    ) throws -> Droidmatch_V1_TransferChunkAck {
        let ackEnvelope = try parseEnvelope(try session.receivePayload())
        if ackEnvelope.kind == .error {
            throw RpcControlClientError.remoteError(try errorPayload(from: ackEnvelope))
        }
        guard ackEnvelope.kind == .stream, ackEnvelope.payloadType == .transferChunkAck else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: ackEnvelope.kind,
                payloadType: ackEnvelope.payloadType
            )
        }
        guard ackEnvelope.requestID == requestID else {
            throw RpcControlClientError.requestIDMismatch(expected: requestID, actual: ackEnvelope.requestID)
        }
        guard ackEnvelope.streamID == streamID else {
            throw RpcControlClientError.streamIDMismatch(expected: streamID, actual: ackEnvelope.streamID)
        }

        let ack = try Droidmatch_V1_TransferChunkAck(serializedBytes: ackEnvelope.payload)
        if ack.hasError {
            throw RpcControlClientError.remoteError(ack.error)
        }
        guard ack.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(expected: transferID, actual: ack.transferID)
        }
        return ack
    }

    private func requestEnvelope<Payload: SwiftProtobuf.Message>(
        payload: Payload,
        payloadType: Droidmatch_V1_PayloadType,
        requestID: UInt64
    ) throws -> Droidmatch_V1_RpcEnvelope {
        try RpcEnvelopeCodec.request(
            payload: payload,
            payloadType: payloadType,
            requestID: requestID
        )
    }

    private func responseEnvelope(
        for request: Droidmatch_V1_RpcEnvelope,
        expectedPayloadType: Droidmatch_V1_PayloadType
    ) throws -> Droidmatch_V1_RpcEnvelope {
        let responseBytes = try session.roundTrip(payload: request.serializedData())
        return try RpcEnvelopeCodec.response(
            from: responseBytes,
            requestID: request.requestID,
            expectedPayloadType: expectedPayloadType
        )
    }

    private func parseEnvelope(_ bytes: Data) throws -> Droidmatch_V1_RpcEnvelope {
        try RpcEnvelopeCodec.parse(bytes)
    }

    private func allocateRequestID() -> UInt64 {
        let requestID = nextRequestID
        nextRequestID = requestID == UInt64.max ? 1 : requestID + 1
        return requestID
    }

    private func errorPayload(from envelope: Droidmatch_V1_RpcEnvelope) throws -> Droidmatch_V1_DroidMatchError {
        try RpcEnvelopeCodec.errorPayload(from: envelope)
    }
}
