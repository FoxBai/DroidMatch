import Darwin
import Foundation
import Testing
@testable import DroidMatchCore

private let privateAtomicPythonTransactionScript = #"""
import fcntl
import os
import stat
import sys
import time

mode, lock_path, target_path, ready_path, go_path = sys.argv[1:]
descriptor = os.open(lock_path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
metadata = os.fstat(descriptor)
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 1
    or metadata.st_uid != os.geteuid()
    or stat.S_IMODE(metadata.st_mode) != 0o600
    or metadata.st_size != 0
):
    os._exit(3)
fcntl.flock(descriptor, fcntl.LOCK_EX)
named = os.stat(lock_path, follow_symlinks=False)
if (named.st_dev, named.st_ino) != (metadata.st_dev, metadata.st_ino):
    os._exit(4)

ready = os.open(
    ready_path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
    0o600,
)
os.write(ready, b"ready\n")
os.fsync(ready)
os.close(ready)

deadline = time.monotonic() + 10
while not os.path.exists(go_path):
    if time.monotonic() >= deadline:
        os._exit(5)
    time.sleep(0.01)

parent = os.path.dirname(target_path)
directory = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
if mode == "remove":
    removing = os.path.join(parent, "." + os.path.basename(target_path) + ".removing")
    os.rename(target_path, removing)
    os.fsync(directory)
    os.unlink(removing)
    os.fsync(directory)
