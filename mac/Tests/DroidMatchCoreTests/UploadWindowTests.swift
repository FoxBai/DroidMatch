import Foundation
import Testing
@testable import DroidMatchCore

// `UploadWindow` 的纯逻辑测试，对称 Android `DownloadTransfer` 的 windowing
// 模型。覆盖 canSendMore 的窗口满判定、recordSent 推进 offset、recordAck
// 按队首匹配 + 四条错误路径、final chunk 终止语义。这些是窗口化 upload
// 的纯逻辑契约；端到端通过 `FrameCodecTests.swift` 的本地服务器测试覆盖。

@Test func uploadWindowStartsEmptyAtGivenOffset() {
    let window = UploadWindow(startingOffsetBytes: 0)
    #expect(window.acknowledgedOffsetBytes == 0)
    #expect(window.nextSendOffsetBytes == 0)
    #expect(window.outstandingChunkCount == 0)
    #expect(window.outstandingByteCount == 0)
    #expect(window.finalChunkSent == false)
}

@Test func uploadWindowCanSendMoreWhenEmpty() {
    let window = UploadWindow(startingOffsetBytes: 0)
    // 空窗口 + 还有剩余字节 -> 可以发。
    #expect(window.canSendMore(chunkSizeBytes: 256 * 1024, remainingBytes: 1024))
}

@Test func uploadWindowAllowsEmptyFinalChunkWhenNoRemainingBytes() {
    let window = UploadWindow(startingOffsetBytes: 0)
    #expect(window.canSendMore(chunkSizeBytes: 256, remainingBytes: 0))
}

@Test func uploadWindowRejectsNegativeRemainingBytes() {
    let window = UploadWindow(startingOffsetBytes: 0)
    #expect(window.canSendMore(chunkSizeBytes: 256, remainingBytes: -1) == false)
}

@Test func uploadWindowRejectsEmptyFinalChunkWhileChunkIsOutstanding() {
    var window = UploadWindow(startingOffsetBytes: 0)
    window.recordSent(offsetBytes: 0, dataLength: 10, finalChunk: false)

    #expect(window.canSendMore(chunkSizeBytes: 256, remainingBytes: 0) == false)
}

@Test func uploadWindowBlocksAtMaxInFlightChunks() {
    var window = UploadWindow(startingOffsetBytes: 0)
    // 发满 4 个 chunk（默认 maxInFlightChunks）。
    for index in 0..<UploadWindow.maxInFlightChunks {
        #expect(window.canSendMore(chunkSizeBytes: 8, remainingBytes: 1024))
        window.recordSent(offsetBytes: Int64(index * 8), dataLength: 8, finalChunk: false)
    }
    // 第 5 个 chunk 应被窗口拒绝。
    #expect(window.canSendMore(chunkSizeBytes: 8, remainingBytes: 1024) == false)
    #expect(window.outstandingChunkCount == UploadWindow.maxInFlightChunks)
}

@Test func uploadWindowBlocksAtMaxInFlightBytes() {
    var window = UploadWindow(startingOffsetBytes: 0)
    // maxInFlightBytes = 2 MiB。用 1 MiB chunk 发 2 个就到字节上限。
    let oneMib = 1024 * 1024
    window.recordSent(offsetBytes: 0, dataLength: oneMib, finalChunk: false)
    #expect(window.canSendMore(chunkSizeBytes: oneMib, remainingBytes: Int64(oneMib * 4)))
    window.recordSent(offsetBytes: Int64(oneMib), dataLength: oneMib, finalChunk: false)
    // 第 3 个 1 MiB chunk 会超出 2 MiB 在途上限。
    #expect(window.canSendMore(chunkSizeBytes: oneMib, remainingBytes: Int64(oneMib * 4)) == false)
}

@Test func uploadWindowRecordSentAdvancesNextSendOffset() {
    var window = UploadWindow(startingOffsetBytes: 100)
    window.recordSent(offsetBytes: 100, dataLength: 50, finalChunk: false)
    #expect(window.nextSendOffsetBytes == 150)
    #expect(window.acknowledgedOffsetBytes == 100) // ACK 之前不推进
    #expect(window.outstandingByteCount == 50)
    #expect(window.outstandingChunkCount == 1)
}

