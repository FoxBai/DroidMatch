import Combine
import DroidMatchPresentation
import Foundation

/// Main-actor ownership for the persisted notification opt-in and its process
/// generation. Changing the preference invalidates every older delivery candidate.
@MainActor
final class TransferNotificationPreferenceStore: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private var generation = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: AppPreferenceKeys.transferNotifications)
    }

    var snapshot: TransferNotificationPreferencePolicy.Snapshot {
        .init(isEnabled: isEnabled, generation: generation)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        generation = UUID()
        isEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKeys.transferNotifications)
    }
}
