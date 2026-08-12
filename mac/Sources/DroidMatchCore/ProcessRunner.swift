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

private enum ProcessObservationError: Error {
    case waitUnconfirmed
    case io(Int32)
}

private struct OwnedProcessDescriptor {
    private(set) var value: Int32

    var isOpen: Bool { value >= 0 }

    mutating func close() {
        guard isOpen else { return }
        let descriptor = value
        value = -1
        // A close interrupted by a signal may already have released the FD.
        // Never retry and risk closing a descriptor reused by another runner.
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }
}

private struct ProcessPipe {
    var read: OwnedProcessDescriptor
    var write: OwnedProcessDescriptor

    mutating func closeAll() {
        read.close()
        write.close()
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
        guard AsyncTimeoutPolicy.nanoseconds(for: timeoutSeconds) != nil,
              AsyncTimeoutPolicy.nanoseconds(for: terminationGraceSeconds) != nil else {
            throw ProcessRunnerError.invalidTimeout
        }

        var stdoutPipe = try makePipe()
        var stderrPipe: ProcessPipe
        do {
            stderrPipe = try makePipe()
        } catch {
            stdoutPipe.closeAll()
            throw error
        }
        defer {
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
        }

        let processID = try spawn(
            executable: executable,
            arguments: arguments,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        stdoutPipe.write.close()
        stderrPipe.write.close()

        var stdoutData = Data()
        var stderrData = Data()
        var leaderExitObserved = false
        let executionDeadline = dispatchDeadline(after: timeoutSeconds)
        let completed: Bool
        do {
            completed = try observeUntilCompletion(
                processID: processID,
                stdout: &stdoutPipe.read,
                stderr: &stderrPipe.read,
                stdoutData: &stdoutData,
                stderrData: &stderrData,
                leaderExitObserved: &leaderExitObserved,
                deadline: executionDeadline,
                collectOutput: true
            )
        } catch ProcessObservationError.waitUnconfirmed {
            // The leader can no longer anchor this exact PID/PGID. Never send
            // a negative-PID signal that could target a reused process group.
            throw ProcessRunnerError.cleanupUnconfirmed
        } catch ProcessObservationError.io(let code) {
            guard cleanUpProcessGroup(
                processGroupID: processID,
                stdout: &stdoutPipe.read,
                stderr: &stderrPipe.read,
                stdoutData: &stdoutData,
                stderrData: &stderrData,
                leaderExitObserved: &leaderExitObserved
            ) else {
                throw ProcessRunnerError.cleanupUnconfirmed
            }
            throw posixError(code)
        }

        guard completed else {
            guard cleanUpProcessGroup(
                processGroupID: processID,
                stdout: &stdoutPipe.read,
                stderr: &stderrPipe.read,
                stdoutData: &stdoutData,
                stderrData: &stderrData,
                leaderExitObserved: &leaderExitObserved
            ) else {
                throw ProcessRunnerError.cleanupUnconfirmed
            }
            throw ProcessRunnerError.timedOut(
                executable: executable,
                timeoutSeconds: timeoutSeconds
            )
        }

        // waitid(WNOWAIT) kept the leader as the identity anchor. Reap only
        // after both output streams reached EOF; never signal this PGID later.
        guard let status = try? reapObservedProcess(processID) else {
            throw ProcessRunnerError.cleanupUnconfirmed
        }
        return ProcessResult(
            status: terminationStatus(from: status),
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func makePipe() throws -> ProcessPipe {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            #if canImport(Darwin)
            Darwin.pipe(buffer.baseAddress!)
            #else
            Glibc.pipe(buffer.baseAddress!)
            #endif
        }
        guard result == 0 else {
            throw posixError(errno)
        }
        var pipe = ProcessPipe(
            read: OwnedProcessDescriptor(value: descriptors[0]),
            write: OwnedProcessDescriptor(value: descriptors[1])
        )
        do {
            try setCloseOnExec(pipe.read.value)
            try setCloseOnExec(pipe.write.value)
            try setNonBlocking(pipe.read.value)
        } catch {
            pipe.closeAll()
            throw error
        }
        return pipe
    }

    private func spawn(
        executable: String,
        arguments: [String],
        stdoutPipe: ProcessPipe,
        stderrPipe: ProcessPipe
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

        let descriptors = [
            stdoutPipe.read.value,
            stdoutPipe.write.value,
            stderrPipe.read.value,
            stderrPipe.write.value,
        ]
        guard descriptors.allSatisfy({ $0 > STDERR_FILENO }) else {
            throw posixError(EBADF)
        }
        if fcntl(STDIN_FILENO, F_GETFD) != -1 {
            try checkPOSIX(
                posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO)
            )
        } else if errno != EBADF {
            throw posixError(errno)
        }
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stdoutPipe.write.value,
                STDOUT_FILENO
            )
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stderrPipe.write.value,
                STDERR_FILENO
            )
        )
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

    private func observeUntilCompletion(
        processID: pid_t,
        stdout: inout OwnedProcessDescriptor,
        stderr: inout OwnedProcessDescriptor,
        stdoutData: inout Data,
        stderrData: inout Data,
        leaderExitObserved: inout Bool,
        deadline: DispatchTime,
        collectOutput: Bool
    ) throws -> Bool {
        while !deadlineReached(deadline) {
            if !leaderExitObserved {
                leaderExitObserved = try observeLeaderExit(processID)
            }
            try drain(
                &stdout,
                into: &stdoutData,
                collectOutput: collectOutput,
                deadline: deadline
            )
            try drain(
                &stderr,
                into: &stderrData,
                collectOutput: collectOutput,
                deadline: deadline
            )
            if leaderExitObserved, !stdout.isOpen, !stderr.isOpen {
                return true
            }
            if deadlineReached(deadline) {
                break
            }
            try pollForOutput(stdout: stdout, stderr: stderr, until: deadline)
        }
        return false
    }

    private func observeLeaderExit(_ processID: pid_t) throws -> Bool {
        var information = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(
                P_PID,
                id_t(processID),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
        } while result == -1 && errno == EINTR
        guard result == 0 else {
            throw ProcessObservationError.waitUnconfirmed
        }
        guard information.si_pid == 0 || information.si_pid == processID else {
            throw ProcessObservationError.waitUnconfirmed
        }
        return information.si_pid == processID
    }

    private func drain(
        _ descriptor: inout OwnedProcessDescriptor,
        into data: inout Data,
        collectOutput: Bool,
        deadline: DispatchTime
    ) throws {
        guard descriptor.isOpen else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var chunksRead = 0
        while chunksRead < 4, !deadlineReached(deadline) {
            let count = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Darwin)
                Darwin.read(descriptor.value, bytes.baseAddress, bytes.count)
                #else
                Glibc.read(descriptor.value, bytes.baseAddress, bytes.count)
                #endif
            }
            let readError = errno
            if count > 0 {
                if collectOutput {
                    buffer.withUnsafeBufferPointer { bytes in
                        data.append(bytes.baseAddress!, count: count)
                    }
                }
                chunksRead += 1
                continue
            }
            if count == 0 {
                descriptor.close()
                return
            }
            if readError == EINTR {
                continue
            }
            if readError == EAGAIN || readError == EWOULDBLOCK {
                return
            }
            throw ProcessObservationError.io(readError)
        }
    }

    private func pollForOutput(
        stdout: OwnedProcessDescriptor,
        stderr: OwnedProcessDescriptor,
        until deadline: DispatchTime
    ) throws {
        var descriptors = [pollfd]()
        if stdout.isOpen {
            descriptors.append(pollfd(fd: stdout.value, events: Int16(POLLIN), revents: 0))
        }
        if stderr.isOpen {
            descriptors.append(pollfd(fd: stderr.value, events: Int16(POLLIN), revents: 0))
        }
        let timeout = pollTimeout(until: deadline)
        let result: Int32
        if descriptors.isEmpty {
            result = poll(nil, 0, timeout)
        } else {
            result = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), timeout)
            }
        }
        let pollError = errno
        if result == -1 {
            if pollError == EINTR { return }
            throw ProcessObservationError.io(pollError)
        }
        if descriptors.contains(where: { ($0.revents & Int16(POLLNVAL)) != 0 }) {
            throw ProcessObservationError.io(EBADF)
        }
        // POLLHUP is only a readiness hint. The next drain must read to zero so
        // bytes written immediately before the close are never discarded.
    }

    private func cleanUpProcessGroup(
        processGroupID: pid_t,
        stdout: inout OwnedProcessDescriptor,
        stderr: inout OwnedProcessDescriptor,
        stdoutData: inout Data,
        stderrData: inout Data,
        leaderExitObserved: inout Bool
    ) -> Bool {
        // The unreaped group leader anchors this exact PID/PGID across both
        // signals. Never probe then signal, and never signal after reaping.
        _ = kill(-processGroupID, SIGTERM)
        let terminationDeadline = dispatchDeadline(after: terminationGraceSeconds)
        do {
            _ = try observeUntilCompletion(
                processID: processGroupID,
                stdout: &stdout,
                stderr: &stderr,
                stdoutData: &stdoutData,
                stderrData: &stderrData,
                leaderExitObserved: &leaderExitObserved,
                deadline: terminationDeadline,
                collectOutput: false
            )
        } catch ProcessObservationError.waitUnconfirmed {
            stdout.close()
            stderr.close()
            return false
        } catch {
            // A pipe error does not invalidate the unreaped leader anchor. Kill
            // the group, close both parent read ends, and prove exit below.
        }

        _ = kill(-processGroupID, SIGKILL)
        stdout.close()
        stderr.close()
        let cleanupDeadline = dispatchDeadline(after: terminationGraceSeconds)
        guard waitForLeaderExit(
            processGroupID,
            observed: &leaderExitObserved,
            until: cleanupDeadline
        ), (try? reapObservedProcess(processGroupID)) != nil else {
            return false
        }
        return waitForProcessGroupToDisappear(processGroupID, until: cleanupDeadline)
    }

    private func waitForLeaderExit(
        _ processID: pid_t,
        observed: inout Bool,
        until deadline: DispatchTime
    ) -> Bool {
        while !observed, !deadlineReached(deadline) {
            do {
                observed = try observeLeaderExit(processID)
            } catch {
                return false
            }
            if !observed {
                _ = poll(nil, 0, pollTimeout(until: deadline))
            }
        }
        if observed { return true }
        do {
            observed = try observeLeaderExit(processID)
        } catch {
            return false
        }
        return observed
    }

    private func waitForProcessGroupToDisappear(
        _ processGroupID: pid_t,
        until deadline: DispatchTime
    ) -> Bool {
        while !deadlineReached(deadline) {
            if !processGroupExists(processGroupID) {
                return true
            }
            _ = poll(nil, 0, pollTimeout(until: deadline))
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
        AsyncTimeoutPolicy.dispatchDeadline(after: seconds) ?? .now()
    }

    private func deadlineReached(_ deadline: DispatchTime) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds
    }

    private func pollTimeout(until deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return 0 }
        let remaining = deadline.uptimeNanoseconds - now
        let wholeMilliseconds = remaining / 1_000_000
        let roundedMilliseconds = wholeMilliseconds + (remaining % 1_000_000 == 0 ? 0 : 1)
        return Int32(max(1, min(10, roundedMilliseconds)))
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

    private func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1 else {
            throw posixError(errno)
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
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
