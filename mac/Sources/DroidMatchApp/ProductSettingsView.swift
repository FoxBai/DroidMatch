import DroidMatchPresentation
import SwiftUI
@preconcurrency import UserNotifications

enum AppPreferenceKeys {
    static let mediaGridByDefault = "file-browser.media-grid-by-default"
    static let transferNotifications = "transfers.notifications-enabled"
}

/// Small, honest preference surface for behavior the product already supports.
/// Security, authentication, and destructive-operation safeguards are not user
/// defaults and therefore do not appear as configurable switches.
struct ProductSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferenceKeys.mediaGridByDefault) private var mediaGridByDefault = true
    @AppStorage(AppPreferenceKeys.transferNotifications) private var transferNotifications = false
    @State private var isCheckingNotificationPermission = false
    @State private var notificationPermissionFailure = false
    @State private var notificationPermissionGeneration: UInt64 = 0

    var body: some View {
        Form {
            Section(AppStrings.fileBrowsing) {
                Toggle(AppStrings.mediaGridByDefault, isOn: $mediaGridByDefault)
                Text(AppStrings.mediaGridByDefaultDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(AppStrings.transferNotifications) {
                HStack {
                    Toggle(
                        AppStrings.notifyWhenTransfersFinish,
                        isOn: transferNotificationsBinding
                    )
                    .disabled(isCheckingNotificationPermission)
                    if isCheckingNotificationPermission {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(AppStrings.transferNotificationsDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 280)
        .navigationTitle(AppStrings.settings)
        .onAppear { reconcileNotificationPermission() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                reconcileNotificationPermission()
            }
        }
        .alert(
            AppStrings.notificationPermissionNotGranted,
            isPresented: $notificationPermissionFailure
        ) {
            Button(AppStrings.dismiss) {}
        } message: {
            Text(AppStrings.notificationPermissionNotGrantedDetail)
        }
    }

    private var transferNotificationsBinding: Binding<Bool> {
        Binding(
            get: { transferNotifications },
            set: { enabled in
                if enabled {
                    requestNotificationPermission()
                } else {
                    notificationPermissionGeneration &+= 1
                    isCheckingNotificationPermission = false
                    transferNotifications = false
                }
            }
        )
    }

    private func reconcileNotificationPermission() {
        guard !isCheckingNotificationPermission else { return }
        notificationPermissionGeneration &+= 1
        let generation = notificationPermissionGeneration
        isCheckingNotificationPermission = true
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowsDelivery = TransferNotificationAuthorizationPolicy.allowsDelivery(
                settings.authorizationStatus
            )
            Task { @MainActor in
                guard generation == notificationPermissionGeneration else { return }
                let decision = TransferNotificationPreferencePolicy.reconcile(
                    storedEnabled: transferNotifications,
                    permissionAllowsDelivery: allowsDelivery
                )
                transferNotifications = decision.isEnabled
                isCheckingNotificationPermission = false
            }
        }
    }

    private func requestNotificationPermission() {
        notificationPermissionGeneration &+= 1
        let generation = notificationPermissionGeneration
        isCheckingNotificationPermission = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in
            center.getNotificationSettings { settings in
                let allowsDelivery = TransferNotificationAuthorizationPolicy.allowsDelivery(
                    settings.authorizationStatus
                )
                Task { @MainActor in
                    guard generation == notificationPermissionGeneration else { return }
                    let decision = TransferNotificationPreferencePolicy.completedRequest(
                        permissionAllowsDelivery: allowsDelivery
                    )
                    transferNotifications = decision.isEnabled
                    notificationPermissionFailure = decision.showsPermissionFailure
                    isCheckingNotificationPermission = false
                }
            }
        }
    }
}
