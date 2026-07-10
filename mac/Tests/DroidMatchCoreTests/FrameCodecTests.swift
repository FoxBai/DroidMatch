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

@Test func framedTcpClientRoundTripsAgainstLocalEchoServer() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.echoOneFrame)
    defer {
        server.cancel()
    }

    let payload = Data("loopback-echo".utf8)
    let client = FramedTcpClient(port: server.port, timeoutSeconds: 2)
    #expect(try client.roundTrip(payload: payload) == payload)
}

@Test func framedTcpSessionBuffersCoalescedFrames() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.sendTwoFramesTogether)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }

    #expect(try session.receivePayload() == Data("first".utf8))
    #expect(try session.receivePayload() == Data("second".utf8))
}

@Test func framedTcpClientPerformsClientHelloServerHelloHandshake() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyWithServerHello)
    defer {
        server.cancel()
    }

    let result = try HandshakeSmokeClient().run(port: server.port, timeoutSeconds: 2)

    #expect(result.serverName == "LocalFrameTestServer")
    #expect(result.serverVersion == "test")
    #expect(result.protocolMajor == 1)
    #expect(result.transport == .adb)
    #expect(result.grantedCapabilities == [.diagnostics])
}

@Test func m1SmokeClientRunsHandshakeHeartbeatDeviceInfoDiagnosticsOnOneConnection() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer {
        server.cancel()
    }

    let result = try M1SmokeClient().run(port: server.port, timeoutSeconds: 2)

    #expect(result.handshake.serverName == "LocalFrameTestServer")
    #expect(result.heartbeat.monotonicMillis > 0)
    #expect(result.deviceInfo.manufacturer == "DroidMatch")
    #expect(result.deviceInfo.model == "Loopback")
    #expect(result.deviceInfo.sdkInt == 35)
    #expect(result.deviceInfo.permissions["media_read"] == .granted)
    #expect(result.rootList.entries.count == 1)
    #expect(result.rootList.entries[0].path == "dm://media-images/")
    #expect(result.rootList.entries[0].kind == .virtual)
    #expect(result.diagnostics.transport == .adb)
    #expect(result.diagnostics.serviceState == "rpc.session.open")
    #expect(result.diagnostics.recentEvents.contains { $0.hasSuffix(":state:rpc.session.open") })
}

@Test func rpcControlClientRoundTripsHeartbeat() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let heartbeat = try client.heartbeat(monotonicMillis: 123456789)

    #expect(heartbeat.monotonicMillis == 123456789)
}

@Test func rpcControlClientDownloadsFirstChunkAndAcks() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let result = try client.downloadFirstChunk(
        sourcePath: "dm://media-images/media/42",
        transferID: "loopback-transfer",
        preferredChunkSizeBytes: 16
    )

    #expect(result.openResponse.transferID == "loopback-transfer")
    #expect(result.openResponse.chunkSizeBytes == 16)
    #expect(result.openResponse.streamID == 2)
    #expect(result.chunk.transferID == "loopback-transfer")
    #expect(result.chunk.offsetBytes == 0)
    #expect(result.chunk.data == Data("download-bytes".utf8))
    #expect(result.chunk.crc32 == Crc32.checksum(Data("download-bytes".utf8)))
    #expect(result.chunk.finalChunk)
}

@Test func rpcControlClientRejectsDownloadChunkWithBadChecksum() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToBadChecksumDownloadRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    var sawChecksumMismatch = false
    do {
        _ = try client.downloadFirstChunk(
            sourcePath: "dm://media-images/media/42",
            transferID: "loopback-transfer",
            preferredChunkSizeBytes: 16
        )
    } catch let RpcControlClientError.checksumMismatch(expected, actual) {
        sawChecksumMismatch = expected == 0
            && actual == Crc32.checksum(Data("download-bytes".utf8))
    }

    #expect(sawChecksumMismatch)
}

@Test func rpcControlClientDownloadsAllChunksAndAcksEachBoundary() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToMultiChunkDownloadRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    var downloaded = Data()
    let result = try client.download(
        sourcePath: "dm://media-images/media/42",
        transferID: "loopback-transfer",
        preferredChunkSizeBytes: 8
    ) { chunk in
        downloaded.append(chunk.data)
    }

    #expect(downloaded == Data("download-bytes".utf8))
    #expect(result.openResponse.transferID == "loopback-transfer")
    #expect(result.openResponse.chunkSizeBytes == 8)
    #expect(result.openResponse.totalSizeBytes == 14)
    #expect(result.chunkCount == 2)
    #expect(result.bytesReceived == 14)
    #expect(result.finalOffsetBytes == 14)
}

@Test func rpcControlClientResumesDownloadFromAcceptedOffset() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToMultiChunkDownloadRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 14
    fingerprint.modifiedUnixMillis = 1_700_000_000_000
    fingerprint.providerEtag = "loopback-etag"
    var downloaded = Data("download".utf8)
    let result = try client.download(
        sourcePath: "dm://media-images/media/42",
        transferID: "loopback-transfer",
        requestedOffsetBytes: 8,
        sourceFingerprint: fingerprint,
        preferredChunkSizeBytes: 8
    ) { chunk in
        downloaded.append(chunk.data)
    }

    #expect(downloaded == Data("download-bytes".utf8))
    #expect(result.openResponse.acceptedOffsetBytes == 8)
    #expect(result.chunkCount == 1)
    #expect(result.bytesReceived == 6)
    #expect(result.finalOffsetBytes == 14)
}

@Test func rpcControlClientCancelsDownloadAfterFirstChunk() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToMultiChunkDownloadRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let result = try client.downloadFirstChunkThenCancel(
        sourcePath: "dm://media-images/media/42",
        transferID: "loopback-transfer",
        preferredChunkSizeBytes: 8,
        reason: "test-cancel"
    )

    #expect(result.openResponse.transferID == "loopback-transfer")
    #expect(result.chunk.data == Data("download".utf8))
    #expect(!result.chunk.finalChunk)
    #expect(result.cancelResponse.transferID == "loopback-transfer")
    #expect(result.cancelResponse.ok)
    #expect(!result.cancelResponse.hasError)
}

@Test func rpcControlClientPausesDownloadAfterFirstChunk() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToMultiChunkDownloadRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let result = try client.downloadFirstChunkThenPause(
        sourcePath: "dm://media-images/media/42",
        transferID: "loopback-transfer",
        preferredChunkSizeBytes: 8
    )

    #expect(result.openResponse.transferID == "loopback-transfer")
    #expect(result.chunk.data == Data("download".utf8))
    #expect(!result.chunk.finalChunk)
    #expect(result.pauseResponse.transferID == "loopback-transfer")
    #expect(result.pauseResponse.ok)
    #expect(result.pauseResponse.resumableOffsetBytes == 0)
    #expect(!result.pauseResponse.hasError)
}

