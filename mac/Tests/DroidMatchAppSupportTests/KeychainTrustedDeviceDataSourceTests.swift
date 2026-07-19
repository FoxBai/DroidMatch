import DroidMatchCore
import Foundation
import Testing
@testable import DroidMatchAppSupport

@Test func keychainTrustedDeviceDataSourceUsesStableOpaqueUIIDsAndRevokesRawID() async throws {
    let pairingID = Data(repeating: 0x44, count: 16)
    let storedDisplayName = " \u{202E}Cafe\u{0301}\n\u{200B}Android\u{2069} "
    let store = PairingStoreProbe(metadata: [
        PairingCredentialDisplayMetadata(
            pairingID: pairingID,
            displayName: storedDisplayName,
            createdAt: Date(timeIntervalSince1970: 10),
            lastUsedAt: Date(timeIntervalSince1970: 20)
        ),
    ])
    let displayNameCache = TrustedDeviceDisplayNameCache()
    let source = KeychainTrustedDeviceDataSource(
        store: store,
        displayNameCache: displayNameCache
    )

    let first = try await source.list()
    await displayNameCache.remember("シンプルスマホ4", for: pairingID)
    let second = try await source.list()
    #expect(first.count == 1)
    #expect(first.first?.id == second.first?.id)
    #expect(first.first?.displayName == "Café Android")
    #expect(second.first?.displayName == "シンプルスマホ4")
    #expect(store.storedDisplayNames() == [storedDisplayName])
    #expect(try await source.revoke(id: first[0].id))
    #expect(store.revokedPairingIDs() == [pairingID])
    #expect(await displayNameCache.displayName(for: pairingID) == nil)
    #expect(!(try await source.revoke(id: UUID())))
}

private final class PairingStoreProbe:
    PairingCredentialStoring,
    PairingCredentialDisplayMetadataListing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var metadata: [PairingCredentialDisplayMetadata]
    private var revoked: [Data] = []

    init(metadata: [PairingCredentialDisplayMetadata]) { self.metadata = metadata }

    func insertNew(_ record: PairingCredentialRecord) throws {
        throw PairingStoreProbeError.unexpectedInsert
    }
    func save(_ record: PairingCredentialRecord) throws {}
    func load(pairingID: Data) throws -> PairingCredentialRecord {
        throw PairingStoreProbeError.unexpectedLoad
    }
    func list() throws -> [PairingCredentialMetadata] {
        throw PairingStoreProbeError.unexpectedCredentialList
    }
    func listForDisplay() throws -> [PairingCredentialDisplayMetadata] {
        lock.withLock { metadata }
    }
    func revoke(pairingID: Data) throws {
        lock.withLock {
            revoked.append(pairingID)
            metadata.removeAll { $0.pairingID == pairingID }
        }
    }
    func revokedPairingIDs() -> [Data] { lock.withLock { revoked } }
    func storedDisplayNames() -> [String] {
        lock.withLock { metadata.map(\.displayName) }
    }
}

private enum PairingStoreProbeError: Error {
    case unexpectedInsert
    case unexpectedLoad
    case unexpectedCredentialList
}
