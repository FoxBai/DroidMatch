import DroidMatchCore
import Foundation

/// Upload CLI probes kept separate from download command orchestration.
extension HarnessCommand {
    static func upload(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.positiveFiniteDouble("--timeout-seconds") ?? 5
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
            }
            if resume && resumeRecord == nil {
                throw HarnessError.missingResumeRecord(sidecarURL.path)
            }
            if !resume {
                try UploadResumeRecord.remove(from: sidecarURL)
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
                    completedResult = try await performUpload(
                        host: host,
                        port: port,
                        timeout: timeout,
                        sourceURL: sourceURL,
                        destinationPath: destinationPath,
                        expectedSizeBytes: expectedSizeBytes,
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
                            + "backoff_ms=\(delayMs)): \(HarnessPrivacy.errorLabel(error))\n",
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
                "requested_chunk_size_bytes=\(chunkSize)",
                "chunk_size_bytes=\(result.result.openResponse.chunkSizeBytes)",
                "final_offset=\(result.result.finalOffsetBytes)",
                "elapsed_ms=\(result.elapsedMilliseconds)",
                "throughput_mib_per_sec=\(throughput)",
                "resume=\(attemptResume)",
                "retry_attempts=\(attempt)",
                "recovered=\(attempt > 1)",
                "source=<local-file>",
                "destination=\(HarnessPrivacy.redactedPath)"
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
            fputs("upload failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        } catch {
            fputs("upload failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
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
        chunkSize: UInt32,
        resume: Bool,
        stopAfterBytes: Int64?
    ) async throws -> TimedUploadResult {
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
        }
        if resume && resumeRecord == nil {
            throw HarnessError.missingResumeRecord(sidecarURL.path)
        }
        if !resume {
            try UploadResumeRecord.remove(from: sidecarURL)
        }

        let source = AsyncUploadFileSource(sourceURL: sourceURL)
        let snapshot = try await source.snapshot()
        guard snapshot.sizeBytes == expectedSizeBytes else {
            throw HarnessError.resumeSourceChanged(sourceURL.path)
        }
        if let resumeRecord {
            try validateUploadResumeRecord(
                resumeRecord,
                sourceURL: sourceURL,
                destinationPath: destinationPath,
                snapshot: snapshot
            )
        }
        let session: AsyncFramedTcpSession
        do {
            session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
        } catch {
            await source.close()
            throw error
        }
        let client = AsyncRpcControlClient(
            session: session,
            requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
            requestTimeoutSeconds: timeout
        )
        do {
            _ = try await client.handshake()
            let requestedOffset = resumeRecord?.nextOffsetBytes ?? 0
            let transfer = try await client.openUpload(
                sourcePath: TransferWireMetadata.localUploadSource,
                destinationPath: destinationPath,
                transferID: resumeRecord?.transferID ?? UUID().uuidString,
                requestedOffsetBytes: requestedOffset,
                expectedSizeBytes: expectedSizeBytes,
                preferredChunkSizeBytes: chunkSize
            )
            let response = transfer.openResponse
            guard response.acceptedOffsetBytes == requestedOffset else {
                throw HarnessError.resumeOffsetRejected(
                    requested: requestedOffset,
                    accepted: response.acceptedOffsetBytes
                )
            }
            let openedRecord = UploadResumeRecord(
                transferID: response.transferID,
                sourcePath: sourceURL.path,
                destinationPath: destinationPath,
                sourceIdentity: UploadSourceIdentityRecord(snapshot),
                nextOffsetBytes: response.acceptedOffsetBytes
            )
            try openedRecord.save(to: sidecarURL)

            let startedMilliseconds = monotonicMilliseconds()
            let result = try await AsyncUploadFileSender().send(
                transfer: transfer,
                source: source,
                snapshot: snapshot,
                sendLimitBytes: stopAfterBytes
            ) { ack in
                let record = UploadResumeRecord(
                    transferID: response.transferID,
                    sourcePath: sourceURL.path,
                    destinationPath: destinationPath,
                    sourceIdentity: UploadSourceIdentityRecord(snapshot),
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
            let elapsedMilliseconds = max(1, monotonicMilliseconds() - startedMilliseconds)
            try await source.validate(snapshot)
            try UploadResumeRecord.remove(from: sidecarURL)
            await source.close()
            await client.close()
            return TimedUploadResult(result: result, elapsedMilliseconds: elapsedMilliseconds)
        } catch {
            await source.close()
            await client.close()
            throw error
        }
    }

    private static func validateUploadResumeRecord(
        _ record: UploadResumeRecord,
        sourceURL: URL,
        destinationPath: String,
        snapshot: UploadSourceSnapshot
    ) throws {
        guard record.sourcePath == sourceURL.path else {
            throw HarnessError.resumeSourceMismatch(
                expected: record.sourcePath,
                actual: sourceURL.path
            )
        }
        guard record.destinationPath == destinationPath else {
            throw HarnessError.resumeDestinationMismatch(
                expected: record.destinationPath,
                actual: destinationPath
            )
        }
        if let identity = record.sourceIdentity {
            guard record.formatVersion == UploadResumeRecord.currentFormatVersion,
                  identity.matches(snapshot) else {
                throw HarnessError.resumeSourceChanged(sourceURL.path)
            }
        } else {
            guard record.nextOffsetBytes == 0,
                  record.totalSizeBytes == snapshot.sizeBytes,
                  record.sourceModifiedUnixMillis == snapshot.modifiedUnixMillis else {
                throw HarnessError.resumeSourceChanged(sourceURL.path)
            }
        }
    }

    static func uploadOpenExpectError(_ arguments: [String]) async -> Int32 {
        var activeClient: AsyncRpcControlClient?
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.positiveFiniteDouble("--timeout-seconds") ?? 5
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
                        + "requested_offset=\(requestedOffset) destination=\(HarnessPrivacy.redactedPath) "
                        + "message=\"\(HarnessPrivacy.message(error.message))\""
                )
                return 0
            }
        } catch let error as HarnessError {
            if let activeClient { await activeClient.close() }
            fputs("upload-open-expect-error failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        } catch {
            if let activeClient { await activeClient.close() }
            fputs("upload-open-expect-error failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }
}
