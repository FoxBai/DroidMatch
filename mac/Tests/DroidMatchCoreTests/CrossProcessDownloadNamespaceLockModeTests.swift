import Darwin
import Foundation
import Testing
@testable import DroidMatchCore

@Test func downloadNamespaceLockRejectsSpecialBitsOnEveryInfrastructureNode() async throws {
    for specialBit in [mode_t(0o4000), mode_t(0o2000), mode_t(0o1000)] {
        #expect(!CrossProcessDownloadNamespaceLock.hasExactPermissionBits(
            mode_t(0o600) | specialBit,
            expected: 0o600
        ))
        #expect(!CrossProcessDownloadNamespaceLock.hasExactPermissionBits(
            mode_t(0o700) | specialBit,
            expected: 0o700
        ))
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-download-lock-special-mode-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("payload.bin")
    let provider = UnrestrictedLocalFileAccessProvider()
    let bootstrap = try await provider.acquireDownloadDestination(to: destination)
    bootstrap.release()

    let root = directory.appendingPathComponent(
        CrossProcessDownloadNamespaceLock.rootEntryName,
        isDirectory: true
    )
    let anchor = directory.appendingPathComponent(
        CrossProcessDownloadNamespaceLock.identityEntryName
    )
    let lockName = try #require(
        FileManager.default.contentsOfDirectory(atPath: root.path).sorted().first
    )
    let lock = root.appendingPathComponent(lockName)

    for (url, unsafeMode, safeMode) in [
        (root, mode_t(0o1700), mode_t(0o700)),
        (anchor, mode_t(0o1600), mode_t(0o600)),
        (lock, mode_t(0o1600), mode_t(0o600)),
    ] {
        try setAndRequireDownloadLockMode(unsafeMode, at: url)
        await #expect(throws: AtomicDownloadWriterError.unsafeDestinationDirectory) {
            _ = try await provider.acquireDownloadDestination(to: destination)
        }
        try setAndRequireDownloadLockMode(safeMode, at: url)
    }

    let reacquired = try await provider.acquireDownloadDestination(to: destination)
    reacquired.release()
}

private func setAndRequireDownloadLockMode(_ mode: mode_t, at url: URL) throws {
    guard Darwin.chmod(url.path, mode) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try #require(metadata.st_mode & mode_t(0o7777) == mode)
}
