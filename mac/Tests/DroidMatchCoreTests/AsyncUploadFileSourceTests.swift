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

@Test func asyncUploadFileSourceKeepsDescriptorBoundAcrossPathSwap() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-upload-descriptor-bind-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.bin")
    let heldURL = directory.appendingPathComponent("held-original.bin")
    try Data("original".utf8).write(to: sourceURL)

    let source = AsyncUploadFileSource(sourceURL: sourceURL)
    let snapshot = try await source.snapshot()
    try FileManager.default.moveItem(at: sourceURL, to: heldURL)
    try Data("replaced".utf8).write(to: sourceURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(
            timeIntervalSince1970: Double(snapshot.modifiedUnixMillis) / 1_000
        )],
        ofItemAtPath: sourceURL.path
    )

    do {
        _ = try await source.read(
            offsetBytes: 0,
            byteCount: 8,
            expectedSnapshot: snapshot
        )
        Issue.record("expected the descriptor/path identity mismatch to fail")
    } catch let error as AsyncUploadFileSourceError {
        guard case .sourceChanged = error else {
            Issue.record("unexpected source error: \(error)")
            return
        }
        #expect(!error.description.contains(directory.path))
    }
    #expect(try Data(contentsOf: heldURL) == Data("original".utf8))
    #expect(try Data(contentsOf: sourceURL) == Data("replaced".utf8))
    await source.close()
}
