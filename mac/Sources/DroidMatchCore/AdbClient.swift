import Foundation

public enum AdbClientError: Error, CustomStringConvertible, Sendable {
    case commandFailed(status: Int32, stderr: String)
    case missingAllocatedForwardPort(stdout: String)

    public var description: String {
        switch self {
        case let .commandFailed(status, stderr):
            return "adb exited with status \(status): \(stderr)"
        case let .missingAllocatedForwardPort(stdout):
            return "adb did not report an allocated forward port: \(stdout)"
        }
    }
}

public struct AdbDevice: Equatable, Sendable {
    public let serial: String
    public let state: String
    public let product: String?
    public let model: String?
    public let device: String?
}

public struct AdbForward: Equatable, Sendable {
    public let serial: String?
    public let local: String
    public let remote: String
}

public final class AdbClient {
    public let adbPath: String
    private let processRunner: ProcessRunner

    public init(adbPath: String? = nil, processRunner: ProcessRunner = ProcessRunner()) {
        self.adbPath = adbPath ?? Self.defaultAdbPath()
        self.processRunner = processRunner
    }

    public static func defaultAdbPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        if let configured = environment["DROIDMATCH_ADB"], fileManager.isExecutableFile(atPath: configured) {
            return configured
        }

        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key] {
                let candidate = "\(sdk)/platform-tools/adb"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        let homeCandidate = "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        if fileManager.isExecutableFile(atPath: homeCandidate) {
            return homeCandidate
        }

        return "adb"
    }

    public func devices() throws -> [AdbDevice] {
        let output = try run(arguments: ["devices", "-l"]).stdout
        return Self.parseDevices(output)
    }

    @discardableResult
    public func forward(serial: String, localPort: Int, remotePort: Int) throws -> Int {
        let output = try run(arguments: ["-s", serial, "forward", "tcp:\(localPort)", "tcp:\(remotePort)"]).stdout
        if localPort > 0 {
            return localPort
        }
        if let allocatedPort = Self.parseAllocatedForwardPort(output) {
            return allocatedPort
        }
        if let existingPort = Self.findForwardedTcpPort(
            in: try listForwards(),
            serial: serial,
            remotePort: remotePort
        ) {
            return existingPort
        }
        throw AdbClientError.missingAllocatedForwardPort(stdout: output)
    }

    public func removeForward(serial: String, localPort: Int) throws {
        _ = try run(arguments: ["-s", serial, "forward", "--remove", "tcp:\(localPort)"])
    }

    public func listForwards() throws -> [AdbForward] {
        let output = try run(arguments: ["forward", "--list"]).stdout
        return Self.parseForwards(output)
    }

    private func run(arguments: [String]) throws -> (stdout: String, stderr: String) {
        let result = try processRunner.run(executable: adbPath, arguments: arguments)
        guard result.status == 0 else {
            throw AdbClientError.commandFailed(status: result.status, stderr: result.stderr)
        }

        return (result.stdout, result.stderr)
    }

    static func parseDevices(_ output: String) -> [AdbDevice] {
        let knownStates: Set<String> = [
            "device",
            "offline",
            "unauthorized",
            "recovery",
            "sideload",
            "bootloader",
            "host"
        ]

        var devices: [AdbDevice] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, knownStates.contains(fields[1]) else {
                continue
            }

            var product: String?
            var model: String?
            var device: String?

            for field in fields.dropFirst(2) {
                if field.hasPrefix("product:") {
                    product = String(field.dropFirst("product:".count))
                } else if field.hasPrefix("model:") {
                    model = String(field.dropFirst("model:".count))
                } else if field.hasPrefix("device:") {
                    device = String(field.dropFirst("device:".count))
                }
            }

            devices.append(AdbDevice(
                serial: fields[0],
                state: fields[1],
                product: product,
                model: model,
                device: device
            ))
        }

        return devices
    }

    static func parseForwards(_ output: String) -> [AdbForward] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 3 else {
                    return nil
                }
                return AdbForward(serial: parts[0], local: parts[1], remote: parts[2])
            }
    }

    static func parseAllocatedForwardPort(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
                continue
            }
            if let port = Int(trimmed) {
                return port
            }
        }
        return nil
    }

    static func findForwardedTcpPort(in forwards: [AdbForward], serial: String, remotePort: Int) -> Int? {
        let remote = "tcp:\(remotePort)"
        for forward in forwards where forward.serial == serial && forward.remote == remote {
            guard forward.local.hasPrefix("tcp:") else {
                continue
            }
            let rawPort = forward.local.dropFirst("tcp:".count)
            guard let localPort = Int(rawPort) else {
                continue
            }
            return localPort
        }
        return nil
    }
}
