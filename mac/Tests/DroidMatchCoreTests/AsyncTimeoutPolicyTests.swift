import Dispatch
import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncTimeoutPolicyRejectsInvalidFloatingPointValues() {
    let invalidTimeouts: [TimeInterval] = [0, -1, .nan, .infinity, -.infinity]
    for timeout in invalidTimeouts {
        #expect(AsyncTimeoutPolicy.nanoseconds(for: timeout) == nil)
        #expect(AsyncTimeoutPolicy.dispatchDeadline(after: timeout) == nil)
    }
}

@Test func asyncTimeoutPolicySaturatesWithoutIntegerOrDispatchOverflow() throws {
    #expect(AsyncTimeoutPolicy.nanoseconds(for: 1.5) == 1_500_000_000)
    #expect(
        AsyncTimeoutPolicy.nanoseconds(for: .greatestFiniteMagnitude) == UInt64.max
    )

    let nearMaximum = DispatchTime(uptimeNanoseconds: UInt64.max - 10)
    let deadline = try #require(
        AsyncTimeoutPolicy.dispatchDeadline(
            after: .greatestFiniteMagnitude,
            now: nearMaximum
        )
    )
    #expect(deadline.uptimeNanoseconds == UInt64.max)
}
