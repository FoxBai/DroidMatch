import Darwin
import Foundation
import Network
import Testing
@testable import DroidMatchCore

@Test func frameCodecRoundTripsOnePayload() throws {
    let codec = FrameCodec()
    let payload = Data("hello".utf8)

    var frame = try codec.encode(payload: payload)
    let decoded = try codec.decodeNext(from: &frame)

    #expect(decoded == payload)
    #expect(frame.isEmpty)
}

@Test func frameCodecWaitsForCompletePayload() throws {
    let codec = FrameCodec()
    let payload = Data("hello".utf8)
    let frame = try codec.encode(payload: payload)

    var partial = frame.prefix(6)
    let decoded = try codec.decodeNext(from: &partial)

    #expect(decoded == nil)
}

@Test func frameReaderDecodesMultiplePayloadsWithoutClearingBuffer() throws {
    let codec = FrameCodec()
    let reader = FrameReader(compactThreshold: 1024)
    let first = Data("first".utf8)
    let second = Data("second".utf8)

    var combined = Data()
    combined.append(try codec.encode(payload: first))
    combined.append(try codec.encode(payload: second))
    reader.append(combined)

    #expect(try reader.decodeNext() == first)
    #expect(try reader.decodeNext() == second)
    #expect(try reader.decodeNext() == nil)
}

@Test func frameReaderRequiresClearAfterInvalidFrame() throws {
    let codec = FrameCodec()
    let reader = FrameReader()
    reader.append(Data([0, 0, 0, 0]))

    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try reader.decodeNext()
    }

    reader.append(try codec.encode(payload: Data("valid".utf8)))
    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try reader.decodeNext()
    }

    reader.clear()
    reader.append(try codec.encode(payload: Data("valid".utf8)))
    #expect(try reader.decodeNext() == Data("valid".utf8))
}

@Test func frameCodecRejectsEmptyPayload() throws {
    let codec = FrameCodec()

    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try codec.encode(payload: Data())
    }
}

@Test func frameCodecRejectsOversizedPayloads() throws {
    let codec = FrameCodec(maxEnvelopeLength: 4)

    #expect(throws: FrameCodecError.frameTooLarge(5)) {
        _ = try codec.encode(payload: Data(repeating: 0x41, count: 5))
    }
}

@Test func frameCodecRejectsOversizedIncomingFrameBeforePayloadRead() throws {
    let codec = FrameCodec(maxEnvelopeLength: 4)
    var frame = Data([0, 0, 0, 5])

    #expect(throws: FrameCodecError.frameTooLarge(5)) {
        _ = try codec.decodeNext(from: &frame)
    }
}

@Test func crc32MatchesKnownVector() {
    let data = Data("123456789".utf8)
    #expect(Crc32.checksum(data) == 0xcbf43926)
}

@Test func atomicDownloadWriterLeavesDestinationUntouchedUntilCommit() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destination = directory.appendingPathComponent("photo.bin")
    try Data("old".utf8).write(to: destination)

    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    try writer.write(Data("new".utf8))

    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(FileManager.default.fileExists(atPath: AtomicDownloadWriter.partialURL(for: destination).path))

    try writer.commit()

    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: AtomicDownloadWriter.partialURL(for: destination).path))
}

@Test func atomicDownloadWriterResumesFromPartialFile() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destination = directory.appendingPathComponent("video.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    try Data("download".utf8).write(to: partial)

    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: true)
    #expect(writer.requestedOffsetBytes == 8)
    try writer.write(Data("-bytes".utf8))
    try writer.commit()

    #expect(try Data(contentsOf: destination) == Data("download-bytes".utf8))
    #expect(!FileManager.default.fileExists(atPath: partial.path))
}

@Test func atomicDownloadWriterFreshStartRemovesStalePartialFile() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destination = directory.appendingPathComponent("fresh.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    try Data("stale".utf8).write(to: partial)

    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    #expect(writer.requestedOffsetBytes == 0)
    try writer.write(Data("fresh".utf8))
    try writer.commit()

    #expect(try Data(contentsOf: destination) == Data("fresh".utf8))
    #expect(!FileManager.default.fileExists(atPath: partial.path))
}

