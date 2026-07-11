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
        expect(ProductDeviceVisibilityPolicy.matchesDiscoveryButton(
            role: "AXButton",
            text: "已就绪、MEIZU M20、ADB",
            expectedLabel: "MEIZU M20"
        ), "ready discovery button must match")
        expect(ProductDeviceVisibilityPolicy.matchesDiscoveryButton(
            role: "AXButton",
            text: "ready, meizu m20, adb",
            expectedLabel: "MEIZU M20"
        ), "matching is case-insensitive")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryButton(
            role: "AXButton",
            text: "受信任设备 MEIZU M20",
            expectedLabel: "MEIZU M20"
        ), "trusted-device history without ADB must not match")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryButton(
            role: "AXStaticText",
            text: "MEIZU M20 backup over ADB.txt",
            expectedLabel: "MEIZU M20"
        ), "file/static text must not match")
        expect(!ProductDeviceVisibilityPolicy.matchesDiscoveryButton(
            role: "AXButton",
            text: "已就绪、MEIZU M20、ADB",
            expectedLabel: ""
        ), "empty expected label must not match")

        print("product device visibility policy test passed.")
    }
}
