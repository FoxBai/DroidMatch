import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func apkExportCodecRejectsIncompleteAndConflictingSets() throws {
    let fixture = ApkExportWireFixture(split: true)
    let original = fixture.manifest
    #expect(try ApkExportCodec.manifest(original.serializedData(), identifier: "fixture.app").components.count == 2)
    var invalid: [Droidmatch_V1_PrepareApkExportResponse] = []
    var next = original; next.components[0].splitName = "base"; invalid.append(next)
    next = original; next.components[1].index = 0; invalid.append(next)
    next = original; next.components[1].splitName = "../private"; invalid.append(next)
    next = original; next.components[1].sizeBytes = UInt64.max; invalid.append(next)
    next = original; next.exportID = "../invalid"; invalid.append(next)
    next = original; next.error.code = .permissionRequired; invalid.append(next)
    next = original; next.components = []; invalid.append(next)
    for value in invalid {
        #expect(throws: ApkExportError.invalidResponse) {
            try ApkExportCodec.manifest(value.serializedData(), identifier: "fixture.app")
        }
    }
}

@Test func apkExportStreamsStandaloneAndCompleteZipWithUnchangedBytes() async throws {
    for split in [false, true] {
        let fixture = ApkExportWireFixture(split: split)
        let (server, client) = try fixture.makeClient()
        defer { server.cancel() }
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await client.exportApk(packageIdentifier: "fixture.app", directoryURL: directory, progress: { _ in })
        let output = directory.appendingPathComponent(result.filename)
        #expect(fixture.didValidate)
        #expect(result.componentCount == fixture.contents.count)
        #expect(result.totalBytes == Int64(fixture.contents.reduce(0) { $0 + $1.count }))
        #expect(!FileManager.default.fileExists(atPath: AtomicDownloadWriter.partialURL(for: output).path))
        if split {
            #expect(result.filename.hasSuffix("-apks.zip"))
            #expect(try unzip(output, entry: "base.apk") == fixture.contents[0])
            #expect(try unzip(output, entry: "split-1.apk") == fixture.contents[1])
            let metadata = try #require(JSONSerialization.jsonObject(with: unzip(output, entry: "manifest.json")) as? [String: Any])
            #expect(metadata["formatVersion"] as? Int == 1)
            let files = try #require(metadata["components"] as? [[String: Any]])
            #expect(files.count == 2)
            #expect(files[1]["splitName"] as? String == "config.arm64_v8a")
            #expect(files[1]["sha256"] as? String == fixture.digest(1))
        } else { #expect(try Data(contentsOf: output) == fixture.contents[0]) }
        await client.invalidate()
    }
}

@Test func apkExportSourceChangeAndCancellationLeaveNoCompletedOrPartialExport() async throws {
    for cancellation in [false, true] {
        let fixture = ApkExportWireFixture(split: true, sourceChanged: !cancellation)
        let (server, client) = try fixture.makeClient()
        defer { server.cancel() }
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.apk")
        try Data("preserved".utf8).write(to: existing)
        let task = Task {
            try await client.exportApk(packageIdentifier: "fixture.app", directoryURL: directory) { progress in
                if cancellation && progress.completedBytes > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        if cancellation { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: ApkExportError.sourceChanged) { try await task.value } }
        #expect(try Data(contentsOf: existing) == Data("preserved".utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.contains { $0.hasPrefix("fixture.app-") })
        await client.invalidate()
    }
}

@Test func apkExportUnpublishedCleanupDoesNotDeleteAReplacedPartial() throws {
    let directory = try exportDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("export.apk")
    let writer = try AtomicDownloadWriter(destinationURL: target, resume: false, publicationPolicy: .mustBeAbsent)
    defer { try? writer.close() }
    try writer.write(Data("original partial".utf8))
    try FileManager.default.moveItem(at: writer.partialURL, to: directory.appendingPathComponent("displaced.partial"))
    try Data("replacement".utf8).write(to: writer.partialURL)
    #expect(throws: AtomicDownloadWriterError.destinationChanged) { try writer.discardUnpublished() }
    #expect(try Data(contentsOf: writer.partialURL) == Data("replacement".utf8))
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

private func exportDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apk-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func unzip(_ archive: URL, entry: String) throws -> Data {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path, entry]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return bytes
}
