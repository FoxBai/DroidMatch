/// Stable clock-style rendering for positive provider video durations.
///
/// The value is already bounded to positive `Int64` milliseconds by Core.
/// Keeping this numeric avoids a locale-dependent parser or date/time zone.
public enum MediaDurationText {
    public static func value(_ durationMillis: Int64?) -> String? {
        guard let durationMillis, durationMillis > 0 else { return nil }
        let totalSeconds = durationMillis / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds / 60) % 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        }
        return "\(minutes):\(twoDigits(seconds))"
    }

    private static func twoDigits(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
