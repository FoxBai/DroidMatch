import Foundation
import Network
import Testing
@testable import DroidMatchCore

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

@Test func handshakeSmokeClientPerformsClientHelloServerHelloOnAsyncSession() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyWithServerHello)
    defer {
        server.cancel()
    }

    let result = try await HandshakeSmokeClient().run(port: server.port, timeoutSeconds: 2)

    #expect(result.serverName == "LocalFrameTestServer")
    #expect(result.serverVersion == "test")
    #expect(result.protocolMajor == 1)
    #expect(result.transport == .adb)
    #expect(result.grantedCapabilities == [.diagnostics])
}

@Test func handshakeSmokeClientReturnsPairingRequiredWithoutAuthenticating() async throws {
    let server = try LocalFrameTestServer(
        handler: LocalFrameTestServer.replyWithPairingRequiredServerHello
    )
    defer { server.cancel() }

    let result = try await HandshakeSmokeClient().run(port: server.port, timeoutSeconds: 2)

    #expect(result.authenticationState == .pairingRequired)
    #expect(result.serverNonce.isEmpty)
    #expect(result.grantedCapabilities == [.diagnostics])
}

@Test func m1SmokeClientRunsHandshakeHeartbeatDeviceInfoDiagnosticsOnOneAsyncConnection() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer {
        server.cancel()
    }

    let result = try await M1SmokeClient().run(port: server.port, timeoutSeconds: 2)

    #expect(result.handshake.serverName == "LocalFrameTestServer")
    #expect(result.handshake.grantedCapabilities == [
        .fileList,
        .fileRead,
        .fileWrite,
        .resumableTransfer,
        .diagnostics,
    ])
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
