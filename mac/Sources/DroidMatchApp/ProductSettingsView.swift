import SwiftUI

enum AppPreferenceKeys {
    static let mediaGridByDefault = "file-browser.media-grid-by-default"
}

/// Small, honest preference surface for behavior the product already supports.
/// Security, authentication, and destructive-operation safeguards are not user
/// defaults and therefore do not appear as configurable switches.
struct ProductSettingsView: View {
    @AppStorage(AppPreferenceKeys.mediaGridByDefault) private var mediaGridByDefault = true

    var body: some View {
        Form {
            Section(AppStrings.fileBrowsing) {
                Toggle(AppStrings.mediaGridByDefault, isOn: $mediaGridByDefault)
                Text(AppStrings.mediaGridByDefaultDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 180)
        .navigationTitle(AppStrings.settings)
    }
}
