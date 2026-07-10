import Foundation

public typealias AsyncRpcControlClientFactory = @Sendable (
    _ attemptIndex: Int
) async throws -> AsyncRpcControlClient

public struct AsyncDownloadCoordinatorRequest: Sendable {
    public let sourcePath: String
    public let destinationURL: URL
    public let resume: Bool
    public let freshTransferID: String
    public let preferredChunkSizeBytes: UInt32
    public let recoveryPolicy: RecoveryPolicy

    public init(
        sourcePath: String,
        destinationURL: URL,
        resume: Bool = false,
        freshTransferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        recoveryPolicy: RecoveryPolicy = .disabled
    ) {
        self.sourcePath = sourcePath
        self.destinationURL = destinationURL
        self.resume = resume
        self.freshTransferID = freshTransferID
        self.preferredChunkSizeBytes = preferredChunkSizeBytes
        self.recoveryPolicy = recoveryPolicy
    }
}

public struct AsyncDownloadCoordinatorResult: Sendable {
    public let download: DownloadResult
    public let attemptCount: Int

    public var recovered: Bool { attemptCount > 1 }
}

public enum AsyncDownloadCoordinatorError: Error, CustomStringConvertible, Sendable, Equatable {
    case missingResumeRecord(String)
    case sourcePathMismatch(expected: String, actual: String)
    case orphanedPartial(path: String, sizeBytes: Int64)
    case missingAcceptedSourceFingerprint
    case acceptedSourceFingerprintChanged
    case acceptedTotalSizeChanged(expected: Int64, actual: Int64)

    public var description: String {
        switch self {
        case let .missingResumeRecord(path):
            return "download resume record is missing: \(path)"
        case let .sourcePathMismatch(expected, actual):
            return "download resume source mismatch: expected \(expected), got \(actual)"
        case let .orphanedPartial(path, sizeBytes):
            return "download partial has \(sizeBytes) bytes but no resume record: \(path)"
        case .missingAcceptedSourceFingerprint:
            return "download open response did not include an accepted source fingerprint"
        case .acceptedSourceFingerprintChanged:
            return "download accepted source fingerprint changed during resume"
        case let .acceptedTotalSizeChanged(expected, actual):
            return "download total size changed during resume: expected \(expected), got \(actual)"
        }
    }
}

/// Product-level download orchestration across connection attempts.
///
/// The injected factory owns transport creation and pairing/auth configuration;
/// this coordinator owns sidecar checkpoints, open/resume parameters, atomic file
/// receive, retry policy, and client teardown for each attempt.
public struct AsyncDownloadCoordinator: Sendable {
    private let clientFactory: AsyncRpcControlClientFactory
    private let resumeStore: AsyncTransferResumeStore
    private let sleeper: AsyncRecoverySleeper
    private let retryClassifier: @Sendable (Error) -> Bool

    public init(
        clientFactory: @escaping AsyncRpcControlClientFactory,
        resumeStore: AsyncTransferResumeStore = AsyncTransferResumeStore(),
        sleeper: @escaping AsyncRecoverySleeper = defaultAsyncRecoverySleeper,
        retryClassifier: @escaping @Sendable (Error) -> Bool = isRetryableTransferError
    ) {
        self.clientFactory = clientFactory
        self.resumeStore = resumeStore
        self.sleeper = sleeper
        self.retryClassifier = retryClassifier
    }

