import Darwin
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
    /// Permanent cancellation is waiting for authenticated remote partial cleanup.
    case cleanupPending
}

struct PersistedUploadPartialIdentity: Codable, Equatable, Sendable {
    let transferID: String
    let destinationPath: String
    let expectedSizeBytes: Int64

    init(_ identity: AsyncUploadPartialIdentity) {
        transferID = identity.transferID
        destinationPath = identity.destinationPath
        expectedSizeBytes = identity.expectedSizeBytes
    }

    func value(for request: AsyncTransferJobRequest) throws -> AsyncUploadPartialIdentity {
        guard case let .upload(upload) = request else {
            throw TransferQueuePersistenceStoreError.invalidData
        }
        do {
            return try AsyncUploadPartialIdentity(
                transferID: transferID,
                destinationPath: destinationPath,
                expectedSizeBytes: expectedSizeBytes
            ).validated(for: upload)
        } catch {
            // A manifest is untrusted local input; do not expose coordinator or
            // protocol-layer errors across the persistence validation boundary.
            throw TransferQueuePersistenceStoreError.invalidData
        }
    }
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
              maxAttempts <= PersistedTransferQueue.maximumRecoveryAttempts,
              baseDelayMs >= 0,
              baseDelayMs <= PersistedTransferQueue.maximumRecoveryDelayMs,
              maxDelayMs >= 0,
              maxDelayMs <= PersistedTransferQueue.maximumRecoveryDelayMs,
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
    private let resumeRecordPath: String?

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
            resumeRecordPath = nil
        case let .upload(value):
            kind = .upload
            source = value.sourceURL.path
            destination = value.destinationPath
            resume = value.resume
            transferID = value.freshTransferID
            preferredChunkSizeBytes = value.preferredChunkSizeBytes
            recoveryPolicy = PersistedRecoveryPolicy(value.recoveryPolicy)
            resumeRecordPath = value.resumeRecordURL?.path
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
            guard Self.isAbsoluteLocalPath(source), destination.hasPrefix("dm://"),
                  resumeRecordPath.map(Self.isAbsoluteLocalPath) ?? true else {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            return .upload(AsyncUploadCoordinatorRequest(
                sourceURL: URL(fileURLWithPath: source),
                destinationPath: destination,
                resume: resume,
                freshTransferID: transferID,
                preferredChunkSizeBytes: preferredChunkSizeBytes,
                recoveryPolicy: policy,
                resumeRecordURL: resumeRecordPath.map(URL.init(fileURLWithPath:))
            ))
        }
    }

    private static func isAbsoluteLocalPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).path == path && path.hasPrefix("/")
    }

    func validateManagedResumeRecordLocation(under directoryURL: URL) throws {
        guard let resumeRecordPath else { return }
        let expectedDirectory = directoryURL
            .appendingPathComponent("UploadResumeRecords", isDirectory: true)
            .standardizedFileURL.path + "/"
        guard URL(fileURLWithPath: resumeRecordPath).standardizedFileURL.path
            .hasPrefix(expectedDirectory) else {
            throw TransferQueuePersistenceStoreError.invalidLocation
        }
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
    let uploadPartialIdentity: PersistedUploadPartialIdentity?
    /// Optional so schema-v1 manifests decode without manufacturing a value.
    let removeAfterUploadCleanup: Bool?

    init(
        id: UUID,
        sequence: UInt64,
        request: PersistedTransferRequest,
        state: PersistedTransferJobState,
        attemptNumber: Int,
        attemptBase: Int,
        resumeAttemptBase: Int?,
        pauseRequiresResume: Bool,
        uploadPartialIdentity: PersistedUploadPartialIdentity? = nil,
        removeAfterUploadCleanup: Bool = false
    ) {
        self.id = id
        self.sequence = sequence
        self.request = request
        self.state = state
        self.attemptNumber = attemptNumber
        self.attemptBase = attemptBase
        self.resumeAttemptBase = resumeAttemptBase
        self.pauseRequiresResume = pauseRequiresResume
        self.uploadPartialIdentity = uploadPartialIdentity
        self.removeAfterUploadCleanup = removeAfterUploadCleanup ? true : nil
    }
}

