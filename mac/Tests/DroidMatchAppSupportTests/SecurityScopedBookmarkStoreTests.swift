@_spi(DroidMatchAppSupport) @testable import DroidMatchCore
import Darwin
import Foundation
import Testing
@testable import DroidMatchAppSupport

@Test func bookmarkStorePersistsRefreshesAndBalancesAccess() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/Downloads/result.bin")
    let authorization = target.deletingLastPathComponent()
    let codec = BookmarkCodecProbe(staleOnFirstResolve: true)
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    let owner = try bookmarkOwner(0x01)

    try await store.register(
        owner: owner,
        targetURL: target,
        authorizationURL: authorization
    )
    let lease = try await store.acquireAccess(owner: owner, to: target)
    #expect(codec.createdURLs().map(\.path) == [authorization.path, authorization.path])
    #expect(codec.startCount() == 1)
    lease.release()
    lease.release()
    #expect(codec.stopCount() == 1)

    let reopened = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    let reopenedLease = try await reopened.acquireAccess(owner: owner, to: target)
    reopenedLease.release()
    #expect(codec.startCount() == 2)
    #expect(codec.stopCount() == 2)
}

@Test func bookmarkStorePrunesOrphansAndFailsClosedWithoutAuthorization() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let first = URL(fileURLWithPath: "/Users/test/first.bin")
    let second = URL(fileURLWithPath: "/Users/test/second.bin")
    let codec = BookmarkCodecProbe()
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    let owner = try bookmarkOwner(0x02)
    try await store.register(owner: owner, targetURL: first, authorizationURL: first)
    try await store.register(owner: owner, targetURL: second, authorizationURL: second)

    try await store.retainOnly(owner: owner, targetURLs: [second])
    await #expect(throws: SecurityScopedBookmarkStoreError.missingAuthorization) {
        _ = try await store.acquireAccess(owner: owner, to: first)
    }
    let lease = try await store.acquireAccess(owner: owner, to: second)
    lease.release()
    try await store.remove(owner: owner, targetURL: second)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func emptyBookmarkArchiveSavePreservesEveryUnexpectedDestinationNode() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/empty-archive.bin")
    let owner = try bookmarkOwner(0x71)
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: BookmarkCodecProbe())
    try await store.register(owner: owner, targetURL: target, authorizationURL: target)

    try FileManager.default.removeItem(at: fileURL)
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    let sentinel = fileURL.appendingPathComponent("keep.txt")
    try Data("directory-sentinel".utf8).write(to: sentinel)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await store.remove(owner: owner, targetURL: target)
    }
    #expect(try Data(contentsOf: sentinel) == Data("directory-sentinel".utf8))
    try FileManager.default.removeItem(at: fileURL)

    let protected = directory.appendingPathComponent("protected.bin")
    let protectedBytes = Data("protected".utf8)
    try protectedBytes.write(to: protected)
    try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: protected)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await store.remove(owner: owner, targetURL: target)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path) == protected.path)
    #expect(try Data(contentsOf: protected) == protectedBytes)
    try FileManager.default.removeItem(at: fileURL)

    try FileManager.default.linkItem(at: protected, to: fileURL)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await store.remove(owner: owner, targetURL: target)
    }
    #expect(try Data(contentsOf: fileURL) == protectedBytes)
    #expect(try Data(contentsOf: protected) == protectedBytes)
    try FileManager.default.removeItem(at: fileURL)

    #expect(Darwin.mkfifo(fileURL.path, mode_t(0o600)) == 0)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await store.remove(owner: owner, targetURL: target)
    }
    var fifoMetadata = stat()
    #expect(Darwin.lstat(fileURL.path, &fifoMetadata) == 0)
    #expect(fifoMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
}

@Test func nonemptyBookmarkArchiveSaveNeverOverwritesUnexpectedDestinationNode() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/nonempty-archive.bin")
    let owner = try bookmarkOwner(0x72)
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: BookmarkCodecProbe())

    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    let sentinel = fileURL.appendingPathComponent("keep.txt")
    try Data("keep-directory".utf8).write(to: sentinel)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await store.register(owner: owner, targetURL: target, authorizationURL: target)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep-directory".utf8))
    try FileManager.default.removeItem(at: fileURL)

    let protected = directory.appendingPathComponent("protected.bin")
    let protectedBytes = Data("keep-target".utf8)
    try protectedBytes.write(to: protected)
    try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: protected)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await store.register(owner: owner, targetURL: target, authorizationURL: target)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path) == protected.path)
    #expect(try Data(contentsOf: protected) == protectedBytes)
}

