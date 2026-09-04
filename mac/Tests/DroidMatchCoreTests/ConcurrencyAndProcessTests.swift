import Foundation
import Testing
@testable import DroidMatchCore
import Darwin

private enum LockedValueTestError: Error {
    case intentional
    case workerDidNotStart
    case lockDidNotRelease
}

private enum ProcessRunnerTestError: Error {
    case expectedTimeout
    case unexpectedError(Error)
}

@Test func lockedValueUnlocksAfterThrowingUpdate() throws {
    let lockedValue = LockedValue(0)
    let workerReady = DispatchSemaphore(value: 0)
    let startUpdate = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)

    // Admit the worker before exercising the lock so the bounded wait measures
    // lock release rather than unrelated global-queue pressure on a CI host.
    DispatchQueue.global().async {
        workerReady.signal()
        startUpdate.wait()
        lockedValue.set(2)
        released.signal()
    }

    guard workerReady.wait(timeout: .now() + 5) == .success else {
        startUpdate.signal()
        throw LockedValueTestError.workerDidNotStart
    }

    do {
        try lockedValue.update { value in
            value = 1
            throw LockedValueTestError.intentional
        }
    } catch LockedValueTestError.intentional {
    }

    startUpdate.signal()
    guard released.wait(timeout: .now() + 5) == .success else {
        throw LockedValueTestError.lockDidNotRelease
    }
    #expect(lockedValue.value() == 2)
}

@Test func processRunnerKillsProcessThatIgnoresTerminate() throws {
    let runner = ProcessRunner(timeoutSeconds: 0.2, terminationGraceSeconds: 1)
    let clock = ContinuousClock()
    let started = clock.now

    do {
        _ = try runner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                trap '' TERM
                while :; do
                  printf 'stdout-0123456789abcdef\n'
                  printf 'stderr-0123456789abcdef\n' >&2
                done
                """,
            ]
        )
        throw ProcessRunnerTestError.expectedTimeout
    } catch let ProcessRunnerError.timedOut(executable, timeoutSeconds) {
        #expect(executable == "/bin/sh")
        #expect(timeoutSeconds == 0.2)
    } catch {
        throw ProcessRunnerTestError.unexpectedError(error)
    }

    #expect(started.duration(to: clock.now) < .seconds(4))
}

@Test func processRunnerTimesOutWhenExitedParentLeavesPipeHoldingDescendant() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-process-runner-\(UUID().uuidString)",
        isDirectory: true
    )
    let readyURL = directory.appendingPathComponent("ready")
    let processIDURL = directory.appendingPathComponent("descendant-pid")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // The five-second sleep is the failure-path cleanup ceiling. Avoid sending
    // a deferred signal to a PID that the runner may already have released.
    defer { try? FileManager.default.removeItem(at: directory) }

    let timeoutSeconds = 0.5
    let runner = ProcessRunner(timeoutSeconds: timeoutSeconds, terminationGraceSeconds: 1)
    let clock = ContinuousClock()
    let started = clock.now
    do {
        _ = try runner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                (trap '' TERM; printf ready > "$1"; exec /bin/sleep 5) &
                descendant=$!
                printf '%s\n' "$descendant" > "$2"
                while [ ! -s "$1" ]; do :; done
                exit 0
                """,
                "droidmatch-process-runner",
                readyURL.path,
                processIDURL.path,
            ]
        )
        throw ProcessRunnerTestError.expectedTimeout
    } catch let ProcessRunnerError.timedOut(executable, observedTimeout) {
        #expect(executable == "/bin/sh")
        #expect(observedTimeout == timeoutSeconds)
    } catch {
        throw ProcessRunnerTestError.unexpectedError(error)
    }

    let elapsed = started.duration(to: clock.now)
    let descendantProcessID = try #require(recordedProcessID(at: processIDURL))
    #expect(elapsed < .seconds(4))
    #expect(!processExists(descendantProcessID))
}

