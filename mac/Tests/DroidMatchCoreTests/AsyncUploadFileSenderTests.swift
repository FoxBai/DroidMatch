import Foundation
import Testing
@testable import DroidMatchCore

@Test func refillingUploadReaderEmitsExactlyOneEmptyFinalChunk() async throws {
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-empty-upload-\(UUID().uuidString).bin"
    )
    try Data().write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let source = AsyncUploadFileSource(sourceURL: sourceURL)
    defer { Task { await source.close() } }
    let snapshot = try await source.snapshot()
    let reader = RefillingUploadChunkReader(
        source: source,
        snapshot: snapshot,
        startingOffset: 0,
        chunkSize: 1024,
        sendLimitBytes: 0
    )

    let initial = try await reader.initialWindow()

    #expect(initial.count == 1)
    #expect(initial[0].data.isEmpty)
    #expect(initial[0].finalChunk)
    #expect(try await reader.nextChunk() == nil)
}

@Test func refillingUploadReaderBoundsReadAheadAndAdvancesOneAckSlot() async throws {
    let oneMiB = 1024 * 1024
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-refill-upload-\(UUID().uuidString).bin"
    )
    try Data(repeating: 0x5a, count: 5 * oneMiB).write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let source = AsyncUploadFileSource(sourceURL: sourceURL)
    defer { Task { await source.close() } }
    let snapshot = try await source.snapshot()
    let reader = RefillingUploadChunkReader(
        source: source,
        snapshot: snapshot,
        startingOffset: 0,
        chunkSize: oneMiB,
        sendLimitBytes: snapshot.sizeBytes
    )

    let initial = try await reader.initialWindow()
    let refill = try #require(try await reader.nextChunk())

    #expect(initial.count == 2)
    #expect(initial.map(\.offsetBytes) == [0, Int64(oneMiB)])
    #expect(initial.allSatisfy { !$0.finalChunk })
    #expect(refill.offsetBytes == Int64(2 * oneMiB))
    #expect(refill.data.count == oneMiB)
    #expect(!refill.finalChunk)
}
