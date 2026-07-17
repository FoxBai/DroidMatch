import Foundation
import Testing
@testable import DroidMatchHarness

@Test func harnessTimeoutOptionRequiresAPositiveFiniteValue() throws {
    let missing = try CommandOptions(["--timeout-seconds"])
    #expect(throws: HarnessError.self) {
        _ = try missing.positiveFiniteDouble("--timeout-seconds")
    }

    for rawValue in ["0", "-1", "nan", "inf", "-inf"] {
        let options = try CommandOptions(["--timeout-seconds", rawValue])
        #expect(throws: HarnessError.self) {
            _ = try options.positiveFiniteDouble("--timeout-seconds")
        }
    }

    let valid = try CommandOptions(["--timeout-seconds", "0.25"])
    #expect(try valid.positiveFiniteDouble("--timeout-seconds") == 0.25)
}
