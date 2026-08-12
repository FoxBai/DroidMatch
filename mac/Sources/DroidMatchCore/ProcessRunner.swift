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
    case invalidTimeout
    case timedOut(executable: String, timeoutSeconds: TimeInterval)
    case cleanupUnconfirmed

    public var description: String {
        switch self {
        case .invalidTimeout:
            return "process timeout and termination grace must be finite and greater than zero"
        case let .timedOut(executable, timeoutSeconds):
            return "\(executable) timed out after \(timeoutSeconds)s"
        case .cleanupUnconfirmed:
            return "subprocess cleanup could not be confirmed"
        }
    }
}

private enum ProcessWaitOutcome: Sendable {
    case exitObserved
    case failed(Int32)
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
        guard AsyncTimeoutPolicy.nanoseconds(for: timeoutSeconds) != nil,
              AsyncTimeoutPolicy.nanoseconds(for: terminationGraceSeconds) != nil else {
            throw ProcessRunnerError.invalidTimeout
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let processID: pid_t
        do {
            processID = try spawn(
                executable: executable,
                arguments: arguments,
                stdout: stdout,
                stderr: stderr
            )
        } catch {
            closeAllHandles(stdout: stdout, stderr: stderr)
            throw error
        }

        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let executionDeadline = dispatchDeadline(after: timeoutSeconds)
        let completion = DispatchGroup()
        let workQueue = DispatchQueue(
            label: "app.droidmatch.process-runner",
            attributes: .concurrent
        )
        let stdoutData = LockedValue(Data())
        let stderrData = LockedValue(Data())
        let waitOutcome = LockedValue<ProcessWaitOutcome?>(nil)

        completion.enter()
        workQueue.async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            completion.leave()
        }

