import Darwin
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
    #expect(try resumeRecordPermissions(sidecar) == 0o600)
    #expect(record.fingerprint.proto == fingerprint)
    #expect(sidecar.lastPathComponent == "download.bin.droidmatch-transfer.json")

    let json = try #require(String(data: Data(contentsOf: sidecar), encoding: .utf8))
    #expect(json.contains("\"transferID\""))
    #expect(json.contains("\"sourcePath\""))
    #expect(!json.contains("transfer_id"))
}

@Test func uploadResumeRecordRoundTripsStrongIdentityAndRemovesSidecar() async throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("upload.bin")
    try Data(repeating: 7, count: 100).write(to: source)
    let fileSource = AsyncUploadFileSource(sourceURL: source)
    let snapshot = try await fileSource.snapshot()
    await fileSource.close()
    let sidecar = UploadResumeRecord.sidecarURL(forSource: source)
    let record = UploadResumeRecord(
        transferID: "upload-id",
        sourcePath: source.path,
        destinationPath: "dm://app-sandbox/upload.bin",
        sourceIdentity: UploadSourceIdentityRecord(snapshot),
        nextOffsetBytes: 40
    )

    try record.save(to: sidecar)
    #expect(try UploadResumeRecord.load(from: sidecar) == record)
    #expect(try resumeRecordPermissions(sidecar) == 0o600)
    #expect(record.formatVersion == UploadResumeRecord.currentFormatVersion)
    #expect(record.sourceIdentity?.matches(snapshot) == true)
    #expect(sidecar.lastPathComponent == "upload.bin.droidmatch-upload-transfer.json")
    let json = try #require(String(data: Data(contentsOf: sidecar), encoding: .utf8))
    #expect(json.contains("\"formatVersion\":2"))
    #expect(json.contains("\"changedUnixNanoseconds\""))
    #expect(json.contains("\"fileSystemNumber\""))
    #expect(json.contains("\"fileNumber\""))
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
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: sidecar.path
    )

    #expect(throws: TransferResumeRecordError.self) {
        _ = try UploadResumeRecord.load(from: sidecar)
    }
}

@Test func resumeRecordIORejectsPermissiveFilesWithoutReplacingOrRemovingThem() throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 4
    fingerprint.modifiedUnixMillis = 1
    let download = DownloadResumeRecord(
        transferID: "download-private",
        sourcePath: "dm://app-sandbox/private.bin",
        totalSizeBytes: 4,
        fingerprint: TransferFingerprintRecord(fingerprint)
    )
    let downloadSidecar = directory.appendingPathComponent("download.json")
    try download.save(to: downloadSidecar)

    let upload = UploadResumeRecord(
        transferID: "upload-private",
        sourcePath: "/redacted/private.bin",
        destinationPath: "dm://app-sandbox/private.bin",
        totalSizeBytes: 4,
        sourceModifiedUnixMillis: 1,
        nextOffsetBytes: 0
    )
    let uploadSidecar = directory.appendingPathComponent("upload.json")
    try upload.save(to: uploadSidecar)

    for sidecar in [downloadSidecar, uploadSidecar] {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: sidecar.path
        )
    }
    let originalDownload = try Data(contentsOf: downloadSidecar)
    let originalUpload = try Data(contentsOf: uploadSidecar)

    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        _ = try DownloadResumeRecord.load(from: downloadSidecar)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try download.save(to: downloadSidecar)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try DownloadResumeRecord.remove(from: downloadSidecar)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        _ = try UploadResumeRecord.load(from: uploadSidecar)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try upload.save(to: uploadSidecar)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try UploadResumeRecord.remove(from: uploadSidecar)
    }

    #expect(try Data(contentsOf: downloadSidecar) == originalDownload)
    #expect(try Data(contentsOf: uploadSidecar) == originalUpload)
    #expect(try resumeRecordPermissions(downloadSidecar) == 0o644)
    #expect(try resumeRecordPermissions(uploadSidecar) == 0o644)
}

