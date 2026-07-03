import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    private let terminationGraceSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 30) {
        self.init(timeoutSeconds: timeoutSeconds, terminationGraceSeconds: 2)
    }

    init(timeoutSeconds: TimeInterval, terminationGraceSeconds: TimeInterval) {
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
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

        let stdoutData = LockedValue(Data())
        let stderrData = LockedValue(Data())

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
            var didTerminate = termination.wait(timeout: .now() + terminationGraceSeconds) == .success
            if !didTerminate {
                sendKillSignal(to: process)
                didTerminate = termination.wait(timeout: .now() + terminationGraceSeconds) == .success
            }
            if didTerminate {
                group.wait()
            }
            throw ProcessRunnerError.timedOut(executable: executable, timeoutSeconds: timeoutSeconds)
        }

        group.wait()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData.value(), encoding: .utf8) ?? "",
            stderr: String(data: stderrData.value(), encoding: .utf8) ?? ""
        )
    }

    private func sendKillSignal(to process: Process) {
        #if canImport(Darwin) || canImport(Glibc)
        kill(pid_t(process.processIdentifier), SIGKILL)
        #else
        process.terminate()
        #endif
    }
}
