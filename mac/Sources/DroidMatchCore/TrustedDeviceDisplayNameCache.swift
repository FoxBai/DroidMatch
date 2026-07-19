import Foundation

/// Produces the same safe text used by product UI while also satisfying the
/// credential envelope's stricter UTF-8 byte ceiling.
enum PairingCredentialDisplayText {
    static func value(_ rawValue: String?) -> String? {
        var scalarLimit = 120
        while scalarLimit > 0 {
            guard let candidate = ProductDisplayText.value(
                rawValue,
                maximumScalars: scalarLimit
            ) else { return nil }
            if Data(candidate.utf8).count
                <= PairingAuthenticator.maximumDisplayNameBytes {
                return candidate
            }
            scalarLimit -= 1
        }
        return nil
    }
}

/// Process-local correlation between a secret Core pairing identity and its
/// already-sanitized discovery name.
///
/// Pairing IDs never cross this actor into Presentation or persistence. Existing
/// Keychain records can therefore gain an accurate display name after an
/// explicit authenticated connection without another Keychain read or write.
public actor TrustedDeviceDisplayNameCache {
    private var namesByPairingID: [Data: String] = [:]
    private var revokedPairingIDs = Set<Data>()

    public init() {}

    public func remember(_ displayName: String?, for pairingID: Data) {
        guard pairingID.count == PairingAuthenticator.pairingIDLength,
              !revokedPairingIDs.contains(pairingID),
              let displayName = PairingCredentialDisplayText.value(displayName) else { return }
        namesByPairingID[pairingID] = displayName
    }

    public func displayName(for pairingID: Data) -> String? {
        guard pairingID.count == PairingAuthenticator.pairingIDLength else { return nil }
        return namesByPairingID[pairingID]
    }

    public func forget(pairingID: Data) {
        guard pairingID.count == PairingAuthenticator.pairingIDLength else { return }
        namesByPairingID.removeValue(forKey: pairingID)
        // A confirmed revoke is terminal for this process. This tombstone makes
        // a late authentication task harmless even if actor jobs are reordered.
        revokedPairingIDs.insert(pairingID)
    }
}
