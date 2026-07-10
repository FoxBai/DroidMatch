import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncUploadFileSourceReadsExactRangesAndRejectsInvalidBounds() async throws {
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-source-\(UUID().uuidString).bin"
    )
    try Data("abcdefghij".utf8).write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let source = AsyncUploadFileSource(sourceURL: sourceURL)
    let snapshot = try await source.snapshot()
    #expect(snapshot.sizeBytes == 10)
    #expect(try await source.read(
        offsetBytes: 2,
        byteCount: 3,
        expectedSnapshot: snapshot
    ) == Data("cde".utf8))

    do {
        _ = try await source.read(
            offsetBytes: 9,
            byteCount: 2,
            expectedSnapshot: snapshot
        )
        Issue.record("expected an out-of-bounds source read to fail")
    } catch let error as AsyncUploadFileSourceError {
        guard case .invalidRead = error else {
            Issue.record("unexpected source error: \(error)")
            return
        }
    }
    await source.close()
}

@Test func asyncUploadFileSourceDetectsSameMetadataPathReplacementByInode() async throws {
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-replaced-\(UUID().uuidString).bin"
    )
    try Data("original".utf8).write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let source = AsyncUploadFileSource(sourceURL: sourceURL)
    let snapshot = try await source.snapshot()
    let originalDate = Date(timeIntervalSince1970: Double(snapshot.modifiedUnixMillis) / 1_000)
    try FileManager.default.removeItem(at: sourceURL)
    try Data("replaced".utf8).write(to: sourceURL)
    try FileManager.default.setAttributes(
        [.modificationDate: originalDate],
        ofItemAtPath: sourceURL.path
    )

    do {
        try await source.validate(snapshot)
        Issue.record("expected a replacement inode to invalidate the source snapshot")
    } catch let error as AsyncUploadFileSourceError {
        guard case .sourceChanged = error else {
            Issue.record("unexpected source error: \(error)")
            return
        }
    }
    await source.close()
}
