import Foundation

@main
private enum ProductDeviceVisibilityPolicyTest {
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            FileHandle.standardError.write(
                Data("visibility policy failed: \(message)\n".utf8)
            )
            exit(1)
        }
    }

    static func main() {
        expect(ProductDeviceVisibilityPolicy.canInspectAXElement(inspectedCount: 9_999),
               "the final element below the traversal cap remains inspectable")
        expect(!ProductDeviceVisibilityPolicy.canInspectAXElement(inspectedCount: 10_000),
               "an element left at the traversal cap must fail closed")
        expect(ProductDeviceVisibilityPolicy.isBenignMissingAXAttribute(.noValue),
               "AX no-value is an expected missing attribute")
        expect(ProductDeviceVisibilityPolicy.isBenignMissingAXAttribute(.attributeUnsupported),
               "unsupported AX attributes may be absent")
        expect(!ProductDeviceVisibilityPolicy.isBenignMissingAXAttribute(.cannotComplete),
               "AX cannot-complete must fail closed")
        expect(!ProductDeviceVisibilityPolicy.isBenignMissingAXAttribute(.invalidUIElement),
               "invalid AX elements must fail closed")
        expect(ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: ProductAccessibilityIdentifiers.discoveryDeviceCard,
            text: "MEIZU M20, ADB, 已就绪, 连接",
            expectedLabel: "MEIZU M20"
        ), "identified discovery element must match")
        expect(ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: ProductAccessibilityIdentifiers.discoveryDeviceCard,
            text: "ready, meizu m20, adb",
            expectedLabel: "MEIZU M20"
        ), "matching is case-insensitive")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: "app.droidmatch.trusted-device",
            text: "MEIZU M20, ADB",
            expectedLabel: "MEIZU M20"
        ), "trusted-device history must not reuse the discovery identifier")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: ProductAccessibilityIdentifiers.discoveryDeviceCard,
            text: "受信任设备 MEIZU M20",
            expectedLabel: "MEIZU M20"
        ), "trusted-device history without ADB must not match")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: "",
            text: "MEIZU M20 backup over ADB.txt",
            expectedLabel: "MEIZU M20"
        ), "file/static text must not match")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: ProductAccessibilityIdentifiers.discoveryDeviceCard,
            text: "MEIZU M20, ADB, 已就绪, 连接",
            expectedLabel: ""
        ), "empty expected label must not match")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: ProductAccessibilityIdentifiers.discoveryDeviceCard,
            text: "Ready, MEIZU M20, ADB, Connect",
            expectedLabel: "   "
        ), "whitespace-only expected label must not match")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryElement(
            identifier: ProductAccessibilityIdentifiers.discoveryDeviceCard,
            text: "MEIZU M20, ADB, Ready, Connect",
            expectedLabel: "M20"
        ), "partial model-name substrings must not match")

        print("product device visibility policy test passed.")
    }
}
