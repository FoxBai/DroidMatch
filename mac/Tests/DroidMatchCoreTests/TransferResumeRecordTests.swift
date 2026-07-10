import Foundation
import Testing
@testable import DroidMatchCore

@Test func downloadResumeRecordRoundTripsLegacyCamelCaseFormat() throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("download.bin")
    let sidecar = DownloadResumeRecord.sidecarURL(forDestination: destination)
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 12
    fingerprint.modifiedUnixMillis = 34
    fingerprint.providerEtag = "etag"
    fingerprint.sha256 = "abcd"
    let record = DownloadResumeRecord(
        transferID: "download-id",
        sourcePath: "dm://app-sandbox/source.bin",
        totalSizeBytes: 12,
        fingerprint: TransferFingerprintRecord(fingerprint)
    )

    try record.save(to: sidecar)
    #expect(try DownloadResumeRecord.load(from: sidecar) == record)
    #expect(record.fingerprint.proto == fingerprint)
    #expect(sidecar.lastPathComponent == "download.bin.droidmatch-transfer.json")

    let json = try #require(String(data: Data(contentsOf: sidecar), encoding: .utf8))
    #expect(json.contains("\"transferID\""))
    #expect(json.contains("\"sourcePath\""))
    #expect(!json.contains("transfer_id"))
}

@Test func uploadResumeRecordRoundTripsAndRemovesAtomicallyWrittenSidecar() throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("upload.bin")
    let sidecar = UploadResumeRecord.sidecarURL(forSource: source)
    let record = UploadResumeRecord(
        transferID: "upload-id",
        sourcePath: source.path,
        destinationPath: "dm://app-sandbox/upload.bin",
        totalSizeBytes: 100,
        sourceModifiedUnixMillis: 123,
        nextOffsetBytes: 40
    )

    try record.save(to: sidecar)
    #expect(try UploadResumeRecord.load(from: sidecar) == record)
    #expect(sidecar.lastPathComponent == "upload.bin.droidmatch-upload-transfer.json")
    try UploadResumeRecord.remove(from: sidecar)
    #expect(try UploadResumeRecord.load(from: sidecar) == nil)
}

@Test func resumeRecordLoadRejectsInvalidDurableOffsets() throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sidecar = directory.appendingPathComponent("invalid.json")
    let invalidJSON = """
    {
      "transferID": "upload-id",
      "sourcePath": "/tmp/source.bin",
      "destinationPath": "dm://app-sandbox/upload.bin",
      "totalSizeBytes": 5,
      "sourceModifiedUnixMillis": 123,
      "nextOffsetBytes": 6
    }
    """
    try Data(invalidJSON.utf8).write(to: sidecar)

    #expect(throws: TransferResumeRecordError.self) {
        _ = try UploadResumeRecord.load(from: sidecar)
    }
}

private func makeResumeRecordTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-resume-record-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
