import Foundation

enum AppStrings {
    private static let localizationBundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(
               url: resourceURL.appendingPathComponent(
                   "DroidMatchMac_DroidMatchApp.bundle",
                   isDirectory: true
               )
           ) {
            return bundle
        }
        return .module
    }()

    static let appName = value("DroidMatch")
    static let devices = value("Devices")
    static let files = value("Files")
    static let transfers = value("Transfers")
    static let diagnostics = value("Diagnostics")
    static let localFirst = value("Local first")
    static let adbFoundation = value("USB discovery through the product ADB boundary")
    static let refresh = value("Refresh")
    static let refreshDevices = value("Refresh devices")
    static let deviceOverview = value("Your Android devices")
    static let deviceOverviewDetail = value("Private, local discovery. Hardware serials stay outside the interface.")
    static let visible = value("Visible")
    static let ready = value("Ready")
    static let transport = value("Transport")
    static let lookingForDevices = value("Looking for devices…")
    static let noDevices = value("No Android devices found")
    static let noDevicesDetail = value("Connect a device by USB, unlock it, and approve the ADB prompt if Android asks.")
    static let adbUnavailable = value("ADB is unavailable")
    static let discoveryTimedOut = value("Device discovery timed out")
    static let discoveryUnavailable = value("Device discovery is unavailable")
    static let staleDeviceDetail = value("The last device snapshot is shown as stale. Refresh before starting a session.")
    static let discoveryFailureDetail = value("Check the Android platform tools and try again.")
    static let androidDevice = value("Android device")
    static let stale = value("Stale")
    static let unauthorized = value("Approval needed")
    static let offline = value("Offline")
    static let unavailable = value("Unavailable")
    static let filesNeedSession = value("Files need an authenticated session")
    static let filesNeedSessionDetail = value("Device discovery is live. File browsing will unlock after the product session boundary is connected.")
    static let transfersNeedSession = value("No active transfer session")
    static let transfersNeedSessionDetail = value("The tested transfer queue will appear here after lifecycle-owned session wiring is enabled.")
    static let diagnosticsNeedSession = value("Session diagnostics are not connected yet")
    static let diagnosticsNeedSessionDetail = value("This product surface will use structured transport and permission state, never raw harness output.")

    private static func value(_ key: String) -> String {
        localizationBundle.localizedString(forKey: key, value: key, table: nil)
    }
}
