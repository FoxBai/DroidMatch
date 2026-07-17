import Darwin
import Foundation

public struct LocalDirectoryIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(bitPattern: Int64(metadata.st_dev))
        inode = UInt64(bitPattern: Int64(metadata.st_ino))
    }

    init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public protocol LocalDownloadDestinationLease: LocalFileAccessLease {
    var directoryIdentity: LocalDirectoryIdentity { get }
}

/// Opaque capability for one already-authorized destination directory.
/// Raw descriptors never cross this boundary; each consumer receives a
/// close-on-exec duplicate and performs only fixed-name relative operations.
public final class LocalDownloadDirectoryContext: @unchecked Sendable {
    public let directoryIdentity: LocalDirectoryIdentity
    public let resolvedDestinationURL: URL

    private let lock = NSLock()
    private var descriptor: Int32?

    init(
        descriptor: Int32,
        directoryIdentity: LocalDirectoryIdentity,
        resolvedDestinationURL: URL
    ) {
        self.descriptor = descriptor
        self.directoryIdentity = directoryIdentity
        self.resolvedDestinationURL = resolvedDestinationURL
    }

    deinit {
        lock.lock()
        let descriptor = descriptor
        self.descriptor = nil
        lock.unlock()
        if let descriptor { Darwin.close(descriptor) }
    }

    package func duplicateDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { throw AtomicDownloadWriterError.closed }
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return duplicate
    }
}

package protocol LocalDownloadDirectoryContextProviding:
    LocalDownloadDestinationLease
{
    var directoryContext: LocalDownloadDirectoryContext? { get }
}

struct DownloadDestinationNamespace: Sendable, Hashable {
    let parentPath: String
    let entryNames: Set<String>

    static func lexical(for destinationURL: URL) -> Self? {
        let destination = destinationURL.standardizedFileURL
        let name = destination.lastPathComponent
        let infrastructureNames = Set([
            CrossProcessDownloadNamespaceLock.rootEntryName,
            CrossProcessDownloadNamespaceLock.identityEntryName,
            PrivateAtomicFileTransactionLock.entryName,
        ].map(conservativeName))
        let reservedNames = Set(reservedEntryNames(destinationName: name).map(
            conservativeName
        ))
        let parentComponents = destination.deletingLastPathComponent()
            .pathComponents.map(conservativeName)
        guard destination.isFileURL,
              destination.path.hasPrefix("/"),
              !name.isEmpty,
              name != ".",
              name != "..",
              !name.utf8.contains(0),
              reservedNames.isDisjoint(with: infrastructureNames),
              Set(parentComponents).isDisjoint(with: infrastructureNames) else {
            return nil
        }
        let parent = SafeDirectoryDescriptor.canonicalSystemAliasURL(
            destination.deletingLastPathComponent()
        ).path
        return Self(
            parentPath: conservativeName(parent),
            entryNames: reservedNames
        )
    }

    func conflicts(with other: Self) -> Bool {
        parentPath == other.parentPath && !entryNames.isDisjoint(with: other.entryNames)
    }

    static func reservedEntryNames(destinationName: String) -> Set<String> {
        let partial = destinationName + ".droidmatch-part"
        let sidecar = destinationName + ".droidmatch-transfer.json"
        let commitMarker = ".\(destinationName).droidmatch-commit"
        let displacedDestination = ".\(destinationName).droidmatch-replaced"
        return [
            destinationName,
            partial,
            sidecar,
            ".\(sidecar).pending",
            ".\(sidecar).removing",
            commitMarker,
            displacedDestination,
        ]
    }

    private static func conservativeName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct PhysicalDownloadDestinationNamespace: Sendable {
    let directoryIdentity: LocalDirectoryIdentity
    let entryNames: Set<String>

    func conflicts(with other: Self) -> Bool {
        directoryIdentity == other.directoryIdentity
            && !entryNames.isDisjoint(with: other.entryNames)
    }
}

private final class DownloadDestinationReservationRegistry: @unchecked Sendable {
    static let shared = DownloadDestinationReservationRegistry()

    private let lock = NSLock()
    private var reservations: [UUID: PhysicalDownloadDestinationNamespace] = [:]

    func acquire(_ namespace: PhysicalDownloadDestinationNamespace) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard !reservations.values.contains(where: { $0.conflicts(with: namespace) }) else {
            throw AtomicDownloadWriterError.destinationBusy
        }
        let token = UUID()
        reservations[token] = namespace
        return token
    }

    func release(_ token: UUID) {
        lock.lock()
        reservations.removeValue(forKey: token)
        lock.unlock()
    }
}

private final class ProcessLocalDownloadDestinationLease:
    LocalDownloadDestinationLease,
    LocalDownloadDirectoryContextProviding,
    @unchecked Sendable
{
    let directoryIdentity: LocalDirectoryIdentity

    private let lock = NSLock()
    private var token: UUID?
    private var context: LocalDownloadDirectoryContext?
    private var namespaceLock: CrossProcessDownloadNamespaceLock?
    private var accessLease: (any LocalFileAccessLease)?

    var directoryContext: LocalDownloadDirectoryContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    init(
        token: UUID,
        context: LocalDownloadDirectoryContext,
        namespaceLock: CrossProcessDownloadNamespaceLock,
        directoryIdentity: LocalDirectoryIdentity,
        accessLease: any LocalFileAccessLease
    ) {
        self.token = token
        self.context = context
        self.namespaceLock = namespaceLock
        self.directoryIdentity = directoryIdentity
        self.accessLease = accessLease
    }

    deinit { release() }

    func release() {
        lock.lock()
        let token = token
        let context = context
        let namespaceLock = namespaceLock
        let accessLease = accessLease
        self.token = nil
        self.context = nil
        self.namespaceLock = nil
        self.accessLease = nil
        lock.unlock()

        namespaceLock?.release()
        if let token {
            DownloadDestinationReservationRegistry.shared.release(token)
        }
        withExtendedLifetime(context) {}
        accessLease?.release()
    }
}