        completion.enter()
        workQueue.async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            completion.leave()
        }

        completion.enter()
        workQueue.async {
            var information = siginfo_t()
            var result: Int32
            repeat {
                result = waitid(
                    P_PID,
                    id_t(processID),
                    &information,
                    WEXITED | WNOWAIT
                )
            } while result == -1 && errno == EINTR
            if result == 0 && information.si_pid == processID {
                // Keep the group leader waitable until every timeout signal is
                // complete, so its PID/PGID cannot be reused under this runner.
                waitOutcome.set(.exitObserved)
            } else {
                waitOutcome.set(.failed(result == -1 ? errno : ECHILD))
            }
            completion.leave()
        }

        guard completion.wait(timeout: executionDeadline) == .success,
              case .exitObserved = waitOutcome.value() else {
            let cleanupConfirmed = cleanUpTimedOutProcess(
                processGroupID: processID,
                completion: completion,
                waitOutcome: waitOutcome,
                stdout: stdout,
                stderr: stderr
            )
            guard cleanupConfirmed else {
                throw ProcessRunnerError.cleanupUnconfirmed
            }
            throw ProcessRunnerError.timedOut(
                executable: executable,
                timeoutSeconds: timeoutSeconds
            )
        }

        guard let status = try? reapObservedProcess(processID) else {
            throw ProcessRunnerError.cleanupUnconfirmed
        }
        return ProcessResult(
            status: terminationStatus(from: status),
            stdout: String(data: stdoutData.value(), encoding: .utf8) ?? "",
            stderr: String(data: stderrData.value(), encoding: .utf8) ?? ""
        )
    }

    private func spawn(
        executable: String,
        arguments: [String],
        stdout: Pipe,
        stderr: Pipe
    ) throws -> pid_t {
        let path: String
        let spawnArguments: [String]
        if executable.contains("/") {
            path = executable
            spawnArguments = [executable] + arguments
        } else {
            path = "/usr/bin/env"
            spawnArguments = [path, executable] + arguments
        }

        var fileActions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let stdoutRead = stdout.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdout.fileHandleForWriting.fileDescriptor
        let stderrRead = stderr.fileHandleForReading.fileDescriptor
        let stderrWrite = stderr.fileHandleForWriting.fileDescriptor
        let descriptors = [stdoutRead, stdoutWrite, stderrRead, stderrWrite]
        guard descriptors.allSatisfy({ $0 > STDERR_FILENO }) else {
            throw posixError(EBADF)
        }
        for descriptor in descriptors {
            try setCloseOnExec(descriptor)
        }
        if fcntl(STDIN_FILENO, F_GETFD) != -1 {
            try checkPOSIX(
                posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO)
            )
        } else if errno != EBADF {
            throw posixError(errno)
        }
        try checkPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO))
        try checkPOSIX(posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO))
        for descriptor in descriptors {
            try checkPOSIX(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }

        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let requiredFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        guard let spawnFlags = Int16(exactly: requiredFlags) else {
            throw posixError(EINVAL)
        }
        try checkPOSIX(posix_spawnattr_setflags(&attributes, spawnFlags))
        // A zero pgroup creates a group whose ID is the spawned child PID. The
        // runner can therefore terminate descendants that retain inherited FDs.
        try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))

        let environment = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var processID: pid_t = 0
        let spawnStatus = try withCStringArray(spawnArguments) { argumentVector in
            try withCStringArray(environment) { environmentVector in
                path.withCString { pathPointer in
                    posix_spawn(
                        &processID,
                        pathPointer,
                        &fileActions,
                        &attributes,
                        argumentVector,
                        environmentVector
                    )
                }
            }
        }
        try checkPOSIX(spawnStatus)
        return processID
    }

    private func cleanUpTimedOutProcess(
        processGroupID: pid_t,
        completion: DispatchGroup,
        waitOutcome: LockedValue<ProcessWaitOutcome?>,
        stdout: Pipe,
        stderr: Pipe
    ) -> Bool {
        if case .failed = waitOutcome.value() {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            return false
        }

        // The unreaped group leader anchors this exact PID/PGID across both
        // signals. Never probe then signal, and never signal after reaping.
        _ = kill(-processGroupID, SIGTERM)
        _ = completion.wait(timeout: dispatchDeadline(after: terminationGraceSeconds))
        _ = kill(-processGroupID, SIGKILL)
        // Timeout paths never return output. Closing the read ends also bounds
        // readers if a descendant escaped the managed group but kept an FD.
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        let cleanupDeadline = dispatchDeadline(after: terminationGraceSeconds)
        guard completion.wait(timeout: cleanupDeadline) == .success,
              case .exitObserved = waitOutcome.value(),
              (try? reapObservedProcess(processGroupID)) != nil else {
            return false
        }
        return waitForProcessGroupToDisappear(processGroupID, until: cleanupDeadline)
    }

    private func waitForProcessGroupToDisappear(
        _ processGroupID: pid_t,
        until deadline: DispatchTime
    ) -> Bool {
        while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            if !processGroupExists(processGroupID) {
                return true
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else {
                break
            }
            let remaining = deadline.uptimeNanoseconds - now
            Thread.sleep(forTimeInterval: min(0.01, Double(remaining) / 1_000_000_000))
        }
        return !processGroupExists(processGroupID)
    }

    private func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if kill(-processGroupID, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private func terminationStatus(from waitStatus: Int32) -> Int32 {
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return terminatingSignal
    }

    private func reapObservedProcess(_ processID: pid_t) throws -> Int32 {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processID, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        guard result == processID else {
            throw posixError(result == -1 ? errno : ECHILD)
        }
        return status
    }

    private func dispatchDeadline(after seconds: TimeInterval) -> DispatchTime {
        // `run` validates both stored durations before launching the subprocess.
        AsyncTimeoutPolicy.dispatchDeadline(after: seconds) ?? .now()
    }

    private func closeAllHandles(stdout: Pipe, stderr: Pipe) {
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForReading.close()
        try? stderr.fileHandleForWriting.close()
    }

    private func checkPOSIX(_ status: Int32) throws {
        guard status == 0 else {
            throw posixError(status)
        }
    }

    private func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1 else {
            throw posixError(errno)
        }
        guard fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != -1 else {
            throw posixError(errno)
        }
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers = [UnsafeMutablePointer<CChar>?]()
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        for string in strings {
            guard !string.utf8.contains(0),
                  let pointer = string.withCString({ strdup($0) }) else {
                throw posixError(EINVAL)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
