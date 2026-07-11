import DroidMatchCore
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

/// Private App-owned bookmark registry keyed by the exact transfer endpoint.
///
/// Downloads bookmark their selected parent directory; uploads bookmark their
/// selected file. Core asks only for a lease on the endpoint URL and never sees
/// bookmark bytes. Stale bookmarks are refreshed before execution continues.
public actor SecurityScopedBookmarkStore: LocalFileAccessProviding {
    private struct Archive: Codable {
        static let currentVersion = 1
        let version: Int
        var records: [String: Data]
    }

    private let fileURL: URL
    private let codec: any SecurityScopedBookmarkCoding
    private var records: [String: Data]
    private var persistenceHealthy = true

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
        records = try Self.load(fileURL: fileURL)
    }

    public func register(targetURL: URL, authorizationURL: URL) throws {
        guard targetURL.isFileURL, authorizationURL.isFileURL else {
            throw SecurityScopedBookmarkStoreError.invalidLocation
        }
        do {
            let data = try codec.create(for: authorizationURL)
            var updated = records
            updated[targetURL.standardizedFileURL.path] = data
            try persist(updated)
        } catch let error as SecurityScopedBookmarkStoreError {
            throw error
        } catch {
            throw SecurityScopedBookmarkStoreError.unavailable
        }
    }

    public func remove(targetURL: URL) throws {
        var updated = records
        updated.removeValue(forKey: targetURL.standardizedFileURL.path)
        try persist(updated)
    }

    public func retainOnly(targetURLs: Set<URL>) throws {
        let retained = Set(targetURLs.map { $0.standardizedFileURL.path })
        try persist(records.filter { retained.contains($0.key) })
    }

    public func isPersistenceHealthy() -> Bool {
        persistenceHealthy
    }

    /// Verifies that the last durable registry can still be written. Failed
    /// mutations are rolled back, so their authorization must be resubmitted.
    public func retryPersistence() -> Bool {
        do {
            try save(records)
            persistenceHealthy = true
            return true
        } catch {
            persistenceHealthy = false
            return false
        }
    }

    public func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        let key = url.standardizedFileURL.path
        guard let data = records[key] else {
            throw SecurityScopedBookmarkStoreError.missingAuthorization
        }
        do {
            let resolved = try codec.resolve(data)
            if resolved.isStale {
                var updated = records
                updated[key] = try codec.create(for: resolved.url)
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

    private static func load(fileURL: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  let permissions,
                  permissions & 0o077 == 0,
                  permissions & 0o600 == 0o600 else {
                throw SecurityScopedBookmarkStoreError.invalidLocation
            }
            let archive = try JSONDecoder().decode(
                Archive.self,
                from: Data(contentsOf: fileURL, options: .mappedIfSafe)
            )
            guard archive.version == Archive.currentVersion else {
                throw SecurityScopedBookmarkStoreError.unavailable
            }
            return archive.records
        } catch let error as SecurityScopedBookmarkStoreError {
            throw error
        } catch {
            throw SecurityScopedBookmarkStoreError.unavailable
        }
    }

    private func persist(_ updated: [String: Data]) throws {
        do {
            try save(updated)
            records = updated
            persistenceHealthy = true
        } catch {
            persistenceHealthy = false
            throw error
        }
    }

    private func save(_ records: [String: Data]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard isDirectory.boolValue,
                      attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw SecurityScopedBookmarkStoreError.invalidLocation
                }
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            if records.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return
            }
            let archive = Archive(version: Archive.currentVersion, records: records)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw SecurityScopedBookmarkStoreError.invalidLocation
                }
            }
            try PrivateAtomicFileWriter.write(
                try JSONEncoder().encode(archive),
                to: fileURL
            )
        } catch let error as SecurityScopedBookmarkStoreError {
            throw error
        } catch {
            throw SecurityScopedBookmarkStoreError.unavailable
        }
    }
}

private final class SecurityScopedBookmarkLease: LocalFileAccessLease, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private let codec: any SecurityScopedBookmarkCoding

    init(url: URL, codec: any SecurityScopedBookmarkCoding) {
        self.url = url
        self.codec = codec
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
