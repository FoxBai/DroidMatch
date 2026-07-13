import Foundation
import ApplicationServices

enum ProductDeviceVisibilityPolicy {
    static func canInspectAXElement(inspectedCount: Int, limit: Int = 10_000) -> Bool {
        inspectedCount >= 0 && inspectedCount < limit
    }

    static func isBenignMissingAXAttribute(_ error: AXError) -> Bool {
        error == .noValue || error == .attributeUnsupported
    }

    static func matchesDiscoveryElement(
        identifier: String,
        text: String,
        expectedLabel: String
    ) -> Bool {
        let normalizedLabel = expectedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = text.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return identifier == ProductAccessibilityIdentifiers.discoveryDeviceCard
            && !normalizedLabel.isEmpty
            && components.contains {
                $0.caseInsensitiveCompare(normalizedLabel) == .orderedSame
            }
            && components.contains {
                $0.caseInsensitiveCompare("ADB") == .orderedSame
            }
    }
}