@Test func rpcControlClientUploadsChunksAndWaitsForAcks() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToUploadRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()
    let payload = Data("upload-bytes".utf8)

    let result = try client.upload(
        sourcePath: "/tmp/upload-bytes.bin",
        destinationPath: "dm://app-sandbox/upload-bytes.bin",
        expectedSizeBytes: Int64(payload.count),
        transferID: "loopback-upload",
        preferredChunkSizeBytes: 6
    ) { offset, byteCount in
        let start = payload.index(payload.startIndex, offsetBy: Int(offset))
        let end = payload.index(start, offsetBy: byteCount)
        return payload[start..<end]
    }

    #expect(result.openResponse.transferID == "loopback-upload")
    #expect(result.openResponse.chunkSizeBytes == 6)
    #expect(result.chunkCount == 2)
    #expect(result.bytesSent == Int64(payload.count))
    #expect(result.finalOffsetBytes == Int64(payload.count))
}

@Test func rpcControlClientResumesUploadFromAcceptedOffset() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToUploadResumeRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()
    let payload = Data("upload-bytes".utf8)
    let resumeOffset = Int64(Data("upload-".utf8).count)

    let result = try client.upload(
        sourcePath: "/tmp/upload-bytes.bin",
        destinationPath: "dm://app-sandbox/upload-bytes.bin",
        expectedSizeBytes: Int64(payload.count),
        transferID: "loopback-upload",
        requestedOffsetBytes: resumeOffset,
        preferredChunkSizeBytes: 6
    ) { offset, byteCount in
        let start = payload.index(payload.startIndex, offsetBy: Int(offset))
        let end = payload.index(start, offsetBy: byteCount)
        return payload[start..<end]
    }

    #expect(result.openResponse.acceptedOffsetBytes == resumeOffset)
    #expect(result.chunkCount == 1)
    #expect(result.bytesSent == Int64(payload.count) - resumeOffset)
    #expect(result.finalOffsetBytes == Int64(payload.count))
}

@Test func rpcControlClientSurfacesUploadOpenRemoteError() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToUploadOpenUnsupportedRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    var sawUnsupportedCapability = false
    do {
        _ = try client.upload(
            sourcePath: "/tmp/upload-bytes.bin",
            destinationPath: "dm://media-images/upload-bytes.jpg",
            expectedSizeBytes: Int64(Data("upload-bytes".utf8).count),
            transferID: "loopback-upload",
            requestedOffsetBytes: 1,
            preferredChunkSizeBytes: 6
        ) { _, _ in
            Data()
        }
    } catch let RpcControlClientError.remoteError(error) {
        sawUnsupportedCapability = error.code == .unsupportedCapability
            && error.message == "MediaStore upload resume is not supported"
    }

    #expect(sawUnsupportedCapability)
}

@Test func rpcControlClientSurfacesDownloadOpenRemoteError() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToDownloadOpenNotFoundRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    var sawNotFound = false
    do {
        _ = try client.downloadFirstChunk(
            sourcePath: "dm://app-sandbox/missing-download.bin",
            transferID: "missing-download",
            preferredChunkSizeBytes: 6
        )
    } catch let RpcControlClientError.remoteError(error) {
        sawNotFound = error.code == .notFound
            && error.message == "download source is not available"
    }

    #expect(sawNotFound)
}

@Test func rpcControlClientReturnsListDirResponseError() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToListDirPermissionRequiredRequests)
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let response = try client.listDir(path: "dm://media-images/")
    #expect(response.hasError)
    #expect(response.error.code == .permissionRequired)
    #expect(response.error.message == "media permission is required")
}

@Test func framedTcpClientTimesOutWhenServerDoesNotReply() throws {
    let server = try LocalFrameTestServer { _ in }
    defer {
        server.cancel()
    }

    let client = FramedTcpClient(port: server.port, timeoutSeconds: 0.2)
    var sawReadHeaderTimeout = false
    do {
        _ = try client.roundTrip(payload: Data("no-reply".utf8))
    } catch let FramedTcpClientError.timedOut(stage, _) {
        sawReadHeaderTimeout = stage == "reading frame header"
    } catch {
        sawReadHeaderTimeout = false
    }

    #expect(sawReadHeaderTimeout)
}

@Test func framedTcpClientRejectsEmptyFrameFromServer() throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.sendEmptyFrameHeader)
    defer {
        server.cancel()
    }

    let client = FramedTcpClient(port: server.port, timeoutSeconds: 1)
    #expect(throws: FrameCodecError.emptyFrame) {
        _ = try client.roundTrip(payload: Data("bad-frame".utf8))
    }
}

// MARK: - 端到端恢复队列测试
//
// 这一组测试用 LocalFrameTestServer 模拟传输中断（前 N 次连接在 handshake
// 之后立即断开），验证 RpcControlClient.download / upload 配合
// runTransferWithRecovery 能在多次 transport-loss 后最终完成，且 attempt
// cap 耗尽时正确抛出最后一个错误。这些测试是恢复队列的 loop-verified
// 集成证据：不依赖真机，只在本地 loopback 上验证策略 + 协议层的契约。

@Test func recoveryQueueRecoverDownloadAfterTwoTransportLosses() throws {
    // 共享连接计数器：前 2 次（index 0、1）断连，第 3 次（index 2）正常。
    let connectionIndex = LockedValue(0)
    let server = try LocalFrameTestServer { connection in
        connectionIndex.update { $0 += 1 }
        let idx = connectionIndex.value()
        if idx <= 2 {
            // 前两次：先回 ServerHello 让 handshake 成功，再立即断开连接，
            // 触发后续 download 的 connectionClosed（可重试错误）。
            LocalFrameTestServer.replyWithServerHelloThenDrop(on: connection)
            return
        }
        // 第 3 次：走正常的 multi-chunk download 流程。
        LocalFrameTestServer.replyToMultiChunkDownloadRequests(on: connection)
    }
    defer {
        server.cancel()
    }

    // 策略允许 3 次重试，退避 1ms（测试里不真睡），无抖动。
    let policy = RecoveryPolicy(
        maxAttempts: 3,
        baseDelayMs: 1,
        maxDelayMs: 10,
        jitterFactor: 0
    )
    let slept = LockedValue<[Int64]>([])
    let sleeper: RecoverySleeper = { delayMs in
        slept.update { $0.append(delayMs) }
    }
    let attemptCount = LockedValue(0)
    let downloaded = LockedValue(Data())

    let result = try runTransferWithRecovery(
        policy: policy,
        sleeper: sleeper,
        isRetryable: { error in
            // connectionClosed / timedOut / connectionFailed 都可重试。
            switch error {
            case FramedTcpClientError.timedOut,
                 FramedTcpClientError.connectionFailed,
                 FramedTcpClientError.connectionClosed:
                return true
            default:
                return false
            }
        },
        canResume: { true },
        attempt: { _ in
            attemptCount.update { $0 += 1 }
            // 每次尝试都开一个新 session，模拟 harness 的重连行为。
            let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
            defer { session.close() }
            let client = RpcControlClient(session: session)
            _ = try client.handshake()
            return try client.download(
                sourcePath: "dm://media-images/media/42",
                transferID: "recovery-test",
                preferredChunkSizeBytes: 8
            ) { chunk in
                downloaded.update { $0.append(chunk.data) }
            }
        }
    )

    #expect(downloaded.value() == Data("download-bytes".utf8))
    #expect(result.chunkCount == 2)
    #expect(result.bytesReceived == 14)
    #expect(attemptCount.value() == 3)
    // 2 次失败 -> 2 次退避，按指数 1ms、2ms。
    #expect(slept.value() == [1, 2])
}

