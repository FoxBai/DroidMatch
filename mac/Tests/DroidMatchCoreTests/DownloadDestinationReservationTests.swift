import Darwin
import Foundation
import Testing
@testable import DroidMatchCore

private let downloadNamespacePythonLockScript = #"""
import fcntl
import os
import signal
import stat
import sys

flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(sys.argv[1], flags)
metadata = os.fstat(descriptor)
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size != 0:
    os._exit(3)
fcntl.flock(descriptor, fcntl.LOCK_EX)
ready = os.open(
    sys.argv[2],
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
    0o600,
)
os.write(ready, b"ready\n")
os.fsync(ready)
os.close(ready)
while True:
    signal.pause()
"""#

private func startPythonLockHolder(lockURL: URL, readyURL: URL) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c",
        downloadNamespacePythonLockScript,
        lockURL.path,
        readyURL.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func requirePythonLockReady(_ process: Process, readyURL: URL) throws {
    for _ in 0..<250 {
        if FileManager.default.fileExists(atPath: readyURL.path) { return }
        if !process.isRunning { break }
        usleep(20_000)
    }
    try #require(FileManager.default.fileExists(atPath: readyURL.path))
}

private func killAndWait(_ process: Process) {
    guard process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
}

private final class RedirectedDownloadAccessLease:
    ResolvedLocalFileAccessLease,
    @unchecked Sendable
{
    let resolvedAccessURL: URL?

    private let lock = NSLock()
    private var releaseCallCount = 0

    init(resolvedAccessURL: URL?) {
        self.resolvedAccessURL = resolvedAccessURL
    }

    func release() {
        lock.lock()
        releaseCallCount += 1
        lock.unlock()
    }

    func releaseCalls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return releaseCallCount
    }
}

private func snapshotDownloadLockRoot(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
        var metadata = stat()
        guard Darwin.lstat(root.appendingPathComponent(name).path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        result[name] = "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mode):"
            + "\(metadata.st_nlink):\(metadata.st_size):"
            + "\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec):"
            + "\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
    }
    return result
}

@Test func downloadDestinationLeaseReservesEveryDerivedEntryAcrossProviders() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-reservation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("payload.bin")
    let firstProvider = UnrestrictedLocalFileAccessProvider()
    let secondProvider = UnrestrictedLocalFileAccessProvider()
    let first = try await firstProvider.acquireDownloadDestination(to: destination)
    defer { first.release() }

    for reservedName in [
        "payload.bin",
        "payload.bin.droidmatch-part",
        "payload.bin.droidmatch-transfer.json",
        ".payload.bin.droidmatch-transfer.json.pending",
        ".payload.bin.droidmatch-transfer.json.removing",
        ".payload.bin.droidmatch-commit",
        ".payload.bin.droidmatch-replaced",
    ] {
        let conflicting = directory.appendingPathComponent(reservedName)
        await #expect(throws: AtomicDownloadWriterError.destinationBusy) {
            _ = try await secondProvider.acquireDownloadDestination(to: conflicting)
        }
    }

    let distinct = try await secondProvider.acquireDownloadDestination(
        to: directory.appendingPathComponent("distinct.bin")
    )
    distinct.release()
}

@Test func downloadNamespaceReservationUsesKernelLocksAcrossProcesses() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-cross-process-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = UnrestrictedLocalFileAccessProvider()
    let destination = directory.appendingPathComponent("payload.bin")

    // Production creates and validates the persistent lock inode. The child
    // only holds that exact inode with the kernel advisory-lock primitive.
    let bootstrap = try await provider.acquireDownloadDestination(to: destination)
    bootstrap.release()
    let normalizedPartial = CrossProcessDownloadNamespaceLock.normalizeEntryName(
        "payload.bin.droidmatch-part",
        caseSensitive: true
    )
    let lockName = CrossProcessDownloadNamespaceLock.lockEntryName(
        forNormalizedEntryName: normalizedPartial
    )
    let lockURL = directory
        .appendingPathComponent(CrossProcessDownloadNamespaceLock.rootEntryName)
        .appendingPathComponent(lockName)
    let readyURL = directory.appendingPathComponent("child-ready")
    let child = try startPythonLockHolder(lockURL: lockURL, readyURL: readyURL)
    defer { killAndWait(child) }
    try requirePythonLockReady(child, readyURL: readyURL)

    await #expect(throws: AtomicDownloadWriterError.destinationBusy) {
        _ = try await provider.acquireDownloadDestination(
            to: directory.appendingPathComponent("payload.bin.droidmatch-part")
        )
    }
    let distinct = try await provider.acquireDownloadDestination(
        to: directory.appendingPathComponent("distinct.bin")
    )
    distinct.release()

    killAndWait(child)
    #expect(child.terminationReason == .uncaughtSignal)
    let reacquired = try await provider.acquireDownloadDestination(
        to: directory.appendingPathComponent("payload.bin.droidmatch-part")
    )
    reacquired.release()
}

@Test func downloadNamespaceLockLayoutIsPrivateAndRejectsUnsafeRoot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-lock-layout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = UnrestrictedLocalFileAccessProvider()
    let destination = directory.appendingPathComponent("private-name.bin")
    let lease = try await provider.acquireDownloadDestination(to: destination)
    lease.release()

    let root = directory.appendingPathComponent(
        CrossProcessDownloadNamespaceLock.rootEntryName,
        isDirectory: true
    )
    let anchor = directory.appendingPathComponent(
        CrossProcessDownloadNamespaceLock.identityEntryName
    )
    let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
    let anchorAttributes = try FileManager.default.attributesOfItem(atPath: anchor.path)
    #expect(rootAttributes[.type] as? FileAttributeType == .typeDirectory)
    #expect(rootAttributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o700))
    #expect(anchorAttributes[.type] as? FileAttributeType == .typeRegular)
    #expect(anchorAttributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    let anchorData = try Data(contentsOf: anchor)
    #expect(anchorData.count == 40)
    #expect(anchorData.range(of: Data("private-name.bin".utf8)) == nil)

    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(entries.count == 7)
    for entry in entries {
        #expect(entry.range(
            of: #"^v1-[0-9a-f]{64}\.lock$"#,
            options: .regularExpression
        ) != nil)
        #expect(!entry.contains("private"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(entry).path
        )
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(attributes[.size] as? NSNumber == NSNumber(value: 0))
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    }

    let displacedRoot = directory.appendingPathComponent("moved-lock-root", isDirectory: true)
    try FileManager.default.moveItem(at: root, to: displacedRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: root.path
    )
    await #expect(throws: AtomicDownloadWriterError.unsafeDestinationDirectory) {
        _ = try await provider.acquireDownloadDestination(to: destination)
    }
    #expect(FileManager.default.fileExists(atPath: displacedRoot.path))
    #expect(FileManager.default.fileExists(atPath: root.path))
}

@Test func downloadNamespaceLockRejectsSymlinkRootAndHardLinkedLockFile() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-lock-unsafe-\(UUID().uuidString)")
    let symlinkParent = root.appendingPathComponent("symlink-case", isDirectory: true)
    let symlinkTarget = root.appendingPathComponent("symlink-target", isDirectory: true)
    try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = symlinkTarget.appendingPathComponent("sentinel")
    try Data("unchanged".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(
        at: symlinkParent.appendingPathComponent(
            CrossProcessDownloadNamespaceLock.rootEntryName
        ),
        withDestinationURL: symlinkTarget
    )
    let provider = UnrestrictedLocalFileAccessProvider()
    await #expect(throws: AtomicDownloadWriterError.unsafeDestinationDirectory) {
        _ = try await provider.acquireDownloadDestination(
            to: symlinkParent.appendingPathComponent("payload.bin")
        )
    }
    #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))

    let hardlinkParent = root.appendingPathComponent("hardlink-case", isDirectory: true)
    try FileManager.default.createDirectory(at: hardlinkParent, withIntermediateDirectories: true)
    let destination = hardlinkParent.appendingPathComponent("payload.bin")
    let lease = try await provider.acquireDownloadDestination(to: destination)
    lease.release()
    let lockRoot = hardlinkParent.appendingPathComponent(
        CrossProcessDownloadNamespaceLock.rootEntryName
    )
    let firstLockName = try #require(
        FileManager.default.contentsOfDirectory(atPath: lockRoot.path).sorted().first
    )
    let firstLock = lockRoot.appendingPathComponent(firstLockName)
    try FileManager.default.linkItem(
        at: firstLock,
        to: lockRoot.appendingPathComponent("unexpected-hard-link")
    )
    await #expect(throws: AtomicDownloadWriterError.unsafeDestinationDirectory) {
        _ = try await provider.acquireDownloadDestination(to: destination)
    }
    #expect(FileManager.default.fileExists(atPath: firstLock.path))
    #expect(FileManager.default.fileExists(
        atPath: lockRoot.appendingPathComponent("unexpected-hard-link").path
    ))

    let reservedParent = root.appendingPathComponent("reserved-name-case", isDirectory: true)
    try FileManager.default.createDirectory(at: reservedParent, withIntermediateDirectories: true)
    for reservedName in [
        CrossProcessDownloadNamespaceLock.rootEntryName,
        CrossProcessDownloadNamespaceLock.identityEntryName,
    ] {
        await #expect(throws: AtomicDownloadWriterError.invalidDestination) {
            _ = try await provider.acquireDownloadDestination(
                to: reservedParent.appendingPathComponent(reservedName)
            )
        }
    }
    #expect(!FileManager.default.fileExists(
        atPath: reservedParent.appendingPathComponent(
            CrossProcessDownloadNamespaceLock.rootEntryName
        ).path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: reservedParent.appendingPathComponent(
            CrossProcessDownloadNamespaceLock.identityEntryName
        ).path
    ))
}

@Test func downloadReservationRejectsItsPersistentLockInfrastructure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-lock-reserved-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = UnrestrictedLocalFileAccessProvider()
    let bootstrap = try await provider.acquireDownloadDestination(
        to: directory.appendingPathComponent("payload.bin")
    )
    bootstrap.release()

    for destination in [
        directory.appendingPathComponent(CrossProcessDownloadNamespaceLock.rootEntryName),
        directory.appendingPathComponent(CrossProcessDownloadNamespaceLock.identityEntryName),
        directory.appendingPathComponent(PrivateAtomicFileTransactionLock.entryName),
        directory
            .appendingPathComponent(
                CrossProcessDownloadNamespaceLock.rootEntryName,
                isDirectory: true
            )
            .appendingPathComponent("v1-attacker-selected.lock"),
    ] {
        await #expect(throws: AtomicDownloadWriterError.invalidDestination) {
            _ = try await provider.acquireDownloadDestination(to: destination)
        }
    }
}

@Test func resolvedDownloadAuthorizationCannotEnterLockInfrastructure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-resolved-lock-\(UUID().uuidString)")
    let selectedParent = root.appendingPathComponent("selected", isDirectory: true)
    let storageParent = root.appendingPathComponent("storage", isDirectory: true)
    try FileManager.default.createDirectory(at: selectedParent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storageParent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let bootstrap = try await UnrestrictedLocalFileAccessProvider()
        .acquireDownloadDestination(
            to: storageParent.appendingPathComponent("bootstrap.bin")
        )
    bootstrap.release()
    let lockRoot = storageParent.appendingPathComponent(
        CrossProcessDownloadNamespaceLock.rootEntryName,
        isDirectory: true
    )
    let lockName = try #require(
        FileManager.default.contentsOfDirectory(atPath: lockRoot.path).sorted().first
    )
    let lockNode = lockRoot.appendingPathComponent(lockName)
    let request = selectedParent.appendingPathComponent("ordinary-download.bin")
    let originalLockRoot = try snapshotDownloadLockRoot(lockRoot)
    _ = try #require(originalLockRoot[lockName])

    for resolvedParent in [lockRoot, lockNode] {
        let redirectedLease = RedirectedDownloadAccessLease(
            resolvedAccessURL: resolvedParent
        )
        #expect(throws: AtomicDownloadWriterError.invalidDestination) {
            _ = try DownloadDestinationReservation.acquire(
                destinationURL: request,
                accessLease: redirectedLease
            )
        }
        #expect(redirectedLease.releaseCalls() == 1)
        #expect(try snapshotDownloadLockRoot(lockRoot) == originalLockRoot)
    }

    let unavailableLease = RedirectedDownloadAccessLease(resolvedAccessURL: nil)
    #expect(throws: AtomicDownloadWriterError.invalidDestination) {
        _ = try DownloadDestinationReservation.acquire(
            destinationURL: request,
            accessLease: unavailableLease
        )
    }
    #expect(unavailableLease.releaseCalls() == 1)
    #expect(try snapshotDownloadLockRoot(lockRoot) == originalLockRoot)
}

@Test func rawAsyncDownloadWriterUsesTheSharedDerivedEntryReservation() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-raw-download-reservation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("payload.bin")
    let aliasLease = try await UnrestrictedLocalFileAccessProvider()
        .acquireDownloadDestination(
            to: directory.appendingPathComponent("payload.bin.droidmatch-part")
        )
    defer { aliasLease.release() }

    await #expect(throws: AtomicDownloadWriterError.destinationBusy) {
        _ = try await ReservedAsyncDownloadWriter.acquire(
            destinationURL: destination,
            resume: false
        )
    }
}

@Test func pinnedDownloadContextSurvivesParentRenameWithoutSplittingArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-context-\(UUID().uuidString)")
    let parent = root.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = parent.appendingPathComponent("payload.bin")
    try Data("old".utf8).write(to: destination)
    let lease = try await UnrestrictedLocalFileAccessProvider()
        .acquireDownloadDestination(to: destination)
    defer { lease.release() }
    let context = try #require(
        (lease as? any LocalDownloadDirectoryContextProviding)?.directoryContext
    )
    let writer = try AtomicDownloadWriter(
        destinationURL: destination,
        resume: false,
        deferFreshReset: false,
        expectedDirectoryIdentity: lease.directoryIdentity,
        directoryContext: context
    )
    try writer.write(Data("new".utf8))
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 3
    fingerprint.modifiedUnixMillis = 1
    let record = DownloadResumeRecord(
        transferID: "pinned-parent",
        sourcePath: "dm://app-sandbox/payload.bin",
        totalSizeBytes: 3,
        fingerprint: TransferFingerprintRecord(fingerprint)
    )
    let sidecar = DownloadResumeRecord.sidecarURL(forDestination: destination)
    try record.save(
        to: sidecar,
        expectedDirectoryIdentity: lease.directoryIdentity,
        directoryContext: context
    )

    let moved = root.appendingPathComponent("renamed", isDirectory: true)
    try FileManager.default.moveItem(at: parent, to: moved)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)

    try writer.commit(retainRecoveryMarker: true)
    try DownloadResumeRecord.remove(
        from: sidecar,
        expectedDirectoryIdentity: lease.directoryIdentity,
        directoryContext: context
    )
    try writer.finalizeCommit()

    #expect(try Data(contentsOf: moved.appendingPathComponent("payload.bin")) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(
        atPath: moved.appendingPathComponent(sidecar.lastPathComponent).path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: parent.appendingPathComponent("payload.bin").path
    ))
}

@Test func retainedDownloadCommitCanRollbackBeforeCheckpointCleanup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-rollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("payload.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    try Data("old".utf8).write(to: destination)
    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    try writer.write(Data("new".utf8))

    try writer.commit(retainRecoveryMarker: true)
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".payload.bin.droidmatch-commit").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".payload.bin.droidmatch-replaced").path
    ))

    try writer.rollbackCommit()
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(try Data(contentsOf: partial) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".payload.bin.droidmatch-commit").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".payload.bin.droidmatch-replaced").path
    ))
}

@Test func coordinatedDownloadCommitRestoresCheckpointAfterCleanupFailure() throws {
    enum ExpectedFailure: Error { case cleanup }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-checkpoint-rollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("payload.bin")
    let partial = AtomicDownloadWriter.partialURL(for: destination)
    try Data("old".utf8).write(to: destination)
    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    try writer.write(Data("new".utf8))
    var restoredCheckpoint = false

    #expect(throws: ExpectedFailure.cleanup) {
        try writer.commitCoordinatingCheckpoint(
            removeCheckpoint: { throw ExpectedFailure.cleanup },
            restoreCheckpoint: { restoredCheckpoint = true }
        )
    }
    #expect(restoredCheckpoint)
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(try Data(contentsOf: partial) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".payload.bin.droidmatch-commit").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".payload.bin.droidmatch-replaced").path
    ))
}

@Test func coordinatedDownloadCommitKeepsMarkerUntilCheckpointRestoreSucceeds() throws {
    enum ExpectedFailure: Error { case cleanup, restore }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-checkpoint-marker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("payload.bin")
    let marker = directory.appendingPathComponent(".payload.bin.droidmatch-commit")
    try Data("old".utf8).write(to: destination)
    let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
    try writer.write(Data("new".utf8))

    #expect(throws: AtomicDownloadWriterError.checkpointRestoreFailed) {
        try writer.commitCoordinatingCheckpoint(
            removeCheckpoint: { throw ExpectedFailure.cleanup },
            restoreCheckpoint: { throw ExpectedFailure.restore }
        )
    }
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(try Data(
        contentsOf: AtomicDownloadWriter.partialURL(for: destination)
    ) == Data("new".utf8))
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".payload.bin.droidmatch-replaced").path
    ))
    #expect(throws: AtomicDownloadWriterError.commitUncertain) {
        _ = try AtomicDownloadWriter(destinationURL: destination, resume: true)
    }
}

@Test func retainedDownloadCommitRejectsPublishedDestinationReplacement() throws {
    for mutation in ["rename", "unlink", "replace"] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("droidmatch-download-finalize-\(mutation)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.bin")
        let marker = directory.appendingPathComponent(".payload.bin.droidmatch-commit")
        let displaced = directory.appendingPathComponent(".payload.bin.droidmatch-replaced")
        try Data("old".utf8).write(to: destination)
        let writer = try AtomicDownloadWriter(destinationURL: destination, resume: false)
        try writer.write(Data("new".utf8))
        try writer.commit(retainRecoveryMarker: true)

        switch mutation {
        case "rename":
            try FileManager.default.moveItem(
                at: destination,
                to: directory.appendingPathComponent("moved-published.bin")
            )
        case "unlink":
            try FileManager.default.removeItem(at: destination)
        default:
            try FileManager.default.removeItem(at: destination)
            try Data("intruder".utf8).write(to: destination)
        }

        #expect(throws: AtomicDownloadWriterError.commitUncertain) {
            try writer.finalizeCommit()
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: displaced) == Data("old".utf8))
    }
}

@Test func downloadDestinationLeaseRejectsAncestorSymlinkAndAllowsDistinctUnicodeNames() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-path-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let real = directory.appendingPathComponent("real", isDirectory: true)
    let alias = directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let provider = UnrestrictedLocalFileAccessProvider()

    await #expect(throws: AtomicDownloadWriterError.unsafeDestinationDirectory) {
        _ = try await provider.acquireDownloadDestination(
            to: alias.appendingPathComponent("payload.bin")
        )
    }

    let plain = try await provider.acquireDownloadDestination(
        to: real.appendingPathComponent("resume.bin")
    )
    defer { plain.release() }
    let accented = try await provider.acquireDownloadDestination(
        to: real.appendingPathComponent("résumé.bin")
    )
    accented.release()
}

@Test func atomicDownloadWriterRejectsParentReboundAfterDestinationReservation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-download-rebound-\(UUID().uuidString)")
    let parent = root.appendingPathComponent("parent", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = parent.appendingPathComponent("payload.bin")
    let lease = try await UnrestrictedLocalFileAccessProvider()
        .acquireDownloadDestination(to: destination)
    defer { lease.release() }

    let displaced = root.appendingPathComponent("displaced", isDirectory: true)
    try FileManager.default.moveItem(at: parent, to: displaced)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)

    #expect(throws: AtomicDownloadWriterError.destinationChanged) {
        _ = try AtomicDownloadWriter(
            destinationURL: destination,
            resume: false,
            deferFreshReset: false,
            expectedDirectoryIdentity: lease.directoryIdentity
        )
    }
    #expect(!FileManager.default.fileExists(
        atPath: AtomicDownloadWriter.partialURL(for: destination).path
    ))
}