@Test func atomicDownloadWriterRejectsConcurrentResumeUntilOwnerCommits() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("locked-resume.bin")
    let owner = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    try owner.write(Data("owner".utf8))

    #expect(throws: AtomicDownloadWriterError.destinationBusy) {
        _ = try AtomicDownloadWriter(destinationURL: destination, resume: true)
    }
    #expect(!AtomicDownloadWriterError.destinationBusy.description.contains(
        directory.path
    ))

    try owner.write(Data("-commit".utf8))
    try owner.commit()
    #expect(try Data(contentsOf: destination) == Data("owner-commit".utf8))
}

@Test func atomicDownloadWriterRejectsFreshAncestorSymlinkBeforeCheckpointMutation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let realDirectory = directory.appendingPathComponent("real", isDirectory: true)
    let nestedDirectory = realDirectory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(
        at: nestedDirectory,
        withIntermediateDirectories: true
    )
    let aliasDirectory = directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(
        at: aliasDirectory,
        withDestinationURL: realDirectory
    )
    let destination = nestedDirectory.appendingPathComponent("locked-fresh.bin")
    let aliasDestination = aliasDirectory
        .appendingPathComponent("nested", isDirectory: true)
        .appendingPathComponent("locked-fresh.bin")
    let store = AsyncTransferResumeStore()
    let owner = try await AsyncAtomicDownloadWriter.create(
        destinationURL: destination,
        resume: false,
        deferFreshReset: true
    )
    try await store.prepareFreshDownload(destinationURL: destination)
    try await owner.resetFresh()
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 17
    fingerprint.modifiedUnixMillis = 1
    let record = DownloadResumeRecord(
        transferID: "alias-owner",
        sourcePath: "dm://app-sandbox/alias-owner.bin",
        totalSizeBytes: 17,
        fingerprint: TransferFingerprintRecord(fingerprint)
    )
    try await store.saveDownload(record, destinationURL: destination)
    try await owner.write(Data("alias-safe".utf8))

    await #expect(throws: AtomicDownloadWriterError.unsafeDestinationDirectory) {
        _ = try await AsyncAtomicDownloadWriter.create(
            destinationURL: aliasDestination,
            resume: false,
            deferFreshReset: true
        )
    }
    #expect(try DownloadResumeRecord.load(
        from: DownloadResumeRecord.sidecarURL(forDestination: destination)
    ) == record)

    try await owner.write(Data("-commit".utf8))
    try await owner.commit()
    #expect(try Data(contentsOf: destination) == Data("alias-safe-commit".utf8))
}

@Test func atomicDownloadWriterCloseReleasesLockForResume() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("cancel-resume.bin")
    let cancelled = try AtomicDownloadWriter(
        destinationURL: destination,
        resume: false
    )
    try cancelled.write(Data("durable".utf8))
    try cancelled.close()

    let resumed = try AtomicDownloadWriter(
        destinationURL: destination,
        resume: true
    )
    #expect(resumed.requestedOffsetBytes == 7)
    try resumed.write(Data("-resume".utf8))
    try resumed.commit()
    #expect(try Data(contentsOf: destination) == Data("durable-resume".utf8))
}

@Test func atomicDownloadWriterReportsResumeOffsetWithoutMutatingFiles() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destination = directory.appendingPathComponent("planned-resume.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    try Data("partial".utf8).write(to: partial)

    #expect(try AtomicDownloadWriter.requestedOffsetBytes(
        for: destination,
        resume: false
    ) == 0)
    #expect(try AtomicDownloadWriter.requestedOffsetBytes(
        for: destination,
        resume: true
    ) == 7)
    #expect(try Data(contentsOf: partial) == Data("partial".utf8))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func atomicDownloadWriterRejectsSymlinkPartialWithoutTouchingItsTarget() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destination = directory.appendingPathComponent("resume.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    let protectedTarget = directory.appendingPathComponent("protected.bin")
    try Data("protected".utf8).write(to: protectedTarget)
    try FileManager.default.createSymbolicLink(
        at: partial,
        withDestinationURL: protectedTarget
    )

    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        try AtomicDownloadWriter.requestedOffsetBytes(
            for: destination,
            resume: true
        )
    }
    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        _ = try AtomicDownloadWriter(destinationURL: destination, resume: true)
    }
    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        _ = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    }

    #expect(try Data(contentsOf: protectedTarget) == Data("protected".utf8))
    #expect(
        try FileManager.default.attributesOfItem(atPath: partial.path)[.type]
            as? FileAttributeType == .typeSymbolicLink
    )
}