@Test func recoveryQueueExhaustsAttemptsAndThrowsLastError() throws {
    // 服务器永远在 handshake 后断连，模拟持续不可达。
    let server = try LocalFrameTestServer { connection in
        LocalFrameTestServer.replyWithServerHelloThenDrop(on: connection)
    }
    defer {
        server.cancel()
    }

    // 只允许 2 次重试。
    let policy = RecoveryPolicy(
        maxAttempts: 2,
        baseDelayMs: 1,
        maxDelayMs: 10,
        jitterFactor: 0
    )
    let sleeper: RecoverySleeper = { _ in }
    let attemptCount = LockedValue(0)

    #expect(throws: FramedTcpClientError.self) {
        _ = try runTransferWithRecovery(
            policy: policy,
            sleeper: sleeper,
            isRetryable: { error in
                switch error {
                case FramedTcpClientError.timedOut,
                     FramedTcpClientError.connectionFailed,
                     FramedTcpClientError.connectionClosed:
                    return true
                default:
                    return false
                }
            },
            canResume: { true },
            attempt: { _ in
                attemptCount.update { $0 += 1 }
                let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
                defer { session.close() }
                let client = RpcControlClient(session: session)
                _ = try client.handshake()
                return try client.download(
                    sourcePath: "dm://media-images/media/42",
                    transferID: "recovery-exhaust",
                    preferredChunkSizeBytes: 8
                ) { _ in }
            }
        )
    }

    // 首次 + 2 次重试 = 3 次总尝试后抛出。
    #expect(attemptCount.value() == 3)
}

// MARK: - Upload 滑动窗口端到端测试
//
// 以下测试用泛化 upload echo 服务器验证 `RpcControlClient.upload` 的滑动窗口
// 行为：payload 大到需要多于 `UploadWindow.maxInFlightChunks` 个 chunk 时，
// 触发"窗口满 → 收 ACK → 补发"路径，证明窗口化正确性。

@Test func rpcControlClientUploadsLargePayloadWithWindowLargerThanInFlight() throws {
    // 40 字节 payload / 6 字节 chunk = 7 个 chunk，超过 maxInFlightChunks=4，
    // 必然触发"发 4 个 → 收 ACK → 补发 3 个"的分批路径。
    let payload = Data((0..<40).map { _ in UInt8.random(in: 0...255) })
    let chunkSize = 6
    let expectedChunks = (payload.count + chunkSize - 1) / chunkSize
    let ackCount = LockedValue(0)
    let readOffsetsBeforeFirstAck = LockedValue<[Int64]>([])
    let server = try LocalFrameTestServer(
        handler: LocalFrameTestServer.replyToUploadRequestsEchoing(
            payload: payload,
            transferID: "window-upload",
            destinationPath: "dm://app-sandbox/window-upload.bin",
            chunkSize: chunkSize
        )
    )
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let result = try client.upload(
        sourcePath: "/tmp/window-upload.bin",
        destinationPath: "dm://app-sandbox/window-upload.bin",
        expectedSizeBytes: Int64(payload.count),
        transferID: "window-upload",
        preferredChunkSizeBytes: UInt32(chunkSize),
        didAck: { _ in
            ackCount.update { $0 += 1 }
        }
    ) { offset, byteCount in
        if ackCount.value() == 0 {
            readOffsetsBeforeFirstAck.update { $0.append(offset) }
        }
        let start = payload.index(payload.startIndex, offsetBy: Int(offset))
        let end = payload.index(start, offsetBy: byteCount)
        return payload[start..<end]
    }

    #expect(result.openResponse.transferID == "window-upload")
    #expect(result.openResponse.chunkSizeBytes == UInt32(chunkSize))
    // 7 个 chunk 全部发出并确认。
    #expect(result.chunkCount == expectedChunks)
    #expect(result.bytesSent == Int64(payload.count))
    #expect(result.finalOffsetBytes == Int64(payload.count))
    #expect(readOffsetsBeforeFirstAck.value() == [0, 6, 12, 18])
}

@Test func rpcControlClientUploadHonorsSendLimitBeforeCompletion() throws {
    let payload = Data((0..<20).map(UInt8.init))
    let chunkSize = 6
    let sendLimitBytes: Int64 = 12
    let ackOffsets = LockedValue<[Int64]>([])
    let readOffsets = LockedValue<[Int64]>([])
    let server = try LocalFrameTestServer(
        handler: LocalFrameTestServer.replyToUploadRequestsEchoing(
            payload: payload,
            transferID: "limited-upload",
            destinationPath: "dm://app-sandbox/limited-upload.bin",
            chunkSize: chunkSize
        )
    )
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    var stoppedAtLimit = false
    do {
        _ = try client.upload(
            sourcePath: "/tmp/limited-upload.bin",
            destinationPath: "dm://app-sandbox/limited-upload.bin",
            expectedSizeBytes: Int64(payload.count),
            transferID: "limited-upload",
            preferredChunkSizeBytes: UInt32(chunkSize),
            sendLimitBytes: sendLimitBytes,
            didAck: { ack in
                ackOffsets.update { $0.append(ack.nextOffsetBytes) }
                if ack.nextOffsetBytes >= sendLimitBytes {
                    throw LocalUploadStop.stopAfterLimit
                }
            }
        ) { offset, byteCount in
            readOffsets.update { $0.append(offset) }
            let start = payload.index(payload.startIndex, offsetBy: Int(offset))
            let end = payload.index(start, offsetBy: byteCount)
            return payload[start..<end]
        }
    } catch LocalUploadStop.stopAfterLimit {
        stoppedAtLimit = true
    }

    #expect(stoppedAtLimit)
    #expect(readOffsets.value() == [0, 6])
    #expect(ackOffsets.value() == [6, sendLimitBytes])
}

@Test func rpcControlClientUploadsEmptyPayloadAsFinalChunk() throws {
    let payload = Data()
    let chunkSize = 6
    let readCallCount = LockedValue(0)
    let server = try LocalFrameTestServer(
        handler: LocalFrameTestServer.replyToUploadRequestsEchoing(
            payload: payload,
            transferID: "empty-window-upload",
            destinationPath: "dm://app-sandbox/empty-window-upload.bin",
            chunkSize: chunkSize
        )
    )
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let result = try client.upload(
        sourcePath: "/tmp/empty-window-upload.bin",
        destinationPath: "dm://app-sandbox/empty-window-upload.bin",
        expectedSizeBytes: 0,
        transferID: "empty-window-upload",
        preferredChunkSizeBytes: UInt32(chunkSize)
    ) { offset, byteCount in
        readCallCount.update { $0 += 1 }
        #expect(offset == 0)
        #expect(byteCount == 0)
        return payload
    }

    #expect(result.openResponse.transferID == "empty-window-upload")
    #expect(result.chunkCount == 1)
    #expect(result.bytesSent == 0)
    #expect(result.finalOffsetBytes == 0)
    #expect(readCallCount.value() == 1)
}

