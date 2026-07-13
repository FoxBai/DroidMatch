import DroidMatchCore
import Foundation

enum HarnessCommand {
    static func run(arguments: [String]) async -> Int32 {
        let command = arguments.dropFirst().first ?? "help"
        let commandArguments = Array(arguments.dropFirst(2))

        switch command {
        case "adb-path":
            print(AdbClient.defaultAdbPath())
            return 0
        case "devices":
            return listDevices()
        case "forward":
            return forward(commandArguments)
        case "framed-echo":
            return await framedEcho(commandArguments)
        case "handshake-smoke":
            return await handshakeSmoke(commandArguments)
        case "m1-smoke":
            return await m1Smoke(commandArguments)
        case "dual-download-smoke":
            return await dualDownloadSmoke(commandArguments)
        case "mixed-transfer-smoke":
            return await mixedTransferSmoke(commandArguments)
        case "list-dir":
            return await listDir(commandArguments)
        case "list-dir-all":
            return await listDirAll(commandArguments)
        case "list-dir-expect-error":
            return await listDirExpectError(commandArguments)
        case "delete-path":
            return await deletePath(commandArguments)
        case "download-open-expect-error":
            return await downloadOpenExpectError(commandArguments)
        case "download-once":
            return await downloadOnce(commandArguments)
        case "download-cancel":
            return await downloadCancel(commandArguments)
        case "download-pause":
            return await downloadPause(commandArguments)
        case "download":
            return await download(commandArguments)
        case "upload":
            return await upload(commandArguments)
        case "upload-open-expect-error":
            return await uploadOpenExpectError(commandArguments)
        case "frame-self-test":
            return frameSelfTest()
        case "help", "--help", "-h":
            HarnessHelp.printUsage()
            return 0
        default:
            fputs("unknown command: \(command)\n", stderr)
            HarnessHelp.printUsage()
            return 2
        }
    }

