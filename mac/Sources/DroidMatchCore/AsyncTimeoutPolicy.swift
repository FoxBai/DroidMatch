import Dispatch
import Foundation

/// Converts public timeout values without allowing floating-point edge cases to
/// reach trapping integer or DispatchTime conversions.
enum AsyncTimeoutPolicy {
    static func nanoseconds(for seconds: TimeInterval) -> UInt64? {
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        let rawNanoseconds = seconds * 1_000_000_000
        // The multiplication may overflow to infinity even when `seconds` is
        // finite. `Double(UInt64.max)` also rounds to 2^64, so saturate before
        // converting either value back to UInt64.
        guard rawNanoseconds.isFinite,
              rawNanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(rawNanoseconds)
    }

    static func dispatchDeadline(
        after seconds: TimeInterval,
        now: DispatchTime = .now()
    ) -> DispatchTime? {
        guard let delay = nanoseconds(for: seconds) else {
            return nil
        }
        let nowNanoseconds = now.uptimeNanoseconds
        let boundedDelay = min(delay, UInt64.max - nowNanoseconds)
        return DispatchTime(uptimeNanoseconds: nowNanoseconds + boundedDelay)
    }
}
