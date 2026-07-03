import Foundation
import Testing
@testable import DroidMatchCore

private enum LockedValueTestError: Error {
    case intentional
    case lockDidNotRelease
}

private enum ProcessRunnerTestError: Error {
    case expectedTimeout
    case unexpectedError(Error)
}

@Test func lockedValueUnlocksAfterThrowingUpdate() throws {
    let lockedValue = LockedValue(0)

    do {
        try lockedValue.update { value in
            value = 1
            throw LockedValueTestError.intentional
        }
    } catch LockedValueTestError.intentional {
    }

    let released = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        lockedValue.set(2)
        released.signal()
    }

    guard released.wait(timeout: .now() + 1) == .success else {
        throw LockedValueTestError.lockDidNotRelease
    }
    #expect(lockedValue.value() == 2)
}

@Test func processRunnerKillsProcessThatIgnoresTerminate() throws {
    let runner = ProcessRunner(timeoutSeconds: 0.05, terminationGraceSeconds: 0.05)

    do {
        _ = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"]
        )
        throw ProcessRunnerTestError.expectedTimeout
    } catch let ProcessRunnerError.timedOut(executable, timeoutSeconds) {
        #expect(executable == "/bin/sh")
        #expect(timeoutSeconds == 0.05)
    } catch {
        throw ProcessRunnerTestError.unexpectedError(error)
    }
}