package enum DownloadDestinationReservation {
    private struct PreparedContext {
        let context: LocalDownloadDirectoryContext
        let caseSensitive: Bool
    }

    package static func contextForRestore(
        destinationURL: URL,
        accessLease: any LocalFileAccessLease
    ) throws -> LocalDownloadDirectoryContext {
        try prepareContext(
            destinationURL: destinationURL,
            accessLease: accessLease,
            createIntermediateDirectories: false
        ).context
    }

    static func acquire(
        destinationURL: URL,
        accessLease: any LocalFileAccessLease
    ) throws -> any LocalDownloadDestinationLease {
        guard DownloadDestinationNamespace.lexical(for: destinationURL) != nil else {
            accessLease.release()
            throw AtomicDownloadWriterError.invalidDestination
        }
        do {
            let prepared = try prepareContext(
                destinationURL: destinationURL,
                accessLease: accessLease,
                createIntermediateDirectories: true
            )
            let destinationName = destinationURL.standardizedFileURL.lastPathComponent
            let normalizedNames = Set(
                DownloadDestinationNamespace.reservedEntryNames(
                    destinationName: destinationName
                ).map {
                    CrossProcessDownloadNamespaceLock.normalizeEntryName(
                        $0,
                        caseSensitive: prepared.caseSensitive
                    )
                }
            )
            guard !CrossProcessDownloadNamespaceLock.conflictsWithInfrastructure(
                normalizedEntryNames: normalizedNames,
                caseSensitive: prepared.caseSensitive
            ) else {
                throw AtomicDownloadWriterError.invalidDestination
            }
            let token = try DownloadDestinationReservationRegistry.shared.acquire(
                PhysicalDownloadDestinationNamespace(
                    directoryIdentity: prepared.context.directoryIdentity,
                    entryNames: normalizedNames
                )
            )
            do {
                let namespaceLock = try CrossProcessDownloadNamespaceLock.acquire(
                    directoryContext: prepared.context,
                    normalizedEntryNames: normalizedNames
                )
                return ProcessLocalDownloadDestinationLease(
                    token: token,
                    context: prepared.context,
                    namespaceLock: namespaceLock,
                    directoryIdentity: prepared.context.directoryIdentity,
                    accessLease: accessLease
                )
            } catch {
                DownloadDestinationReservationRegistry.shared.release(token)
                throw error
            }
        } catch {
            accessLease.release()
            throw error
        }
    }

    private static func prepareContext(
        destinationURL: URL,
        accessLease: any LocalFileAccessLease,
        createIntermediateDirectories: Bool
    ) throws -> PreparedContext {
        let original = destinationURL.standardizedFileURL
        guard original.isFileURL,
              original.path.hasPrefix("/"),
              !original.lastPathComponent.isEmpty else {
            throw AtomicDownloadWriterError.invalidDestination
        }
        let requestedParent: URL
        if let resolvedLease = accessLease as? any ResolvedLocalFileAccessLease {
            guard let resolvedParent = resolvedLease.resolvedAccessURL else {
                throw AtomicDownloadWriterError.invalidDestination
            }
            requestedParent = resolvedParent
        } else {
            requestedParent = original.deletingLastPathComponent()
        }
        let resolvedDestination = requestedParent.appendingPathComponent(
            original.lastPathComponent,
            isDirectory: false
        ).standardizedFileURL
        guard DownloadDestinationNamespace.lexical(for: resolvedDestination) != nil else {
            // Bookmark resolution is an authorization boundary, not a trusted
            // path substitution. Reapply every reserved-infrastructure check
            // to the exact resolved parent/target pair before opening or
            // creating anything below it.
            throw AtomicDownloadWriterError.invalidDestination
        }
        let parent = resolvedDestination.deletingLastPathComponent()
        let descriptor: Int32
        do {
            descriptor = try SafeDirectoryDescriptor.openAbsolute(
                parent,
                createIntermediateDirectories: createIntermediateDirectories
            )
        } catch is SafeDirectoryDescriptorError {
            throw AtomicDownloadWriterError.unsafeDestinationDirectory
        }
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw AtomicDownloadWriterError.unsafeDestinationDirectory
            }
            errno = 0
            let caseSensitivity = Darwin.fpathconf(descriptor, _PC_CASE_SENSITIVE)
            guard caseSensitivity == 0 || caseSensitivity == 1 else {
                throw AtomicDownloadWriterError.unsafeDestinationDirectory
            }
            let context = LocalDownloadDirectoryContext(
                descriptor: descriptor,
                directoryIdentity: LocalDirectoryIdentity(metadata),
                resolvedDestinationURL: resolvedDestination
            )
            return PreparedContext(
                context: context,
                caseSensitive: caseSensitivity == 1
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
