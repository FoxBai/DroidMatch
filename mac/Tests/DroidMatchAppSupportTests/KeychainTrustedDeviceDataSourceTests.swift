import DroidMatchCore
import Foundation
import Testing
@testable import DroidMatchAppSupport

@Test func keychainTrustedDeviceDataSourceUsesStableOpaqueUIIDsAndRevokesRawID() async throws {
    let pairingID = Data(repeating: 0x44, count: 16)
    let store = PairingStoreProbe(metadata: [
        PairingCredentialMetadata(
            pairingID: pairingID,
            deviceIdentityFingerprint: Data(repeating: 0x55, count: 32),
            displayName: "Test Android",
            createdAt: Date(timeIntervalSince1970: 10),
            lastUsedAt: Date(timeIntervalSince1970: 20)
        ),
    ])
    let source = KeychainTrustedDeviceDataSource(store: store)

    let first = try await source.list()
    let second = try await source.list()
    #expect(first.count == 1)
    #expect(first.first?.id == second.first?.id)
    #expect(first.first?.displayName == "Test Android")
    #expect(try await source.revoke(id: first[0].id))
    #expect(store.revokedPairingIDs() == [pairingID])
    #expect(!(try await source.revoke(id: UUID())))
}

private final class PairingStoreProbe: PairingCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: [PairingCredentialMetadata]
    private var revoked: [Data] = []

    init(metadata: [PairingCredentialMetadata]) { self.metadata = metadata }

    func save(_ record: PairingCredentialRecord) throws {}
    func load(pairingID: Data) throws -> PairingCredentialRecord {
        throw PairingStoreProbeError.unexpectedLoad
    }
    func list() throws -> [PairingCredentialMetadata] { lock.withLock { metadata } }
    func revoke(pairingID: Data) throws {
        lock.withLock {
            revoked.append(pairingID)
            metadata.removeAll { $0.pairingID == pairingID }
        }
    }
    func revokedPairingIDs() -> [Data] { lock.withLock { revoked } }
}

private enum PairingStoreProbeError: Error { case unexpectedLoad }
