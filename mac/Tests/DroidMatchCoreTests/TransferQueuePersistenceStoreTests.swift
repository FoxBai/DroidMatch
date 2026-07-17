import Darwin
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

@Test func productRestorePlanRevalidatesPersistedUploadDestination() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue.json")
    )
    let valid = PersistedTransferQueue(jobs: [persistedUploadJob(
        id: UUID(),
        sequence: 0,
        label: "valid-media-restore",
        destinationPath: "dm://media-images/photo.jpg",
        state: .queued
    )])
    try store.save(valid)
    #expect(try store.productRestorePlan().manifest == valid)

    for (index, destinationPath) in [
        "dm://media-images/not-an-image.bin",
        "dm://media-images/private%name.jpg",
        "dm://media-images/private\u{202E}name.jpg",
        "dm://media-videos/photo.jpg",
        "dm://media-images/nested/photo.jpg",
    ].enumerated() {
        let invalid = PersistedTransferQueue(jobs: [persistedUploadJob(
            id: UUID(),
            sequence: UInt64(index),
            label: "invalid-media-restore-\(index)",
            destinationPath: destinationPath,
            state: .queued
        )])
        try store.save(invalid)
        // Persistence remains provider-agnostic; only the product restore plan
        // refuses to turn an obsolete or crafted destination into live work.
        #expect(try store.load() == invalid)
        #expect(throws: TransferQueuePersistenceStoreError.invalidData) {
            _ = try store.productRestorePlan()
        }
    }
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
    #expect(try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path).sorted() == [
        PrivateAtomicFileTransactionLock.entryName,
        "queue.json",
    ])
    let transactionLock = stateDirectory.appendingPathComponent(
        PrivateAtomicFileTransactionLock.entryName
    )
    let lockAttributes = try FileManager.default.attributesOfItem(
        atPath: transactionLock.path
    )
    #expect(lockAttributes[.type] as? FileAttributeType == .typeRegular)
    #expect(lockAttributes[.size] as? NSNumber == NSNumber(value: 0))
    #expect(lockAttributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    #expect(lockAttributes[.referenceCount] as? NSNumber == NSNumber(value: 1))
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

@Test func transferQueueStoreRejectsExtremeAttemptAndDelayFields() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/extreme-fields.bin",
        destinationURL: directory.appendingPathComponent("extreme-fields.bin"),
        freshTransferID: "extreme-fields",
        recoveryPolicy: RecoveryPolicy(
            maxAttempts: 7,
            baseDelayMs: 12_345,
            maxDelayMs: 54_321,
            jitterFactor: 0
        )
    )
    let manifest = PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: UUID(),
        sequence: 0,
        request: PersistedTransferRequest(.download(request)),
        state: .paused,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )])
    let encoded = try #require(String(
        data: JSONEncoder().encode(manifest),
        encoding: .utf8
    ))
    let extreme = String(Int.max)
    let mutations = [
        (#""attemptNumber":1"#, #""attemptNumber":\#(extreme)"#),
        (#""maxAttempts":7"#, #""maxAttempts":\#(extreme)"#),
        (#""baseDelayMs":12345"#, #""baseDelayMs":\#(Int64.max)"#),
        (#""maxDelayMs":54321"#, #""maxDelayMs":\#(Int64.max)"#),
    ]

    for (original, replacement) in mutations {
        let crafted = encoded.replacingOccurrences(of: original, with: replacement)
        try #require(crafted != encoded)
        let bytes = Data(crafted.utf8)
        try bytes.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )

        #expect(throws: TransferQueuePersistenceStoreError.invalidData) {
            _ = try store.load()
        }
        #expect(try Data(contentsOf: fileURL) == bytes)
    }
}

@Test func transferQueueStoreRejectsRetryThatEscapesAttemptCeiling() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/attempt-ceiling.bin",
        destinationURL: directory.appendingPathComponent("attempt-ceiling.bin"),
        freshTransferID: "attempt-ceiling",
        recoveryPolicy: .defaultSingleRetry
    )
    func manifest(attemptBase: Int, attemptNumber: Int) -> PersistedTransferQueue {
        PersistedTransferQueue(jobs: [PersistedTransferJob(
            id: UUID(),
            sequence: 0,
            request: PersistedTransferRequest(.download(request)),
            state: .queued,
            attemptNumber: attemptNumber,
            attemptBase: attemptBase,
            resumeAttemptBase: nil,
            pauseRequiresResume: false
        )])
    }

    let closedBoundary = manifest(
        attemptBase: PersistedTransferQueue.maximumAttemptNumber - 2,
        attemptNumber: PersistedTransferQueue.maximumAttemptNumber - 1
    )
    try store.save(closedBoundary)
    #expect(try store.load() == closedBoundary)

    // This was previously accepted even though its one configured retry would
    // make markRetry publish maximumAttemptNumber + 1 and fail its next save.
    let crafted = try JSONEncoder().encode(manifest(
        attemptBase: PersistedTransferQueue.maximumAttemptNumber - 1,
        attemptNumber: PersistedTransferQueue.maximumAttemptNumber
    ))
    try crafted.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )

    #expect(throws: TransferQueuePersistenceStoreError.invalidData) {
        _ = try store.load()
    }
    #expect(try Data(contentsOf: fileURL) == crafted)

    let pausedWithoutHeadroom = try JSONEncoder().encode(PersistedTransferQueue(jobs: [
        PersistedTransferJob(
            id: UUID(),
            sequence: 0,
            request: PersistedTransferRequest(.download(request)),
            state: .paused,
            attemptNumber: PersistedTransferQueue.maximumAttemptNumber,
            attemptBase: PersistedTransferQueue.maximumAttemptNumber - 1,
            resumeAttemptBase: nil,
            pauseRequiresResume: false
        ),
    ]))
    try pausedWithoutHeadroom.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )

    #expect(throws: TransferQueuePersistenceStoreError.invalidData) {
        _ = try store.load()
    }
    #expect(try Data(contentsOf: fileURL) == pausedWithoutHeadroom)

    // A resumable pause may continue from the displayed attempt (running) or
    // one before it (retry delay). An older base would roll the counter back
    // and regain retry headroom beyond the global ceiling.
    let rolledBackResume = try JSONEncoder().encode(PersistedTransferQueue(jobs: [
        PersistedTransferJob(
            id: UUID(),
            sequence: 0,
            request: PersistedTransferRequest(.download(request)),
            state: .paused,
            attemptNumber: PersistedTransferQueue.maximumAttemptNumber,
            attemptBase: PersistedTransferQueue.maximumAttemptNumber - 2,
            resumeAttemptBase: PersistedTransferQueue.maximumAttemptNumber - 2,
            pauseRequiresResume: true
        ),
    ]))
    try rolledBackResume.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )

    #expect(throws: TransferQueuePersistenceStoreError.invalidData) {
        _ = try store.load()
    }
    #expect(try Data(contentsOf: fileURL) == rolledBackResume)

    let noRetryRequest = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/no-retry-ceiling.bin",
        destinationURL: directory.appendingPathComponent("no-retry-ceiling.bin"),
        freshTransferID: "no-retry-ceiling",
        recoveryPolicy: .disabled
    )
    let replayedFirstAttempt = try JSONEncoder().encode(PersistedTransferQueue(jobs: [
        PersistedTransferJob(
            id: UUID(),
            sequence: 0,
            request: PersistedTransferRequest(.download(noRetryRequest)),
            state: .paused,
            attemptNumber: PersistedTransferQueue.maximumAttemptNumber,
            attemptBase: PersistedTransferQueue.maximumAttemptNumber - 1,
            resumeAttemptBase: PersistedTransferQueue.maximumAttemptNumber - 1,
            pauseRequiresResume: true
        ),
    ]))
    try replayedFirstAttempt.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )

    #expect(throws: TransferQueuePersistenceStoreError.invalidData) {
        _ = try store.load()
    }
    #expect(try Data(contentsOf: fileURL) == replayedFirstAttempt)
}