@Test func rpcControlClientUploadResumesWithWindowFromNonZeroOffset() throws {
    // resume 场景：服务器预置已收到前 6 字节（offset 6），客户端从 6 起发剩余。
    let fullPayload = Data((0..<40).map { _ in UInt8.random(in: 0...255) })
    let alreadyReceived = fullPayload.prefix(6)
    let chunkSize = 6
    let remaining = fullPayload.suffix(from: 6)
    let expectedRemainingChunks = (remaining.count + chunkSize - 1) / chunkSize

    // 服务器从 offset 6 起校验，期望收到剩余 34 字节。
    let server = try LocalFrameTestServer { connection in
        LocalFrameTestServer.readUploadRequestEchoing(
            on: connection,
            received: Data(alreadyReceived),
            transferID: nil,
            expectedSizeBytes: Int64(fullPayload.count),
            expectedTotalPayload: fullPayload,
            expectedTransferID: "window-resume",
            expectedDestinationPath: "dm://app-sandbox/window-resume.bin",
            streamID: nil
        )
    }
    defer {
        server.cancel()
    }

    let session = try FramedTcpSession(port: server.port, timeoutSeconds: 2)
    defer {
        session.close()
    }
    let client = RpcControlClient(session: session)
    _ = try client.handshake()

    let result = try client.upload(
        sourcePath: "/tmp/window-resume.bin",
        destinationPath: "dm://app-sandbox/window-resume.bin",
        expectedSizeBytes: Int64(fullPayload.count),
        transferID: "window-resume",
        requestedOffsetBytes: Int64(alreadyReceived.count),
        preferredChunkSizeBytes: UInt32(chunkSize)
    ) { offset, byteCount in
        let start = fullPayload.index(fullPayload.startIndex, offsetBy: Int(offset))
        let end = fullPayload.index(start, offsetBy: byteCount)
        return fullPayload[start..<end]
    }

    #expect(result.openResponse.acceptedOffsetBytes == Int64(alreadyReceived.count))
    // 只发了剩余部分的 chunk。
    #expect(result.chunkCount == expectedRemainingChunks)
    #expect(result.bytesSent == Int64(remaining.count))
    #expect(result.finalOffsetBytes == Int64(fullPayload.count))
}



private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DroidMatchTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum LocalEchoServerError: Error {
    case listenerDidNotBecomeReady
    case missingPort
    case unexpectedPayloadType
}

private enum LocalUploadStop: Error {
    case stopAfterLimit
}

