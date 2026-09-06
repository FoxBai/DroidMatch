import DroidMatchCore
import Foundation

/// Pure authorization-domain decisions for asynchronous media derivatives.
/// Ordinary stale results are generation-gated, while a permission failure
/// remains authoritative only within the browser's current Android media domain.
enum DirectoryBrowserMediaAuthorizationPolicy {
    static func isPermissionFailure(_ error: Error) -> Bool {
        if error as? MediaPlaybackError == .permissionRequired { return true }
        guard let thumbnailError = error as? MediaThumbnailError,
              case .remote(.permissionRequired) = thumbnailError else {
            return false
        }
        return true
    }

    static func sharesDomain(_ first: String, _ second: String) -> Bool {
        func domain(_ path: String) -> Int? {
            if path.hasPrefix("dm://media-images/") { return 1 }
            if path.hasPrefix("dm://media-videos/") { return 2 }
            if path.hasPrefix("dm://media-audio/") { return 3 }
            return nil
        }
        guard let firstDomain = domain(first) else { return false }
        return firstDomain == domain(second)
    }
}