@Test func atomicDownloadWriterRejectsHardLinkedPartialBeforeTruncation() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("hard-link.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    let protectedTarget = directory.appendingPathComponent("protected.bin")
    let protectedData = Data("must-not-be-truncated".utf8)
    try protectedData.write(to: protectedTarget)
    try FileManager.default.linkItem(at: protectedTarget, to: partial)

    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        try AtomicDownloadWriter.requestedOffsetBytes(for: destination, resume: true)
    }
    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        _ = try AtomicDownloadWriter(destinationURL: destination, resume: true)
    }
    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        _ = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    }

    #expect(try Data(contentsOf: protectedTarget) == protectedData)
    #expect(try Data(contentsOf: partial) == protectedData)
}

@Test func atomicDownloadWriterRejectsDirectoryAndFifoPartialsWithoutRemovingThem() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let directoryDestination = directory.appendingPathComponent("directory.bin")
    let directoryPartial = AtomicDownloadWriter.partialURL(for: directoryDestination)
    try FileManager.default.createDirectory(
        at: directoryPartial,
        withIntermediateDirectories: false
    )
    let sentinel = directoryPartial.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)

    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        try AtomicDownloadWriter.requestedOffsetBytes(
            for: directoryDestination,
            resume: true
        )
    }
    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        _ = try AtomicDownloadWriter(destinationURL: directoryDestination, resume: false)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))

    let fifoDestination = directory.appendingPathComponent("fifo.bin")
    let fifoPartial = AtomicDownloadWriter.partialURL(for: fifoDestination)
    #expect(Darwin.mkfifo(fifoPartial.path, mode_t(0o600)) == 0)
    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        try AtomicDownloadWriter.requestedOffsetBytes(for: fifoDestination, resume: true)
    }
    #expect(throws: AtomicDownloadWriterError.unsafePartialFile) {
        _ = try AtomicDownloadWriter(destinationURL: fifoDestination, resume: false)
    }
    var fifoMetadata = stat()
    #expect(Darwin.lstat(fifoPartial.path, &fifoMetadata) == 0)
    #expect(fifoMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
}

@Test func atomicDownloadWriterRejectsSymlinkDestinationDirectory() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let realDirectory = directory.appendingPathComponent("real", isDirectory: true)
    let linkedDirectory = directory.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        at: linkedDirectory,
        withDestinationURL: realDirectory
    )
    let destination = linkedDirectory.appendingPathComponent("download.bin")

    #expect(throws: AtomicDownloadWriterError.unsafeDestinationDirectory) {
        _ = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    }
    #expect(!FileManager.default.fileExists(
        atPath: realDirectory.appendingPathComponent("download.bin.droidmatch-part").path
    ))
}

