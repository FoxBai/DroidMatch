import DroidMatchCore
import DroidMatchPresentation
import Foundation

/// Converts Keychain metadata into process-local UI identities. Pairing IDs and
/// device fingerprints never cross the AppSupport-to-Presentation boundary.
public actor KeychainTrustedDeviceDataSource: TrustedDeviceDataSource {
    private let store: any PairingCredentialStoring & PairingCredentialDisplayMetadataListing
    private let displayNameCache: TrustedDeviceDisplayNameCache
    private var pairingIDsByUIID: [UUID: Data] = [:]
    private var uiIDsByPairingID: [Data: UUID] = [:]

    public init(
        store: any PairingCredentialStoring & PairingCredentialDisplayMetadataListing,
        displayNameCache: TrustedDeviceDisplayNameCache = .init()
    ) {
        self.store = store
        self.displayNameCache = displayNameCache
    }

    public func list() async throws -> [TrustedDeviceItem] {
        let metadata = try store.listForDisplay()
        var currentIDs = Set<UUID>()
        var stableIDs: [UUID] = []
        stableIDs.reserveCapacity(metadata.count)
        for record in metadata {
            let id = uiIDsByPairingID[record.pairingID] ?? UUID()
            uiIDsByPairingID[record.pairingID] = id
            pairingIDsByUIID[id] = record.pairingID
            currentIDs.insert(id)
            stableIDs.append(id)
        }
        pairingIDsByUIID = pairingIDsByUIID.filter { currentIDs.contains($0.key) }
        uiIDsByPairingID = uiIDsByPairingID.filter { currentIDs.contains($0.value) }

        var items: [TrustedDeviceItem] = []
        items.reserveCapacity(metadata.count)
        for (record, id) in zip(metadata, stableIDs) {
            let displayName = await displayNameCache.displayName(
                for: record.pairingID
            ) ?? record.displayName
            items.append(TrustedDeviceItem(
                id: id,
                displayName: displayName,
                createdAt: record.createdAt,
                lastUsedAt: record.lastUsedAt
            ))
        }
        return items
    }

    public func revoke(id: UUID) async throws -> Bool {
        guard let pairingID = pairingIDsByUIID[id] else { return false }
        try store.revoke(pairingID: pairingID)
        await displayNameCache.forget(pairingID: pairingID)
        pairingIDsByUIID.removeValue(forKey: id)
        uiIDsByPairingID.removeValue(forKey: pairingID)
        return true
    }
}
