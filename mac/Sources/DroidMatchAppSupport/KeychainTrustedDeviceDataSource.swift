import DroidMatchCore
import DroidMatchPresentation
import Foundation

/// Converts Keychain metadata into process-local UI identities. Pairing IDs and
/// device fingerprints never cross the AppSupport-to-Presentation boundary.
public actor KeychainTrustedDeviceDataSource: TrustedDeviceDataSource {
    private let store: any PairingCredentialStoring & PairingCredentialDisplayMetadataListing
    private var pairingIDsByUIID: [UUID: Data] = [:]
    private var uiIDsByPairingID: [Data: UUID] = [:]

    public init(store: any PairingCredentialStoring & PairingCredentialDisplayMetadataListing) {
        self.store = store
    }

    public func list() throws -> [TrustedDeviceItem] {
        let metadata = try store.listForDisplay()
        var currentIDs = Set<UUID>()
        let items = metadata.map { record -> TrustedDeviceItem in
            let id = uiIDsByPairingID[record.pairingID] ?? UUID()
            uiIDsByPairingID[record.pairingID] = id
            pairingIDsByUIID[id] = record.pairingID
            currentIDs.insert(id)
            return TrustedDeviceItem(
                id: id,
                displayName: record.displayName,
                createdAt: record.createdAt,
                lastUsedAt: record.lastUsedAt
            )
        }
        pairingIDsByUIID = pairingIDsByUIID.filter { currentIDs.contains($0.key) }
        uiIDsByPairingID = uiIDsByPairingID.filter { currentIDs.contains($0.value) }
        return items
    }

    public func revoke(id: UUID) throws -> Bool {
        guard let pairingID = pairingIDsByUIID[id] else { return false }
        try store.revoke(pairingID: pairingID)
        pairingIDsByUIID.removeValue(forKey: id)
        uiIDsByPairingID.removeValue(forKey: pairingID)
        return true
    }
}