struct PersistedTransferQueue: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let maximumJobCount = 10_000
    // A manifest is untrusted recovery input, not an unbounded execution
    // request. These ceilings dwarf the documented one-retry/30-second
    // defaults while keeping restored arithmetic and scheduling finite.
    static let maximumAttemptNumber = AsyncTransferSchedulerPolicy.maximumAttemptNumber
    static let maximumRecoveryAttempts = 10_000
    static let maximumRecoveryDelayMs: Int64 = 86_400_000

    let schemaVersion: Int
    let jobs: [PersistedTransferJob]

    init(jobs: [PersistedTransferJob]) {
        schemaVersion = Self.currentSchemaVersion
        self.jobs = jobs
    }

    func validate() throws {
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw TransferQueuePersistenceStoreError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard jobs.count <= Self.maximumJobCount,
              Set(jobs.map(\.id)).count == jobs.count,
              Set(jobs.map(\.sequence)).count == jobs.count else {
            throw TransferQueuePersistenceStoreError.invalidData
        }
        for job in jobs {
            let request = try job.request.value()
            if schemaVersion == 1,
               job.uploadPartialIdentity != nil
                || job.state == .cleanupPending
                || job.removeAfterUploadCleanup == true {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            let partialIdentity = try job.uploadPartialIdentity?.value(for: request)
            if job.state == .cleanupPending, partialIdentity == nil {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            if job.state != .cleanupPending, job.removeAfterUploadCleanup == true {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            let validResumeBase = job.resumeAttemptBase.map { resumeBase in
                guard resumeBase >= job.attemptBase,
                      resumeBase <= job.attemptNumber else {
                    return false
                }
                guard job.state == .paused, job.pauseRequiresResume else {
                    return true
                }
                // A running pause has consumed the displayed attempt; a pause
                // during retry delay has only announced it. These are the only
                // two bases the runtime can persist. Accepting an older base
                // would roll cumulative accounting backwards before Resume.
                let previousAttempt = job.attemptNumber
                    .subtractingReportingOverflow(1)
                return resumeBase == job.attemptNumber
                    || (!previousAttempt.overflow
                        && resumeBase == previousAttempt.partialValue
                        && resumeBase > job.attemptBase)
            } ?? true
            let currentAttemptCount = job.attemptNumber.subtractingReportingOverflow(
                job.attemptBase
            )
            guard job.sequence < UInt64.max,
                  job.attemptBase >= 0,
                  !currentAttemptCount.overflow,
                  AsyncTransferSchedulerPolicy.checkedAttemptNumber(
                      attemptBase: job.attemptBase,
                      attemptCount: currentAttemptCount.partialValue
                  ) == job.attemptNumber,
                  validResumeBase else {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            if job.state != .interrupted,
               AsyncTransferSchedulerPolicy.checkedResultAttemptNumber(
                   attemptBase: job.attemptBase,
                   attemptCount: currentAttemptCount.partialValue,
                   for: request
               ) != job.attemptNumber {
                throw TransferQueuePersistenceStoreError.invalidData
            }

            let futureAttemptBase: Int?
            switch job.state {
            case .queued:
                guard AsyncTransferSchedulerPolicy.checkedAttemptNumber(
                    attemptBase: job.attemptBase,
                    attemptCount: 1
                ) == job.attemptNumber else {
                    throw TransferQueuePersistenceStoreError.invalidData
                }
                futureAttemptBase = job.attemptBase
            case .paused:
                if !job.pauseRequiresResume,
                   AsyncTransferSchedulerPolicy.checkedAttemptNumber(
                       attemptBase: job.attemptBase,
                       attemptCount: 1
                   ) != job.attemptNumber {
                    throw TransferQueuePersistenceStoreError.invalidData
                }
                futureAttemptBase = job.pauseRequiresResume
                    ? (job.resumeAttemptBase ?? job.attemptNumber)
                    : job.attemptBase
            case .active, .interrupted, .cleanupPending:
                // Active work never auto-replays. Restore separately proves
                // checkpoint and resume headroom before exposing a Resume action.
                futureAttemptBase = nil
            }
            if let futureAttemptBase,
               !AsyncTransferSchedulerPolicy.hasRecoveryHeadroom(
                   after: futureAttemptBase,
                   for: request
               ) {
                throw TransferQueuePersistenceStoreError.invalidData
            }
        }
    }
}

package enum TransferRestoreAccessTarget: Hashable, Sendable {
    case download(URL)
    case upload(URL)

    package var url: URL {
        switch self {
        case let .download(url), let .upload(url): return url
        }
    }
}

package struct ProductTransferRestorePlan: Sendable {
    let manifest: PersistedTransferQueue
    package let checkpointAccessTargets: Set<TransferRestoreAccessTarget>
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

    func managedUploadResumeRecordURL(transferID: String) -> URL? {
        guard UUID(uuidString: transferID) != nil else { return nil }
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("UploadResumeRecords", isDirectory: true)
            .appendingPathComponent("\(transferID).json", isDirectory: false)
    }

    func load() throws -> PersistedTransferQueue {
        try queue.sync {
            do {
                guard let data = try PrivateAtomicFileWriter
                    .readRegularSingleLinkIfPresent(at: fileURL) else {
                    return PersistedTransferQueue(jobs: [])
                }
                let manifest = try JSONDecoder().decode(
                    PersistedTransferQueue.self,
                    from: data
                )
                try manifest.validate()
                for job in manifest.jobs {
                    try job.request.validateManagedResumeRecordLocation(
                        under: fileURL.deletingLastPathComponent()
                    )
                }
                return manifest
            } catch PrivateAtomicFileWriterError.unsafeDestination {
                throw TransferQueuePersistenceStoreError.invalidLocation
            } catch let error as TransferQueuePersistenceStoreError {
                throw error
            } catch is DecodingError {
                throw TransferQueuePersistenceStoreError.invalidData
            } catch {
                throw TransferQueuePersistenceStoreError.ioFailure
            }
        }
    }

    func productRestorePlan() throws -> ProductTransferRestorePlan {
        let manifest = try load()
        let targetValues: [TransferRestoreAccessTarget] = try manifest.jobs.compactMap { job in
            let request = try job.request.value()
            if case let .upload(upload) = request,
               !Self.isValidProductUploadDestination(upload.destinationPath) {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            let requiresCheckpointAccess = job.state == .active
                || (job.state == .paused && job.pauseRequiresResume)
            guard requiresCheckpointAccess else { return nil }
            switch request {
            case let .download(request):
                return TransferRestoreAccessTarget.download(request.destinationURL)
            case let .upload(request):
                return TransferRestoreAccessTarget.upload(request.sourceURL)
            }
        }
        let targets = Set(targetValues)
        return ProductTransferRestorePlan(
            manifest: manifest,
            checkpointAccessTargets: targets
        )
    }

    /// Replays the product submission boundary for untrusted restored uploads.
    /// The generic persistence codec intentionally accepts future `dm://` shapes;
    /// only product restoration knows that this queue was created by the native
    /// file picker and must still match `ProductUploadDestination` exactly.
    private static func isValidProductUploadDestination(_ destinationPath: String) -> Bool {
        guard let separator = destinationPath.lastIndex(of: "/"),
              separator < destinationPath.index(before: destinationPath.endIndex) else {
            return false
        }
        let fileName = String(destinationPath[destinationPath.index(after: separator)...])
        let parent = String(destinationPath[..<separator])
        return [parent, parent + "/"].contains { directoryPath in
            ProductUploadDestination(
                directoryPath: directoryPath,
                fileName: fileName
            )?.path == destinationPath
        }
    }

    func save(_ manifest: PersistedTransferQueue) throws {
        try queue.sync {
            do {
                try manifest.validate()
                let directoryURL = fileURL.deletingLastPathComponent()
                for job in manifest.jobs {
                    try job.request.validateManagedResumeRecordLocation(under: directoryURL)
                }
                let directoryDescriptor: Int32
                do {
                    directoryDescriptor = try SafeDirectoryDescriptor.openAbsolute(
                        directoryURL,
                        createIntermediateDirectories: true,
                        creationMode: 0o700
                    )
                } catch is SafeDirectoryDescriptorError {
                    throw TransferQueuePersistenceStoreError.invalidLocation
                }
                defer { Darwin.close(directoryDescriptor) }

                if manifest.jobs.isEmpty {
                    try PrivateAtomicFileWriter.removeRegularSingleLinkIfPresent(
                        at: fileURL
                    )
                    return
                }

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try PrivateAtomicFileWriter.write(
                    try encoder.encode(manifest),
                    to: fileURL,
                    fileManager: fileManager
                )
            } catch PrivateAtomicFileWriterError.unsafeDestination {
                throw TransferQueuePersistenceStoreError.invalidLocation
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