@Test func bookmarkStoreFailsClosedOnInvalidParentAndRecoversExplicitly() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blockedParent = directory.appendingPathComponent("not-a-directory")
    try Data("blocker".utf8).write(to: blockedParent)
    let fileURL = blockedParent.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/rollback.bin")
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: BookmarkCodecProbe())
    let owner = try bookmarkOwner(0x03)

    await #expect(throws: SecurityScopedBookmarkStoreError.unavailable) {
        try await store.register(owner: owner, targetURL: target, authorizationURL: target)
    }
    #expect(!(await store.isPersistenceHealthy()))
    await #expect(throws: SecurityScopedBookmarkStoreError.unavailable) {
        _ = try await store.acquireAccess(owner: owner, to: target)
    }

    try FileManager.default.removeItem(at: blockedParent)
    try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
    #expect(await store.retryPersistence())
    #expect(await store.isPersistenceHealthy())
    try await store.register(owner: owner, targetURL: target, authorizationURL: target)

    let reopened = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: BookmarkCodecProbe())
    let lease = try await reopened.acquireAccess(owner: owner, to: target)
    lease.release()
}

@Test func bookmarkStoreRetriesStartupLoadWithoutOverwritingCorruptState() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let corrupt = Data("not-a-bookmark-archive".utf8)
    try corrupt.write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )
    let codec = BookmarkCodecProbe()
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    let target = URL(fileURLWithPath: "/Users/test/startup-recovery.bin")
    let owner = try bookmarkOwner(0x04)

    #expect(!(await store.isPersistenceHealthy()))
    await #expect(throws: SecurityScopedBookmarkStoreError.unavailable) {
        try await store.register(owner: owner, targetURL: target, authorizationURL: target)
    }
    await #expect(throws: SecurityScopedBookmarkStoreError.unavailable) {
        _ = try await store.acquireAccess(owner: owner, to: target)
    }
    #expect(try Data(contentsOf: fileURL) == corrupt)
    #expect(codec.createdURLs().isEmpty)
    #expect(!(await store.retryPersistence()))
    #expect(try Data(contentsOf: fileURL) == corrupt)

    try FileManager.default.removeItem(at: fileURL)
    #expect(await store.retryPersistence())
    #expect(await store.isPersistenceHealthy())
    try await store.register(owner: owner, targetURL: target, authorizationURL: target)
    let lease = try await store.acquireAccess(owner: owner, to: target)
    lease.release()
}

@Test func bookmarkStoreKeepsSamePathScopedAuthoritiesIsolatedByOwner() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/shared-target.bin")
    let firstAuthorization = URL(fileURLWithPath: "/Users/test/owner-a")
    let secondAuthorization = URL(fileURLWithPath: "/Users/test/owner-b")
    let firstOwner = try bookmarkOwner(0x11)
    let secondOwner = try bookmarkOwner(0x22)
    let codec = BookmarkCodecProbe()
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)

    try await store.register(
        owner: firstOwner,
        targetURL: target,
        authorizationURL: firstAuthorization
    )
    #expect(await store.isReadyForTransferExecution(
        owner: firstOwner,
        targetURLs: [target]
    ))
    #expect(!(await store.isReadyForTransferExecution(
        owner: secondOwner,
        targetURLs: [target]
    )))
    await #expect(throws: SecurityScopedBookmarkStoreError.missingAuthorization) {
        _ = try await store.acquireAccess(owner: secondOwner, to: target)
    }

    try await store.register(
        owner: secondOwner,
        targetURL: target,
        authorizationURL: secondAuthorization
    )
    try await store.retainOnly(owner: firstOwner, targetURLs: [])
    #expect(!(await store.isReadyForTransferExecution(
        owner: firstOwner,
        targetURLs: [target]
    )))
    #expect(await store.isReadyForTransferExecution(
        owner: secondOwner,
        targetURLs: [target]
    ))
    let lease = try await store.acquireAccess(owner: secondOwner, to: target)
    lease.release()
    #expect(codec.resolvedURLs() == [secondAuthorization])

    // Removing an already-empty first-owner bucket must not delete the second
    // owner's durable authority or the archive containing it.
    try await store.remove(owner: firstOwner, targetURL: target)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    let reopened = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    #expect(await reopened.isReadyForTransferExecution(
        owner: secondOwner,
        targetURLs: [target]
    ))
}