@Test func atomicDownloadCommitReplacesDestinationSymlinkWithoutFollowingIt() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destination = directory.appendingPathComponent("result.bin")
    let protectedTarget = directory.appendingPathComponent("protected.bin")
    try Data("protected".utf8).write(to: protectedTarget)
    try FileManager.default.createSymbolicLink(
        at: destination,
        withDestinationURL: protectedTarget
    )

    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    try writer.write(Data("download".utf8))
    try writer.commit()

    #expect(try Data(contentsOf: protectedTarget) == Data("protected".utf8))
    #expect(try Data(contentsOf: destination) == Data("download".utf8))
    #expect(
        try FileManager.default.attributesOfItem(atPath: destination.path)[.type]
            as? FileAttributeType == .typeRegular
    )

    let changedDestination = directory.appendingPathComponent("changed.bin")
    try Data("old".utf8).write(to: changedDestination)
    let changedWriter = try AtomicDownloadWriter(
        destinationURL: changedDestination,
        resume: false
    )
    try changedWriter.write(Data("downloaded".utf8))
    try FileManager.default.removeItem(at: changedDestination)
    try Data("new-owner".utf8).write(to: changedDestination)
    #expect(throws: AtomicDownloadWriterError.destinationChanged) {
        try changedWriter.commit()
    }
    #expect(try Data(contentsOf: changedDestination) == Data("new-owner".utf8))
    #expect(try Data(contentsOf: AtomicDownloadWriter.partialURL(
        for: changedDestination
    )) == Data("downloaded".utf8))

    let reboundDestination = directory.appendingPathComponent("rebound.bin")
    let reboundPartial = AtomicDownloadWriter.partialURL(for: reboundDestination)
    let reboundWriter = try AtomicDownloadWriter(
        destinationURL: reboundDestination,
        resume: false
    )
    try reboundWriter.write(Data("owned-partial".utf8))
    let movedPartial = directory.appendingPathComponent("moved-owned-partial")
    try FileManager.default.moveItem(at: reboundPartial, to: movedPartial)
    try Data("intruder".utf8).write(to: reboundPartial)
    #expect(throws: AtomicDownloadWriterError.destinationBusy) {
        try reboundWriter.commit()
    }
    #expect(!FileManager.default.fileExists(atPath: reboundDestination.path))
    #expect(try Data(contentsOf: reboundPartial) == Data("intruder".utf8))
    #expect(try Data(contentsOf: movedPartial) == Data("owned-partial".utf8))
}

@Test func atomicDownloadWriterRejectsWritesAfterClose() throws {
    let directory = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let destination = directory.appendingPathComponent("closed.bin")
    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    try writer.close()

    #expect(throws: AtomicDownloadWriterError.closed) {
        try writer.write(Data("late".utf8))
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(FileManager.default.fileExists(
        atPath: AtomicDownloadWriter.partialURL(for: destination).path
    ))
}

@Test func clientHelloEnvelopeBinaryRoundTrips() throws {
    let nonce = Data(repeating: 0x41, count: 32)
    let envelope = try HandshakeSmokeClient(
        sessionNonce: nonce
    ).clientHelloEnvelope(requestID: 1)

    let decodedEnvelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: envelope.serializedData())
    let decodedHello = try Droidmatch_V1_ClientHello(serializedBytes: decodedEnvelope.payload)

    #expect(decodedEnvelope.frameVersion == 1)
    #expect(decodedEnvelope.kind == .request)
    #expect(decodedEnvelope.payloadType == .clientHello)
    #expect(decodedHello.clientName == "DroidMatchHarness")
    #expect(decodedHello.protocolMajor == 1)
    #expect(decodedHello.transport == .adb)
    #expect(decodedHello.sessionNonce == nonce)
}

@Test func handshakeParserReadsEnvelopeErrorFieldWithoutPayload() throws {
    var error = Droidmatch_V1_DroidMatchError()
    error.code = .unauthorized
    error.message = "ClientHello must be the first request on a session"

    var envelope = Droidmatch_V1_RpcEnvelope()
    envelope.frameVersion = 1
    envelope.kind = .error
    envelope.requestID = 1
    envelope.payloadType = .droidmatchError
    envelope.error = error

    var decodedError: Droidmatch_V1_DroidMatchError?
    do {
        _ = try HandshakeSmokeClient.parseServerHelloResponse(
            envelope.serializedData(),
            expectedSessionNonce: Data(repeating: 0x41, count: 32)
        )
    } catch let HandshakeSmokeClientError.remoteError(error) {
        decodedError = error
    }

    #expect(decodedError?.code == .unauthorized)
    #expect(decodedError?.message == error.message)
}