elif mode == "write":
    candidate = os.path.join(parent, ".python-private-atomic-candidate")
    output = os.open(
        candidate,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    os.write(output, b"child-published")
    os.fsync(output)
    os.close(output)
    os.replace(candidate, target_path)
    os.fsync(directory)
elif mode != "hold":
    os._exit(6)
os.close(directory)
fcntl.flock(descriptor, fcntl.LOCK_UN)
os.close(descriptor)
"""#

private final class PrivateAtomicCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markCompleted() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func startPrivateAtomicPythonTransaction(
    mode: String,
    lockURL: URL,
    targetURL: URL,
    readyURL: URL,
    goURL: URL
) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c",
        privateAtomicPythonTransactionScript,
        mode,
        lockURL.path,
        targetURL.path,
        readyURL.path,
        goURL.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func requirePrivateAtomicPythonReady(_ process: Process, at readyURL: URL) throws {
    for _ in 0..<250 {
        if FileManager.default.fileExists(atPath: readyURL.path) { return }
        if !process.isRunning { break }
        usleep(20_000)
    }
    try #require(FileManager.default.fileExists(atPath: readyURL.path))
}

private func killAndWaitForPrivateAtomicPython(_ process: Process) {
    if process.isRunning {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}

private func privateAtomicLockURL(in directory: URL) -> URL {
    directory.appendingPathComponent(PrivateAtomicFileTransactionLock.entryName)
}

@Test func privateAtomicReadPinsOnePrivateRegularEntryAndRejectsUnsafeNodes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-read-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let archive = directory.appendingPathComponent("archive.json")
    let expected = Data("private-state".utf8)
    try PrivateAtomicFileWriter.write(expected, to: archive)
    #expect(try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(at: archive) == expected)
    try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(at: archive)
    #expect(try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(at: archive) == nil)

    let archiveDirectory = directory.appendingPathComponent("archive-directory")
    try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: false)
    let sentinel = archiveDirectory.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)

    let symlinkTarget = directory.appendingPathComponent("symlink-target")
    try expected.write(to: symlinkTarget)
    let symlink = directory.appendingPathComponent("archive-symlink")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)

    let hardLinkTarget = directory.appendingPathComponent("hard-link-target")
    try expected.write(to: hardLinkTarget)
    let hardLink = directory.appendingPathComponent("archive-hard-link")
    try FileManager.default.linkItem(at: hardLinkTarget, to: hardLink)

    let fifo = directory.appendingPathComponent("archive-fifo")
    #expect(Darwin.mkfifo(fifo.path, mode_t(0o600)) == 0)

    for unsafeURL in [archiveDirectory, symlink, hardLink, fifo] {
        #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
            _ = try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(at: unsafeURL)
        }
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(try Data(contentsOf: symlinkTarget) == expected)
    #expect(try Data(contentsOf: hardLinkTarget) == expected)

    let permissive = directory.appendingPathComponent("archive-permissive")
    try expected.write(to: permissive)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)],
        ofItemAtPath: permissive.path
    )
    #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
        _ = try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(at: permissive)
    }
}

@Test func privateAtomicIORejectsSymlinkParentWithoutTouchingItsTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-parent-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let realParent = root.appendingPathComponent("real", isDirectory: true)
    let aliasParent = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
    let archive = aliasParent.appendingPathComponent("archive.json")

    #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
        _ = try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(at: archive)
    }
    #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
        try PrivateAtomicFileWriter.write(Data("do-not-publish".utf8), to: archive)
    }
    #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
        try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(at: archive)
    }
    #expect(!FileManager.default.fileExists(
        atPath: realParent.appendingPathComponent("archive.json").path
    ))
}

@Test func privateAtomicIOPreservesRecognizableRecoveryNodesAndFailsClosed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-recovery-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = directory.appendingPathComponent("archive.json")
    let original = Data("original".utf8)
    try PrivateAtomicFileWriter.write(original, to: archive)

    for suffix in ["pending", "removing"] {
        let recovery = directory.appendingPathComponent(".archive.json.\(suffix)")
        let recoveryData = Data("recoverable-\(suffix)".utf8)
        try recoveryData.write(to: recovery)
        #expect(throws: PrivateAtomicFileWriterError.commitUncertain) {
            _ = try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(at: archive)
        }
        #expect(throws: PrivateAtomicFileWriterError.commitUncertain) {
            try PrivateAtomicFileWriter.write(Data("replacement".utf8), to: archive)
        }
        #expect(throws: PrivateAtomicFileWriterError.commitUncertain) {
            try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(at: archive)
        }
        #expect(try Data(contentsOf: archive) == original)
        #expect(try Data(contentsOf: recovery) == recoveryData)
        try FileManager.default.removeItem(at: recovery)
    }
}

@Test func privateAtomicCrossProcessRemoveCompletesBeforeWaitingWrite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-remove-write-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = directory.appendingPathComponent("archive.json")
    try PrivateAtomicFileWriter.write(Data("original".utf8), to: archive)

    let ready = directory.appendingPathComponent("child-ready")
    let go = directory.appendingPathComponent("child-go")
    let child = try startPrivateAtomicPythonTransaction(
        mode: "remove",
        lockURL: privateAtomicLockURL(in: directory),
        targetURL: archive,
        readyURL: ready,
        goURL: go
    )
    defer { killAndWaitForPrivateAtomicPython(child) }
    try requirePrivateAtomicPythonReady(child, at: ready)

    let replacement = Data("parent-published".utf8)
    let probe = PrivateAtomicCompletionProbe()
    let write = Task.detached {
        defer { probe.markCompleted() }
        try PrivateAtomicFileWriter.write(replacement, to: archive)
    }
    usleep(200_000)
    #expect(!probe.isCompleted)
    try Data("go".utf8).write(to: go)
    child.waitUntilExit()
    #expect(child.terminationReason == .exit)
    #expect(child.terminationStatus == 0)
    try await write.value
    #expect(try Data(contentsOf: archive) == replacement)
}

@Test func privateAtomicCrossProcessWriteCompletesBeforeWaitingRemove() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-write-remove-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = directory.appendingPathComponent("archive.json")
    try PrivateAtomicFileWriter.write(Data("original".utf8), to: archive)

    let ready = directory.appendingPathComponent("child-ready")
    let go = directory.appendingPathComponent("child-go")
    let child = try startPrivateAtomicPythonTransaction(
        mode: "write",
        lockURL: privateAtomicLockURL(in: directory),
        targetURL: archive,
        readyURL: ready,
        goURL: go
    )
    defer { killAndWaitForPrivateAtomicPython(child) }
    try requirePrivateAtomicPythonReady(child, at: ready)

    let probe = PrivateAtomicCompletionProbe()
    let remove = Task.detached {
        defer { probe.markCompleted() }
        try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(at: archive)
    }
    usleep(200_000)
    #expect(!probe.isCompleted)
    try Data("go".utf8).write(to: go)
    child.waitUntilExit()
    #expect(child.terminationReason == .exit)
    #expect(child.terminationStatus == 0)
    try await remove.value
    #expect(!FileManager.default.fileExists(atPath: archive.path))
}

@Test func privateAtomicLocksDifferentParentsIndependentlyAndSIGKILLReleases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-independent-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    let first = firstDirectory.appendingPathComponent("archive.json")
    let second = secondDirectory.appendingPathComponent("archive.json")
    try PrivateAtomicFileWriter.write(Data("first".utf8), to: first)
    try PrivateAtomicFileWriter.write(Data("second".utf8), to: second)

    let ready = firstDirectory.appendingPathComponent("child-ready")
    let go = firstDirectory.appendingPathComponent("never-created")
    let child = try startPrivateAtomicPythonTransaction(
        mode: "hold",
        lockURL: privateAtomicLockURL(in: firstDirectory),
        targetURL: first,
        readyURL: ready,
        goURL: go
    )
    defer { killAndWaitForPrivateAtomicPython(child) }
    try requirePrivateAtomicPythonReady(child, at: ready)

    let firstReplacement = Data("first-after-crash".utf8)
    let probe = PrivateAtomicCompletionProbe()
    let waitingWrite = Task.detached {
        defer { probe.markCompleted() }
        try PrivateAtomicFileWriter.write(firstReplacement, to: first)
    }
    usleep(200_000)
    #expect(!probe.isCompleted)

    let secondReplacement = Data("second-replaced".utf8)
    try PrivateAtomicFileWriter.write(secondReplacement, to: second)
    #expect(try Data(contentsOf: second) == secondReplacement)

    killAndWaitForPrivateAtomicPython(child)
    #expect(child.terminationReason == .uncaughtSignal)
    try await waitingWrite.value
    #expect(try Data(contentsOf: first) == firstReplacement)
}

@Test func privateAtomicLockSerializesSeparateOpenDescriptionsInOneProcess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-same-process-lock-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    try #require(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    var identity = stat()
    try #require(Darwin.fstat(descriptor, &identity) == 0)
    let held = try PrivateAtomicFileTransactionLock.acquire(
        parentDescriptor: descriptor,
        parentIdentity: identity,
        destinationName: "held.json"
    )
    defer { held.release() }

    let archive = directory.appendingPathComponent("archive.json")
    let expected = Data("published-after-release".utf8)
    let probe = PrivateAtomicCompletionProbe()
    let write = Task.detached {
        defer { probe.markCompleted() }
        try PrivateAtomicFileWriter.write(expected, to: archive)
    }
    usleep(200_000)
    #expect(!probe.isCompleted)
    held.release()
    try await write.value
    #expect(try Data(contentsOf: archive) == expected)
}

@Test func privateAtomicTransactionLockIsPrivateFixedMetadataAndFailsClosed() throws {
    enum UnsafeNode {
        case symlink
        case hardLink
        case permissive
        case directory
    }

    for node in [UnsafeNode.symlink, .hardLink, .permissive, .directory] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "droidmatch-private-unsafe-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("archive.json")
        let original = Data("untouched".utf8)
        try original.write(to: archive)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: archive.path
        )
        let lock = privateAtomicLockURL(in: directory)
        let backing = directory.appendingPathComponent("lock-backing")
        switch node {
        case .symlink:
            try Data().write(to: backing)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: backing)
        case .hardLink:
            try Data().write(to: backing)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: backing.path
            )
            try FileManager.default.linkItem(at: backing, to: lock)
        case .permissive:
            try Data().write(to: lock)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: lock.path
            )
        case .directory:
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        }

        #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
            _ = try PrivateAtomicFileWriter.readRegularSingleLinkIfPresent(at: archive)
        }
        #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
            try PrivateAtomicFileWriter.write(Data("replacement".utf8), to: archive)
        }
        #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
            try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(at: archive)
        }
        #expect(try Data(contentsOf: archive) == original)
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-private-lock-layout-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = directory.appendingPathComponent("personal-name.json")
    try PrivateAtomicFileWriter.write(Data("state".utf8), to: archive)
    let lock = privateAtomicLockURL(in: directory)
    let attributes = try FileManager.default.attributesOfItem(atPath: lock.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect(attributes[.size] as? NSNumber == NSNumber(value: 0))
    #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    #expect(attributes[.referenceCount] as? NSNumber == NSNumber(value: 1))
    #expect(try Data(contentsOf: lock).range(of: Data("personal-name".utf8)) == nil)

    let reserved = directory.appendingPathComponent(PrivateAtomicFileTransactionLock.entryName)
    #expect(throws: PrivateAtomicFileWriterError.unsafeDestination) {
        try PrivateAtomicFileWriter.write(Data("do-not-overwrite".utf8), to: reserved)
    }
    #expect((try FileManager.default.attributesOfItem(atPath: lock.path)[.size] as? NSNumber) == 0)
}