@Test func bookmarkStoreMigratesV1RecordsOnlyAsLegacyAndRefreshesThemInPlace() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/legacy-target.bin")
    let legacyAuthorization = URL(fileURLWithPath: "/Users/test/legacy-authority")
    try writePrivateArchive(
        BookmarkArchiveV1Probe(
            version: 1,
            records: [target.standardizedFileURL.path: Data(legacyAuthorization.path.utf8)]
        ),
        to: fileURL
    )
    let firstOwner = try bookmarkOwner(0x31)
    let secondOwner = try bookmarkOwner(0x32)
    let codec = BookmarkCodecProbe(staleOnFirstResolve: true)
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)

    #expect(await store.isReadyForTransferExecution(
        owner: firstOwner,
        targetURLs: [target]
    ))
    #expect(await store.isReadyForTransferExecution(
        owner: secondOwner,
        targetURLs: [target]
    ))
    let lease = try await store.acquireAccess(owner: firstOwner, to: target)
    lease.release()
    #expect(codec.createdURLs() == [legacyAuthorization])

    // A healthy retry writes v2, but must not guess which authenticated owner
    // owns a v1 path-only record.
    #expect(await store.retryPersistence())
    try await store.retainOnly(owner: firstOwner, targetURLs: [])
    let archive = try JSONDecoder().decode(
        BookmarkArchiveV2Probe.self,
        from: Data(contentsOf: fileURL)
    )
    #expect(archive.version == 2)
    #expect(archive.scopedRecords.isEmpty)
    #expect(archive.legacyUnscopedRecords.map(\.targetPath) == [target.path])

    let reopened = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    #expect(await reopened.isReadyForTransferExecution(
        owner: secondOwner,
        targetURLs: [target]
    ))
}

@Test func ownerScopedBookmarkFailureNeverFallsBackToHealthyLegacyRecord() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/precedence-target.bin")
    let legacyAuthorization = URL(fileURLWithPath: "/Users/test/legacy-good")
    let brokenScopedAuthorization = URL(fileURLWithPath: "/Users/test/scoped-broken")
    try writePrivateArchive(
        BookmarkArchiveV1Probe(
            version: 1,
            records: [target.path: Data(legacyAuthorization.path.utf8)]
        ),
        to: fileURL
    )
    let scopedOwner = try bookmarkOwner(0x41)
    let legacyOnlyOwner = try bookmarkOwner(0x42)
    let codec = BookmarkCodecProbe(failingResolvePaths: [brokenScopedAuthorization.path])
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    try await store.register(
        owner: scopedOwner,
        targetURL: target,
        authorizationURL: brokenScopedAuthorization
    )

    await #expect(throws: SecurityScopedBookmarkStoreError.unavailable) {
        _ = try await store.acquireAccess(owner: scopedOwner, to: target)
    }
    #expect(codec.resolvedURLs() == [brokenScopedAuthorization])

    let legacyLease = try await store.acquireAccess(owner: legacyOnlyOwner, to: target)
    legacyLease.release()
    #expect(codec.resolvedURLs() == [brokenScopedAuthorization, legacyAuthorization])

    // Owner-scoped cleanup cannot delete the still-unowned legacy grant.
    try await store.remove(owner: scopedOwner, targetURL: target)
    #expect(await store.isReadyForTransferExecution(
        owner: scopedOwner,
        targetURLs: [target]
    ))
}

