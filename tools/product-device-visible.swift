import AppKit
import ApplicationServices
import Foundation

@main
private enum ProductDeviceVisibleCommand {
    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }

    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fail("usage: product-device-visible <bundle-id> <visible-label>", code: 2)
        }
        guard AXIsProcessTrusted() else {
            fail("Accessibility permission is required for the product-visible probe.", code: 3)
        }

        let bundleID = CommandLine.arguments[1]
        let expectedLabel = CommandLine.arguments[2]
        guard !bundleID.isEmpty, !expectedLabel.isEmpty else {
            fail("bundle ID and visible label must be non-empty.", code: 2)
        }
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        )
        guard !applications.isEmpty else {
            fail("DroidMatch product App is not running.", code: 4)
        }
        guard let application = applications.first(where: \.isActive) else {
            fail("DroidMatch product App must remain foreground-active.", code: 5)
        }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        var pending: [AXUIElement] = [root]
        var inspected = 0
        let searchableAttributes = [
            kAXValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
        ]

        while let element = pending.popLast(), inspected < 10_000 {
            inspected += 1
            var rawRole: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &rawRole
            ) == .success,
               let role = rawRole as? String,
               role == kAXButtonRole {
                for attribute in searchableAttributes {
                    var raw: CFTypeRef?
                    if AXUIElementCopyAttributeValue(
                        element,
                        attribute as CFString,
                        &raw
                    ) == .success,
                       let text = raw as? String,
                       ProductDeviceVisibilityPolicy.matchesDiscoveryButton(
                           role: role,
                           text: text,
                           expectedLabel: expectedLabel
                       ) {
                        exit(0)
                    }
                }
            }

            var rawChildren: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &rawChildren
            ) == .success,
               let children = rawChildren as? [AXUIElement] {
                pending.append(contentsOf: children)
            }
        }

        exit(1)
    }
}
