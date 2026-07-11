import DroidMatchCore
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

    try await store.register(targetURL: target, authorizationURL: authorization)
    let lease = try await store.acquireAccess(to: target)
    #expect(codec.createdURLs().map(\.path) == [authorization.path, authorization.path])
    #expect(codec.startCount() == 1)
    lease.release()
    lease.release()
    #expect(codec.stopCount() == 1)

    let reopened = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: codec)
    let reopenedLease = try await reopened.acquireAccess(to: target)
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
    try await store.register(targetURL: first, authorizationURL: first)
    try await store.register(targetURL: second, authorizationURL: second)

    try await store.retainOnly(targetURLs: [second])
    await #expect(throws: SecurityScopedBookmarkStoreError.missingAuthorization) {
        _ = try await store.acquireAccess(to: first)
    }
    let lease = try await store.acquireAccess(to: second)
    lease.release()
    try await store.remove(targetURL: second)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func bookmarkStoreRollsBackFailedWritesAndRecoversHealthExplicitly() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blockedParent = directory.appendingPathComponent("not-a-directory")
    try Data("blocker".utf8).write(to: blockedParent)
    let fileURL = blockedParent.appendingPathComponent("bookmarks.json")
    let target = URL(fileURLWithPath: "/Users/test/rollback.bin")
    let store = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: BookmarkCodecProbe())

    await #expect(throws: SecurityScopedBookmarkStoreError.invalidLocation) {
        try await store.register(targetURL: target, authorizationURL: target)
    }
    #expect(!(await store.isPersistenceHealthy()))
    await #expect(throws: SecurityScopedBookmarkStoreError.missingAuthorization) {
        _ = try await store.acquireAccess(to: target)
    }

    try FileManager.default.removeItem(at: blockedParent)
    try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
    #expect(await store.retryPersistence())
    #expect(await store.isPersistenceHealthy())
    try await store.register(targetURL: target, authorizationURL: target)

    let reopened = try SecurityScopedBookmarkStore(fileURL: fileURL, codec: BookmarkCodecProbe())
    let lease = try await reopened.acquireAccess(to: target)
    lease.release()
}

private final class BookmarkCodecProbe: SecurityScopedBookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var created: [URL] = []
    private var starts = 0
    private var stops = 0
    private var staleOnNextResolve: Bool

    init(staleOnFirstResolve: Bool = false) {
        staleOnNextResolve = staleOnFirstResolve
    }

    func create(for url: URL) throws -> Data {
        lock.withLock { created.append(url) }
        return Data(url.path.utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        let path = String(decoding: data, as: UTF8.self)
        return lock.withLock {
            let stale = staleOnNextResolve
            staleOnNextResolve = false
            return (URL(fileURLWithPath: path), stale)
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
    func startCount() -> Int { lock.withLock { starts } }
    func stopCount() -> Int { lock.withLock { stops } }
}
