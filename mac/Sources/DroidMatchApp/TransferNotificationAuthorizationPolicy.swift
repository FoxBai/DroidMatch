@preconcurrency import UserNotifications

/// One App-owned interpretation of the live macOS notification authorization.
/// Settings and final delivery must agree on whether the stored opt-in is usable.
enum TransferNotificationAuthorizationPolicy {
    nonisolated static func allowsDelivery(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}
