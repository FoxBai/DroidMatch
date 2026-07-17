import CryptoKit
import Darwin
import Foundation

// Darwin also imports `struct flock`, so bind the advisory-lock function to
// its C symbol explicitly. Locks are released by close after process exit.
@_silgen_name("flock")
private func droidMatchNamespaceFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// A cross-process advisory reservation for the seven entries derived from one
/// download destination. All filesystem traversal starts from the already
/// authorized, pinned parent directory descriptor.
final class CrossProcessDownloadNamespaceLock: @unchecked Sendable {
    static let rootEntryName = ".droidmatch-download-locks"
    static let identityEntryName = ".droidmatch-download-lock-root"

    private static let bindingMagic = Data("DMLOCK01".utf8)
    private static let bindingSize = 40
    private static let hashDomain = Data("DroidMatch download namespace lock v1\0".utf8)

    private let stateLock = NSLock()
    private var anchorDescriptor: Int32?
    private var rootDescriptor: Int32?
    private var lockDescriptors: [Int32]

    private init(
        anchorDescriptor: Int32,
        rootDescriptor: Int32,
        lockDescriptors: [Int32]
    ) {
        self.anchorDescriptor = anchorDescriptor
        self.rootDescriptor = rootDescriptor
        self.lockDescriptors = lockDescriptors
    }

    deinit { release() }