@Test func processRunnerReturnsCompleteOutputAndExitStatus() throws {
    let runner = ProcessRunner(timeoutSeconds: 2)
    let result = try runner.run(
        executable: "/bin/sh",
        arguments: [
            "-c",
            """
            (/usr/bin/yes o | /usr/bin/head -c 300000) & stdout_pid=$!
            (/usr/bin/yes e | /usr/bin/head -c 300000 >&2) & stderr_pid=$!
            wait "$stdout_pid"
            wait "$stderr_pid"
            exit 7
            """,
        ]
    )

    #expect(result.status == 7)
    #expect(result.stdout == String(repeating: "o\n", count: 150_000))
    #expect(result.stderr == String(repeating: "e\n", count: 150_000))
}

@Test func processRunnerDoesNotInheritUnrelatedFileDescriptors() throws {
    let sentinel = Pipe()
    defer {
        try? sentinel.fileHandleForReading.close()
        try? sentinel.fileHandleForWriting.close()
    }
    let descriptor = sentinel.fileHandleForWriting.fileDescriptor
    let flags = fcntl(descriptor, F_GETFD)
    try #require(flags != -1)
    try #require(fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) != -1)
    let readDescriptor = sentinel.fileHandleForReading.fileDescriptor
    let readFlags = fcntl(readDescriptor, F_GETFL)
    try #require(readFlags != -1)
    try #require(fcntl(readDescriptor, F_SETFL, readFlags | O_NONBLOCK) != -1)

    let result = try ProcessRunner(timeoutSeconds: 2).run(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "if printf leaked >&$1 2>/dev/null; then exit 42; else exit 0; fi",
            "droidmatch-process-runner",
            String(descriptor),
        ]
    )

    // The shell can reuse a closed descriptor number for its own redirections.
    // Observe the original pipe, rather than treating that number as identity.
    // 中文：shell 可复用已关闭的 FD 编号；原 pipe 是否收到字节才证明继承。
    #expect(result.status == 0 || result.status == 42)
    var byte: UInt8 = 0
    let receivedBytes = Darwin.read(readDescriptor, &byte, 1)
    let noInheritedWrite = receivedBytes == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)
    #expect(noInheritedWrite)
}

@Test func processRunnerRejectsInvalidTimeoutBeforeLaunching() throws {
    for timeout in [0, -1, .nan, .infinity] {
        let runner = ProcessRunner(timeoutSeconds: timeout)
        #expect(throws: ProcessRunnerError.self) {
            _ = try runner.run(executable: "/usr/bin/true", arguments: [])
        }
    }

}

@Test func processRunnerPreservesExplicitEnvironment() throws {
    let boundedEnvironment = try ProcessRunner().run(
        executable: "/usr/bin/env",
        arguments: [],
        environment: ["DROIDMATCH_PROCESS_ENVIRONMENT_PROBE": "bounded"]
    )
    #expect(boundedEnvironment.status == 0)
    // Assert only a boolean so a regression cannot print inherited secrets.
    // 中文：仅断言布尔结果，避免回归时输出继承的机密环境值。
    let matchesExplicitEnvironment = boundedEnvironment.stdout
        .split(whereSeparator: \.isNewline)
        .map(String.init) == ["DROIDMATCH_PROCESS_ENVIRONMENT_PROBE=bounded"]
    #expect(matchesExplicitEnvironment)
    let emptyEnvironment = try ProcessRunner().run(
        executable: "/usr/bin/env", arguments: [], environment: [:]
    )
    #expect(emptyEnvironment.status == 0)
    let containsNoInheritedValues = emptyEnvironment.stdout.isEmpty
    #expect(containsNoInheritedValues)
}

private func recordedProcessID(at url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let processID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          processID > 0 else {
        return nil
    }
    return processID
}

private func processExists(_ processID: pid_t) -> Bool {
    if Darwin.kill(processID, 0) == 0 {
        return true
    }
    return errno != ESRCH
}
