import Foundation

public struct ProcessResult: Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case timedOut(executable: String, timeoutSeconds: TimeInterval)

    public var description: String {
        switch self {
        case let .timedOut(executable, timeoutSeconds):
            return "\(executable) timed out after \(timeoutSeconds)s"
        }
    }
}

public struct ProcessRunner {
    public let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 30) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let group = DispatchGroup()
        let outputQueue = DispatchQueue(label: "app.droidmatch.process-output", attributes: .concurrent)

        let stdoutData = LockedData()
        let stderrData = LockedData()

        group.enter()
        outputQueue.async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        group.enter()
        outputQueue.async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        try process.run()

        let waitResult = termination.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            process.terminate()
            _ = termination.wait(timeout: .now() + 2)
            throw ProcessRunnerError.timedOut(executable: executable, timeoutSeconds: timeoutSeconds)
        }

        group.wait()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData.value(), encoding: .utf8) ?? "",
            stderr: String(data: stderrData.value(), encoding: .utf8) ?? ""
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) {
        lock.lock()
        data = newValue
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}
