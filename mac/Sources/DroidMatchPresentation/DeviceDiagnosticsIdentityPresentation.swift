import DroidMatchCore
import Foundation

/// UI-only identity for the authenticated diagnostics overview.
///
/// The session's reviewed or catalog-resolved retail name is presentation
/// metadata only. Raw Android model/manufacturer values remain secondary
/// technical context and never become protocol or storage identity.
public struct DeviceDiagnosticsIdentityPresentation: Sendable, Equatable {
    public let primaryName: String?
    public let technicalDetail: String?

    public init(
        sessionDisplayName: String?,
        snapshot: ProductDeviceDiagnosticsSnapshot
    ) {
        let marketingName = ProductDisplayText.value(sessionDisplayName)
        let model = ProductDisplayText.value(snapshot.model)
        let manufacturer = ProductDisplayText.value(snapshot.manufacturer)
        primaryName = marketingName ?? model ?? manufacturer

        var technicalNames: [String] = []
        for value in [manufacturer, model].compactMap({ $0 }) {
            guard value.caseInsensitiveCompare(primaryName ?? "") != .orderedSame,
                  !technicalNames.contains(where: {
                      $0.caseInsensitiveCompare(value) == .orderedSame
                  }) else { continue }
            technicalNames.append(value)
        }
        technicalDetail = technicalNames.isEmpty
            ? nil
            : technicalNames.joined(separator: " · ")
    }
}