    private static func listDevices() -> Int32 {
        do {
            let client = AdbClient()
            let devices = try client.devices()
            if devices.isEmpty {
                print("no adb devices visible")
            } else {
                for device in devices {
                    let model = device.model.map { " model=\($0)" } ?? ""
                    print("\(AdbClient.redactedSerial(device.serial)) \(device.state)\(model)")
                }
            }
            return 0
        } catch {
            fputs("adb devices failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    private static func frameSelfTest() -> Int32 {
        do {
            let payload = Data("droidmatch-frame-self-test".utf8)
            let codec = FrameCodec()
            var frame = try codec.encode(payload: payload)
            guard let decoded = try codec.decodeNext(from: &frame), decoded == payload, frame.isEmpty else {
                fputs("frame self-test failed\n", stderr)
                return 1
            }
            print("frame self-test passed crc32=\(String(Crc32.checksum(payload), radix: 16))")
            return 0
        } catch {
            fputs("frame self-test failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    private static func forward(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let remotePort = try options.requiredInt("--remote-port")
            let localPort = try options.int("--local-port") ?? 0
            let client = AdbClient()
            let serial = try options.value("--serial") ?? singleReadyDeviceSerial(client)
            let allocatedPort = try client.forward(
                serial: serial,
                localPort: localPort,
                remotePort: remotePort
            )
            print("serial=\(AdbClient.redactedSerial(serial)) local_port=\(allocatedPort) remote_port=\(remotePort)")
            return 0
        } catch {
            fputs("forward failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    private static func framedEcho(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let payload = try payload(from: options)
            let session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            do {
                let echoed = try await session.roundTrip(payload: payload)
                guard echoed == payload else {
                    fputs("framed echo mismatch: sent \(payload.count) bytes, received \(echoed.count) bytes\n", stderr)
                    await session.close()
                    return 1
                }
                print("framed echo passed bytes=\(payload.count) crc32=\(String(Crc32.checksum(payload), radix: 16))")
                await session.close()
                return 0
            } catch {
                await session.close()
                throw error
            }
        } catch {
            fputs("framed echo failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    private static func handshakeSmoke(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let result = try await HandshakeSmokeClient().run(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            let capabilities = result.grantedCapabilities
                .map { String(describing: $0) }
                .joined(separator: ",")
            print(
                "handshake smoke passed server=\(result.serverName) version=\(result.serverVersion) "
                    + "protocol=\(result.protocolMajor).\(result.protocolMinor) transport=\(result.transport) "
                    + "granted_capabilities=\(capabilities)"
            )
            return 0
        } catch {
            fputs("handshake smoke failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    private static func m1Smoke(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let result = try await M1SmokeClient().run(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            print(
                "m1 smoke passed server=\(result.handshake.serverName) "
                    + "device=\"\(result.deviceInfo.manufacturer) \(result.deviceInfo.model)\" "
                    + "sdk=\(result.deviceInfo.sdkInt) battery=\(result.deviceInfo.batteryPercent) "
                    + "heartbeat_ms=\(result.heartbeat.monotonicMillis) "
                    + "roots=\(result.rootList.entries.count) "
                    + "service_state=\(result.diagnostics.serviceState) "
                    + "events=\(result.diagnostics.recentEvents.count) errors=\(result.diagnostics.recentErrors.count)"
            )
            return 0
        } catch {
            fputs("m1 smoke failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    private static func dualDownloadSmoke(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let firstSourcePath = try options.requiredValue("--source-path-a")
            let secondSourcePath = try options.requiredValue("--source-path-b")
            let chunkSize = try options.uint32("--chunk-size-bytes") ?? 256 * 1024
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
            let result = try await AsyncDualDownloadSmokeClient(client: client).run(
                firstSourcePath: firstSourcePath,
                secondSourcePath: secondSourcePath,
                preferredChunkSizeBytes: chunkSize
            )
            await client.close()
            print(
                "dual-download-smoke passed "
                    + "stream_a=\(result.first.openResponse.streamID) "
                    + "chunks_a=\(result.first.chunkCount) bytes_a=\(result.first.bytesReceived) "
                    + "stream_b=\(result.second.openResponse.streamID) "
                    + "chunks_b=\(result.second.chunkCount) bytes_b=\(result.second.bytesReceived) "
                    + "heartbeat_ms=\(result.heartbeat.monotonicMillis)"
            )
            return 0
        } catch {
            fputs("dual-download-smoke failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    private static func mixedTransferSmoke(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let downloadSourcePath = try options.requiredValue("--download-source-path")
            let downloadDestinationURL = URL(
                fileURLWithPath: try options.requiredValue("--download-destination")
            )
            let uploadSourceURL = URL(
                fileURLWithPath: try options.requiredValue("--upload-source")
            )
            let uploadDestinationPath = try options.requiredValue(
                "--upload-destination-path"
            )
            let chunkSize = try options.uint32("--chunk-size-bytes") ?? 256 * 1024
            let result = try await AsyncMixedTransferSmokeClient().run(
                host: host,
                port: port,
                timeoutSeconds: timeout,
                request: AsyncMixedTransferSmokeRequest(
                    downloadSourcePath: downloadSourcePath,
                    downloadDestinationURL: downloadDestinationURL,
                    uploadSourceURL: uploadSourceURL,
                    uploadDestinationPath: uploadDestinationPath,
                    preferredChunkSizeBytes: chunkSize
                )
            )
            print(
                "mixed-transfer-smoke passed "
                    + "server=\(result.handshake.serverName) "
                    + "download_stream=\(result.download.openResponse.streamID) "
                    + "download_chunks=\(result.download.chunkCount) "
                    + "download_bytes=\(result.download.bytesReceived) "
                    + "upload_stream=\(result.upload.openResponse.streamID) "
                    + "upload_chunks=\(result.upload.chunkCount) "
                    + "upload_bytes=\(result.upload.bytesSent) "
                    + "heartbeat_ms=\(result.heartbeatMonotonicMillis) "
                    + "elapsed_ms=\(result.elapsedMilliseconds) "
                    + "upload_destination=\(HarnessPrivacy.redactedPath)"
            )
            return 0
        } catch {
            fputs("mixed-transfer-smoke failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }

    /// Runs one evidence command on the product async control path and preserves
    /// the legacy defer order: the operation emits its result before teardown,
    /// while every thrown error still closes the client before it escapes.
    static func withAsyncControlClient<Result>(
        host: String,
        port: Int,
        timeout: TimeInterval,
        operation: (AsyncRpcControlClient) async throws -> Result
    ) async throws -> Result {
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
            let result = try await operation(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    private static func singleReadyDeviceSerial(_ client: AdbClient) throws -> String {
        let readyDevices = try client.devices().filter { $0.state == "device" }
        if readyDevices.count == 1 {
            return readyDevices[0].serial
        }
        if readyDevices.isEmpty {
            throw HarnessError.noReadyDevice
        }
        throw HarnessError.multipleReadyDevices(readyDevices.map { AdbClient.redactedSerial($0.serial) })
    }

    private static func payload(from options: CommandOptions) throws -> Data {
        if let hex = try options.value("--hex") {
            return try Data(hexString: hex)
        }
        let text = try options.value("--payload") ?? "droidmatch-framed-echo"
        return Data(text.utf8)
    }


    static func isRetryableTransportError(_ error: Error) -> Bool {
        isRetryableTransferError(error)
    }

    /// 把 harness 命令行选项解析成 `RecoveryPolicy`。
    ///
    /// - 未开启 `--retry-on-transport-loss` 时返回 `.disabled`，完全跳过恢复。
    /// - 开启但未传 `--max-retry-attempts` 时退回到 `.defaultSingleRetry`，
    ///   与恢复队列之前的 harness 行为一致。
    /// - 开启并显式传 `--max-retry-attempts` 时构造可配置多次重试 + 指数退避
    ///   的策略。`--retry-backoff-ms` 控制基准退避（默认 500ms）。
    ///
    /// 调用方负责保证 `--stop-after-bytes` 等不支持恢复的路径不进入重试循环。
    static func resolveRecoveryPolicy(
        enabled: Bool,
        options: CommandOptions
    ) throws -> RecoveryPolicy {
        guard enabled else {
            return .disabled
        }
        guard let maxAttempts = try options.int("--max-retry-attempts") else {
            return .defaultSingleRetry
        }
        guard maxAttempts >= 0 else {
            throw HarnessError.invalidInt(
                option: "--max-retry-attempts",
                value: "\(maxAttempts)"
            )
        }
        if maxAttempts == 0 {
            // 显式传 0 = 开启恢复语义但不允许任何重试，等价于关闭。
            return .disabled
        }
        let baseDelayMs = try options.int("--retry-backoff-ms").map(Int64.init) ?? 500
        guard baseDelayMs >= 0 else {
            throw HarnessError.invalidInt(
                option: "--retry-backoff-ms",
                value: "\(baseDelayMs)"
            )
        }
        // harness 退避默认不带抖动，使真机矩阵日志里的 backoff_ms 可复现；
        // 抖动主要给未来并发多流重试避免撞线用，当前单流串行不需要。
        return RecoveryPolicy(
            maxAttempts: maxAttempts,
            baseDelayMs: baseDelayMs,
            maxDelayMs: 30_000,
            jitterFactor: 0
        )
    }

    /// 在重试之间按 `RecoveryPolicy` 计算出的延迟睡眠。
    /// 抽出来便于在真机日志里看到确切的 backoff_ms。
    static func sleepRecovery(delayMs: Int64) {
        defaultRecoverySleeper(delayMs)
    }

    static func hasDownloadResumeRecord(at url: URL) -> Bool {
        do {
            return try DownloadResumeRecord.load(from: url) != nil
        } catch {
            return false
        }
    }

    static func hasUploadResumeRecord(at url: URL) -> Bool {
        do {
            return try UploadResumeRecord.load(from: url) != nil
        } catch {
            return false
        }
    }

    static func errorCode(from value: String) throws -> Droidmatch_V1_ErrorCode {
        if let rawValue = Int(value), let code = Droidmatch_V1_ErrorCode(rawValue: rawValue) {
            return code
        }
        switch value {
        case "unspecified", "ERROR_CODE_UNSPECIFIED":
            return .unspecified
        case "unsupportedVersion", "unsupported_version", "ERROR_CODE_UNSUPPORTED_VERSION":
            return .unsupportedVersion
        case "unsupportedCapability", "unsupported_capability", "ERROR_CODE_UNSUPPORTED_CAPABILITY":
            return .unsupportedCapability
        case "unauthorized", "ERROR_CODE_UNAUTHORIZED":
            return .unauthorized
        case "permissionRequired", "permission_required", "ERROR_CODE_PERMISSION_REQUIRED":
            return .permissionRequired
        case "notFound", "not_found", "ERROR_CODE_NOT_FOUND":
            return .notFound
        case "alreadyExists", "already_exists", "ERROR_CODE_ALREADY_EXISTS":
            return .alreadyExists
        case "invalidArgument", "invalid_argument", "ERROR_CODE_INVALID_ARGUMENT":
            return .invalidArgument
        case "cancelled", "ERROR_CODE_CANCELLED":
            return .cancelled
        case "timeout", "ERROR_CODE_TIMEOUT":
            return .timeout
        case "transportLost", "transport_lost", "ERROR_CODE_TRANSPORT_LOST":
            return .transportLost
        case "checksumMismatch", "checksum_mismatch", "ERROR_CODE_CHECKSUM_MISMATCH":
            return .checksumMismatch
        case "storageReadOnly", "storage_read_only", "ERROR_CODE_STORAGE_READ_ONLY":
            return .storageReadOnly
        case "internal", "ERROR_CODE_INTERNAL":
            return .internal
        case "protocolError", "protocol_error", "ERROR_CODE_PROTOCOL_ERROR":
            return .protocolError
        default:
            throw HarnessError.invalidErrorCode(value)
        }
    }

}


struct TimedDownloadResult {
    let result: DownloadResult
    let elapsedMilliseconds: Int64
}

struct TimedUploadResult {
    let result: UploadResult
    let elapsedMilliseconds: Int64
}

func resumeRecordURL(for destinationURL: URL) -> URL {
    DownloadResumeRecord.sidecarURL(forDestination: destinationURL)
}

func uploadResumeRecordURL(for sourceURL: URL) -> URL {
    UploadResumeRecord.sidecarURL(forSource: sourceURL)
}

func localModifiedUnixMillis(attributes: [FileAttributeKey: Any], path: String) throws -> Int64 {
    guard let modifiedDate = attributes[.modificationDate] as? Date else {
        throw HarnessError.localFileSizeUnavailable(path)
    }
    return Int64(modifiedDate.timeIntervalSince1970 * 1000)
}

func monotonicMilliseconds() -> Int64 {
    Int64(ProcessInfo.processInfo.systemUptime * 1000)
}

func formatThroughputMiBPerSecond(bytes: Int64, elapsedMilliseconds: Int64) -> String {
    let seconds = max(Double(elapsedMilliseconds) / 1000.0, 0.001)
    let mibPerSecond = (Double(bytes) / 1_048_576.0) / seconds
    return String(format: "%.2f", mibPerSecond)
}

private extension Data {
    init(hexString: String) throws {
        let compact = hexString.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else {
            throw HarnessError.invalidHex(hexString)
        }

        var data = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let nextIndex = compact.index(index, offsetBy: 2)
            let byteString = compact[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw HarnessError.invalidHex(hexString)
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

exit(await HarnessCommand.run(arguments: CommandLine.arguments))