final class LocalFrameTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.droidmatch.tests.local-framed-echo")

    let port: Int

    init(handler: @escaping @Sendable (NWConnection) -> Void) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            handler(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            throw LocalEchoServerError.listenerDidNotBecomeReady
        }
        guard let rawPort = listener.port?.rawValue else {
            throw LocalEchoServerError.missingPort
        }
        port = Int(rawPort)
    }

    func cancel() {
        listener.cancel()
    }

    static func echoOneFrame(on connection: NWConnection) {
        echoFrames(1, on: connection)
    }

    static func echoFrames(
        _ remaining: Int,
        delayBeforeResponse: TimeInterval = 0,
        on connection: NWConnection
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                var frame = Data()
                frame.append(header)
                frame.append(body)
                let responseFrame = frame
                let sendResponse: @Sendable () -> Void = {
                    connection.send(content: responseFrame, completion: .contentProcessed { error in
                        guard error == nil, remaining > 1 else {
                            connection.cancel()
                            return
                        }
                        echoFrames(remaining - 1, on: connection)
                    })
                }
                if delayBeforeResponse > 0 {
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + delayBeforeResponse,
                        execute: sendResponse
                    )
                } else {
                    sendResponse()
                }
            }
        }
    }

    static func sendTwoFramesTogether(on connection: NWConnection) {
        guard let first = try? FrameCodec().encode(payload: Data("first".utf8)),
              let second = try? FrameCodec().encode(payload: Data("second".utf8)) else {
            connection.cancel()
            return
        }
        var combined = Data()
        combined.append(first)
        combined.append(second)
        connection.send(content: combined, completion: .contentProcessed { _ in })
    }

    static func replyWithServerHello(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                guard let response = try? handshakeResponse(to: body),
                      let frame = try? FrameCodec().encode(payload: response) else {
                    connection.cancel()
                    return
                }
                connection.send(content: frame, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// 回复 ServerHello 让 handshake 成功，然后立即断开连接。
    /// 用于端到端恢复队列测试：客户端 handshake 成功后，download 阶段
    /// 第一次 read 会遇到 `connectionClosed`（可重试错误）。
    static func replyWithServerHelloThenDrop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                guard let response = try? handshakeResponse(to: body),
                      let frame = try? FrameCodec().encode(payload: response) else {
                    connection.cancel()
                    return
                }
                // 发完 ServerHello 立刻断连，模拟传输中断。
                connection.send(content: frame, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    static func replyToM1SmokeRequests(on connection: NWConnection) {
        readM1SmokeRequest(on: connection)
    }

    static func pairedAuthenticationHandler(
        pairingID: Data,
        pairingKey: Data,
        corruptServerProof: Bool = false,
        allowMissingPairingID: Bool = false
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            readPairedClientHello(
                on: connection,
                pairingID: pairingID,
                pairingKey: pairingKey,
                corruptServerProof: corruptServerProof,
                allowMissingPairingID: allowMissingPairingID
            )
        }
    }

    static func replyToBadChecksumDownloadRequests(on connection: NWConnection) {
        readM1SmokeRequest(on: connection, corruptDownloadCrc: true)
    }

    static func replyToMultiChunkDownloadRequests(on connection: NWConnection) {
        readMultiChunkDownloadRequest(
            on: connection,
            chunks: [Data("download".utf8), Data("-bytes".utf8)],
            nextChunkIndex: 0,
            transferID: nil
        )
    }

    static func replyToUploadRequests(on connection: NWConnection) {
        readUploadRequest(
            on: connection,
            received: Data(),
            transferID: nil,
            expectedSizeBytes: 0,
            streamID: nil
        )
    }

    /// 泛化 upload echo 服务器：接受任意 payload 和 transfer id，逐 chunk
    /// 校验 offset/CRC、按顺序回 ACK。用于窗口化端到端测试（payload 大到
    /// 需要多于 maxInFlightChunks 个 chunk，触发"窗口满 → ACK → 补发"路径）。
    static func replyToUploadRequestsEchoing(
        payload: Data,
        transferID: String,
        destinationPath: String,
        chunkSize: Int
    ) -> (@Sendable (NWConnection) -> Void) {
        { connection in
            readUploadRequestEchoing(
                on: connection,
                received: Data(),
                transferID: nil,
                expectedSizeBytes: Int64(payload.count),
                expectedTotalPayload: payload,
                expectedTransferID: transferID,
                expectedDestinationPath: destinationPath,
                streamID: nil
            )
        }
    }

    static func replyToUploadResumeRequests(on connection: NWConnection) {
        readUploadRequest(
            on: connection,
            received: Data("upload-".utf8),
            transferID: nil,
            expectedSizeBytes: Int64(Data("upload-bytes".utf8).count),
            streamID: nil
        )
    }

    static func replyToUploadOpenUnsupportedRequests(on connection: NWConnection) {
        readUploadOpenUnsupportedRequest(on: connection)
    }

    static func replyToDownloadOpenNotFoundRequests(on connection: NWConnection) {
        readDownloadOpenNotFoundRequest(on: connection)
    }

    static func replyToListDirPermissionRequiredRequests(on connection: NWConnection) {
        readListDirPermissionRequiredRequest(on: connection, didHandshake: false)
    }

    static func sendEmptyFrameHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
            connection.send(content: Data([0, 0, 0, 0]), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func readListDirPermissionRequiredRequest(on connection: NWConnection, didHandshake: Bool) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? listDirPermissionRequiredResponse(
                          to: body,
                          didHandshake: didHandshake
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readListDirPermissionRequiredRequest(on: connection, didHandshake: true)
                    }
                }
            }
        }
    }

    private static func readDownloadOpenNotFoundRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? downloadOpenNotFoundResponse(to: body) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readDownloadOpenNotFoundRequest(on: connection)
                    }
                }
            }
        }
    }

    private static func readUploadOpenUnsupportedRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? uploadOpenUnsupportedResponse(to: body) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readUploadOpenUnsupportedRequest(on: connection)
                    }
                }
            }
        }
    }

    private static func readM1SmokeRequest(
        on connection: NWConnection,
        corruptDownloadCrc: Bool = false
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                guard let response = try? m1SmokeResponse(
                    to: body,
                    corruptDownloadCrc: corruptDownloadCrc
                ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readM1SmokeRequest(on: connection, corruptDownloadCrc: corruptDownloadCrc)
                    }
                }
            }
        }
    }

    private static func readPairedClientHello(
        on connection: NWConnection,
        pairingID: Data,
        pairingKey: Data,
        corruptServerProof: Bool,
        allowMissingPairingID: Bool
    ) {
        receiveFrameBody(on: connection) { requestBody in
            do {
                let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
                guard request.payloadType == .clientHello else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                let clientHello = try Droidmatch_V1_ClientHello(serializedBytes: request.payload)
                guard clientHello.pairingID == pairingID
                        || (allowMissingPairingID && clientHello.pairingID.isEmpty) else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }

                let serverNonce = Data((0..<SessionAuthenticator.nonceLength).map {
                    UInt8(0x40 + $0)
                })
                var serverHello = Droidmatch_V1_ServerHello()
                serverHello.serverName = "PairedLocalFrameTestServer"
                serverHello.serverVersion = "test"
                serverHello.protocolMajor = 1
                serverHello.protocolMinor = min(clientHello.protocolMinor, 0)
                serverHello.transport = .adb
                serverHello.sessionNonce = clientHello.sessionNonce
                serverHello.serverNonce = serverNonce
                serverHello.authenticationState = .required

                var response = Droidmatch_V1_RpcEnvelope()
                response.frameVersion = 1
                response.kind = .response
                response.requestID = request.requestID
                response.payloadType = .serverHello
                response.payload = try serverHello.serializedData()
                send([try response.serializedData()], on: connection) {
                    readPairedProof(
                        on: connection,
                        pairingID: pairingID,
                        pairingKey: pairingKey,
                        clientNonce: clientHello.sessionNonce,
                        serverNonce: serverNonce,
                        corruptServerProof: corruptServerProof
                    )
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private static func readPairedProof(
        on connection: NWConnection,
        pairingID: Data,
        pairingKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        corruptServerProof: Bool
    ) {
        receiveFrameBody(on: connection) { requestBody in
            do {
                let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
                guard request.payloadType == .authenticateSessionRequest else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                let authentication = try Droidmatch_V1_AuthenticateSessionRequest(
                    serializedBytes: request.payload
                )
                let transcript = try SessionAuthenticator.transcript(
                    pairingID: pairingID,
                    clientNonce: clientNonce,
                    serverNonce: serverNonce,
                    protocolMajor: 1,
                    protocolMinor: 0,
                    transport: .adb
                )
                let transcriptHash = SessionAuthenticator.transcriptHash(transcript)
                let valid = try authentication.pairingID == pairingID
                    && SessionAuthenticator.verifyClientProof(
                        authentication.clientProof,
                        pairingKey: pairingKey,
                        transcriptHash: transcriptHash
                    )

                var authenticationResponse = Droidmatch_V1_AuthenticateSessionResponse()
                authenticationResponse.authenticated = valid
                if valid {
                    var serverProof = try SessionAuthenticator.serverProof(
                        pairingKey: pairingKey,
                        transcriptHash: transcriptHash
                    )
                    if corruptServerProof {
                        serverProof[serverProof.startIndex] ^= 0x01
                    }
                    authenticationResponse.serverProof = serverProof
                    authenticationResponse.grantedCapabilities = [.diagnostics]
                } else {
                    var error = Droidmatch_V1_DroidMatchError()
                    error.code = .unauthorized
                    error.message = "session authentication failed"
                    authenticationResponse.error = error
                }

                var response = Droidmatch_V1_RpcEnvelope()
                response.frameVersion = 1
                response.kind = .response
                response.requestID = request.requestID
                response.payloadType = .authenticateSessionResponse
                response.payload = try authenticationResponse.serializedData()
                send([try response.serializedData()], on: connection) {
                    connection.cancel()
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private static func receiveFrameBody(
        on connection: NWConnection,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                completion(body)
            }
        }
    }

    private static func readMultiChunkDownloadRequest(
        on connection: NWConnection,
        chunks: [Data],
        nextChunkIndex: Int,
        transferID: String?
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? multiChunkDownloadResponse(
                          to: body,
                          chunks: chunks,
                          nextChunkIndex: nextChunkIndex,
                          transferID: transferID
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readMultiChunkDownloadRequest(
                            on: connection,
                            chunks: chunks,
                            nextChunkIndex: response.nextChunkIndex,
                            transferID: response.transferID
                        )
                    }
                }
            }
        }
    }

    private static func readUploadRequest(
        on connection: NWConnection,
        received: Data,
        transferID: String?,
        expectedSizeBytes: Int64,
        streamID: UInt64?
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? uploadResponse(
                          to: body,
                          received: received,
                          transferID: transferID,
                          expectedSizeBytes: expectedSizeBytes,
                          streamID: streamID
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readUploadRequest(
                            on: connection,
                            received: response.received,
                            transferID: response.transferID,
                            expectedSizeBytes: response.expectedSizeBytes,
                            streamID: response.streamID
                        )
                    }
                }
            }
        }
    }

    /// 泛化版 readUploadRequest：接受任意 payload/transferID/destinationPath，
    /// 用于窗口化端到端测试。逻辑与 readUploadRequest 对称：收一帧 → 回 ACK → 续读。
    /// fileprivate 让同文件内的顶层测试函数能直接调用（构造 resume 场景的服务器）。
    fileprivate static func readUploadRequestEchoing(
        on connection: NWConnection,
        received: Data,
        transferID: String?,
        expectedSizeBytes: Int64,
        expectedTotalPayload: Data,
        expectedTransferID: String,
        expectedDestinationPath: String,
        streamID: UInt64?
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length),
                      let response = try? uploadResponseEchoing(
                          to: body,
                          received: received,
                          transferID: transferID,
                          expectedSizeBytes: expectedSizeBytes,
                          streamID: streamID,
                          expectedPayload: expectedTotalPayload,
                          expectedTransferID: expectedTransferID,
                          expectedDestinationPath: expectedDestinationPath
                      ) else {
                    connection.cancel()
                    return
                }
                send(response.payloads, on: connection) {
                    if response.isFinal {
                        connection.cancel()
                    } else {
                        readUploadRequestEchoing(
                            on: connection,
                            received: response.received,
                            transferID: response.transferID,
                            expectedSizeBytes: response.expectedSizeBytes,
                            expectedTotalPayload: expectedTotalPayload,
                            expectedTransferID: expectedTransferID,
                            expectedDestinationPath: expectedDestinationPath,
                            streamID: response.streamID
                        )
                    }
                }
            }
        }
    }

    private static func send(_ payloads: [Data], on connection: NWConnection, completion: @escaping @Sendable () -> Void) {
        guard let payload = payloads.first,
              let frame = try? FrameCodec().encode(payload: payload) else {
            completion()
            return
        }
        connection.send(content: frame, completion: .contentProcessed { _ in
            send(Array(payloads.dropFirst()), on: connection, completion: completion)
        })
    }

    private static func handshakeResponse(to requestBody: Data) throws -> Data {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        let clientHello = try Droidmatch_V1_ClientHello(serializedBytes: request.payload)

        var serverHello = Droidmatch_V1_ServerHello()
        serverHello.serverName = "LocalFrameTestServer"
        serverHello.serverVersion = "test"
        serverHello.protocolMajor = 1
        serverHello.protocolMinor = min(clientHello.protocolMinor, 0)
        serverHello.transport = .adb
        serverHello.sessionNonce = clientHello.sessionNonce
        serverHello.authenticationState = .correlated
        if clientHello.requestedCapabilities.contains(.diagnostics) {
            serverHello.grantedCapabilities = [.diagnostics]
        }

        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .serverHello
        response.payload = try serverHello.serializedData()
        return try response.serializedData()
    }

    private static func m1SmokeResponse(
        to requestBody: Data,
        corruptDownloadCrc: Bool = false
    ) throws -> LocalControlPlaneResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalControlPlaneResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false
            )
        case .deviceInfoRequest:
            _ = try Droidmatch_V1_DeviceInfoRequest(serializedBytes: request.payload)
            var deviceInfo = Droidmatch_V1_DeviceInfoResponse()
            deviceInfo.deviceID = "loopback-test"
            deviceInfo.manufacturer = "DroidMatch"
            deviceInfo.model = "Loopback"
            deviceInfo.androidVersion = "15"
            deviceInfo.sdkInt = 35
            deviceInfo.totalStorageBytes = 1024
            deviceInfo.freeStorageBytes = 512
            deviceInfo.batteryPercent = 87
            deviceInfo.permissions = ["media_read": .granted]
            response.payloadType = .deviceInfoResponse
            response.payload = try deviceInfo.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: false)
        case .heartbeatRequest:
            let heartbeat = try Droidmatch_V1_HeartbeatRequest(serializedBytes: request.payload)
            var heartbeatResponse = Droidmatch_V1_HeartbeatResponse()
            heartbeatResponse.monotonicMillis = heartbeat.monotonicMillis
            response.payloadType = .heartbeatResponse
            response.payload = try heartbeatResponse.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: false)
        case .listDirRequest:
            let listDirRequest = try Droidmatch_V1_ListDirRequest(serializedBytes: request.payload)
            guard listDirRequest.path == "dm://roots/" else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var rootEntry = Droidmatch_V1_FileEntry()
            rootEntry.path = "dm://media-images/"
            rootEntry.name = "Images"
            rootEntry.kind = .virtual
            rootEntry.canRead = true
            rootEntry.canWrite = false
            rootEntry.mimeType = "vnd.droidmatch.root"
            var listDirResponse = Droidmatch_V1_ListDirResponse()
            listDirResponse.entries = [rootEntry]
            response.payloadType = .listDirResponse
            response.payload = try listDirResponse.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: false)
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .download else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = 0
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = 14
            openResponse.streamID = request.requestID
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()

            let data = Data("download-bytes".utf8)
            var chunk = Droidmatch_V1_TransferChunk()
            chunk.transferID = openRequest.transferID
            chunk.offsetBytes = 0
            chunk.data = data
            chunk.crc32 = corruptDownloadCrc ? 0 : Crc32.checksum(data)
            chunk.finalChunk = true
            var chunkEnvelope = Droidmatch_V1_RpcEnvelope()
            chunkEnvelope.frameVersion = 1
            chunkEnvelope.kind = .stream
            chunkEnvelope.requestID = request.requestID
            chunkEnvelope.streamID = request.requestID
            chunkEnvelope.payloadType = .transferChunk
            chunkEnvelope.payload = try chunk.serializedData()
            return LocalControlPlaneResponse(
                payloads: [try response.serializedData(), try chunkEnvelope.serializedData()],
                isFinal: false
            )
        case .transferChunkAck:
            let ack = try Droidmatch_V1_TransferChunkAck(serializedBytes: request.payload)
            guard ack.transferID == "loopback-transfer", ack.finalAck else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            return LocalControlPlaneResponse(payloads: [], isFinal: true)
        case .diagnosticsRequest:
            _ = try Droidmatch_V1_DiagnosticsRequest(serializedBytes: request.payload)
            var diagnostics = Droidmatch_V1_DiagnosticsResponse()
            diagnostics.transport = .adb
            diagnostics.serviceState = "rpc.session.open"
            diagnostics.recentErrors = [
                localDiagnosticEvent(
                    kind: "error",
                    code: "rpc.envelope.invalid:InvalidProtocolBufferException",
                    message: "bad wire payload"
                )
            ]
            diagnostics.counters = ["rpc.frames.received": "4"]
            diagnostics.recentEvents = [
                localDiagnosticEvent(kind: "state", code: "rpc.session.open"),
                localDiagnosticEvent(kind: "state", code: "permission.media_read:GRANTED")
            ]
            response.payloadType = .diagnosticsResponse
            response.payload = try diagnostics.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: true)
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private static func listDirPermissionRequiredResponse(
        to requestBody: Data,
        didHandshake: Bool
    ) throws -> LocalControlPlaneResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        if !didHandshake {
            guard request.payloadType == .clientHello else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            return LocalControlPlaneResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false
            )
        }

        guard request.payloadType == .listDirRequest else {
            throw LocalEchoServerError.unexpectedPayloadType
        }
        let listDirRequest = try Droidmatch_V1_ListDirRequest(serializedBytes: request.payload)
        guard listDirRequest.path == "dm://media-images/" else {
            throw LocalEchoServerError.unexpectedPayloadType
        }

        var error = Droidmatch_V1_DroidMatchError()
        error.code = .permissionRequired
        error.message = "media permission is required"
        var listDirResponse = Droidmatch_V1_ListDirResponse()
        listDirResponse.error = error
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID
        response.payloadType = .listDirResponse
        response.payload = try listDirResponse.serializedData()
        return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: true)
    }

    private static func multiChunkDownloadResponse(
        to requestBody: Data,
        chunks: [Data],
        nextChunkIndex: Int,
        transferID currentTransferID: String?
    ) throws -> LocalMultiChunkDownloadResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalMultiChunkDownloadResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false,
                nextChunkIndex: nextChunkIndex,
                transferID: currentTransferID
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .download, nextChunkIndex == 0 else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            if openRequest.hasSourceFingerprint,
               openRequest.sourceFingerprint != loopbackTransferFingerprint() {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            guard let startIndex = chunkIndex(forOffset: openRequest.requestedOffsetBytes, chunks: chunks),
                  startIndex < chunks.count else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = openRequest.requestedOffsetBytes
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = chunks.reduce(Int64(0)) { $0 + Int64($1.count) }
            openResponse.streamID = request.requestID
            openResponse.acceptedSourceFingerprint = loopbackTransferFingerprint()
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()

            return LocalMultiChunkDownloadResponse(
                payloads: [
                    try response.serializedData(),
                    try transferChunkEnvelope(
                        request: request,
                        transferID: openRequest.transferID,
                        offset: openRequest.requestedOffsetBytes,
                        data: chunks[startIndex],
                        finalChunk: startIndex == chunks.count - 1
                    )
                ],
                isFinal: false,
                nextChunkIndex: startIndex + 1,
                transferID: openRequest.transferID
            )
        case .transferChunkAck:
            guard let currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let ack = try Droidmatch_V1_TransferChunkAck(serializedBytes: request.payload)
            let expectedOffset = chunks.prefix(nextChunkIndex).reduce(Int64(0)) { $0 + Int64($1.count) }
            guard ack.transferID == currentTransferID, ack.nextOffsetBytes == expectedOffset else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            if ack.finalAck {
                guard nextChunkIndex == chunks.count else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                return LocalMultiChunkDownloadResponse(
                    payloads: [],
                    isFinal: true,
                    nextChunkIndex: nextChunkIndex,
                    transferID: currentTransferID
                )
            }
            guard nextChunkIndex < chunks.count else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            return LocalMultiChunkDownloadResponse(
                payloads: [
                    try transferChunkEnvelope(
                        request: request,
                        transferID: currentTransferID,
                        offset: expectedOffset,
                        data: chunks[nextChunkIndex],
                        finalChunk: nextChunkIndex == chunks.count - 1
                    )
                ],
                isFinal: false,
                nextChunkIndex: nextChunkIndex + 1,
                transferID: currentTransferID
            )
        case .cancelTransferRequest:
            guard let currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let cancelRequest = try Droidmatch_V1_CancelTransferRequest(serializedBytes: request.payload)
            guard cancelRequest.transferID == currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var cancelResponse = Droidmatch_V1_CancelTransferResponse()
            cancelResponse.transferID = currentTransferID
            cancelResponse.ok = true
            response.payloadType = .cancelTransferResponse
            response.payload = try cancelResponse.serializedData()
            return LocalMultiChunkDownloadResponse(
                payloads: [try response.serializedData()],
                isFinal: true,
                nextChunkIndex: nextChunkIndex,
                transferID: currentTransferID
            )
        case .pauseTransferRequest:
            guard let currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let pauseRequest = try Droidmatch_V1_PauseTransferRequest(serializedBytes: request.payload)
            guard pauseRequest.transferID == currentTransferID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var pauseResponse = Droidmatch_V1_PauseTransferResponse()
            pauseResponse.transferID = currentTransferID
            pauseResponse.ok = true
            // No TransferChunkAck was sent before this control request, so zero
            // is the only safe resume boundary even though one chunk was received.
            pauseResponse.resumableOffsetBytes = 0
            response.payloadType = .pauseTransferResponse
            response.payload = try pauseResponse.serializedData()
            return LocalMultiChunkDownloadResponse(
                payloads: [try response.serializedData()],
                isFinal: true,
                nextChunkIndex: nextChunkIndex,
                transferID: currentTransferID
            )
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private static func uploadResponse(
        to requestBody: Data,
        received: Data,
        transferID currentTransferID: String?,
        expectedSizeBytes: Int64,
        streamID currentStreamID: UInt64?
    ) throws -> LocalUploadResponse {
        try uploadResponse(
            to: requestBody,
            received: received,
            transferID: currentTransferID,
            expectedSizeBytes: expectedSizeBytes,
            streamID: currentStreamID,
            expectedPayload: Data("upload-bytes".utf8)
        )
    }

    /// 泛化版 upload 响应：支持任意 expectedPayload，用于窗口化端到端测试。
    /// 行为与 uploadResponse 一致：逐 chunk 校验 offset/CRC、追加到 received、
    /// 按顺序回 ACK，final chunk 校验总长度和内容。
    private static func uploadResponse(
        to requestBody: Data,
        received: Data,
        transferID currentTransferID: String?,
        expectedSizeBytes: Int64,
        streamID currentStreamID: UInt64?,
        expectedPayload: Data
    ) throws -> LocalUploadResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalUploadResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false,
                received: received,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .upload,
                  openRequest.transferID == "loopback-upload",
                  openRequest.destinationPath == "dm://app-sandbox/upload-bytes.bin",
                  openRequest.expectedSizeBytes == Int64(expectedPayload.count),
                  openRequest.requestedOffsetBytes == Int64(received.count) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = openRequest.requestedOffsetBytes
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = openRequest.expectedSizeBytes
            openResponse.streamID = request.requestID
            response.kind = .response
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: false,
                received: received,
                transferID: openRequest.transferID,
                expectedSizeBytes: openRequest.expectedSizeBytes,
                streamID: request.requestID
            )
        case .transferChunk:
            guard let currentTransferID,
                  let currentStreamID,
                  request.streamID == currentStreamID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: request.payload)
            guard chunk.transferID == currentTransferID,
                  chunk.offsetBytes == Int64(received.count),
                  chunk.crc32 == Crc32.checksum(chunk.data) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var nextReceived = received
            nextReceived.append(chunk.data)
            if chunk.finalChunk {
                guard Int64(nextReceived.count) == expectedSizeBytes,
                      nextReceived == expectedPayload else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
            }
            var ack = Droidmatch_V1_TransferChunkAck()
            ack.transferID = currentTransferID
            ack.nextOffsetBytes = Int64(nextReceived.count)
            ack.finalAck = chunk.finalChunk
            response.kind = .stream
            response.streamID = currentStreamID
            response.payloadType = .transferChunkAck
            response.payload = try ack.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: chunk.finalChunk,
                received: nextReceived,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    /// 泛化 upload 响应：open 阶段校验参数化的 transferID/destinationPath，
    /// 其余逻辑与 uploadResponse 泛化版一致。用于窗口化端到端测试。
    private static func uploadResponseEchoing(
        to requestBody: Data,
        received: Data,
        transferID currentTransferID: String?,
        expectedSizeBytes: Int64,
        streamID currentStreamID: UInt64?,
        expectedPayload: Data,
        expectedTransferID: String,
        expectedDestinationPath: String
    ) throws -> LocalUploadResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalUploadResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false,
                received: received,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .upload,
                  openRequest.transferID == expectedTransferID,
                  openRequest.destinationPath == expectedDestinationPath,
                  openRequest.expectedSizeBytes == Int64(expectedPayload.count),
                  openRequest.requestedOffsetBytes == Int64(received.count) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.acceptedOffsetBytes = openRequest.requestedOffsetBytes
            openResponse.chunkSizeBytes = openRequest.preferredChunkSizeBytes
            openResponse.totalSizeBytes = openRequest.expectedSizeBytes
            openResponse.streamID = request.requestID
            response.kind = .response
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: false,
                received: received,
                transferID: openRequest.transferID,
                expectedSizeBytes: openRequest.expectedSizeBytes,
                streamID: request.requestID
            )
        case .transferChunk:
            guard let currentTransferID,
                  let currentStreamID,
                  request.streamID == currentStreamID else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: request.payload)
            guard chunk.transferID == currentTransferID,
                  chunk.offsetBytes == Int64(received.count),
                  chunk.crc32 == Crc32.checksum(chunk.data) else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var nextReceived = received
            nextReceived.append(chunk.data)
            if chunk.finalChunk {
                guard Int64(nextReceived.count) == expectedSizeBytes,
                      nextReceived == expectedPayload else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
            }
            var ack = Droidmatch_V1_TransferChunkAck()
            ack.transferID = currentTransferID
            ack.nextOffsetBytes = Int64(nextReceived.count)
            ack.finalAck = chunk.finalChunk
            response.kind = .stream
            response.streamID = currentStreamID
            response.payloadType = .transferChunkAck
            response.payload = try ack.serializedData()
            return LocalUploadResponse(
                payloads: [try response.serializedData()],
                isFinal: chunk.finalChunk,
                received: nextReceived,
                transferID: currentTransferID,
                expectedSizeBytes: expectedSizeBytes,
                streamID: currentStreamID
            )
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private static func downloadOpenNotFoundResponse(to requestBody: Data) throws -> LocalControlPlaneResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalControlPlaneResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .download,
                  openRequest.transferID == "missing-download",
                  openRequest.sourcePath == "dm://app-sandbox/missing-download.bin" else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var error = Droidmatch_V1_DroidMatchError()
            error.code = .notFound
            error.message = "download source is not available"
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.streamID = request.requestID
            openResponse.error = error
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: true)
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private static func uploadOpenUnsupportedResponse(to requestBody: Data) throws -> LocalControlPlaneResponse {
        let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
        var response = Droidmatch_V1_RpcEnvelope()
        response.frameVersion = 1
        response.kind = .response
        response.requestID = request.requestID

        switch request.payloadType {
        case .clientHello:
            return LocalControlPlaneResponse(
                payloads: [try handshakeResponse(to: requestBody)],
                isFinal: false
            )
        case .openTransferRequest:
            let openRequest = try Droidmatch_V1_OpenTransferRequest(serializedBytes: request.payload)
            guard openRequest.direction == .upload,
                  openRequest.transferID == "loopback-upload",
                  openRequest.destinationPath == "dm://media-images/upload-bytes.jpg",
                  openRequest.requestedOffsetBytes == 1 else {
                throw LocalEchoServerError.unexpectedPayloadType
            }
            var error = Droidmatch_V1_DroidMatchError()
            error.code = .unsupportedCapability
            error.message = "MediaStore upload resume is not supported"
            var openResponse = Droidmatch_V1_OpenTransferResponse()
            openResponse.transferID = openRequest.transferID
            openResponse.streamID = request.requestID
            openResponse.error = error
            response.payloadType = .openTransferResponse
            response.payload = try openResponse.serializedData()
            return LocalControlPlaneResponse(payloads: [try response.serializedData()], isFinal: true)
        default:
            throw LocalEchoServerError.unexpectedPayloadType
        }
    }

    private static func chunkIndex(forOffset offset: Int64, chunks: [Data]) -> Int? {
        guard offset >= 0 else {
            return nil
        }
        var runningOffset: Int64 = 0
        for (index, chunk) in chunks.enumerated() {
            if runningOffset == offset {
                return index
            }
            runningOffset += Int64(chunk.count)
        }
        return runningOffset == offset ? chunks.count : nil
    }

    private static func loopbackTransferFingerprint() -> Droidmatch_V1_TransferFingerprint {
        var fingerprint = Droidmatch_V1_TransferFingerprint()
        fingerprint.sizeBytes = 14
        fingerprint.modifiedUnixMillis = 1_700_000_000_000
        fingerprint.providerEtag = "loopback-etag"
        return fingerprint
    }

    private static func transferChunkEnvelope(
        request: Droidmatch_V1_RpcEnvelope,
        transferID: String,
        offset: Int64,
        data: Data,
        finalChunk: Bool
    ) throws -> Data {
        var chunk = Droidmatch_V1_TransferChunk()
        chunk.transferID = transferID
        chunk.offsetBytes = offset
        chunk.data = data
        chunk.crc32 = Crc32.checksum(data)
        chunk.finalChunk = finalChunk
        var chunkEnvelope = Droidmatch_V1_RpcEnvelope()
        chunkEnvelope.frameVersion = 1
        chunkEnvelope.kind = .stream
        chunkEnvelope.requestID = request.requestID
        chunkEnvelope.streamID = request.streamID == 0 ? request.requestID : request.streamID
        chunkEnvelope.payloadType = .transferChunk
        chunkEnvelope.payload = try chunk.serializedData()
        return try chunkEnvelope.serializedData()
    }

    private static func localDiagnosticEvent(kind: String, code: String, message: String? = nil) -> String {
        let base = "1:local-frame-test:\(kind):\(code)"
        if let message, !message.isEmpty {
            return "\(base):\(message)"
        }
        return base
    }
}

private struct LocalControlPlaneResponse {
    let payloads: [Data]
    let isFinal: Bool
}

private struct LocalMultiChunkDownloadResponse {
    let payloads: [Data]
    let isFinal: Bool
    let nextChunkIndex: Int
    let transferID: String?
}

private struct LocalUploadResponse {
    let payloads: [Data]
    let isFinal: Bool
    let received: Data
    let transferID: String?
    let expectedSizeBytes: Int64
    let streamID: UInt64?
}