@Test func downloadResumeRecordIORejectsUnsafeNodesWithoutChangingThem() throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 4
    fingerprint.modifiedUnixMillis = 1
    let record = DownloadResumeRecord(
        transferID: "download-id",
        sourcePath: "dm://app-sandbox/source.bin",
        totalSizeBytes: 4,
        fingerprint: TransferFingerprintRecord(fingerprint)
    )

    let directoryArtifact = directory.appendingPathComponent("artifact-directory")
    try FileManager.default.createDirectory(
        at: directoryArtifact,
        withIntermediateDirectories: false
    )
    let directorySentinel = directoryArtifact.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: directorySentinel)
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        _ = try DownloadResumeRecord.load(from: directoryArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try record.save(to: directoryArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try DownloadResumeRecord.remove(from: directoryArtifact)
    }
    #expect(try Data(contentsOf: directorySentinel) == Data("keep".utf8))

    let protectedTarget = directory.appendingPathComponent("protected.bin")
    let protectedData = Data("protected".utf8)
    try protectedData.write(to: protectedTarget)
    let symlinkArtifact = directory.appendingPathComponent("artifact-symlink")
    try FileManager.default.createSymbolicLink(
        at: symlinkArtifact,
        withDestinationURL: protectedTarget
    )
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        _ = try DownloadResumeRecord.load(from: symlinkArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try record.save(to: symlinkArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try DownloadResumeRecord.remove(from: symlinkArtifact)
    }
    #expect(try Data(contentsOf: protectedTarget) == protectedData)
    #expect(
        try FileManager.default.attributesOfItem(atPath: symlinkArtifact.path)[.type]
            as? FileAttributeType == .typeSymbolicLink
    )

    let hardLinkArtifact = directory.appendingPathComponent("artifact-hard-link")
    try FileManager.default.linkItem(at: protectedTarget, to: hardLinkArtifact)
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        _ = try DownloadResumeRecord.load(from: hardLinkArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try record.save(to: hardLinkArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try DownloadResumeRecord.remove(from: hardLinkArtifact)
    }
    #expect(try Data(contentsOf: hardLinkArtifact) == protectedData)

    let fifoArtifact = directory.appendingPathComponent("artifact-fifo")
    #expect(Darwin.mkfifo(fifoArtifact.path, mode_t(0o600)) == 0)
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        _ = try DownloadResumeRecord.load(from: fifoArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try record.save(to: fifoArtifact)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try DownloadResumeRecord.remove(from: fifoArtifact)
    }
    var fifoMetadata = stat()
    #expect(Darwin.lstat(fifoArtifact.path, &fifoMetadata) == 0)
    #expect(fifoMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
}

@Test func uploadResumeRecordIORejectsUnsafeNodesWithoutChangingThem() throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = UploadResumeRecord(
        transferID: "upload-id",
        sourcePath: "/redacted/source.bin",
        destinationPath: "dm://app-sandbox/upload.bin",
        totalSizeBytes: 4,
        sourceModifiedUnixMillis: 1,
        nextOffsetBytes: 0
    )

    let directoryArtifact = directory.appendingPathComponent("upload-directory")
    try FileManager.default.createDirectory(
        at: directoryArtifact,
        withIntermediateDirectories: false
    )
    let sentinel = directoryArtifact.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)

    let protectedTarget = directory.appendingPathComponent("protected.bin")
    let protectedData = Data("protected".utf8)
    try protectedData.write(to: protectedTarget)
    let symlinkArtifact = directory.appendingPathComponent("upload-symlink")
    try FileManager.default.createSymbolicLink(
        at: symlinkArtifact,
        withDestinationURL: protectedTarget
    )
    let hardLinkArtifact = directory.appendingPathComponent("upload-hard-link")
    try FileManager.default.linkItem(at: protectedTarget, to: hardLinkArtifact)
    let fifoArtifact = directory.appendingPathComponent("upload-fifo")
    #expect(Darwin.mkfifo(fifoArtifact.path, mode_t(0o600)) == 0)

    for artifact in [directoryArtifact, symlinkArtifact, hardLinkArtifact, fifoArtifact] {
        #expect(throws: TransferResumeRecordError.unsafeArtifact) {
            _ = try UploadResumeRecord.load(from: artifact)
        }
        #expect(throws: TransferResumeRecordError.unsafeArtifact) {
            try record.save(to: artifact)
        }
        #expect(throws: TransferResumeRecordError.unsafeArtifact) {
            try UploadResumeRecord.remove(from: artifact)
        }
    }

    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(try Data(contentsOf: protectedTarget) == protectedData)
    #expect(try Data(contentsOf: hardLinkArtifact) == protectedData)
    #expect(
        try FileManager.default.attributesOfItem(atPath: symlinkArtifact.path)[.type]
            as? FileAttributeType == .typeSymbolicLink
    )
    var fifoMetadata = stat()
    #expect(Darwin.lstat(fifoArtifact.path, &fifoMetadata) == 0)
    #expect(fifoMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
}

