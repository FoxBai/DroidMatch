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
              frame-self-test       Verify local length-prefixed frame encode/decode.

            examples:
              droidmatch-harness forward --serial ABC123 --remote-port 39001
              droidmatch-harness framed-echo --port 49152 --payload hello
              droidmatch-harness handshake-smoke --port 49152
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
    case invalidDouble(option: String, value: String)
    case invalidHex(String)
    case noReadyDevice
    case multipleReadyDevices([String])

    var description: String {
        switch self {
        case let .missingOption(option):
            return "missing required option \(option)"
        case let .missingOptionValue(option):
            return "missing value for option \(option)"
        case let .invalidInt(option, value):
            return "invalid integer for \(option): \(value)"
        case let .invalidDouble(option, value):
            return "invalid number for \(option): \(value)"
        case let .invalidHex(value):
            return "invalid hex payload: \(value)"
        case .noReadyDevice:
            return "no adb device in device state; pass --serial after authorizing one"
        case let .multipleReadyDevices(serials):
            return "multiple adb devices are ready (\(serials.joined(separator: ", "))); pass --serial"
        }
    }
}

private struct CommandOptions {
    private let values: [String: String]

    init(_ arguments: [String]) throws {
        var parsed: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--") else {
                throw HarnessError.missingOption(option)
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw HarnessError.missingOptionValue(option)
            }
            parsed[option] = arguments[valueIndex]
            index += 2
        }
        values = parsed
    }

    func value(_ option: String) throws -> String? {
        values[option]
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
