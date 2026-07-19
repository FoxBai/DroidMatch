import Combine
import DroidMatchCore
import DroidMatchPresentation
import Foundation
@preconcurrency import UserNotifications

/// App-owned bridge from privacy-bounded queue transitions to macOS notices.
/// Core and Presentation never request OS permission or own notification state.
@MainActor
final class TransferNotificationCoordinator: NSObject, ObservableObject,
    UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var sessionCancellable: AnyCancellable?
    private var queueCancellable: AnyCancellable?
    private var previousStates: [UUID: AsyncTransferJobState] = [:]

    init(
        sessionModel: DeviceSessionModel,
        center: UNUserNotificationCenter = .current()
    ) {
        self.center = center
        super.init()
        center.delegate = self
        sessionCancellable = sessionModel.$transferQueue.sink { [weak self] queue in
            self?.observe(queue)
        }
    }

    private func observe(_ queue: TransferQueueModel?) {
        queueCancellable?.cancel()
        queueCancellable = nil
        previousStates = [:]
        guard let queue else { return }
        var seeded = false
        queueCancellable = queue.$items.sink { [weak self] items in
            guard let self else { return }
            if seeded {
                let events = TransferCompletionPolicy.events(
                    previousStates: previousStates,
                    currentItems: items
                )
                if UserDefaults.standard.bool(forKey: AppPreferenceKeys.transferNotifications) {
                    for event in events {
                        deliver(event)
                    }
                }
            }
            previousStates = TransferCompletionPolicy.states(for: items)
            seeded = true
        }
    }

    private func deliver(_ event: TransferCompletionEvent) {
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: event)
        content.body = event.localFileName ?? AppStrings.transferFinished
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "transfer-\(event.id.uuidString)-\(event.state.rawValue)",
            content: content,
            trigger: nil
        )
        let center = center
        center.getNotificationSettings { settings in
            guard TransferNotificationAuthorizationPolicy.allowsDelivery(
                settings.authorizationStatus
            ) else {
                return
            }
            center.add(request)
        }
    }

    private static func title(for event: TransferCompletionEvent) -> String {
        switch event.state {
        case .completed:
            return event.kind == .download
                ? AppStrings.downloadCompletedNotification
                : AppStrings.uploadCompletedNotification
        case .failed:
            return AppStrings.transferFailedNotification
        case .interrupted:
            return AppStrings.transferInterruptedNotification
        default:
            return AppStrings.transferFinished
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
