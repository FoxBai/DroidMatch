import SwiftUI
import UserNotifications

enum AppPreferenceKeys {
    static let mediaGridByDefault = "file-browser.media-grid-by-default"
    static let transferNotifications = "transfers.notifications-enabled"
}

/// Small, honest preference surface for behavior the product already supports.
/// Security, authentication, and destructive-operation safeguards are not user
/// defaults and therefore do not appear as configurable switches.
struct ProductSettingsView: View {
    @AppStorage(AppPreferenceKeys.mediaGridByDefault) private var mediaGridByDefault = true
    @AppStorage(AppPreferenceKeys.transferNotifications) private var transferNotifications = false

    var body: some View {
        Form {
            Section(AppStrings.fileBrowsing) {
                Toggle(AppStrings.mediaGridByDefault, isOn: $mediaGridByDefault)
                Text(AppStrings.mediaGridByDefaultDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(AppStrings.transferNotifications) {
                Toggle(AppStrings.notifyWhenTransfersFinish, isOn: $transferNotifications)
                    .onChange(of: transferNotifications) { enabled in
                        guard enabled else { return }
                        UNUserNotificationCenter.current().requestAuthorization(
                            options: [.alert, .sound]
                        ) { _, _ in }
                    }
                Text(AppStrings.transferNotificationsDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 280)
        .navigationTitle(AppStrings.settings)
    }
}