    static func normalizeEntryName(_ value: String, caseSensitive: Bool) -> String {
        let canonical = value.precomposedStringWithCanonicalMapping
        guard !caseSensitive else { return canonical }
        return canonical.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func lockEntryName(forNormalizedEntryName name: String) -> String {
        var input = hashDomain
        input.append(contentsOf: name.utf8)
        let digest = SHA256.hash(data: input)
        return "v1-" + digest.map { String(format: "%02x", $0) }.joined() + ".lock"
    }

    static func conflictsWithInfrastructure(
        normalizedEntryNames: Set<String>,
        caseSensitive: Bool
    ) -> Bool {
        let infrastructure = Set([
            rootEntryName,
            identityEntryName,
            PrivateAtomicFileTransactionLock.entryName,
        ].map {
            normalizeEntryName($0, caseSensitive: caseSensitive)
        })
        return !normalizedEntryNames.isDisjoint(with: infrastructure)
    }

    static func acquire(
        directoryContext: LocalDownloadDirectoryContext,
        normalizedEntryNames: Set<String>
    ) throws -> CrossProcessDownloadNamespaceLock {
        guard !normalizedEntryNames.isEmpty else {
            throw AtomicDownloadWriterError.invalidDestination
        }
        let parentDescriptor: Int32
        do {
            parentDescriptor = try directoryContext.duplicateDescriptor()
        } catch {
            throw AtomicDownloadWriterError.unsafeDestinationDirectory
        }
        defer { Darwin.close(parentDescriptor) }

        var anchorDescriptor: Int32?
        var rootDescriptor: Int32?
        var lockDescriptors: [Int32] = []
        do {
            let parentMetadata = try directoryMetadata(descriptor: parentDescriptor)
            guard LocalDirectoryIdentity(parentMetadata) == directoryContext.directoryIdentity else {
                throw LockError.unsafe
            }
            let openedAnchor = try openAnchor(parentDescriptor: parentDescriptor)
            anchorDescriptor = openedAnchor.descriptor
            let openedRoot = try openBoundRoot(
                parentDescriptor: parentDescriptor,
                parentIdentity: directoryContext.directoryIdentity,
                anchorDescriptor: openedAnchor.descriptor,
                anchorWasCreated: openedAnchor.created
            )
            rootDescriptor = openedRoot

            var createdLockEntry = false
            for name in normalizedEntryNames
                .map(lockEntryName(forNormalizedEntryName:))
                .sorted() {
                let opened = try openAndLockEntry(
                    rootDescriptor: openedRoot,
                    name: name
                )
                createdLockEntry = createdLockEntry || opened.created
                lockDescriptors.append(opened.descriptor)
            }
            if createdLockEntry, Darwin.fsync(openedRoot) != 0 {
                throw LockError.unsafe
            }
            try validateBoundInfrastructure(
                parentDescriptor: parentDescriptor,
                parentIdentity: directoryContext.directoryIdentity,
                anchorDescriptor: openedAnchor.descriptor,
                rootDescriptor: openedRoot
            )

            anchorDescriptor = nil
            rootDescriptor = nil
            let result = CrossProcessDownloadNamespaceLock(
                anchorDescriptor: openedAnchor.descriptor,
                rootDescriptor: openedRoot,
                lockDescriptors: lockDescriptors
            )
            lockDescriptors.removeAll(keepingCapacity: false)
            return result
        } catch LockError.busy {
            closeAll(
                anchorDescriptor: anchorDescriptor,
                rootDescriptor: rootDescriptor,
                lockDescriptors: lockDescriptors
            )
            throw AtomicDownloadWriterError.destinationBusy
        } catch {
            closeAll(
                anchorDescriptor: anchorDescriptor,
                rootDescriptor: rootDescriptor,
                lockDescriptors: lockDescriptors
            )
            throw AtomicDownloadWriterError.unsafeDestinationDirectory
        }
    }

    func release() {
        stateLock.lock()
        let anchorDescriptor = anchorDescriptor
        let rootDescriptor = rootDescriptor
        let lockDescriptors = lockDescriptors
        self.anchorDescriptor = nil
        self.rootDescriptor = nil
        self.lockDescriptors = []
        stateLock.unlock()

        // Never unlink these persistent files. Removing a locked inode would
        // let another process create and lock a replacement name, splitting the
        // reservation. Each previously unseen destination can leave up to seven
        // empty private inodes; this deliberate space tradeoff keeps crash reuse
        // safe until an anchor-wide, cross-process GC can be proven race-free.
        for descriptor in lockDescriptors.reversed() {
            _ = droidMatchNamespaceFlock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        if let rootDescriptor { Darwin.close(rootDescriptor) }
        if let anchorDescriptor {
            _ = droidMatchNamespaceFlock(anchorDescriptor, LOCK_UN)
            Darwin.close(anchorDescriptor)
        }
    }

    private struct OpenedAnchor {
        let descriptor: Int32
        let created: Bool
    }

    private struct OpenedLockEntry {
        let descriptor: Int32
        let created: Bool
    }

    private enum LockError: Error {
        case busy
        case unsafe
    }

    private static func openAnchor(parentDescriptor: Int32) throws -> OpenedAnchor {
        var descriptor = identityEntryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        var created = descriptor >= 0
        if descriptor < 0, errno == EEXIST {
            descriptor = identityEntryName.withCString {
                Darwin.openat(parentDescriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            created = false
        }
        guard descriptor >= 0 else { throw LockError.unsafe }
        do {
            if created, Darwin.fchmod(descriptor, mode_t(0o600)) != 0 {
                throw LockError.unsafe
            }
            let metadata = try anchorMetadata(descriptor: descriptor)
            guard metadata.st_size == 0 || metadata.st_size == bindingSize,
                  try namedEntryMatches(
                    directoryDescriptor: parentDescriptor,
                    name: identityEntryName,
                    opened: metadata,
                    validator: isSafeAnchor
                  ) else {
                throw LockError.unsafe
            }
            return OpenedAnchor(descriptor: descriptor, created: created)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openBoundRoot(
        parentDescriptor: Int32,
        parentIdentity: LocalDirectoryIdentity,
        anchorDescriptor: Int32,
        anchorWasCreated: Bool
    ) throws -> Int32 {
        if anchorWasCreated {
            try acquireFlock(anchorDescriptor, operation: LOCK_EX | LOCK_NB)
            return try initializeBinding(
                parentDescriptor: parentDescriptor,
                parentIdentity: parentIdentity,
                anchorDescriptor: anchorDescriptor
            )
        }

        try acquireFlock(anchorDescriptor, operation: LOCK_SH | LOCK_NB)
        var anchor = try anchorMetadata(descriptor: anchorDescriptor)
        if anchor.st_size == 0 {
            _ = droidMatchNamespaceFlock(anchorDescriptor, LOCK_UN)
            try acquireFlock(anchorDescriptor, operation: LOCK_EX | LOCK_NB)
            anchor = try anchorMetadata(descriptor: anchorDescriptor)
            guard anchor.st_size == 0 || anchor.st_size == bindingSize else {
                throw LockError.unsafe
            }
            if anchor.st_size == 0 {
                return try initializeBinding(
                    parentDescriptor: parentDescriptor,
                    parentIdentity: parentIdentity,
                    anchorDescriptor: anchorDescriptor
                )
            }
            try acquireFlock(anchorDescriptor, operation: LOCK_SH)
        }
        let binding = try readBinding(descriptor: anchorDescriptor)
        guard binding.parent == parentIdentity else { throw LockError.unsafe }
        let rootDescriptor = try openRoot(parentDescriptor: parentDescriptor, create: false)
        do {
            let root = try directoryMetadata(descriptor: rootDescriptor)
            guard LocalDirectoryIdentity(root) == binding.root else { throw LockError.unsafe }
            return rootDescriptor
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    private static func initializeBinding(
        parentDescriptor: Int32,
        parentIdentity: LocalDirectoryIdentity,
        anchorDescriptor: Int32
    ) throws -> Int32 {
        let rootDescriptor = try openRoot(parentDescriptor: parentDescriptor, create: true)
        do {
            let rootIdentity = LocalDirectoryIdentity(
                try directoryMetadata(descriptor: rootDescriptor)
            )
            let binding = bindingData(parent: parentIdentity, root: rootIdentity)
            try writeAll(binding, descriptor: anchorDescriptor)
            guard Darwin.fsync(anchorDescriptor) == 0,
                  Darwin.fsync(parentDescriptor) == 0 else {
                throw LockError.unsafe
            }
            try acquireFlock(anchorDescriptor, operation: LOCK_SH)
            let persisted = try readBinding(descriptor: anchorDescriptor)
            guard persisted.parent == parentIdentity,
                  persisted.root == rootIdentity else {
                throw LockError.unsafe
            }
            return rootDescriptor
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    private static func openRoot(parentDescriptor: Int32, create: Bool) throws -> Int32 {
        var created = false
        if create {
            let result = rootEntryName.withCString {
                Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
            }
            if result == 0 {
                created = true
            } else if errno != EEXIST {
                throw LockError.unsafe
            }
        }
        let descriptor = rootEntryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw LockError.unsafe }
        do {
            if created, Darwin.fchmod(descriptor, mode_t(0o700)) != 0 {
                throw LockError.unsafe
            }
            let metadata = try directoryMetadata(descriptor: descriptor)
            guard isSafeRoot(metadata),
                  try namedEntryMatches(
                    directoryDescriptor: parentDescriptor,
                    name: rootEntryName,
                    opened: metadata,
                    validator: isSafeRoot
                  ) else {
                throw LockError.unsafe
            }
            if created, Darwin.fsync(descriptor) != 0 {
                throw LockError.unsafe
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openAndLockEntry(
        rootDescriptor: Int32,
        name: String
    ) throws -> OpenedLockEntry {
        var descriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        var created = descriptor >= 0
        if descriptor < 0, errno == EEXIST {
            descriptor = name.withCString {
                Darwin.openat(rootDescriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            created = false
        }
        guard descriptor >= 0 else { throw LockError.unsafe }
        do {
            if created, Darwin.fchmod(descriptor, mode_t(0o600)) != 0 {
                throw LockError.unsafe
            }
            var metadata = try lockMetadata(descriptor: descriptor)
            guard try namedEntryMatches(
                directoryDescriptor: rootDescriptor,
                name: name,
                opened: metadata,
                validator: isSafeLockEntry
            ) else {
                throw LockError.unsafe
            }
            try acquireFlock(descriptor, operation: LOCK_EX | LOCK_NB)
            metadata = try lockMetadata(descriptor: descriptor)
            guard try namedEntryMatches(
                directoryDescriptor: rootDescriptor,
                name: name,
                opened: metadata,
                validator: isSafeLockEntry
            ) else {
                throw LockError.unsafe
            }
            if created, Darwin.fsync(descriptor) != 0 { throw LockError.unsafe }
            return OpenedLockEntry(descriptor: descriptor, created: created)
        } catch {
            _ = droidMatchNamespaceFlock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateBoundInfrastructure(
        parentDescriptor: Int32,
        parentIdentity: LocalDirectoryIdentity,
        anchorDescriptor: Int32,
        rootDescriptor: Int32
    ) throws {
        let parent = try directoryMetadata(descriptor: parentDescriptor)
        let anchor = try anchorMetadata(descriptor: anchorDescriptor)
        let root = try directoryMetadata(descriptor: rootDescriptor)
        let binding = try readBinding(descriptor: anchorDescriptor)
        guard LocalDirectoryIdentity(parent) == parentIdentity,
              binding.parent == parentIdentity,
              binding.root == LocalDirectoryIdentity(root),
              try namedEntryMatches(
                directoryDescriptor: parentDescriptor,
                name: identityEntryName,
                opened: anchor,
                validator: isSafeAnchor
              ),
              try namedEntryMatches(
                directoryDescriptor: parentDescriptor,
                name: rootEntryName,
                opened: root,
                validator: isSafeRoot
              ) else {
            throw LockError.unsafe
        }
    }

    private static func acquireFlock(_ descriptor: Int32, operation: Int32) throws {
        guard droidMatchNamespaceFlock(descriptor, operation) == 0 else {
            let value = errno
            if value == EWOULDBLOCK || value == EAGAIN { throw LockError.busy }
            throw LockError.unsafe
        }
    }

    private static func anchorMetadata(descriptor: Int32) throws -> stat {
        let metadata = try metadata(descriptor: descriptor)
        guard isSafeAnchor(metadata) else { throw LockError.unsafe }
        return metadata
    }

    private static func lockMetadata(descriptor: Int32) throws -> stat {
        let metadata = try metadata(descriptor: descriptor)
        guard isSafeLockEntry(metadata) else { throw LockError.unsafe }
        return metadata
    }

    private static func directoryMetadata(descriptor: Int32) throws -> stat {
        let metadata = try metadata(descriptor: descriptor)
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw LockError.unsafe
        }
        return metadata
    }

    private static func metadata(descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw LockError.unsafe }
        return value
    }

    private static func namedEntryMatches(
        directoryDescriptor: Int32,
        name: String,
        opened: stat,
        validator: (stat) -> Bool
    ) throws -> Bool {
        var named = stat()
        let result = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw LockError.unsafe }
        return validator(named)
            && named.st_dev == opened.st_dev
            && named.st_ino == opened.st_ino
            && named.st_mode == opened.st_mode
            && named.st_nlink == opened.st_nlink
            && named.st_uid == opened.st_uid
            && named.st_gid == opened.st_gid
            && named.st_size == opened.st_size
    }

    private static func isSafeAnchor(_ metadata: stat) -> Bool {
        isPrivateRegularSingleLink(metadata)
            && (metadata.st_size == 0 || metadata.st_size == bindingSize)
    }

    private static func isSafeLockEntry(_ metadata: stat) -> Bool {
        isPrivateRegularSingleLink(metadata) && metadata.st_size == 0
    }

    private static func isPrivateRegularSingleLink(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_nlink == 1
            && metadata.st_uid == geteuid()
            && hasExactPermissionBits(metadata.st_mode, expected: 0o600)
    }

    private static func isSafeRoot(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && metadata.st_uid == geteuid()
            && hasExactPermissionBits(metadata.st_mode, expected: 0o700)
    }

    static func hasExactPermissionBits(_ mode: mode_t, expected: mode_t) -> Bool {
        mode & mode_t(0o7777) == expected
    }

    private static func bindingData(
        parent: LocalDirectoryIdentity,
        root: LocalDirectoryIdentity
    ) -> Data {
        var data = bindingMagic
        for value in [parent.device, parent.inode, root.device, root.inode] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func readBinding(
        descriptor: Int32
    ) throws -> (parent: LocalDirectoryIdentity, root: LocalDirectoryIdentity) {
        let bytes = try readExact(descriptor: descriptor, count: bindingSize)
        guard bytes.prefix(bindingMagic.count) == bindingMagic else {
            throw LockError.unsafe
        }
        var values: [UInt64] = []
        var offset = bindingMagic.count
        for _ in 0..<4 {
            let end = offset + MemoryLayout<UInt64>.size
            guard end <= bytes.count else { throw LockError.unsafe }
            let value = bytes[offset..<end].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            values.append(value)
            offset = end
        }
        guard values.count == 4 else { throw LockError.unsafe }
        return (
            LocalDirectoryIdentity(device: values[0], inode: values[1]),
            LocalDirectoryIdentity(device: values[2], inode: values[3])
        )
    }

    private static func readExact(descriptor: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var completed = 0
        while completed < count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: completed),
                    count - completed,
                    off_t(completed)
                )
            }
            if result > 0 {
                completed += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw LockError.unsafe
            }
        }
        var extra: UInt8 = 0
        let extraCount = Darwin.pread(descriptor, &extra, 1, off_t(count))
        guard extraCount == 0 else { throw LockError.unsafe }
        return Data(bytes)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var completed = 0
            while completed < buffer.count {
                let result = Darwin.pwrite(
                    descriptor,
                    base.advanced(by: completed),
                    buffer.count - completed,
                    off_t(completed)
                )
                if result > 0 {
                    completed += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw LockError.unsafe
                }
            }
        }
        guard Darwin.ftruncate(descriptor, off_t(data.count)) == 0 else {
            throw LockError.unsafe
        }
    }

    private static func closeAll(
        anchorDescriptor: Int32?,
        rootDescriptor: Int32?,
        lockDescriptors: [Int32]
    ) {
        for descriptor in lockDescriptors.reversed() {
            _ = droidMatchNamespaceFlock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        if let rootDescriptor { Darwin.close(rootDescriptor) }
        if let anchorDescriptor {
            _ = droidMatchNamespaceFlock(anchorDescriptor, LOCK_UN)
            Darwin.close(anchorDescriptor)
        }
    }
}
