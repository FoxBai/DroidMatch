import Dispatch
import Foundation

public enum TransferQueuePersistenceStoreError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidLocation
    case invalidData
    case unsupportedSchemaVersion(Int)
    case ioFailure

    public var description: String {
        switch self {
        case .invalidLocation:
            return "transfer queue persistence location is invalid"
        case .invalidData:
            return "transfer queue persistence data is invalid"
        case let .unsupportedSchemaVersion(version):
            return "transfer queue persistence schema version is unsupported: \(version)"
        case .ioFailure:
            return "transfer queue persistence I/O failed"
        }
    }
}

public enum AsyncTransferQueuePersistenceStatus: String, Sendable, Equatable {
    case disabled
    case healthy
    case writeFailed
}

enum PersistedTransferJobState: String, Codable, Sendable {
    case queued
    case paused
    /// The executor was live when this manifest snapshot was committed.
    case active
    /// Unsafe-to-replay work remains visible until the user removes it.
    case interrupted
}

private enum PersistedTransferRequestKind: String, Codable, Sendable {
    case download
    case upload
}

private struct PersistedRecoveryPolicy: Codable, Equatable, Sendable {
    let maxAttempts: Int
    let baseDelayMs: Int64
    let maxDelayMs: Int64
    let jitterFactor: Double

    init(_ policy: RecoveryPolicy) {
        maxAttempts = policy.maxAttempts
        baseDelayMs = policy.baseDelayMs
        maxDelayMs = policy.maxDelayMs
        jitterFactor = policy.jitterFactor
    }

    func value() throws -> RecoveryPolicy {
        guard maxAttempts >= 0,
              baseDelayMs >= 0,
              maxDelayMs >= 0,
              jitterFactor.isFinite,
              jitterFactor >= 0,
              jitterFactor <= 1 else {
            throw TransferQueuePersistenceStoreError.invalidData
        }
        return RecoveryPolicy(
            maxAttempts: maxAttempts,
            baseDelayMs: baseDelayMs,
            maxDelayMs: maxDelayMs,
            jitterFactor: jitterFactor
        )
    }
}

struct PersistedTransferRequest: Codable, Equatable, Sendable {
    private let kind: PersistedTransferRequestKind
    private let source: String
    private let destination: String
    private let resume: Bool
    private let transferID: String
    private let preferredChunkSizeBytes: UInt32
    private let recoveryPolicy: PersistedRecoveryPolicy

    init(_ request: AsyncTransferJobRequest) {
        switch request {
        case let .download(value):
            kind = .download
            source = value.sourcePath
            destination = value.destinationURL.path
            resume = value.resume
            transferID = value.freshTransferID
            preferredChunkSizeBytes = value.preferredChunkSizeBytes
            recoveryPolicy = PersistedRecoveryPolicy(value.recoveryPolicy)
        case let .upload(value):
            kind = .upload
            source = value.sourceURL.path
            destination = value.destinationPath
            resume = value.resume
            transferID = value.freshTransferID
            preferredChunkSizeBytes = value.preferredChunkSizeBytes
            recoveryPolicy = PersistedRecoveryPolicy(value.recoveryPolicy)
        }
    }

    func value() throws -> AsyncTransferJobRequest {
        guard !source.isEmpty,
              !destination.isEmpty,
              !transferID.isEmpty,
              preferredChunkSizeBytes > 0 else {
            throw TransferQueuePersistenceStoreError.invalidData
        }
        let policy = try recoveryPolicy.value()
        switch kind {
        case .download:
            guard source.hasPrefix("dm://"), Self.isAbsoluteLocalPath(destination) else {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            return .download(AsyncDownloadCoordinatorRequest(
                sourcePath: source,
                destinationURL: URL(fileURLWithPath: destination),
                resume: resume,
                freshTransferID: transferID,
                preferredChunkSizeBytes: preferredChunkSizeBytes,
                recoveryPolicy: policy
            ))
        case .upload:
            guard Self.isAbsoluteLocalPath(source), destination.hasPrefix("dm://") else {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            return .upload(AsyncUploadCoordinatorRequest(
                sourceURL: URL(fileURLWithPath: source),
                destinationPath: destination,
                resume: resume,
                freshTransferID: transferID,
                preferredChunkSizeBytes: preferredChunkSizeBytes,
                recoveryPolicy: policy
            ))
        }
    }

    private static func isAbsoluteLocalPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).path == path && path.hasPrefix("/")
    }
}

