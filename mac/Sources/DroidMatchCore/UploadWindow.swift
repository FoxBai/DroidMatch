import Foundation

// MARK: - UploadWindow

/// Upload 传输的发送侧滑动窗口状态。
///
/// 这是 Mac 客户端 upload 路径的发送窗口管理器，对称 Android 服务端
/// `DownloadTransfer`（`RpcDispatcher.java:1076-1162`）的 windowing 模型。
/// 之前 `RpcControlClient.upload` 是 stop-and-wait：发一个 chunk → 阻塞等
/// ACK → 再发下一个，管道里永远只有 1 个 in-flight chunk，吞吐被
/// `chunkSize / RTT` 限制（实测 11.49 MiB/s）。
///
/// `UploadWindow` 把发送侧改成滑动窗口：允许最多 `maxInFlightChunks` 个
/// chunk 或 `maxInFlightBytes` 字节在途（in-flight）未确认。发送方在单线程
/// 内连续发送填满窗口，然后阻塞收一个 ACK；ACK 到达后窗口腾空，再补发新
/// chunk。这把有效吞吐从 `chunkSize / RTT` 提升到
/// `min(maxInFlightBytes, chunkSize * maxInFlightChunks) / RTT`。
///
/// 设计要点：
///
/// - 纯值类型（`struct`），无锁、无线程，状态由调用方驱动，可单测。
/// - outstanding 队列按发送顺序排列，`recordAck` 按队首匹配 `nextOffsetBytes`，
///   与 Android `DownloadTransfer.recordAck` 的顺序确认语义一致。Android 端
///   `handleTransferChunk` 只校验 `chunk.offsetBytes == transfer.nextOffsetBytes`
///   （顺序到达），所以 Mac 按顺序发送即可，Android 天然兼容窗口化。
/// - `recordAck` 复刻 Android `DownloadTransfer.recordAck` 的四条错误路径：
///   无 outstanding chunk / offset 不匹配 / final chunk 缺 final_ack /
///   非 final chunk 提前收到 final_ack。
public struct UploadWindow: Sendable {
    /// 在途 chunk 数上限。对称 Android `MAX_DOWNLOAD_IN_FLIGHT_CHUNKS = 4`。
    public static let maxInFlightChunks = 4

    /// 在途字节数上限。对称 Android `MAX_DOWNLOAD_IN_FLIGHT_BYTES = 2 MiB`。
    public static let maxInFlightBytes: Int64 = 2 * 1024 * 1024

    /// 已确认的 offset（队首 ACK 推进到这里）。
    public private(set) var acknowledgedOffsetBytes: Int64

    /// 下一个待发送 chunk 的起始 offset。
    public private(set) var nextSendOffsetBytes: Int64

    /// 是否已发送过 final chunk（发送完 final 后不再发新 chunk）。
    public private(set) var finalChunkSent: Bool

    /// outstanding 队列：已发送但未确认的 chunk，按发送顺序排列。
    /// 每个元素记录该 chunk 期望的 `nextOffsetBytes`（即 offset + data.count）
    /// 和是否为 final chunk。
    private var outstandingChunks: [SentChunk]

    /// 单个 outstanding chunk 的元数据。对称 Android `SentChunk`。
    private struct SentChunk: Sendable {
        let nextOffsetBytes: Int64
        let finalChunk: Bool
    }

    /// 从 `startingOffsetBytes`（即 `OpenTransferResponse.acceptedOffsetBytes`）
    /// 初始化窗口。resume 场景下 startingOffset > 0，窗口从该 offset 起算。
    public init(startingOffsetBytes: Int64) {
        self.acknowledgedOffsetBytes = startingOffsetBytes
        self.nextSendOffsetBytes = startingOffsetBytes
        self.finalChunkSent = false
        self.outstandingChunks = []
    }

    /// 当前在途（已发未确认）的 chunk 数。
    public var outstandingChunkCount: Int {
        outstandingChunks.count
    }

    /// 当前在途字节数 = nextSendOffset - acknowledgedOffset。
    public var outstandingByteCount: Int64 {
        nextSendOffsetBytes - acknowledgedOffsetBytes
    }

    /// 是否还能再发一个 chunk。
    ///
    /// 返回 `false` 当满足以下任一条件：
    /// - 已发送 final chunk（`finalChunkSent`）
    /// - outstanding chunk 数已达 `maxInFlightChunks`
    /// - 再发一个 `chunkSizeBytes` 的 chunk 会超过 `maxInFlightBytes`
    ///
    /// - Parameter chunkSizeBytes: 协商的单个 chunk 大小。
    /// - Parameter remainingBytes: 源文件剩余未读字节数
    ///   （`expectedSizeBytes - nextSendOffsetBytes`）。
    public func canSendMore(chunkSizeBytes: Int, remainingBytes: Int64) -> Bool {
        if finalChunkSent {
            return false
        }
        if remainingBytes <= 0 {
            return false
        }
        if outstandingChunks.count >= Self.maxInFlightChunks {
            return false
        }
        return outstandingByteCount + Int64(chunkSizeBytes) <= Self.maxInFlightBytes
    }

    /// 登记一个已发送的 chunk，推进 `nextSendOffsetBytes` 并入队 outstanding。
    ///
    /// - Parameters:
    ///   - offsetBytes: 该 chunk 的起始 offset。
    ///   - dataLength: 该 chunk 的数据长度。
    ///   - finalChunk: 是否为 final chunk。
    public mutating func recordSent(
        offsetBytes: Int64,
        dataLength: Int,
        finalChunk: Bool
    ) {
        let nextOffset = offsetBytes + Int64(dataLength)
        outstandingChunks.append(SentChunk(nextOffsetBytes: nextOffset, finalChunk: finalChunk))
        nextSendOffsetBytes = nextOffset
        if finalChunk {
            finalChunkSent = true
        }
    }

    /// 登记一个收到的 ACK，校验队首匹配并出队。
    ///
    /// 对称 Android `DownloadTransfer.recordAck` 的校验逻辑，复刻四条
    /// 错误路径。ACK 必须按发送顺序到达（队首的 `nextOffsetBytes` 必须等于
    /// ACK 的 `nextOffsetBytes`）。
    ///
    /// - Returns: `(acknowledged: 是否成功确认了一个非 final chunk,
    ///             finalAcknowledged: 是否确认了 final chunk 并结束传输)`。
    /// - Throws: `RpcControlClientError` 的 `invalidTransferState` 或
    ///           `offsetMismatch`，对应四条错误路径。
    public mutating func recordAck(
        nextOffsetBytes: Int64,
        finalAck: Bool
    ) throws -> (acknowledged: Bool, finalAcknowledged: Bool) {
        guard let head = outstandingChunks.first else {
            throw RpcControlClientError.invalidTransferState(
                "transfer ack received with no outstanding chunk"
            )
        }
        guard nextOffsetBytes == head.nextOffsetBytes else {
            throw RpcControlClientError.offsetMismatch(
                expected: head.nextOffsetBytes,
                actual: nextOffsetBytes
            )
        }
        if head.finalChunk && !finalAck {
            throw RpcControlClientError.invalidTransferState(
                "final chunk requires final_ack"
            )
        }
        if !head.finalChunk && finalAck {
            throw RpcControlClientError.invalidTransferState(
                "final_ack received before final chunk"
            )
        }

        outstandingChunks.removeFirst()
        acknowledgedOffsetBytes = nextOffsetBytes
        if head.finalChunk {
            return (acknowledged: false, finalAcknowledged: true)
        }
        return (acknowledged: true, finalAcknowledged: false)
    }
}
