import Foundation

/// Pure preference decisions for the App-owned notification permission bridge.
///
/// Presentation never requests an OS permission. It only prevents the stored
/// opt-in from claiming that notifications are enabled when macOS cannot
/// deliver them.
public enum TransferNotificationPreferencePolicy {
    public struct Snapshot: Sendable, Equatable {
        public let isEnabled: Bool
        public let generation: UUID

        public init(isEnabled: Bool, generation: UUID) {
            self.isEnabled = isEnabled
            self.generation = generation
        }
    }

    public struct Decision: Sendable, Equatable {
        public let isEnabled: Bool
        public let showsPermissionFailure: Bool

        fileprivate init(isEnabled: Bool, showsPermissionFailure: Bool) {
            self.isEnabled = isEnabled
            self.showsPermissionFailure = showsPermissionFailure
        }
    }

    public static func reconcile(
        storedEnabled: Bool,
        permissionAllowsDelivery: Bool
    ) -> Decision {
        Decision(
            isEnabled: storedEnabled && permissionAllowsDelivery,
            showsPermissionFailure: false
        )
    }

    public static func completedRequest(permissionAllowsDelivery: Bool) -> Decision {
        Decision(
            isEnabled: permissionAllowsDelivery,
            showsPermissionFailure: !permissionAllowsDelivery
        )
    }

    public static func shouldEnqueueNotification(
        eventPreference: Snapshot,
        currentPreference: Snapshot,
        permissionAllowsDelivery: Bool
    ) -> Bool {
        eventPreference.isEnabled
            && currentPreference.isEnabled
            && eventPreference.generation == currentPreference.generation
            && permissionAllowsDelivery
    }
}