@Test func handshakeClientRejectsInvalidSessionNonceLength() {
    #expect(throws: HandshakeSmokeClientError.self) {
        _ = try HandshakeSmokeClient(sessionNonce: Data()).clientHelloEnvelope()
    }
    #expect(throws: HandshakeSmokeClientError.self) {
        _ = try HandshakeSmokeClient(
            sessionNonce: Data(repeating: 0x41, count: 33)
        ).clientHelloEnvelope()
    }
}

@Test func handshakeParserRejectsMismatchedServerNonce() throws {
    let expectedNonce = Data(repeating: 0x41, count: 32)
    var serverHello = Droidmatch_V1_ServerHello()
    serverHello.serverName = "LocalFrameTestServer"
    serverHello.serverVersion = "test"
    serverHello.protocolMajor = 1
    serverHello.transport = .adb
    serverHello.sessionNonce = Data(repeating: 0x42, count: 32)

    var envelope = Droidmatch_V1_RpcEnvelope()
    envelope.frameVersion = 1
    envelope.kind = .response
    envelope.requestID = 1
    envelope.payloadType = .serverHello
    envelope.payload = try serverHello.serializedData()

    #expect(throws: HandshakeSmokeClientError.self) {
        _ = try HandshakeSmokeClient.parseServerHelloResponse(
            envelope.serializedData(),
            expectedSessionNonce: expectedNonce
        )
    }
}

@Test func adbDeviceParserHandlesLongOutput() {
    let output = """
    * daemon not running; starting now at tcp:5037
    * daemon started successfully
    List of devices attached
    ABC123 device product:oriole model:Pixel_6 device:oriole transport_id:1
    XYZ offline

    """

    let devices = AdbClient.parseDevices(output)

    #expect(devices.count == 2)
    #expect(devices[0].serial == "ABC123")
    #expect(devices[0].state == "device")
    #expect(devices[0].model == "Pixel_6")
    #expect(devices[1].state == "offline")
}

@Test func adbSerialRedactionNeverIncludesRawIdentity() {
    let serial = "private-device-serial-123456"
    let redacted = AdbClient.redactedSerial(serial)

    #expect(redacted == "<serial-redacted:067997c4>")
    #expect(!redacted.contains(serial))
    #expect(!redacted.contains("private-device"))
}

@Test func adbForwardParserHandlesEmptyAndMultipleForwards() {
    #expect(AdbClient.parseForwards("").isEmpty)

    let output = """
    ABC123 tcp:49152 tcp:39001
    XYZ tcp:49153 localabstract:droidmatch
    """

    let forwards = AdbClient.parseForwards(output)

    #expect(forwards.count == 2)
    #expect(forwards[0].serial == "ABC123")
    #expect(forwards[0].local == "tcp:49152")
    #expect(forwards[0].remote == "tcp:39001")
}

@Test func adbForwardParserHandlesAllocatedPortOutput() {
    #expect(AdbClient.parseAllocatedForwardPort("49152\n") == 49152)
    #expect(AdbClient.parseAllocatedForwardPort("\n\t49152  \n") == 49152)
    #expect(AdbClient.parseAllocatedForwardPort("* daemon started successfully\n49152\n") == 49152)
    #expect(AdbClient.parseAllocatedForwardPort("") == nil)
    #expect(AdbClient.parseAllocatedForwardPort("not-a-port") == nil)
}

@Test func adbForwardParserFindsExistingDynamicForward() {
    let forwards = [
        AdbForward(serial: "ABC123", local: "tcp:49152", remote: "tcp:39001"),
        AdbForward(serial: "ABC123", local: "localabstract:droidmatch", remote: "tcp:39002"),
        AdbForward(serial: "XYZ", local: "tcp:49153", remote: "tcp:39001")
    ]

    #expect(AdbClient.findForwardedTcpPort(in: forwards, serial: "ABC123", remotePort: 39001) == 49152)
    #expect(AdbClient.findForwardedTcpPort(in: forwards, serial: "ABC123", remotePort: 39002) == nil)
    #expect(AdbClient.findForwardedTcpPort(in: forwards, serial: "MISSING", remotePort: 39001) == nil)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DroidMatchTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