@Test func emptyTransferQueueSavePreservesEveryUnexpectedDestinationNode() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let empty = PersistedTransferQueue(jobs: [])

    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    let sentinel = fileURL.appendingPathComponent("keep.txt")
    try Data("directory-sentinel".utf8).write(to: sentinel)
    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        try store.save(empty)
    }
    #expect(try Data(contentsOf: sentinel) == Data("directory-sentinel".utf8))
    try FileManager.default.removeItem(at: fileURL)

    let protected = directory.appendingPathComponent("protected.bin")
    let protectedBytes = Data("protected".utf8)
    try protectedBytes.write(to: protected)
    try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: protected)
    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        try store.save(empty)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path) == protected.path)
    #expect(try Data(contentsOf: protected) == protectedBytes)
    try FileManager.default.removeItem(at: fileURL)

    try FileManager.default.linkItem(at: protected, to: fileURL)
    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        try store.save(empty)
    }
    #expect(try Data(contentsOf: fileURL) == protectedBytes)
    #expect(try Data(contentsOf: protected) == protectedBytes)
    try FileManager.default.removeItem(at: fileURL)

    #expect(Darwin.mkfifo(fileURL.path, mode_t(0o600)) == 0)
    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        try store.save(empty)
    }
    var fifoMetadata = stat()
    #expect(Darwin.lstat(fileURL.path, &fifoMetadata) == 0)
    #expect(fifoMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
}

@Test func nonemptyTransferQueueSaveNeverOverwritesUnexpectedDestinationNode() throws {
    let directory = try makeTransferQueueTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: fileURL)
    let manifest = PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: UUID(),
        sequence: 7,
        label: "unsafe-publication",
        state: .paused
    )])

    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    let sentinel = fileURL.appendingPathComponent("keep.txt")
    try Data("keep-directory".utf8).write(to: sentinel)
    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        try store.save(manifest)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep-directory".utf8))
    try FileManager.default.removeItem(at: fileURL)

    let protected = directory.appendingPathComponent("protected.bin")
    let protectedBytes = Data("keep-target".utf8)
    try protectedBytes.write(to: protected)
    try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: protected)
    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        try store.save(manifest)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path) == protected.path)
    #expect(try Data(contentsOf: protected) == protectedBytes)
}