struct PersistedTransferJob: Codable, Equatable, Sendable {
    let id: UUID
    let sequence: UInt64
    let request: PersistedTransferRequest
    let state: PersistedTransferJobState
    let attemptNumber: Int
    let attemptBase: Int
    let resumeAttemptBase: Int?
    let pauseRequiresResume: Bool
}

struct PersistedTransferQueue: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobs: [PersistedTransferJob]

    init(jobs: [PersistedTransferJob]) {
        schemaVersion = Self.currentSchemaVersion
        self.jobs = jobs
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TransferQueuePersistenceStoreError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard Set(jobs.map(\.id)).count == jobs.count,
              Set(jobs.map(\.sequence)).count == jobs.count,
              jobs.allSatisfy({ job in
                  let validResumeBase = job.resumeAttemptBase.map {
                      $0 >= job.attemptBase && $0 <= job.attemptNumber
                  } ?? true
                  return job.sequence < UInt64.max
                      && job.attemptNumber > job.attemptBase
                      && job.attemptBase >= 0
                      && validResumeBase
              }) else {
            throw TransferQueuePersistenceStoreError.invalidData
        }
        for job in jobs {
            _ = try job.request.value()
        }
    }
}

/// Atomic, permission-bounded storage for the product transfer queue manifest.
///
/// The caller chooses the file URL so a future app target can place it in its
/// own container. Local paths are recovery data and never appear in public
/// errors; directories created by this store use 0700 and the manifest itself
/// always uses 0600. Existing parent-directory permissions are never changed.
public final class TransferQueuePersistenceStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(
        label: "app.droidmatch.transfer-queue-persistence"
    )

    public init(fileURL: URL, fileManager: FileManager = .default) throws {
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              !fileURL.lastPathComponent.isEmpty else {
            throw TransferQueuePersistenceStoreError.invalidLocation
        }
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> PersistedTransferQueue {
        try queue.sync {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return PersistedTransferQueue(jobs: [])
            }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                      let permissions,
                      permissions & 0o077 == 0,
                      permissions & 0o600 == 0o600 else {
                    throw TransferQueuePersistenceStoreError.invalidLocation
                }
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let manifest = try JSONDecoder().decode(
                    PersistedTransferQueue.self,
                    from: data
                )
                try manifest.validate()
                return manifest
            } catch let error as TransferQueuePersistenceStoreError {
                throw error
            } catch is DecodingError {
                throw TransferQueuePersistenceStoreError.invalidData
            } catch {
                throw TransferQueuePersistenceStoreError.ioFailure
            }
        }
    }

    func save(_ manifest: PersistedTransferQueue) throws {
        try queue.sync {
            do {
                try manifest.validate()
                let directoryURL = fileURL.deletingLastPathComponent()
                var isDirectory: ObjCBool = false
                let directoryExists = fileManager.fileExists(
                    atPath: directoryURL.path,
                    isDirectory: &isDirectory
                )
                if directoryExists {
                    let attributes = try fileManager.attributesOfItem(
                        atPath: directoryURL.path
                    )
                    guard isDirectory.boolValue,
                          attributes[.type] as? FileAttributeType
                              != .typeSymbolicLink else {
                        throw TransferQueuePersistenceStoreError.invalidLocation
                    }
                }
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )

                if manifest.jobs.isEmpty {
                    if fileManager.fileExists(atPath: fileURL.path) {
                        try fileManager.removeItem(at: fileURL)
                    }
                    return
                }

                if fileManager.fileExists(atPath: fileURL.path) {
                    let attributes = try fileManager.attributesOfItem(
                        atPath: fileURL.path
                    )
                    guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                        throw TransferQueuePersistenceStoreError.invalidLocation
                    }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(manifest).write(to: fileURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: fileURL.path
                )
            } catch let error as TransferQueuePersistenceStoreError {
                throw error
            } catch is EncodingError {
                throw TransferQueuePersistenceStoreError.invalidData
            } catch {
                throw TransferQueuePersistenceStoreError.ioFailure
            }
        }
    }
}