@Test func bookmarkStoreRejectsDuplicateAndIllegalV2OwnersWithoutOverwriting() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = URL(fileURLWithPath: "/Users/test/duplicate.bin")
    let owner = try bookmarkOwner(0x51)
    let record = BookmarkScopedRecordProbe(
        owner: owner.storageKey,
        targetPath: target.path,
        bookmarkData: Data("authority".utf8)
    )
    let duplicateURL = directory.appendingPathComponent("duplicate.json")
    try writePrivateArchive(
        BookmarkArchiveV2Probe(
            version: 2,
            scopedRecords: [record, record],
            legacyUnscopedRecords: []
        ),
        to: duplicateURL
    )
    let duplicateBytes = try Data(contentsOf: duplicateURL)
    let duplicateStore = try SecurityScopedBookmarkStore(
        fileURL: duplicateURL,
        codec: BookmarkCodecProbe()
    )
    #expect(!(await duplicateStore.isPersistenceHealthy()))
    #expect(!(await duplicateStore.retryPersistence()))
    #expect(try Data(contentsOf: duplicateURL) == duplicateBytes)

    let duplicateLegacyURL = directory.appendingPathComponent("duplicate-legacy.json")
    let legacyRecord = BookmarkLegacyRecordProbe(
        targetPath: target.path,
        bookmarkData: Data("legacy-authority".utf8)
    )
    try writePrivateArchive(
        BookmarkArchiveV2Probe(
            version: 2,
            scopedRecords: [],
            legacyUnscopedRecords: [legacyRecord, legacyRecord]
        ),
        to: duplicateLegacyURL
    )
    let duplicateLegacyStore = try SecurityScopedBookmarkStore(
        fileURL: duplicateLegacyURL,
        codec: BookmarkCodecProbe()
    )
    #expect(!(await duplicateLegacyStore.isPersistenceHealthy()))

    let illegalURL = directory.appendingPathComponent("illegal.json")
    try writePrivateArchive(
        BookmarkArchiveV2Probe(
            version: 2,
            scopedRecords: [BookmarkScopedRecordProbe(
                owner: owner.storageKey.uppercased(),
                targetPath: target.path,
                bookmarkData: Data("authority".utf8)
            )],
            legacyUnscopedRecords: []
        ),
        to: illegalURL
    )
    let illegalBytes = try Data(contentsOf: illegalURL)
    let illegalStore = try SecurityScopedBookmarkStore(
        fileURL: illegalURL,
        codec: BookmarkCodecProbe()
    )
    #expect(!(await illegalStore.isPersistenceHealthy()))
    await #expect(throws: SecurityScopedBookmarkStoreError.unavailable) {
        try await illegalStore.register(
            owner: owner,
            targetURL: target,
            authorizationURL: target
        )
    }
    #expect(try Data(contentsOf: illegalURL) == illegalBytes)
}

