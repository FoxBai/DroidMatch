@_spi(DroidMatchAppSupport) import DroidMatchCore
import Darwin
import Foundation

public enum SecurityScopedBookmarkStoreError: Error, Sendable, Equatable {
    case invalidLocation
    case unavailable
    case missingAuthorization
    case accessDenied
}

protocol SecurityScopedBookmarkCoding: Sendable {
    func create(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SystemSecurityScopedBookmarkCodec: SecurityScopedBookmarkCoding {
    func create(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Private App-owned bookmark registry keyed by authenticated owner and exact
/// transfer endpoint.
///
/// Downloads bookmark their selected parent directory; uploads bookmark their
/// selected file. Core asks only for a lease on the endpoint URL and never sees
/// bookmark bytes. Stale bookmarks are refreshed in their original ownership
/// compartment before execution continues.
public actor SecurityScopedBookmarkStore {
    private struct ArchiveHeader: Decodable {
        let version: Int
    }

    private struct ArchiveV1: Codable {
        let version: Int
        var records: [String: Data]
    }

    private struct ArchiveV2: Codable {
        static let currentVersion = 2

        let version: Int
        var scopedRecords: [ScopedRecord]
        var legacyUnscopedRecords: [LegacyRecord]
    }

    private struct ScopedRecord: Codable {
        let owner: String
        let targetPath: String
        let bookmarkData: Data
    }

    private struct LegacyRecord: Codable {
        let targetPath: String
        let bookmarkData: Data
    }

    private struct ScopedKey: Hashable {
        let owner: String
        let targetPath: String
    }

    private struct Records {
        var scoped: [ScopedKey: Data] = [:]
        var legacyUnscoped: [String: Data] = [:]

        var isEmpty: Bool {
            scoped.isEmpty && legacyUnscoped.isEmpty
        }
    }

    private enum RecordLocation {
        case scoped(ScopedKey)
        case legacy(String)
    }

    private let fileURL: URL
    private let codec: any SecurityScopedBookmarkCoding
    private var records: Records
    private var persistenceHealthy = true
    private var requiresReload = false

    /// Opens the registry without destroying recoverable startup failures.
    /// Invalid URL shapes still throw; unreadable/corrupt durable state is held
    /// as unhealthy and may only be reloaded through `retryPersistence()`.
    public init(fileURL: URL) throws {
        try self.init(fileURL: fileURL, codec: SystemSecurityScopedBookmarkCodec())
    }

    init(fileURL: URL, codec: any SecurityScopedBookmarkCoding) throws {
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              !fileURL.lastPathComponent.isEmpty else {
            throw SecurityScopedBookmarkStoreError.invalidLocation
        }
        self.fileURL = fileURL
        self.codec = codec
        do {
            records = try Self.load(fileURL: fileURL)
        } catch {
            // Preserve unreadable/corrupt startup state for an explicit retry.
            // Mutations stay blocked so an empty in-memory map cannot overwrite
            // the last durable registry before an operator repairs its location.
            records = Records()
            persistenceHealthy = false
            requiresReload = true
        }
    }

    package func register(
        owner: LocalFileAccessOwnerID,
        targetURL: URL,
        authorizationURL: URL
    ) throws {
        guard !requiresReload else { throw SecurityScopedBookmarkStoreError.unavailable }
        guard targetURL.isFileURL,
              authorizationURL.isFileURL else {
            throw SecurityScopedBookmarkStoreError.invalidLocation
        }
        do {
            let data = try codec.create(for: authorizationURL)
            var updated = records
            updated.scoped[ScopedKey(
                owner: owner.storageKey,
                targetPath: targetURL.standardizedFileURL.path
            )] = data
            try persist(updated)
        } catch let error as SecurityScopedBookmarkStoreError {
            throw error
        } catch {
            throw SecurityScopedBookmarkStoreError.unavailable
        }
    }

    package func remove(owner: LocalFileAccessOwnerID, targetURL: URL) throws {
        guard !requiresReload else { throw SecurityScopedBookmarkStoreError.unavailable }
        var updated = records
        updated.scoped.removeValue(forKey: ScopedKey(
            owner: owner.storageKey,
            targetPath: targetURL.standardizedFileURL.path
        ))
        try persist(updated)
    }

    package func retainOnly(
        owner: LocalFileAccessOwnerID,
        targetURLs: Set<URL>
    ) throws {
        guard !requiresReload else { throw SecurityScopedBookmarkStoreError.unavailable }
        let retained = Set(targetURLs.map { $0.standardizedFileURL.path })
        var updated = records
        updated.scoped = updated.scoped.filter { key, _ in
            key.owner != owner.storageKey || retained.contains(key.targetPath)
        }
        try persist(updated)
    }

    public func isPersistenceHealthy() -> Bool {
        persistenceHealthy
    }

    package func isReadyForTransferExecution(
        owner: LocalFileAccessOwnerID,
        targetURLs: Set<URL>
    ) -> Bool {
        isReadyForTransferExecutionState && targetURLs.allSatisfy { targetURL in
            let path = targetURL.standardizedFileURL.path
            let scopedKey = ScopedKey(owner: owner.storageKey, targetPath: path)
            return records.scoped[scopedKey] != nil
                || records.legacyUnscoped[path] != nil
        }
    }

    /// Verifies that the last durable registry can still be written. Failed
    /// mutations are rolled back, so their authorization must be resubmitted.
    public func retryPersistence() -> Bool {
        do {
            if requiresReload {
                records = try Self.load(fileURL: fileURL)
                requiresReload = false
                persistenceHealthy = true
                return true
            }
            try save(records)
            persistenceHealthy = true
            return true
        } catch {
            persistenceHealthy = false
            return false
        }
    }

    private var isReadyForTransferExecutionState: Bool {
        persistenceHealthy && !requiresReload
    }

    package func acquireAccess(
        owner: LocalFileAccessOwnerID,
        to url: URL
    ) async throws -> any LocalFileAccessLease {
        guard !requiresReload else { throw SecurityScopedBookmarkStoreError.unavailable }
        let path = url.standardizedFileURL.path
        let scopedKey = ScopedKey(owner: owner.storageKey, targetPath: path)
        let selected: (data: Data, location: RecordLocation)?
        if let data = records.scoped[scopedKey] {
            // An owner-scoped record is authoritative. Resolution or access
            // failure must not silently resurrect a legacy authorization.
            selected = (data, .scoped(scopedKey))
        } else if let data = records.legacyUnscoped[path] {
            selected = (data, .legacy(path))
        } else {
            selected = nil
        }
        guard let selected else {
            throw SecurityScopedBookmarkStoreError.missingAuthorization
        }
        do {
            let resolved = try codec.resolve(selected.data)
            if resolved.isStale {
                var updated = records
                let refreshed = try codec.create(for: resolved.url)
                switch selected.location {
                case let .scoped(key):
                    updated.scoped[key] = refreshed
                case let .legacy(key):
                    updated.legacyUnscoped[key] = refreshed
                }
                try persist(updated)
            }
            guard codec.startAccessing(resolved.url) else {
                throw SecurityScopedBookmarkStoreError.accessDenied
            }
            return SecurityScopedBookmarkLease(url: resolved.url, codec: codec)
        } catch let error as SecurityScopedBookmarkStoreError {
            throw error
        } catch {
            throw SecurityScopedBookmarkStoreError.unavailable
        }
    }

    private static func load(fileURL: URL) throws -> Records {
        do {
            guard let data = try PrivateAtomicFileWriter
                .readRegularSingleLinkIfPresent(at: fileURL) else { return Records() }
            let decoder = JSONDecoder()
            let header = try decoder.decode(ArchiveHeader.self, from: data)
            switch header.version {
            case 1:
                let archive = try decoder.decode(ArchiveV1.self, from: data)
                // Ownership cannot be inferred from the historical path-only
                // archive. Preserve every record as legacy until a separately
                // verified migration policy can retire it.
                return Records(legacyUnscoped: archive.records)
            case ArchiveV2.currentVersion:
                return try decodeV2(decoder.decode(ArchiveV2.self, from: data))
            default:
                throw SecurityScopedBookmarkStoreError.unavailable
            }
        } catch PrivateAtomicFileWriterError.unsafeDestination {
            throw SecurityScopedBookmarkStoreError.invalidLocation
        } catch let error as SecurityScopedBookmarkStoreError {
            throw error
        } catch {
            throw SecurityScopedBookmarkStoreError.unavailable
        }
    }

    private static func decodeV2(_ archive: ArchiveV2) throws -> Records {
        var decoded = Records()
        for record in archive.scopedRecords {
            guard isValidOwnerStorageKey(record.owner),
                  isCanonicalTargetPath(record.targetPath) else {
                throw SecurityScopedBookmarkStoreError.unavailable
            }
            let key = ScopedKey(owner: record.owner, targetPath: record.targetPath)
            guard decoded.scoped.updateValue(record.bookmarkData, forKey: key) == nil else {
                throw SecurityScopedBookmarkStoreError.unavailable
            }
        }
        for record in archive.legacyUnscopedRecords {
            // Legacy keys are retained verbatim so a valid v1 archive can be
            // upgraded losslessly even if it predates current path validation.
            guard decoded.legacyUnscoped.updateValue(
                record.bookmarkData,
                forKey: record.targetPath
            ) == nil else {
                throw SecurityScopedBookmarkStoreError.unavailable
            }
        }
        return decoded
    }

    private static func isValidOwnerStorageKey(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isCanonicalTargetPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private func persist(_ updated: Records) throws {
        do {
            try save(updated)
            records = updated
            persistenceHealthy = true
        } catch {
            persistenceHealthy = false
            throw error
        }
    }

    private func save(_ records: Records) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            let directoryDescriptor: Int32
            do {
                directoryDescriptor = try SafeDirectoryDescriptor.openAbsolute(
                    directory,
                    createIntermediateDirectories: true,
                    creationMode: 0o700
                )
            } catch is SafeDirectoryDescriptorError {
                throw SecurityScopedBookmarkStoreError.invalidLocation
            }
            defer { Darwin.close(directoryDescriptor) }
            if records.isEmpty {
                try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(
                    at: fileURL
                )
                return
            }
            let archive = ArchiveV2(
                version: ArchiveV2.currentVersion,
                scopedRecords: records.scoped.map { key, data in
                    ScopedRecord(
                        owner: key.owner,
                        targetPath: key.targetPath,
                        bookmarkData: data
                    )
                }.sorted {
                    ($0.owner, $0.targetPath) < ($1.owner, $1.targetPath)
                },
                legacyUnscopedRecords: records.legacyUnscoped.map { path, data in
                    LegacyRecord(targetPath: path, bookmarkData: data)
                }.sorted { $0.targetPath < $1.targetPath }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PrivateAtomicFileWriter.write(try encoder.encode(archive), to: fileURL)
        } catch PrivateAtomicFileWriterError.unsafeDestination {
            throw SecurityScopedBookmarkStoreError.invalidLocation
        } catch let error as SecurityScopedBookmarkStoreError {
            throw error
        } catch {
            throw SecurityScopedBookmarkStoreError.unavailable
        }
    }
}

private final class SecurityScopedBookmarkLease:
    ResolvedLocalFileAccessLease,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var url: URL?
    private let codec: any SecurityScopedBookmarkCoding

    init(url: URL, codec: any SecurityScopedBookmarkCoding) {
        self.url = url
        self.codec = codec
    }

    var resolvedAccessURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    func release() {
        lock.lock()
        let releasedURL = url
        url = nil
        lock.unlock()
        if let releasedURL {
            codec.stopAccessing(releasedURL)
        }
    }

    deinit {
        release()
    }
}
