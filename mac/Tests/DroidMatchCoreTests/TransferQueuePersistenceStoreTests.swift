import Foundation
import Testing
@testable import DroidMatchCore

@Test func transferQueueStoreRoundTripsWithPrivatePermissions() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("state/queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let job = persistedDownloadJob(
        id: UUID(),
        sequence: 4,
        label: "round-trip",
        state: .paused
    )
    let manifest = PersistedTransferQueue(jobs: [job])

    try store.save(manifest)

    #expect(try store.load() == manifest)
    let fileMode = try #require(
        FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
            as? NSNumber
    )
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber
    )
    #expect(fileMode.intValue & 0o777 == 0o600)
    #expect(directoryMode.intValue & 0o777 == 0o700)

    try store.save(PersistedTransferQueue(jobs: []))
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func transferQueueStoreKeepsPrivateFilesInsideExistingBroadDirectory() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateDirectory = directory.appendingPathComponent("existing-state", isDirectory: true)
    try FileManager.default.createDirectory(
        at: stateDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: stateDirectory.path
    )
    let fileURL = stateDirectory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let first = PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: UUID(),
        sequence: 1,
        label: "first-private-replacement",
        state: .paused
    )])
    let second = PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: UUID(),
        sequence: 2,
        label: "second-private-replacement",
        state: .paused
    )])

    try store.save(first)
    try store.save(second)

    #expect(try store.load() == second)
    let fileMode = try #require(
        FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
            as? NSNumber
    )
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: stateDirectory.path)[.posixPermissions]
            as? NSNumber
    )
    #expect(fileMode.intValue & 0o777 == 0o600)
    #expect(directoryMode.intValue & 0o777 == 0o755)
    #expect(try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path) == [
        "queue.json",
    ])
}

@Test func transferQueueStorePreservesCorruptAndUnknownVersionFiles() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)

    let corrupt = Data("not-json".utf8)
    try corrupt.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )
    do {
        _ = try store.load()
        Issue.record("expected corrupt queue data to be rejected")
    } catch let error as TransferQueuePersistenceStoreError {
        #expect(error == .invalidData)
    }
    #expect(try Data(contentsOf: fileURL) == corrupt)

    let unknownVersion = Data(#"{"schemaVersion":999,"jobs":[]}"#.utf8)
    try unknownVersion.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )
    do {
        _ = try store.load()
        Issue.record("expected unknown queue schema to be rejected")
    } catch let error as TransferQueuePersistenceStoreError {
        #expect(error == .unsupportedSchemaVersion(999))
    }
    #expect(try Data(contentsOf: fileURL) == unknownVersion)

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)],
        ofItemAtPath: fileURL.path
    )
    do {
        _ = try store.load()
        Issue.record("expected permissive queue file mode to be rejected")
    } catch let error as TransferQueuePersistenceStoreError {
        #expect(error == .invalidLocation)
    }
    #expect(try Data(contentsOf: fileURL) == unknownVersion)
}