@Test func queueAdapterCombinesBookmarkAndManifestPersistenceHealth() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let bookmarkDirectory = directory.appendingPathComponent("bookmarks", isDirectory: true)
    let manifestDirectory = directory.appendingPathComponent("queue", isDirectory: true)
    let owner = try bookmarkOwner(0x61)
    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: bookmarkDirectory.appendingPathComponent("bookmarks.json"),
        codec: BookmarkCodecProbe()
    )
    let manifestStore = try TransferQueuePersistenceStore(
        fileURL: manifestDirectory.appendingPathComponent("queue.json")
    )
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { _, _, _ in
            throw QueueAdapterProbeError.connectionUnavailable
        },
        uploadExecutor: { _, _, _ in
            throw QueueAdapterProbeError.connectionUnavailable
        },
        persistenceStore: manifestStore,
        localFileAccessOwnerID: owner
    )
    let adapter = BookmarkingTransferQueueFactory(store: bookmarkStore)
        .transferQueueDataSource(for: scheduler)
    #expect(await adapter.persistenceStatus() == .healthy)

    try Data("blocks-bookmarks".utf8).write(to: bookmarkDirectory)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await bookmarkStore.register(
            owner: owner,
            targetURL: URL(fileURLWithPath: "/Users/test/bookmark-failure.bin"),
            authorizationURL: URL(fileURLWithPath: "/Users/test")
        )
    }
    #expect(await adapter.persistenceStatus() == .writeFailed)
    #expect(await adapter.submitDownload(
        sourcePath: "dm://app-sandbox/must-not-submit.bin",
        destinationURL: directory.appendingPathComponent("must-not-submit.bin"),
        authorizationURL: directory
    ) == nil)
    #expect(await scheduler.snapshots().isEmpty)
    try FileManager.default.removeItem(at: bookmarkDirectory)
    try FileManager.default.createDirectory(
        at: bookmarkDirectory,
        withIntermediateDirectories: true
    )
    #expect(await adapter.retryPersistence())
    #expect(await adapter.persistenceStatus() == .healthy)

    let orphanTarget = URL(fileURLWithPath: "/Users/test/orphaned-after-remove.bin")
    try await bookmarkStore.register(
        owner: owner,
        targetURL: orphanTarget,
        authorizationURL: orphanTarget
    )
    try FileManager.default.removeItem(at: bookmarkDirectory)
    try Data("blocks-orphan-removal".utf8).write(to: bookmarkDirectory)
    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await bookmarkStore.remove(owner: owner, targetURL: orphanTarget)
    }
    #expect(await adapter.persistenceStatus() == .writeFailed)
    try FileManager.default.removeItem(at: bookmarkDirectory)
    try FileManager.default.createDirectory(
        at: bookmarkDirectory,
        withIntermediateDirectories: true
    )
    #expect(await adapter.retryPersistence())
    #expect(await adapter.persistenceStatus() == .healthy)
    await #expect(throws: SecurityScopedBookmarkStoreError.missingAuthorization) {
        _ = try await bookmarkStore.acquireAccess(owner: owner, to: orphanTarget)
    }

    try FileManager.default.removeItem(at: manifestDirectory)
    try Data("blocks-manifest".utf8).write(to: manifestDirectory)
    _ = await scheduler.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/manifest-failure.bin",
        destinationURL: directory.appendingPathComponent("download.bin")
    )))
    #expect(await adapter.persistenceStatus() == .writeFailed)
    try FileManager.default.removeItem(at: manifestDirectory)
    try FileManager.default.createDirectory(
        at: manifestDirectory,
        withIntermediateDirectories: true
    )
    #expect(await adapter.retryPersistence())
    #expect(await adapter.persistenceStatus() == .healthy)
}

private enum QueueAdapterProbeError: Error {
    case connectionUnavailable
}

private enum BookmarkCodecProbeError: Error {
    case resolutionFailed
}

private struct BookmarkArchiveV1Probe: Codable {
    let version: Int
    let records: [String: Data]
}

private struct BookmarkArchiveV2Probe: Codable {
    let version: Int
    let scopedRecords: [BookmarkScopedRecordProbe]
    let legacyUnscopedRecords: [BookmarkLegacyRecordProbe]
}

private struct BookmarkScopedRecordProbe: Codable {
    let owner: String
    let targetPath: String
    let bookmarkData: Data
}

private struct BookmarkLegacyRecordProbe: Codable {
    let targetPath: String
    let bookmarkData: Data
}

private func bookmarkOwner(_ byte: UInt8) throws -> LocalFileAccessOwnerID {
    try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: Data(repeating: byte, count: 32)
    ))
}

private func writePrivateArchive<T: Encodable>(_ archive: T, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(archive).write(to: fileURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
    )
}

private final class BookmarkCodecProbe: SecurityScopedBookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var created: [URL] = []
    private var resolved: [URL] = []
    private var starts = 0
    private var stops = 0
    private var staleOnNextResolve: Bool
    private let failingResolvePaths: Set<String>

    init(
        staleOnFirstResolve: Bool = false,
        failingResolvePaths: Set<String> = []
    ) {
        staleOnNextResolve = staleOnFirstResolve
        self.failingResolvePaths = failingResolvePaths
    }

    func create(for url: URL) throws -> Data {
        lock.withLock { created.append(url) }
        return Data(url.path.utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        let path = String(decoding: data, as: UTF8.self)
        return try lock.withLock {
            let url = URL(fileURLWithPath: path)
            resolved.append(url)
            if failingResolvePaths.contains(path) {
                throw BookmarkCodecProbeError.resolutionFailed
            }
            let stale = staleOnNextResolve
            staleOnNextResolve = false
            return (url, stale)
        }
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }

    func createdURLs() -> [URL] { lock.withLock { created } }
    func resolvedURLs() -> [URL] { lock.withLock { resolved } }
    func startCount() -> Int { lock.withLock { starts } }
    func stopCount() -> Int { lock.withLock { stops } }
}