@Test func resumeRecordIORejectsSymlinkParentAndPreservesRecoveryMarkers() throws {
    let root = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let realParent = root.appendingPathComponent("real", isDirectory: true)
    let aliasParent = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
    let record = UploadResumeRecord(
        transferID: "upload-id",
        sourcePath: "/redacted/source.bin",
        destinationPath: "dm://app-sandbox/upload.bin",
        totalSizeBytes: 4,
        sourceModifiedUnixMillis: 1,
        nextOffsetBytes: 0
    )
    let aliasedSidecar = aliasParent.appendingPathComponent("upload.json")
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        _ = try UploadResumeRecord.load(from: aliasedSidecar)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try record.save(to: aliasedSidecar)
    }
    #expect(throws: TransferResumeRecordError.unsafeArtifact) {
        try UploadResumeRecord.remove(from: aliasedSidecar)
    }
    #expect(!FileManager.default.fileExists(
        atPath: realParent.appendingPathComponent("upload.json").path
    ))

    let sidecar = realParent.appendingPathComponent("upload.json")
    try record.save(to: sidecar)
    let recovery = realParent.appendingPathComponent(".upload.json.pending")
    let recoveryData = Data("recoverable".utf8)
    try recoveryData.write(to: recovery)
    #expect(throws: TransferResumeRecordError.commitUncertain) {
        _ = try UploadResumeRecord.load(from: sidecar)
    }
    #expect(throws: TransferResumeRecordError.commitUncertain) {
        try record.save(to: sidecar)
    }
    #expect(throws: TransferResumeRecordError.commitUncertain) {
        try UploadResumeRecord.remove(from: sidecar)
    }
    #expect(try Data(contentsOf: recovery) == recoveryData)
}

@Test func freshDownloadPreparationPreservesEveryUnexpectedRecoveryNode() async throws {
    let directory = try makeResumeRecordTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AsyncTransferResumeStore()

    let sidecarDestination = directory.appendingPathComponent("sidecar.bin")
    let sidecar = DownloadResumeRecord.sidecarURL(forDestination: sidecarDestination)
    try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
    let sidecarSentinel = sidecar.appendingPathComponent("keep.txt")
    try Data("sidecar".utf8).write(to: sidecarSentinel)
    do {
        try await store.prepareFreshDownload(destinationURL: sidecarDestination)
        Issue.record("expected an unexpected sidecar directory to fail closed")
    } catch {
        #expect(error as? TransferResumeRecordError == .unsafeArtifact)
    }
    #expect(try Data(contentsOf: sidecarSentinel) == Data("sidecar".utf8))

    let partialDestination = directory.appendingPathComponent("partial.bin")
    let partial = AtomicDownloadWriter.partialURL(for: partialDestination)
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
    let partialSentinel = partial.appendingPathComponent("keep.txt")
    try Data("partial".utf8).write(to: partialSentinel)
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 4
    fingerprint.modifiedUnixMillis = 1
    let preservedRecord = DownloadResumeRecord(
        transferID: "preserved-before-writer-lock",
        sourcePath: "dm://app-sandbox/preserved.bin",
        totalSizeBytes: 4,
        fingerprint: TransferFingerprintRecord(fingerprint)
    )
    try preservedRecord.save(
        to: DownloadResumeRecord.sidecarURL(forDestination: partialDestination)
    )
    await #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        _ = try await AsyncAtomicDownloadWriter.create(
            destinationURL: partialDestination,
            resume: false,
            deferFreshReset: true
        )
    }
    #expect(try Data(contentsOf: partialSentinel) == Data("partial".utf8))
    #expect(try DownloadResumeRecord.load(
        from: DownloadResumeRecord.sidecarURL(forDestination: partialDestination)
    ) == preservedRecord)
}

private func makeResumeRecordTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-resume-record-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func resumeRecordPermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}
