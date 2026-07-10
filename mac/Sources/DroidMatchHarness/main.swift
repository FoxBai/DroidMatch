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
            return framedEcho(commandArguments)
        case "handshake-smoke":
            return handshakeSmoke(commandArguments)
        case "m1-smoke":
            return await m1Smoke(commandArguments)
        case "dual-download-smoke":
            return dualDownloadSmoke(commandArguments)
        case "mixed-transfer-smoke":
            return await mixedTransferSmoke(commandArguments)
        case "list-dir":
            return await listDir(commandArguments)
        case "list-dir-expect-error":
            return listDirExpectError(commandArguments)
        case "download-open-expect-error":
            return downloadOpenExpectError(commandArguments)
        case "download-once":
            return downloadOnce(commandArguments)
        case "download-cancel":
            return downloadCancel(commandArguments)
        case "download-pause":
            return downloadPause(commandArguments)
        case "download":
            return download(commandArguments)
        case "upload":
            return upload(commandArguments)
        case "upload-open-expect-error":
            return uploadOpenExpectError(commandArguments)
        case "frame-self-test":
            return frameSelfTest()
        case "help", "--help", "-h":
            printHelp()
            return 0
        default:
            fputs("unknown command: \(command)\n", stderr)
            printHelp()
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
                    print("\(device.serial) \(device.state)\(model)")
                }
            }
            return 0
        } catch {
            fputs("adb devices failed: \(error)\n", stderr)
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
            fputs("frame self-test failed: \(error)\n", stderr)
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
            print("serial=\(serial) local_port=\(allocatedPort) remote_port=\(remotePort)")
            return 0
        } catch {
            fputs("forward failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func framedEcho(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let payload = try payload(from: options)
            let client = FramedTcpClient(host: host, port: port, timeoutSeconds: timeout)
            let echoed = try client.roundTrip(payload: payload)
            guard echoed == payload else {
                fputs("framed echo mismatch: sent \(payload.count) bytes, received \(echoed.count) bytes\n", stderr)
                return 1
            }
            print("framed echo passed bytes=\(payload.count) crc32=\(String(Crc32.checksum(payload), radix: 16))")
            return 0
        } catch {
            fputs("framed echo failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func handshakeSmoke(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let result = try HandshakeSmokeClient().run(
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
            fputs("handshake smoke failed: \(error)\n", stderr)
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
            fputs("m1 smoke failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func dualDownloadSmoke(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let firstSourcePath = try options.requiredValue("--source-path-a")
            let secondSourcePath = try options.requiredValue("--source-path-b")
            let chunkSize = try options.uint32("--chunk-size-bytes") ?? 256 * 1024
            let session = try FramedTcpSession(
                host: host,
                port: port,
                timeoutSeconds: timeout
            )
            defer { session.close() }

            let result = try DualDownloadSmokeClient(session: session).run(
                firstSourcePath: firstSourcePath,
                secondSourcePath: secondSourcePath,
                preferredChunkSizeBytes: chunkSize
            )
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
            fputs("dual-download-smoke failed: \(error)\n", stderr)
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
                    + "upload_destination=\(uploadDestinationPath)"
            )
            return 0
        } catch {
            fputs("mixed-transfer-smoke failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func listDir(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let path = try options.value("--path") ?? "dm://roots/"
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
                // Preserve the historical metric: connect is excluded, while
                // handshake plus the listing request are included.
                let startedMilliseconds = monotonicMilliseconds()
                _ = try await client.handshake()
                let response = try await client.listDir(path: path)
                let elapsedMilliseconds = max(
                    1,
                    monotonicMilliseconds() - startedMilliseconds
                )
                if response.hasError {
                    fputs(
                        "list-dir failed: \(response.error.code): \(response.error.message)\n",
                        stderr
                    )
                    await client.close()
                    return 1
                }

                let nextPageToken = response.nextPageToken.isEmpty
                    ? "<none>"
                    : response.nextPageToken
                print(
                    "list-dir passed path=\(path) entries=\(response.entries.count) "
                        + "next_page_token=\(nextPageToken) elapsed_ms=\(elapsedMilliseconds)"
                )
                for entry in response.entries {
                    print(
                        "\(entry.kind) \(entry.path) name=\"\(entry.name)\" "
                            + "size=\(entry.sizeBytes) read=\(entry.canRead) write=\(entry.canWrite)"
                    )
                }
                await client.close()
                return 0
            } catch {
                await client.close()
                throw error
            }
        } catch {
            fputs("list-dir failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func listDirExpectError(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let path = try options.requiredValue("--path")
            let expectedErrorCode = try errorCode(from: options.requiredValue("--expected-error-code"))
            let expectedMessage = try options.value("--expected-message-contains")
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
            let response = try client.listDir(path: path)
            guard response.hasError else {
                throw HarnessError.expectedListDirErrorNotReceived(path)
            }
            guard response.error.code == expectedErrorCode else {
                throw HarnessError.unexpectedRemoteErrorCode(
                    expected: expectedErrorCode,
                    actual: response.error.code,
                    message: response.error.message
                )
            }
            if let expectedMessage, !response.error.message.contains(expectedMessage) {
                throw HarnessError.unexpectedRemoteErrorMessage(
                    expectedSubstring: expectedMessage,
                    actual: response.error.message
                )
            }
            print(
                "list-dir error passed code=\(response.error.code) "
                    + "path=\(path) message=\"\(response.error.message)\""
            )
            return 0
        } catch let error as HarnessError {
            fputs("list-dir-expect-error failed: \(error)\n", stderr)
            return 1
        } catch {
            fputs("list-dir-expect-error failed: \(error)\n", stderr)
            return 1
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
        throw HarnessError.multipleReadyDevices(readyDevices.map { redactSerial($0.serial) })
    }

    private static func payload(from options: CommandOptions) throws -> Data {
        if let hex = try options.value("--hex") {
            return try Data(hexString: hex)
        }
        let text = try options.value("--payload") ?? "droidmatch-framed-echo"
        return Data(text.utf8)
    }

    private static func printHelp() {
        print(
            """
            droidmatch-harness commands:
              adb-path              Print the adb executable selected by the harness.
              devices               List adb-visible devices.
              forward               Create an adb forward to an Android endpoint.
              framed-echo           Send one length-prefixed frame and require the same frame back.
              handshake-smoke       Send ClientHello and require ServerHello.
              m1-smoke              Run handshake, heartbeat, device info, root listing, and diagnostics on one connection.
              dual-download-smoke   Keep two downloads active, route interleaved chunks, and prove heartbeat responsiveness.
              mixed-transfer-smoke  Verify heartbeat with download/upload open, then complete both on one async session.
              list-dir              Handshake, then run ListDirRequest for a logical DroidMatch path.
              list-dir-expect-error
                                    Handshake, run ListDirRequest, and require a response error.
              download-open-expect-error
                                    Handshake, open a download, and require a remote open error.
              download-once         Handshake, open a download transfer, read one chunk, and ack it.
              download-cancel       Handshake, open a download transfer, read one chunk, then cancel it.
              download-pause        Handshake, open a download transfer, read one chunk, then pause it.
              download              Handshake, download all chunks for one logical DroidMatch path.
              upload                Handshake, upload one local file to a logical DroidMatch path.
              upload-open-expect-error
                                    Handshake, open an upload with a requested offset, and require a remote error.
              frame-self-test       Verify local length-prefixed frame encode/decode.

            examples:
              droidmatch-harness forward --serial ABC123 --remote-port 39001
              droidmatch-harness framed-echo --port 49152 --payload hello
              droidmatch-harness handshake-smoke --port 49152
              droidmatch-harness m1-smoke --port 49152
              droidmatch-harness dual-download-smoke --port 49152 --source-path-a dm://app-sandbox/a.bin --source-path-b dm://app-sandbox/b.bin
              droidmatch-harness mixed-transfer-smoke --port 49152 --download-source-path dm://app-sandbox/a.bin --download-destination /tmp/a.bin --upload-source /tmp/b.bin --upload-destination-path dm://app-sandbox/b.bin
              droidmatch-harness list-dir --port 49152 --path dm://media-images/
              droidmatch-harness list-dir-expect-error --port 49152 --path dm://saf-missing/ --expected-error-code notFound
              droidmatch-harness download-open-expect-error --port 49152 --source-path dm://app-sandbox/missing.bin --expected-error-code notFound
              droidmatch-harness download-once --port 49152 --source-path dm://media-images/media/42
              droidmatch-harness download-cancel --port 49152 --source-path dm://media-images/media/42
              droidmatch-harness download-pause --port 49152 --source-path dm://media-images/media/42
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --stop-after-bytes 1
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --resume
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --retry-on-transport-loss
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --retry-on-transport-loss --max-retry-attempts 3 --retry-backoff-ms 500
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --stop-after-bytes 1
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --resume
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --retry-on-transport-loss
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --retry-on-transport-loss --max-retry-attempts 3 --retry-backoff-ms 500
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://media-images/photo.jpg
              droidmatch-harness upload-open-expect-error --port 49152 --source /tmp/photo.jpg --destination-path dm://media-images/photo.jpg --requested-offset 1 --expected-error-code unsupportedCapability
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://saf-abc123/photo.jpg --stop-after-bytes 1
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://saf-abc123/photo.jpg --resume
            """
        )
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

    private static func redactSerial(_ serial: String) -> String {
        guard serial.count > 8 else {
            return "<redacted>"
        }
        return "\(serial.prefix(4))...\(serial.suffix(4))"
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case missingOption(String)
    case missingOptionValue(String)
    case invalidInt(option: String, value: String)
    case invalidUInt32(option: String, value: String)
    case invalidDouble(option: String, value: String)
    case invalidHex(String)
    case noReadyDevice
    case multipleReadyDevices([String])
    case invalidOptionCombination(String)
    case missingResumeRecord(String)
    case partialDownloadStopped(bytesWritten: Int64, partialPath: String, sidecarPath: String)
    case partialUploadStopped(bytesSent: Int64, sidecarPath: String)
    case resumeSourceMismatch(expected: String, actual: String)
    case resumeDestinationMismatch(expected: String, actual: String)
    case resumeSourceChanged(String)
    case resumeOffsetRejected(requested: Int64, accepted: Int64)
    case localFileSizeUnavailable(String)
    case transferDidNotComplete(String)
    case invalidErrorCode(String)
    case expectedDownloadOpenErrorNotReceived(String)
    case expectedRemoteOpenErrorNotReceived(String)
    case expectedListDirErrorNotReceived(String)
    case unexpectedRemoteErrorCode(
        expected: Droidmatch_V1_ErrorCode,
        actual: Droidmatch_V1_ErrorCode,
        message: String
    )
    case unexpectedRemoteErrorMessage(expectedSubstring: String, actual: String)

    var description: String {
        switch self {
        case let .missingOption(option):
            return "missing required option \(option)"
        case let .missingOptionValue(option):
            return "missing value for option \(option)"
        case let .invalidInt(option, value):
            return "invalid integer for \(option): \(value)"
        case let .invalidUInt32(option, value):
            return "invalid uint32 for \(option): \(value)"
        case let .invalidDouble(option, value):
            return "invalid number for \(option): \(value)"
        case let .invalidHex(value):
            return "invalid hex payload: \(value)"
        case .noReadyDevice:
            return "no adb device in device state; pass --serial after authorizing one"
        case let .multipleReadyDevices(serials):
            return "multiple adb devices are ready (\(serials.joined(separator: ", "))); pass --serial"
        case let .invalidOptionCombination(message):
            return message
        case let .missingResumeRecord(path):
            return "cannot resume without resume metadata sidecar: \(path)"
        case let .partialDownloadStopped(bytesWritten, partialPath, sidecarPath):
            return "partial download stopped after \(bytesWritten) bytes; partial=\(partialPath) sidecar=\(sidecarPath)"
        case let .partialUploadStopped(bytesSent, sidecarPath):
            return "partial upload stopped after \(bytesSent) bytes; sidecar=\(sidecarPath)"
        case let .resumeSourceMismatch(expected, actual):
            return "resume metadata source_path mismatch: expected \(expected), got \(actual)"
        case let .resumeDestinationMismatch(expected, actual):
            return "resume metadata destination_path mismatch: expected \(expected), got \(actual)"
        case let .resumeSourceChanged(path):
            return "resume metadata source file changed: \(path)"
        case let .resumeOffsetRejected(requested, accepted):
            return "remote rejected resume offset: requested \(requested), accepted \(accepted)"
        case let .localFileSizeUnavailable(path):
            return "could not determine local file size: \(path)"
        case let .transferDidNotComplete(direction):
            return "\(direction) did not complete"
        case let .invalidErrorCode(value):
            return "invalid error code: \(value)"
        case let .expectedDownloadOpenErrorNotReceived(sourcePath):
            return "remote accepted download open unexpectedly for \(sourcePath)"
        case let .expectedRemoteOpenErrorNotReceived(destinationPath):
            return "remote accepted upload open unexpectedly for \(destinationPath)"
        case let .expectedListDirErrorNotReceived(path):
            return "remote returned list-dir success unexpectedly for \(path)"
        case let .unexpectedRemoteErrorCode(expected, actual, message):
            return "expected remote error \(expected), got \(actual): \(message)"
        case let .unexpectedRemoteErrorMessage(expectedSubstring, actual):
            return "expected remote error message to contain \"\(expectedSubstring)\", got \"\(actual)\""
        }
    }
}

struct CommandOptions {
    private let values: [String: String]
    private let flags: Set<String>

    init(_ arguments: [String]) throws {
        var parsed: [String: String] = [:]
        var parsedFlags = Set<String>()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--") else {
                throw HarnessError.missingOption(option)
            }
            let valueIndex = index + 1
            if valueIndex >= arguments.count || arguments[valueIndex].hasPrefix("--") {
                parsedFlags.insert(option)
                index += 1
            } else {
                parsed[option] = arguments[valueIndex]
                index += 2
            }
        }
        values = parsed
        flags = parsedFlags
    }

    func value(_ option: String) throws -> String? {
        values[option]
    }

    func flag(_ option: String) -> Bool {
        flags.contains(option)
    }

    func requiredValue(_ option: String) throws -> String {
        guard let rawValue = values[option] else {
            throw HarnessError.missingOption(option)
        }
        return rawValue
    }

    func requiredInt(_ option: String) throws -> Int {
        guard let rawValue = values[option] else {
            throw HarnessError.missingOption(option)
        }
        guard let value = Int(rawValue) else {
            throw HarnessError.invalidInt(option: option, value: rawValue)
        }
        return value
    }

    func int(_ option: String) throws -> Int? {
        guard let rawValue = values[option] else {
            return nil
        }
        guard let value = Int(rawValue) else {
            throw HarnessError.invalidInt(option: option, value: rawValue)
        }
        return value
    }

    func uint32(_ option: String) throws -> UInt32? {
        guard let rawValue = values[option] else {
            return nil
        }
        guard let value = UInt32(rawValue) else {
            throw HarnessError.invalidUInt32(option: option, value: rawValue)
        }
        return value
    }

    func double(_ option: String) throws -> Double? {
        guard let rawValue = values[option] else {
            return nil
        }
        guard let value = Double(rawValue) else {
            throw HarnessError.invalidDouble(option: option, value: rawValue)
        }
        return value
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