    public func download(
        _ request: AsyncDownloadCoordinatorRequest,
        onRetry: (@Sendable (Int, Int64, Error) -> Void)? = nil,
        onProgress: AsyncTransferProgressObserver? = nil
    ) async throws -> AsyncDownloadCoordinatorResult {
        guard !request.sourcePath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "download coordinator source path must be non-empty"
            )
        }

        if request.resume {
            let snapshot = try await resumeStore.downloadSnapshot(
                destinationURL: request.destinationURL
            )
            guard let record = snapshot.record else {
                throw AsyncDownloadCoordinatorError.missingResumeRecord(
                    DownloadResumeRecord.sidecarURL(
                        forDestination: request.destinationURL
                    ).path
                )
            }
            try validateSourcePath(record, requestedSourcePath: request.sourcePath)
        } else {
            try await resumeStore.prepareFreshDownload(
                destinationURL: request.destinationURL
            )
        }

        return try await runTransferWithRecoveryAsync(
            policy: request.recoveryPolicy,
            sleeper: sleeper,
            isRetryable: retryClassifier,
            canResume: {
                let snapshot = try await resumeStore.downloadSnapshot(
                    destinationURL: request.destinationURL
                )
                if let record = snapshot.record {
                    try validateSourcePath(
                        record,
                        requestedSourcePath: request.sourcePath
                    )
                    return true
                }
                // A connection may fail before OpenTransfer establishes a
                // sidecar. Fresh retry is safe only while no bytes exist.
                guard snapshot.requestedOffsetBytes == 0 else {
                    throw AsyncDownloadCoordinatorError.orphanedPartial(
                        path: AtomicDownloadWriter.partialURL(
                            for: request.destinationURL
                        ).path,
                        sizeBytes: snapshot.requestedOffsetBytes
                    )
                }
                return true
            },
            attempt: { attemptIndex in
                try await performAttempt(
                    request: request,
                    attemptIndex: attemptIndex,
                    onProgress: onProgress
                )
            },
            onRetry: onRetry
        )
    }

    private func performAttempt(
        request: AsyncDownloadCoordinatorRequest,
        attemptIndex: Int,
        onProgress: AsyncTransferProgressObserver?
    ) async throws -> AsyncDownloadCoordinatorResult {
        let snapshot = try await resumeStore.downloadSnapshot(
            destinationURL: request.destinationURL
        )
        let record = snapshot.record
        if let record {
            try validateSourcePath(record, requestedSourcePath: request.sourcePath)
        } else if snapshot.requestedOffsetBytes > 0 {
            throw AsyncDownloadCoordinatorError.orphanedPartial(
                path: AtomicDownloadWriter.partialURL(for: request.destinationURL).path,
                sizeBytes: snapshot.requestedOffsetBytes
            )
        }

        let client = try await clientFactory(attemptIndex)
        do {
            _ = try await client.handshake()
            let transfer = try await client.openDownload(
                sourcePath: request.sourcePath,
                transferID: record?.transferID ?? request.freshTransferID,
                requestedOffsetBytes: snapshot.requestedOffsetBytes,
                sourceFingerprint: record?.fingerprint.proto,
                preferredChunkSizeBytes: request.preferredChunkSizeBytes
            )
            let response = transfer.openResponse
            guard response.hasAcceptedSourceFingerprint else {
                try? await transfer.cancel(reason: "missing-source-fingerprint")
                throw AsyncDownloadCoordinatorError.missingAcceptedSourceFingerprint
            }
            let acceptedFingerprint = TransferFingerprintRecord(
                response.acceptedSourceFingerprint
            )
            if let record {
                guard record.fingerprint == acceptedFingerprint else {
                    try? await transfer.cancel(reason: "source-fingerprint-changed")
                    throw AsyncDownloadCoordinatorError.acceptedSourceFingerprintChanged
                }
                guard record.totalSizeBytes == response.totalSizeBytes else {
                    try? await transfer.cancel(reason: "source-total-size-changed")
                    throw AsyncDownloadCoordinatorError.acceptedTotalSizeChanged(
                        expected: record.totalSizeBytes,
                        actual: response.totalSizeBytes
                    )
                }
            }

            let updatedRecord = DownloadResumeRecord(
                transferID: response.transferID,
                sourcePath: request.sourcePath,
                totalSizeBytes: response.totalSizeBytes,
                fingerprint: acceptedFingerprint
            )
            do {
                try await resumeStore.saveDownload(
                    updatedRecord,
                    destinationURL: request.destinationURL
                )
            } catch {
                try? await transfer.cancel(reason: "download-sidecar-save-failed")
                throw error
            }

            let result = try await transfer.receive(
                to: request.destinationURL,
                resume: record != nil,
                onProgress: onProgress
            )
            try await resumeStore.removeDownload(
                destinationURL: request.destinationURL
            )
            // A 100% download update means the destination was atomically
            // committed and its now-obsolete resume record was removed.
            await onProgress?(AsyncTransferProgress(
                confirmedBytes: result.finalOffsetBytes,
                totalBytes: response.totalSizeBytes
            ))
            await client.close()
            return AsyncDownloadCoordinatorResult(
                download: result,
                attemptCount: attemptIndex + 1
            )
        } catch {
            await client.close()
            throw error
        }
    }

    private func validateSourcePath(
        _ record: DownloadResumeRecord,
        requestedSourcePath: String
    ) throws {
        guard record.sourcePath == requestedSourcePath else {
            throw AsyncDownloadCoordinatorError.sourcePathMismatch(
                expected: record.sourcePath,
                actual: requestedSourcePath
            )
        }
    }
}
