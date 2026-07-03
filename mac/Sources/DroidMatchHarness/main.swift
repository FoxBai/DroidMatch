import DroidMatchCore
import Foundation

enum HarnessCommand {
    static func run(arguments: [String]) -> Int32 {
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
            return m1Smoke(commandArguments)
        case "list-dir":
            return listDir(commandArguments)
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

    private static func m1Smoke(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let result = try M1SmokeClient().run(
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

    private static func listDir(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let path = try options.value("--path") ?? "dm://roots/"
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
            if response.hasError {
                fputs("list-dir failed: \(response.error.code): \(response.error.message)\n", stderr)
                return 1
            }

            let nextPageToken = response.nextPageToken.isEmpty ? "<none>" : response.nextPageToken
            print("list-dir passed path=\(path) entries=\(response.entries.count) next_page_token=\(nextPageToken)")
            for entry in response.entries {
                print(
                    "\(entry.kind) \(entry.path) name=\"\(entry.name)\" "
                        + "size=\(entry.sizeBytes) read=\(entry.canRead) write=\(entry.canWrite)"
                )
            }
            return 0
        } catch {
            fputs("list-dir failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func downloadOnce(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
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
            let result = try client.downloadFirstChunk(
                sourcePath: sourcePath,
                preferredChunkSizeBytes: chunkSize
            )
            print(
                "download-once passed transfer_id=\(result.openResponse.transferID) "
                    + "bytes=\(result.chunk.data.count) total=\(result.openResponse.totalSizeBytes) "
                    + "crc32=\(String(result.chunk.crc32, radix: 16)) final=\(result.chunk.finalChunk)"
            )
            return 0
        } catch {
            fputs("download-once failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func downloadCancel(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let reason = try options.value("--reason") ?? "harness-download-cancel"
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
            let result = try client.downloadFirstChunkThenCancel(
                sourcePath: sourcePath,
                preferredChunkSizeBytes: chunkSize,
                reason: reason
            )
            print(
                "download-cancel passed transfer_id=\(result.openResponse.transferID) "
                    + "first_chunk_bytes=\(result.chunk.data.count) "
                    + "total=\(result.openResponse.totalSizeBytes) "
                    + "cancel_ok=\(result.cancelResponse.ok)"
            )
            return 0
        } catch {
            fputs("download-cancel failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func downloadPause(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
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
            let result = try client.downloadFirstChunkThenPause(
                sourcePath: sourcePath,
                preferredChunkSizeBytes: chunkSize
            )
            print(
                "download-pause passed transfer_id=\(result.openResponse.transferID) "
                    + "first_chunk_bytes=\(result.chunk.data.count) "
                    + "total=\(result.openResponse.totalSizeBytes) "
                    + "pause_ok=\(result.pauseResponse.ok) "
                    + "resumable_offset=\(result.pauseResponse.resumableOffsetBytes)"
            )
            return 0
        } catch {
            fputs("download-pause failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func download(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourcePath = try options.requiredValue("--source-path")
            let destinationURL = URL(fileURLWithPath: try options.requiredValue("--destination"))
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let resume = options.flag("--resume")
            let stopAfterBytes = try options.int("--stop-after-bytes").map(Int64.init)
            if let stopAfterBytes, stopAfterBytes <= 0 {
                throw HarnessError.invalidInt(option: "--stop-after-bytes", value: "\(stopAfterBytes)")
            }
            if resume && stopAfterBytes != nil {
                throw HarnessError.invalidOptionCombination("--stop-after-bytes cannot be combined with --resume")
            }
            let sidecarURL = resumeRecordURL(for: destinationURL)
            let resumeRecord = try resume ? TransferResumeRecord.load(from: sidecarURL) : nil
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
            var bytesWritten = requestedOffset
            let result = try client.download(
                sourcePath: sourcePath,
                transferID: resumeRecord?.transferID ?? UUID().uuidString,
                requestedOffsetBytes: requestedOffset,
                sourceFingerprint: resumeRecord?.fingerprint.proto,
                preferredChunkSizeBytes: chunkSize,
                didOpen: { response in
                    guard response.acceptedOffsetBytes == requestedOffset else {
                        throw HarnessError.resumeOffsetRejected(
                            requested: requestedOffset,
                            accepted: response.acceptedOffsetBytes
                        )
                    }
                    let record = TransferResumeRecord(
                        transferID: response.transferID,
                        sourcePath: sourcePath,
                        totalSizeBytes: response.totalSizeBytes,
                        fingerprint: TransferFingerprintRecord(response.acceptedSourceFingerprint)
                    )
                    try record.save(to: sidecarURL)
                }
            ) { chunk in
                try writer.write(chunk.data)
                bytesWritten = chunk.offsetBytes + Int64(chunk.data.count)
                if let stopAfterBytes, bytesWritten >= stopAfterBytes {
                    throw HarnessError.partialDownloadStopped(
                        bytesWritten: bytesWritten,
                        partialPath: writer.partialURL.path,
                        sidecarPath: sidecarURL.path
                    )
                }
            }
            try writer.commit()
            try? FileManager.default.removeItem(at: sidecarURL)
            print(
                "download passed transfer_id=\(result.openResponse.transferID) "
                    + "chunks=\(result.chunkCount) bytes=\(result.bytesReceived) "
                    + "total=\(result.openResponse.totalSizeBytes) "
                    + "final_offset=\(result.finalOffsetBytes) resume=\(resume) destination=\(destinationURL.path)"
            )
            return 0
        } catch let error as HarnessError {
            if case let .partialDownloadStopped(bytesWritten, partialPath, sidecarPath) = error {
                print(
                    "download partial passed bytes=\(bytesWritten) "
                        + "partial=\(partialPath) sidecar=\(sidecarPath)"
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

    private static func upload(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.double("--timeout-seconds") ?? 5
            let sourceURL = URL(fileURLWithPath: try options.requiredValue("--source"))
            let destinationPath = try options.requiredValue("--destination-path")
            let chunkSize = try options.uint32("--chunk-size") ?? (256 * 1024)
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            guard let fileSize = attributes[.size] as? NSNumber else {
                throw HarnessError.localFileSizeUnavailable(sourceURL.path)
            }
            let expectedSizeBytes = fileSize.int64Value
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
            let result = try client.upload(
                sourcePath: sourceURL.path,
                destinationPath: destinationPath,
                expectedSizeBytes: expectedSizeBytes,
                preferredChunkSizeBytes: chunkSize
            ) { offset, byteCount in
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: byteCount) ?? Data()
            }
            print(
                "upload passed transfer_id=\(result.openResponse.transferID) "
                    + "chunks=\(result.chunkCount) bytes=\(result.bytesSent) "
                    + "total=\(result.openResponse.totalSizeBytes) "
                    + "final_offset=\(result.finalOffsetBytes) "
                    + "source=\(sourceURL.path) destination=\(destinationPath)"
            )
            return 0
        } catch {
            fputs("upload failed: \(error)\n", stderr)
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
              list-dir              Handshake, then run ListDirRequest for a logical DroidMatch path.
              download-once         Handshake, open a download transfer, read one chunk, and ack it.
              download-cancel       Handshake, open a download transfer, read one chunk, then cancel it.
              download-pause        Handshake, open a download transfer, read one chunk, then pause it.
              download              Handshake, download all chunks for one logical DroidMatch path.
              upload                Handshake, upload one local file to a logical DroidMatch path.
              frame-self-test       Verify local length-prefixed frame encode/decode.

            examples:
              droidmatch-harness forward --serial ABC123 --remote-port 39001
              droidmatch-harness framed-echo --port 49152 --payload hello
              droidmatch-harness handshake-smoke --port 49152
              droidmatch-harness m1-smoke --port 49152
              droidmatch-harness list-dir --port 49152 --path dm://media-images/
              droidmatch-harness download-once --port 49152 --source-path dm://media-images/media/42
              droidmatch-harness download-cancel --port 49152 --source-path dm://media-images/media/42
              droidmatch-harness download-pause --port 49152 --source-path dm://media-images/media/42
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --stop-after-bytes 1
              droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --resume
              droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg
            """
        )
    }

    private static func redactSerial(_ serial: String) -> String {
        guard serial.count > 8 else {
            return "<redacted>"
        }
        return "\(serial.prefix(4))...\(serial.suffix(4))"
    }
}

private enum HarnessError: Error, CustomStringConvertible {
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
    case resumeSourceMismatch(expected: String, actual: String)
    case resumeOffsetRejected(requested: Int64, accepted: Int64)
    case localFileSizeUnavailable(String)

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
        case let .resumeSourceMismatch(expected, actual):
            return "resume metadata source_path mismatch: expected \(expected), got \(actual)"
        case let .resumeOffsetRejected(requested, accepted):
            return "remote rejected resume offset: requested \(requested), accepted \(accepted)"
        case let .localFileSizeUnavailable(path):
            return "could not determine local file size: \(path)"
        }
    }
}

private struct CommandOptions {
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

private struct TransferResumeRecord: Codable {
    let transferID: String
    let sourcePath: String
    let totalSizeBytes: Int64
    let fingerprint: TransferFingerprintRecord

    static func load(from url: URL) throws -> TransferResumeRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TransferResumeRecord.self, from: data)
    }

    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

private struct TransferFingerprintRecord: Codable {
    let sizeBytes: Int64
    let modifiedUnixMillis: Int64
    let providerEtag: String
    let sha256: String

    init(_ fingerprint: Droidmatch_V1_TransferFingerprint) {
        sizeBytes = fingerprint.sizeBytes
        modifiedUnixMillis = fingerprint.modifiedUnixMillis
        providerEtag = fingerprint.providerEtag
        sha256 = fingerprint.sha256
    }

    var proto: Droidmatch_V1_TransferFingerprint {
        var fingerprint = Droidmatch_V1_TransferFingerprint()
        fingerprint.sizeBytes = sizeBytes
        fingerprint.modifiedUnixMillis = modifiedUnixMillis
        fingerprint.providerEtag = providerEtag
        fingerprint.sha256 = sha256
        return fingerprint
    }
}

private func resumeRecordURL(for destinationURL: URL) -> URL {
    URL(fileURLWithPath: destinationURL.path + ".droidmatch-transfer.json")
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

exit(HarnessCommand.run(arguments: CommandLine.arguments))
