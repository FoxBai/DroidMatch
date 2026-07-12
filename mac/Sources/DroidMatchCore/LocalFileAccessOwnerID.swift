import CryptoKit
import Foundation

/// Opaque, domain-separated owner for device-bound local file authority.
///
/// The authenticated fingerprint is never used directly as an archive key.
/// Callers may carry this value across targets, but only the named AppSupport
/// SPI can inspect its storage key. Normal output is always redacted.
public struct LocalFileAccessOwnerID:
    Sendable,
    Hashable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable {
    private static let domain = Data("DroidMatch bookmark owner v1\0".utf8)
    private static let redactedDescription = "<redacted-local-file-access-owner>"

    private let value: String

    /// Stable archive routing is available only to the AppSupport SPI. Product
    /// presentation targets receive the opaque value but cannot inspect it.
    @_spi(DroidMatchAppSupport) public var storageKey: String { value }

    public var description: String { Self.redactedDescription }
    public var debugDescription: String { Self.redactedDescription }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    package init?(authenticatedDeviceFingerprint fingerprint: Data) {
        guard fingerprint.count == PairingAuthenticator.digestLength else { return nil }
        var input = Self.domain
        input.append(fingerprint)
        value = SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
