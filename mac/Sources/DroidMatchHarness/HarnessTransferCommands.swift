import DroidMatchCore
import Foundation

/// Download and upload CLI probes kept separate from harness command dispatch.
extension HarnessCommand {
    static func downloadOpenExpectError(_ arguments: [String]) async -> Int32 {
        var activeClient: AsyncRpcControlClient?
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let expectedErrorCode = try errorCode(from: options.requiredValue("--expected-error-code"))
            let expectedMessage = try options.value("--expected-message-contains")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            let client = AsyncRpcControlClient(
                session: session,
                requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
                requestTimeoutSeconds: timeout
            )
            activeClient = client
            _ = try await client.handshake()
            do {
                _ = try await client.openDownload(
                    sourcePath: sourcePath,
                    preferredChunkSizeBytes: chunkSize
                )
                await client.close()
                throw HarnessError.expectedDownloadOpenErrorNotReceived(sourcePath)
            } catch let RpcControlClientError.remoteError(error) {
                await client.close()
                guard error.code == expectedErrorCode else {
                    throw HarnessError.unexpectedRemoteErrorCode(
                        expected: expectedErrorCode,
                        actual: error.code,
                        message: error.message
                    )
                }
                if let expectedMessage, !error.message.contains(expectedMessage) {
                    throw HarnessError.unexpectedRemoteErrorMessage(
                        expectedSubstring: expectedMessage,
                        actual: error.message
                    )
                }
                print(
                    "download open error passed code=\(error.code) "
                        + "source_path=\(sourcePath) message=\"\(error.message)\""
                )
                return 0
            }
        } catch let error as HarnessError {
            if let activeClient { await activeClient.close() }
            fputs("download-open-expect-error failed: \(error)\n", stderr)
            return 1
        } catch {
            if let activeClient { await activeClient.close() }
            fputs("download-open-expect-error failed: \(error)\n", stderr)
            return 1
        }
    }

    static func downloadOnce(_ arguments: [String]) async -> Int32 {
        var activeClient: AsyncRpcControlClient?
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            let client = AsyncRpcControlClient(
                session: session,
                requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
                requestTimeoutSeconds: timeout
            )
            activeClient = client
            _ = try await client.handshake()
            let transfer = try await client.openDownload(
                sourcePath: sourcePath,
                preferredChunkSizeBytes: chunkSize
            )
            guard let chunk = try await transfer.nextChunk() else {
                throw AsyncDownloadFileError.streamEndedBeforeFinalChunk
            }
            try await transfer.acknowledge(chunk)
            await client.close()
            print(
                "download-once passed transfer_id=\(transfer.openResponse.transferID) "
                    + "bytes=\(chunk.data.count) total=\(transfer.openResponse.totalSizeBytes) "
                    + "crc32=\(String(chunk.crc32, radix: 16)) final=\(chunk.finalChunk)"
            )
            return 0
        } catch {
            if let activeClient { await activeClient.close() }
            fputs("download-once failed: \(error)\n", stderr)
            return 1
        }
    }

    static func downloadCancel(_ arguments: [String]) async -> Int32 {
        var activeClient: AsyncRpcControlClient?
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let reason = try options.value("--reason") ?? "harness-download-cancel"
            let session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            let client = AsyncRpcControlClient(
                session: session,
                requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
                requestTimeoutSeconds: timeout
            )
            activeClient = client
            _ = try await client.handshake()
            let transfer = try await client.openDownload(
                sourcePath: sourcePath,
                preferredChunkSizeBytes: chunkSize
            )
            guard let chunk = try await transfer.nextChunk() else {
                throw AsyncDownloadFileError.streamEndedBeforeFinalChunk
            }
            let response = try await transfer.cancel(reason: reason)
            await client.close()
            print(
                "download-cancel passed transfer_id=\(transfer.openResponse.transferID) "
                    + "first_chunk_bytes=\(chunk.data.count) "
                    + "total=\(transfer.openResponse.totalSizeBytes) "
                    + "cancel_ok=\(response.ok)"
            )
            return 0
        } catch {
            if let activeClient { await activeClient.close() }
            fputs("download-cancel failed: \(error)\n", stderr)
            return 1
        }
    }

    static func downloadPause(_ arguments: [String]) async -> Int32 {
        var activeClient: AsyncRpcControlClient?
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            let client = AsyncRpcControlClient(
                session: session,
                requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
                requestTimeoutSeconds: timeout
            )
            activeClient = client
            _ = try await client.handshake()
            let transfer = try await client.openDownload(
                sourcePath: sourcePath,
                preferredChunkSizeBytes: chunkSize
            )
            guard let chunk = try await transfer.nextChunk() else {
                throw AsyncDownloadFileError.streamEndedBeforeFinalChunk
            }
            let response = try await transfer.pause()
            await client.close()
            print(
                "download-pause passed transfer_id=\(transfer.openResponse.transferID) "
                    + "first_chunk_bytes=\(chunk.data.count) "
                    + "total=\(transfer.openResponse.totalSizeBytes) "
                    + "pause_ok=\(response.ok) "
                    + "resumable_offset=\(response.resumableOffsetBytes)"
            )
            return 0
        } catch {
            if let activeClient { await activeClient.close() }
            fputs("download-pause failed: \(error)\n", stderr)
            return 1
        }
    }

    static func download(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let destinationURL = URL(fileURLWithPath: try options.requiredValue("--destination"))
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let resume = options.flag("--resume")
            let retryOnTransportLoss = options.flag("--retry-on-transport-loss")
            let stopAfterBytes = try options.int("--stop-after-bytes").map(Int64.init)
            if let stopAfterBytes, stopAfterBytes <= 0 {
                throw HarnessError.invalidInt(option: "--stop-after-bytes", value: "\(stopAfterBytes)")
            }
            if resume && stopAfterBytes != nil {
                throw HarnessError.invalidOptionCombination("--stop-after-bytes cannot be combined with --resume")
            }
            // 解析恢复策略：未传 --retry-on-transport-loss 时关闭恢复；
            // 否则按 --max-retry-attempts / --retry-backoff-ms 构造，缺省回退到
            // 历史的"最多重试一次"默认值，保证既有真机脚本行为不变。
            let recoveryPolicy = try resolveRecoveryPolicy(
                enabled: retryOnTransportLoss,
                options: options
            )
            var attempt = 1
            var attemptResume = resume
            let sidecarURL = resumeRecordURL(for: destinationURL)
            var completedResult: TimedDownloadResult?
            while true {
                do {
                    completedResult = try await performDownload(
                        host: host,
                        port: port,
                        timeout: timeout,
                        sourcePath: sourcePath,
                        destinationURL: destinationURL,
                        chunkSize: chunkSize,
                        resume: attemptResume,
                        stopAfterBytes: stopAfterBytes
                    )
                    break
                } catch {
                    // 首次尝试的下标是 0；当前 attempt 从 1 开始，所以
                    // 已失败的尝试数是 attempt - 1。
                    let failureIndex = attempt - 1
                    let canRetry = recoveryPolicy.shouldRetry(afterFailureAt: failureIndex)
                        && stopAfterBytes == nil
                        && isRetryableTransportError(error)
                        && hasDownloadResumeRecord(at: sidecarURL)
                    guard canRetry else {
                        throw error
                    }
                    let delayMs = recoveryPolicy.recoveryDelayMs(
                        forAttempt: attempt,
                        randomSource: { Double.random(in: 0..<1) }
                    )
                    fputs(
                        "download retrying after transport loss using resume metadata "
                            + "(attempt \(attempt + 1)/\(recoveryPolicy.maxAttempts + 1), "
                            + "backoff_ms=\(delayMs)): \(error)\n",
                        stderr
                    )
                    sleepRecovery(delayMs: delayMs)
                    attempt += 1
                    attemptResume = true
                }
            }
            guard let result = completedResult else {
                throw HarnessError.transferDidNotComplete("download")
            }
            let throughput = formatThroughputMiBPerSecond(
                bytes: result.result.bytesReceived,
                elapsedMilliseconds: result.elapsedMilliseconds
            )
            let passedLine = [
                "download passed transfer_id=\(result.result.openResponse.transferID)",
                "chunks=\(result.result.chunkCount)",
                "bytes=\(result.result.bytesReceived)",
                "total=\(result.result.openResponse.totalSizeBytes)",
                "final_offset=\(result.result.finalOffsetBytes)",
                "elapsed_ms=\(result.elapsedMilliseconds)",
                "throughput_mib_per_sec=\(throughput)",
                "resume=\(attemptResume)",
                "retry_attempts=\(attempt)",
                "recovered=\(attempt > 1)",
                "destination=<local-file>"
            ].joined(separator: " ")
            print(passedLine)
            return 0
        } catch let error as HarnessError {
            if case let .partialDownloadStopped(bytesWritten, _, _) = error {
                print(
                    "download partial passed bytes=\(bytesWritten) "
                        + "partial=<local-partial> sidecar=<local-sidecar>"
                )
                return 0
            }
            fputs("download failed: \(error)\n", stderr)
            return 1
        } catch {
            fputs("download failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func performDownload(
        host: String,
        port: Int,
        timeout: Double,
        sourcePath: String,
        destinationURL: URL,
        chunkSize: UInt32,
        resume: Bool,
        stopAfterBytes: Int64?
    ) async throws -> TimedDownloadResult {
        let sidecarURL = resumeRecordURL(for: destinationURL)
        let resumeRecord = try resume ? DownloadResumeRecord.load(from: sidecarURL) : nil
        let writer = try AtomicDownloadWriter(destinationURL: destinationURL, resume: resume)
        defer {
            try? writer.close()
        }
        let requestedOffset = writer.requestedOffsetBytes
        if let resumeRecord, resumeRecord.sourcePath != sourcePath {
            throw HarnessError.resumeSourceMismatch(expected: resumeRecord.sourcePath, actual: sourcePath)
        }
        if resume && requestedOffset > 0 && resumeRecord == nil {
            throw HarnessError.missingResumeRecord(sidecarURL.path)
        }
        if !resume {
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        let session = try await AsyncFramedTcpSession.connect(
            host: host,
            port: port,
            timeoutSeconds: timeout
        )
        let client = AsyncRpcControlClient(
            session: session,
            requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
            requestTimeoutSeconds: timeout
        )
        do {
            _ = try await client.handshake()
            let transfer = try await client.openDownload(
                sourcePath: sourcePath,
                transferID: resumeRecord?.transferID ?? UUID().uuidString,
                requestedOffsetBytes: requestedOffset,
                sourceFingerprint: resumeRecord?.fingerprint.proto,
                preferredChunkSizeBytes: chunkSize
            )
            let response = transfer.openResponse
            guard response.acceptedOffsetBytes == requestedOffset else {
                throw HarnessError.resumeOffsetRejected(
                    requested: requestedOffset,
                    accepted: response.acceptedOffsetBytes
                )
            }
            let record = DownloadResumeRecord(
                transferID: response.transferID,
                sourcePath: sourcePath,
                totalSizeBytes: response.totalSizeBytes,
                fingerprint: TransferFingerprintRecord(response.acceptedSourceFingerprint)
            )
            try record.save(to: sidecarURL)

            var bytesWritten = requestedOffset
            var chunkCount = 0
            var bytesReceived: Int64 = 0
            let startedMilliseconds = monotonicMilliseconds()
            while true {
                guard let chunk = try await transfer.nextChunk() else {
                    throw AsyncDownloadFileError.streamEndedBeforeFinalChunk
                }
                try writer.write(chunk.data)
                bytesWritten = chunk.offsetBytes + Int64(chunk.data.count)
                if let stopAfterBytes, bytesWritten >= stopAfterBytes {
                    throw HarnessError.partialDownloadStopped(
                        bytesWritten: bytesWritten,
                        partialPath: writer.partialURL.path,
                        sidecarPath: sidecarURL.path
                    )
                }
                try await transfer.acknowledge(chunk)
                chunkCount += 1
                bytesReceived += Int64(chunk.data.count)
                if chunk.finalChunk {
                    let elapsedMilliseconds = max(
                        1,
                        monotonicMilliseconds() - startedMilliseconds
                    )
                    try writer.commit()
                    try? FileManager.default.removeItem(at: sidecarURL)
                    await client.close()
                    return TimedDownloadResult(
                        result: DownloadResult(
                            openResponse: response,
                            chunkCount: chunkCount,
                            bytesReceived: bytesReceived,
                            finalOffsetBytes: bytesWritten
                        ),
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                }
            }
        } catch {
            await client.close()
            throw error
        }
    }

    static func upload(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourceURL = URL(fileURLWithPath: try options.requiredValue("--source"))
            let destinationPath = try options.requiredValue("--destination-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let resume = options.flag("--resume")
            let retryOnTransportLoss = options.flag("--retry-on-transport-loss")
            let stopAfterBytes = try options.int("--stop-after-bytes").map(Int64.init)
            if let stopAfterBytes, stopAfterBytes <= 0 {
                throw HarnessError.invalidInt(option: "--stop-after-bytes", value: "\(stopAfterBytes)")
            }
            if resume && stopAfterBytes != nil {
                throw HarnessError.invalidOptionCombination("--stop-after-bytes cannot be combined with --resume")
            }
            let uploadResumeCapableDestination = destinationPath.hasPrefix("dm://app-sandbox/")
                || destinationPath.hasPrefix("dm://saf-")
            if (resume || stopAfterBytes != nil || retryOnTransportLoss) && !uploadResumeCapableDestination {
                throw HarnessError.invalidOptionCombination(
                    "upload resume, partial upload, and transport-loss retry are currently supported only for dm://app-sandbox/ or dm://saf- destinations"
                )
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            guard let fileSize = attributes[.size] as? NSNumber else {
                throw HarnessError.localFileSizeUnavailable(sourceURL.path)
            }
            let expectedSizeBytes = fileSize.int64Value
            if let stopAfterBytes, stopAfterBytes >= expectedSizeBytes {
                throw HarnessError.invalidOptionCombination(
                    "--stop-after-bytes must be smaller than the upload source size"
                )
            }
            let sourceModifiedUnixMillis = try localModifiedUnixMillis(attributes: attributes, path: sourceURL.path)
            let sidecarURL = uploadResumeRecordURL(for: sourceURL)
            let resumeRecord = try resume ? UploadResumeRecord.load(from: sidecarURL) : nil
            if let resumeRecord {
                if resumeRecord.sourcePath != sourceURL.path {
                    throw HarnessError.resumeSourceMismatch(expected: resumeRecord.sourcePath, actual: sourceURL.path)
                }
                if resumeRecord.destinationPath != destinationPath {
                    throw HarnessError.resumeDestinationMismatch(
                        expected: resumeRecord.destinationPath,
                        actual: destinationPath
                    )
                }
                if resumeRecord.totalSizeBytes != expectedSizeBytes
                        || resumeRecord.sourceModifiedUnixMillis != sourceModifiedUnixMillis {
                    throw HarnessError.resumeSourceChanged(sourceURL.path)
                }
            }
            if resume && resumeRecord == nil {
                throw HarnessError.missingResumeRecord(sidecarURL.path)
            }
            if !resume {
                try? FileManager.default.removeItem(at: sidecarURL)
            }
            var attempt = 1
            var attemptResume = resume
            var completedResult: TimedUploadResult?
            // 与 download 一致：未传 --retry-on-transport-loss 时关闭恢复；
            // 否则按 --max-retry-attempts / --retry-backoff-ms 构造。
            let recoveryPolicy = try resolveRecoveryPolicy(
                enabled: retryOnTransportLoss,
                options: options
            )
            while true {
                do {
                    completedResult = try performUpload(
                        host: host,
                        port: port,
                        timeout: timeout,
                        sourceURL: sourceURL,
                        destinationPath: destinationPath,
                        expectedSizeBytes: expectedSizeBytes,
                        sourceModifiedUnixMillis: sourceModifiedUnixMillis,
                        chunkSize: chunkSize,
                        resume: attemptResume,
                        stopAfterBytes: stopAfterBytes
                    )
                    break
                } catch {
                    let failureIndex = attempt - 1
                    let canRetry = recoveryPolicy.shouldRetry(afterFailureAt: failureIndex)
                        && stopAfterBytes == nil
                        && isRetryableTransportError(error)
                        && hasUploadResumeRecord(at: sidecarURL)
                    guard canRetry else {
                        throw error
                    }
                    let delayMs = recoveryPolicy.recoveryDelayMs(
                        forAttempt: attempt,
                        randomSource: { Double.random(in: 0..<1) }
                    )
                    fputs(
                        "upload retrying after transport loss using resume metadata "
                            + "(attempt \(attempt + 1)/\(recoveryPolicy.maxAttempts + 1), "
                            + "backoff_ms=\(delayMs)): \(error)\n",
                        stderr
                    )
                    sleepRecovery(delayMs: delayMs)
                    attempt += 1
                    attemptResume = true
                }
            }
            guard let result = completedResult else {
                throw HarnessError.transferDidNotComplete("upload")
            }
            let throughput = formatThroughputMiBPerSecond(
                bytes: result.result.bytesSent,
                elapsedMilliseconds: result.elapsedMilliseconds
            )
            let passedLine = [
                "upload passed transfer_id=\(result.result.openResponse.transferID)",
                "chunks=\(result.result.chunkCount)",
                "bytes=\(result.result.bytesSent)",
                "total=\(result.result.openResponse.totalSizeBytes)",
                "final_offset=\(result.result.finalOffsetBytes)",
                "elapsed_ms=\(result.elapsedMilliseconds)",
                "throughput_mib_per_sec=\(throughput)",
                "resume=\(attemptResume)",
                "retry_attempts=\(attempt)",
                "recovered=\(attempt > 1)",
                "source=<local-file>",
                "destination=\(destinationPath)"
            ].joined(separator: " ")
            print(passedLine)
            return 0
        } catch let error as HarnessError {
            if case let .partialUploadStopped(bytesSent, _) = error {
                print(
                    "upload partial passed bytes=\(bytesSent) "
                        + "sidecar=<local-sidecar>"
                )
                return 0
            }
            fputs("upload failed: \(error)\n", stderr)
            return 1
        } catch {
            fputs("upload failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func performUpload(
        host: String,
        port: Int,
        timeout: Double,
        sourceURL: URL,
        destinationPath: String,
        expectedSizeBytes: Int64,
        sourceModifiedUnixMillis: Int64,
        chunkSize: UInt32,
        resume: Bool,
        stopAfterBytes: Int64?
    ) throws -> TimedUploadResult {
        let sidecarURL = uploadResumeRecordURL(for: sourceURL)
        let resumeRecord = try resume ? UploadResumeRecord.load(from: sidecarURL) : nil
        if let resumeRecord {
            if resumeRecord.sourcePath != sourceURL.path {
                throw HarnessError.resumeSourceMismatch(expected: resumeRecord.sourcePath, actual: sourceURL.path)
            }
            if resumeRecord.destinationPath != destinationPath {
                throw HarnessError.resumeDestinationMismatch(
                    expected: resumeRecord.destinationPath,
                    actual: destinationPath
                )
            }
            if resumeRecord.totalSizeBytes != expectedSizeBytes
                    || resumeRecord.sourceModifiedUnixMillis != sourceModifiedUnixMillis {
                throw HarnessError.resumeSourceChanged(sourceURL.path)
            }
        }
        if resume && resumeRecord == nil {
            throw HarnessError.missingResumeRecord(sidecarURL.path)
        }
        if !resume {
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? handle.close()
        }
        let session = try FramedTcpSession(
            host: host,
            port: port,
            timeoutSeconds: timeout
        )
        defer {
            session.close()
        }

        let client = RpcControlClient(session: session)
        _ = try client.handshake()
        let startedMilliseconds = monotonicMilliseconds()
        let result = try client.upload(
            sourcePath: TransferWireMetadata.localUploadSource,
            destinationPath: destinationPath,
            expectedSizeBytes: expectedSizeBytes,
            transferID: resumeRecord?.transferID ?? UUID().uuidString,
            requestedOffsetBytes: resumeRecord?.nextOffsetBytes ?? 0,
            preferredChunkSizeBytes: chunkSize,
            sendLimitBytes: stopAfterBytes,
            didOpen: { response in
                let requestedOffset = resumeRecord?.nextOffsetBytes ?? 0
                guard response.acceptedOffsetBytes == requestedOffset else {
                    throw HarnessError.resumeOffsetRejected(
                        requested: requestedOffset,
                        accepted: response.acceptedOffsetBytes
                    )
                }
                let record = UploadResumeRecord(
                    transferID: response.transferID,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationPath,
                    totalSizeBytes: expectedSizeBytes,
                    sourceModifiedUnixMillis: sourceModifiedUnixMillis,
                    nextOffsetBytes: response.acceptedOffsetBytes
                )
                try record.save(to: sidecarURL)
            },
            didAck: { ack in
                let record = UploadResumeRecord(
                    transferID: resumeRecord?.transferID ?? ack.transferID,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationPath,
                    totalSizeBytes: expectedSizeBytes,
                    sourceModifiedUnixMillis: sourceModifiedUnixMillis,
                    nextOffsetBytes: ack.nextOffsetBytes
                )
                try record.save(to: sidecarURL)
                if let stopAfterBytes, ack.nextOffsetBytes >= stopAfterBytes {
                    throw HarnessError.partialUploadStopped(
                        bytesSent: ack.nextOffsetBytes,
                        sidecarPath: sidecarURL.path
                    )
                }
            }
        ) { offset, byteCount in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: byteCount) ?? Data()
        }
        let elapsedMilliseconds = max(1, monotonicMilliseconds() - startedMilliseconds)
        try? FileManager.default.removeItem(at: sidecarURL)
        return TimedUploadResult(result: result, elapsedMilliseconds: elapsedMilliseconds)
    }

    static func uploadOpenExpectError(_ arguments: [String]) async -> Int32 {
        var activeClient: AsyncRpcControlClient?
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourceURL = URL(fileURLWithPath: try options.requiredValue("--source"))
            let destinationPath = try options.requiredValue("--destination-path")
            let requestedOffset = Int64(try options.requiredInt("--requested-offset"))
            let expectedErrorCode = try errorCode(from: options.requiredValue("--expected-error-code"))
            let expectedMessage = try options.value("--expected-message-contains")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            if requestedOffset < 0 {
                throw HarnessError.invalidInt(option: "--requested-offset", value: "\(requestedOffset)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            guard let fileSize = attributes[.size] as? NSNumber else {
                throw HarnessError.localFileSizeUnavailable(sourceURL.path)
            }
            let expectedSizeBytes = fileSize.int64Value
            let session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            let client = AsyncRpcControlClient(
                session: session,
                requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
                requestTimeoutSeconds: timeout
            )
            activeClient = client
            _ = try await client.handshake()
            do {
                _ = try await client.openUpload(
                    sourcePath: TransferWireMetadata.localUploadSource,
                    destinationPath: destinationPath,
                    requestedOffsetBytes: requestedOffset,
                    expectedSizeBytes: expectedSizeBytes,
                    preferredChunkSizeBytes: chunkSize
                )
                await client.close()
                throw HarnessError.expectedRemoteOpenErrorNotReceived(destinationPath)
            } catch let RpcControlClientError.remoteError(error) {
                await client.close()
                guard error.code == expectedErrorCode else {
                    throw HarnessError.unexpectedRemoteErrorCode(
                        expected: expectedErrorCode,
                        actual: error.code,
                        message: error.message
                    )
                }
                if let expectedMessage, !error.message.contains(expectedMessage) {
                    throw HarnessError.unexpectedRemoteErrorMessage(
                        expectedSubstring: expectedMessage,
                        actual: error.message
                    )
                }
                print(
                    "upload open error passed code=\(error.code) "
                        + "requested_offset=\(requestedOffset) destination=\(destinationPath) "
                        + "message=\"\(error.message)\""
                )
                return 0
            }
        } catch let error as HarnessError {
            if let activeClient { await activeClient.close() }
            fputs("upload-open-expect-error failed: \(error)\n", stderr)
            return 1
        } catch {
            if let activeClient { await activeClient.close() }
            fputs("upload-open-expect-error failed: \(error)\n", stderr)
            return 1
        }
    }
}
