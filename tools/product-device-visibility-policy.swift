import Foundation

enum ProductDeviceVisibilityPolicy {
    static func matchesDiscoveryButton(
        role: String,
        text: String,
        expectedLabel: String
    ) -> Bool {
        role == "AXButton"
            && !expectedLabel.isEmpty
            && text.localizedCaseInsensitiveContains(expectedLabel)
            && text.localizedCaseInsensitiveContains("ADB")
    }
}
