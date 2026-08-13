import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    static let productServerSocket = "tcp:localhost:47137"

    public let adbPath: String
    private let processRunner: ProcessRunner
    private let productEnvironment: [String: String]?
    private let serverArguments: [String]

    public init(adbPath: String? = nil, processRunner: ProcessRunner = ProcessRunner()) {
        let requiresBundledAdb = Self.currentProcessRequiresBundledAdb()
        let selectedPath = Self.resolveAdbPath(
            explicitPath: adbPath,
            bundleURL: Bundle.main.bundleURL,
            requiresBundledAdb: requiresBundledAdb,
            homeDirectory: NSHomeDirectory(),
            isExecutable: FileManager.default.isExecutableFile(atPath:),
            environmentValue: Self.environmentValue
        )
        let usesBundledProductAdb = requiresBundledAdb || Self.isBundledProductAdb(
            selectedPath,
            bundleURL: Bundle.main.bundleURL
        )
        self.adbPath = selectedPath
        self.processRunner = processRunner
        self.productEnvironment = usesBundledProductAdb ? Self.bundledEnvironment() : nil
        self.serverArguments = usesBundledProductAdb ? ["-L", Self.productServerSocket] : []
    }

    public static func defaultAdbPath() -> String {
        resolveAdbPath(
            explicitPath: nil,
            bundleURL: Bundle.main.bundleURL,
            requiresBundledAdb: currentProcessRequiresBundledAdb(),
            homeDirectory: NSHomeDirectory(),
            isExecutable: FileManager.default.isExecutableFile(atPath:),
            environmentValue: environmentValue
        )
    }

    /// Returns a stable, non-reversible display tag for CLI diagnostics.
    /// Raw serials remain available only to the Core transport boundary.
    /// 中文：为 CLI 诊断生成稳定且不可逆的显示标签；原始 serial 只留在 Core 传输边界。
    public static func redactedSerial(_ serial: String) -> String {
        guard !serial.isEmpty else {
            return "<serial-redacted:unknown>"
        }
        let digest = SHA256.hash(data: Data(serial.utf8))
        let tag = digest.prefix(4)
            .map { String(format: "%02x", Int($0)) }
            .joined()
        return "<serial-redacted:\(tag)>"
    }

    static func bundledAdbPath(bundleURL: URL) -> String {
        bundleURL
            .appendingPathComponent("Contents/Resources/platform-tools/adb")
            .path
    }

    static func isBundledProductAdb(_ path: String, bundleURL: URL) -> Bool {
        path == bundledAdbPath(bundleURL: bundleURL)
    }

    static func resolveAdbPath(
        explicitPath: String?,
        bundleURL: URL,
        requiresBundledAdb: Bool,
        homeDirectory: String,
        isExecutable: (String) -> Bool,
        environmentValue: (String) -> String?
    ) -> String {
        let bundledCandidate = bundledAdbPath(bundleURL: bundleURL)
        // The live sandbox entitlement is the product-mode authority. Missing
        // or temporarily unavailable sealed bytes must fail at launch instead
        // of crossing into a developer SDK or the default ADB server.
        if requiresBundledAdb {
            return bundledCandidate
        }
        if let explicitPath {
            return explicitPath
        }
        if isExecutable(bundledCandidate) {
            return bundledCandidate
        }
        if let configured = environmentValue("DROIDMATCH_ADB"),
           isExecutable(configured) {
            return configured
        }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environmentValue(key) {
                let candidate = "\(sdk)/platform-tools/adb"
                if isExecutable(candidate) {
                    return candidate
                }
            }
        }
        let homeCandidate = "\(homeDirectory)/Library/Android/sdk/platform-tools/adb"
        return isExecutable(homeCandidate) ? homeCandidate : "adb"
    }

    static func currentProcessRequiresBundledAdb() -> Bool {
        if Bundle.main.object(forInfoDictionaryKey: "DroidMatchBundledAdbRequired") as? Bool == true {
            return true
        }
        if Bundle.main.object(forInfoDictionaryKey: "DroidMatchEvidenceBuild") as? Bool == true {
            return true
        }
#if canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              ) else {
            return false
        }
        return value as? Bool == true
#else
        return false
#endif
    }

    static func bundledEnvironment(
        homeDirectory: String = NSHomeDirectory(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        ["HOME": homeDirectory, "TMPDIR": temporaryDirectory.path]
    }

    private static func environmentValue(_ key: String) -> String? {
        guard let value = getenv(key) else {
            return nil
        }
        return String(validatingCString: value)
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
        let result = try processRunner.run(
            executable: adbPath,
            arguments: serverArguments + arguments,
            environment: productEnvironment
        )
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
