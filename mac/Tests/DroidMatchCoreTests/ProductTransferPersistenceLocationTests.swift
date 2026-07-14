import Foundation
import Testing
@testable import DroidMatchCore

@Test func productTransferPersistenceMigratesLegacyQueueWithoutChangingBytesOrMode() throws {
    let directory = try makeProductTransferLocationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fingerprint = Data(repeating: 0x91, count: PairingAuthenticator.digestLength)
    let legacy = try #require(ProductTransferPersistenceLocation.legacyURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let current = try #require(ProductTransferPersistenceLocation.currentURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let bytes = Data("legacy-queue-is-preserved".utf8)
    try bytes.write(to: legacy)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: legacy.path
    )

    let resolved = try ProductTransferPersistenceLocation.resolve(
        directory: directory,
        fingerprint: fingerprint
    )

    #expect(resolved == current)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(try Data(contentsOf: current) == bytes)
    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions]
            as? NSNumber
    )
    #expect(mode.intValue & 0o777 == 0o600)
}

@Test func productTransferPersistenceRejectsAmbiguousLegacyAndCurrentQueues() throws {
    let directory = try makeProductTransferLocationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fingerprint = Data(repeating: 0x92, count: PairingAuthenticator.digestLength)
    let legacy = try #require(ProductTransferPersistenceLocation.legacyURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let current = try #require(ProductTransferPersistenceLocation.currentURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let legacyBytes = Data("legacy".utf8)
    let currentBytes = Data("current".utf8)
    try legacyBytes.write(to: legacy)
    try currentBytes.write(to: current)

    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        _ = try ProductTransferPersistenceLocation.resolve(
            directory: directory,
            fingerprint: fingerprint
        )
    }
    #expect(try Data(contentsOf: legacy) == legacyBytes)
    #expect(try Data(contentsOf: current) == currentBytes)
}

@Test func productTransferPersistenceRejectsLegacySymlinkWithoutTouchingTarget() throws {
    let directory = try makeProductTransferLocationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fingerprint = Data(repeating: 0x93, count: PairingAuthenticator.digestLength)
    let legacy = try #require(ProductTransferPersistenceLocation.legacyURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let current = try #require(ProductTransferPersistenceLocation.currentURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let target = directory.appendingPathComponent("unrelated.json")
    let targetBytes = Data("must-not-move-or-rewrite".utf8)
    try targetBytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)

    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        _ = try ProductTransferPersistenceLocation.resolve(
            directory: directory,
            fingerprint: fingerprint
        )
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) == target.path)
    #expect(try Data(contentsOf: target) == targetBytes)
    #expect(!FileManager.default.fileExists(atPath: current.path))
}

@Test func productTransferPersistenceRejectsCurrentSymlinkWithoutTouchingTarget() throws {
    let directory = try makeProductTransferLocationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fingerprint = Data(repeating: 0x94, count: PairingAuthenticator.digestLength)
    let current = try #require(ProductTransferPersistenceLocation.currentURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let target = directory.appendingPathComponent("current-unrelated.json")
    let targetBytes = Data("must-remain-current".utf8)
    try targetBytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: current, withDestinationURL: target)

    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        _ = try ProductTransferPersistenceLocation.resolve(
            directory: directory,
            fingerprint: fingerprint
        )
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == target.path)
    #expect(try Data(contentsOf: target) == targetBytes)
}

private func makeProductTransferLocationDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
