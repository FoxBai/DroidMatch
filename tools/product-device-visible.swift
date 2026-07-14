import AppKit
import ApplicationServices
import Foundation
import Security

@main
private enum ProductDeviceVisibleCommand {
    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }

    private static func isTrustedAccessibilityClient() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func codeHash(from information: CFDictionary) -> String? {
        guard let data = (information as NSDictionary)[kSecCodeInfoUnique] as? Data,
              data.count == 20 else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func verifiedBundleCodeHash(
        application: NSRunningApplication,
        bundleURL: URL
    ) -> String? {
        let attributes = [
            kSecGuestAttributePid as String: application.processIdentifier,
        ] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &guestCode
        ) == errSecSuccess,
            let guestCode
        else {
            return nil
        }

        var bundleStaticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &bundleStaticCode
        ) == errSecSuccess,
            let bundleStaticCode,
            SecStaticCodeCheckValidity(bundleStaticCode, SecCSFlags(), nil) == errSecSuccess
        else {
            return nil
        }

        let signingFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        var bundleInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
                bundleStaticCode,
                signingFlags,
                &bundleInformation
            ) == errSecSuccess,
            let bundleInformation,
            let bundleHash = codeHash(from: bundleInformation)
        else {
            return nil
        }

        var requirement: SecRequirement?
        let requirementText = "cdhash H\"\(bundleHash)\"" as CFString
        guard SecRequirementCreateWithString(
            requirementText,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
            let requirement,
            SecCodeCheckValidity(guestCode, SecCSFlags(), requirement) == errSecSuccess
        else {
            return nil
        }
        return bundleHash
    }

    static func main() {
        guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 5 else {
            fail(
                "usage: product-device-visible <bundle-id> <visible-label> "
                    + "[expected-source-revision expected-app-bundle]",
                code: 2
            )
        }
        guard isTrustedAccessibilityClient() else {
            fail(
                "Accessibility permission is required for the product-visible probe. "
                    + "macOS was asked to show the authorization prompt; grant access "
                    + "to the invoking app/probe, then rerun.\n"
                    + "产品可见性探针需要辅助功能权限；macOS 已被请求显示授权提示，"
                    + "请为调用方 App/探针授权后重新运行。",
                code: 3
            )
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
        if CommandLine.arguments.count == 5, applications.count != 1 {
            fail("Formal product visibility requires exactly one running DroidMatch App.", code: 7)
        }
        guard let application = applications.first(where: \.isActive) else {
            fail("DroidMatch product App must remain foreground-active.", code: 5)
        }
        var formalBundleCodeHash: String?
        if CommandLine.arguments.count == 5 {
            let expectedRevision = CommandLine.arguments[3]
            let expectedBundleURL = URL(fileURLWithPath: CommandLine.arguments[4])
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard expectedRevision.range(
                of: "^[0-9a-f]{40}$",
                options: .regularExpression
            ) != nil,
                let bundleURL = application.bundleURL,
                bundleURL.resolvingSymlinksInPath().standardizedFileURL == expectedBundleURL,
                let bundleCodeHash = verifiedBundleCodeHash(
                    application: application,
                    bundleURL: expectedBundleURL
                ),
                let bundle = Bundle(url: expectedBundleURL),
                bundle.object(forInfoDictionaryKey: "DroidMatchSourceRevision") as? String
                    == expectedRevision,
                bundle.object(forInfoDictionaryKey: "DroidMatchSourceDirty") as? Bool == false,
                bundle.object(forInfoDictionaryKey: "DroidMatchBuildConfiguration") as? String
                    == "release"
            else {
                fail("Running DroidMatch App provenance does not match the expected clean revision.", code: 6)
            }
            formalBundleCodeHash = bundleCodeHash
        }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        var pending: [AXUIElement] = [root]
        var inspected = 0
        var matches = 0
        let searchableAttributes = [
            kAXValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
        ]

        while !pending.isEmpty {
            guard ProductDeviceVisibilityPolicy.canInspectAXElement(
                inspectedCount: inspected
            ) else {
                fail("Product Accessibility traversal exceeded its safety bound.", code: 9)
            }
            let element = pending.removeLast()
            inspected += 1
            var rawIdentifier: CFTypeRef?
            let identifierError = AXUIElementCopyAttributeValue(
                element,
                kAXIdentifierAttribute as CFString,
                &rawIdentifier
            )
            if identifierError != .success,
               !ProductDeviceVisibilityPolicy.isBenignMissingAXAttribute(identifierError) {
                fail("Product Accessibility traversal was incomplete.", code: 9)
            }
            if identifierError == .success,
               let identifier = rawIdentifier as? String,
               identifier == ProductAccessibilityIdentifiers.discoveryDeviceCard {
                var elementMatches = false
                var readableTextAttribute = false
                for attribute in searchableAttributes {
                    var raw: CFTypeRef?
                    let textError = AXUIElementCopyAttributeValue(
                        element,
                        attribute as CFString,
                        &raw
                    )
                    if textError != .success,
                       !ProductDeviceVisibilityPolicy.isBenignMissingAXAttribute(textError) {
                        fail("Product Accessibility traversal was incomplete.", code: 9)
                    }
                    if textError == .success, let text = raw as? String {
                        readableTextAttribute = true
                        if ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
                           identifier: identifier,
                           text: text,
                           expectedLabel: expectedLabel
                       ) {
                            elementMatches = true
                            break
                        }
                    }
                }
                if !readableTextAttribute {
                    fail("Identified product discovery card has no readable label.", code: 9)
                }
                if elementMatches {
                    matches += 1
                }
            }

            var rawChildren: CFTypeRef?
            let childrenError = AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &rawChildren
            )
            if childrenError == .success {
                guard let children = rawChildren as? [AXUIElement] else {
                    fail("Product Accessibility children were malformed.", code: 9)
                }
                pending.append(contentsOf: children)
            } else if inspected == 1
                        || !ProductDeviceVisibilityPolicy.isBenignMissingAXAttribute(childrenError) {
                fail("Product Accessibility traversal was incomplete.", code: 9)
            }
        }

        if matches == 1 {
            if let formalBundleCodeHash {
                print(
                    "product_visible_matches=1 bundle_cdhash=\(formalBundleCodeHash) "
                        + "dynamic_requirement_verified=true"
                )
            }
            exit(0)
        }
        if matches > 1 {
            fail("More than one product discovery card matched the expected label.", code: 8)
        }
        exit(1)
    }
}