@Test func uploadWindowRecordAckPopsQueueHeadAndAdvancesAcknowledgedOffset() throws {
    var window = UploadWindow(startingOffsetBytes: 0)
    window.recordSent(offsetBytes: 0, dataLength: 10, finalChunk: false)
    window.recordSent(offsetBytes: 10, dataLength: 20, finalChunk: false)

    // ACK 第一个 chunk（队首 nextOffset = 10）。
    let result = try window.recordAck(nextOffsetBytes: 10, finalAck: false)
    #expect(result.acknowledged == true)
    #expect(result.finalAcknowledged == false)
    #expect(window.acknowledgedOffsetBytes == 10)
    #expect(window.outstandingChunkCount == 1)

    // ACK 第二个 chunk（队首 nextOffset = 30）。
    let result2 = try window.recordAck(nextOffsetBytes: 30, finalAck: false)
    #expect(result2.acknowledged == true)
    #expect(window.acknowledgedOffsetBytes == 30)
    #expect(window.outstandingChunkCount == 0)
}

@Test func uploadWindowRecordAckRejectsOffsetMismatch() throws {
    var window = UploadWindow(startingOffsetBytes: 0)
    window.recordSent(offsetBytes: 0, dataLength: 10, finalChunk: false)
    // 队首期望 nextOffset=10，传 20 应拒绝。
    #expect(throws: RpcControlClientError.self) {
        _ = try window.recordAck(nextOffsetBytes: 20, finalAck: false)
    }
    // 失败后队列不应被消费。
    #expect(window.outstandingChunkCount == 1)
}

@Test func uploadWindowRecordAckRejectsAckWithNoOutstanding() throws {
    var window = UploadWindow(startingOffsetBytes: 0)
    // 空队列收到 ACK 应拒绝。
    #expect(throws: RpcControlClientError.self) {
        _ = try window.recordAck(nextOffsetBytes: 0, finalAck: false)
    }
}

@Test func uploadWindowFinalChunkRequiresFinalAck() throws {
    var window = UploadWindow(startingOffsetBytes: 0)
    window.recordSent(offsetBytes: 0, dataLength: 10, finalChunk: true)
    #expect(window.finalChunkSent == true)
    // final chunk 但收到非 final_ack 应拒绝。
    #expect(throws: RpcControlClientError.self) {
        _ = try window.recordAck(nextOffsetBytes: 10, finalAck: false)
    }
}

@Test func uploadWindowNonFinalChunkRejectsFinalAck() throws {
    var window = UploadWindow(startingOffsetBytes: 0)
    window.recordSent(offsetBytes: 0, dataLength: 10, finalChunk: false)
    // 非 final chunk 但收到 final_ack 应拒绝。
    #expect(throws: RpcControlClientError.self) {
        _ = try window.recordAck(nextOffsetBytes: 10, finalAck: true)
    }
}

@Test func uploadWindowFinalAckCompletesTransfer() throws {
    var window = UploadWindow(startingOffsetBytes: 0)
    window.recordSent(offsetBytes: 0, dataLength: 10, finalChunk: false)
    window.recordSent(offsetBytes: 10, dataLength: 5, finalChunk: true)

    // ACK 第一个非 final chunk。
    let r1 = try window.recordAck(nextOffsetBytes: 10, finalAck: false)
    #expect(r1.finalAcknowledged == false)

    // ACK final chunk -> finalAcknowledged=true。
    let r2 = try window.recordAck(nextOffsetBytes: 15, finalAck: true)
    #expect(r2.acknowledged == false)
    #expect(r2.finalAcknowledged == true)
    #expect(window.acknowledgedOffsetBytes == 15)
    #expect(window.outstandingChunkCount == 0)
}

@Test func uploadWindowCannotSendAfterFinalChunkSent() {
    var window = UploadWindow(startingOffsetBytes: 0)
    window.recordSent(offsetBytes: 0, dataLength: 10, finalChunk: true)
    // final 已发，即便窗口未满、还有剩余字节也不能再发。
    #expect(window.canSendMore(chunkSizeBytes: 8, remainingBytes: 1024) == false)
}

@Test func uploadWindowResumesFromNonZeroOffset() {
    let window = UploadWindow(startingOffsetBytes: 500)
    #expect(window.acknowledgedOffsetBytes == 500)
    #expect(window.nextSendOffsetBytes == 500)
    #expect(window.canSendMore(chunkSizeBytes: 8, remainingBytes: 1024))
}
