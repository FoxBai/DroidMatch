import DroidMatchCore
import Foundation

/// Coarse product guidance groups with no raw platform or provider text.
public enum TransferQueueFailureCategory: Sendable, Equatable {
    case connection
    case androidPermission
    case remoteUnavailable
    case destinationConflict
    case invalidRequest
    case integrity
    case androidStorage
    case unsupported
    case localSource
    case localDestination
    case queuePersistence
    case restartRequired
    case protocolFailure
    case generic

    init(code: AsyncTransferFailureCode) {
        switch code {
        case .timeout, .transportLost, .transport:
            self = .connection
        case .unauthorized, .permissionRequired:
            self = .androidPermission
        case .notFound:
            self = .remoteUnavailable
        case .alreadyExists, .duplicateDestination:
            self = .destinationConflict
        case .invalidArgument:
            self = .invalidRequest
        case .checksumMismatch:
            self = .integrity
        case .storageReadOnly:
            self = .androidStorage
        case .unsupportedVersion, .unsupportedCapability:
            self = .unsupported
        case .uploadSource:
            self = .localSource
        case .downloadFile:
            self = .localDestination
        case .persistenceWrite, .retryPersistence:
            self = .queuePersistence
        case .manualRestart, .attemptLimit, .restoredDuplicateDestination:
            self = .restartRequired
        case .remoteInternal, .protocolError:
            self = .protocolFailure
        case .remoteFailure, .cancelled, .downloadTransfer, .uploadTransfer, .transfer:
            self = .generic
        }
    }
}

/// Immutable, privacy-bounded state for one native transfer-row presentation.
///
/// The Core snapshot must retain exact local paths for file ownership and resume
/// validation. Presentation exposes only a safe local basename; remote paths and
/// raw failure strings stay below this boundary because either may contain user
/// names or POSIX paths that the row does not need.
public struct TransferQueuePresentationItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: AsyncTransferJobKind
    public let state: AsyncTransferJobState
    public let localFileName: String?
    public let attemptNumber: Int
    public let confirmedBytes: Int64
    public let totalBytes: Int64?
    public let recentBytesPerSecond: Double?
    public let retryDelayMilliseconds: Int64?
    public let fractionCompleted: Double?
    public let failureCategory: TransferQueueFailureCategory?
    public let canPause: Bool
    public let canResume: Bool
    public let canCancel: Bool
    public let canRemove: Bool

    public init(snapshot: AsyncTransferJobSnapshot) {
        let localPath: String
        switch snapshot.kind {
        case .download:
            localPath = snapshot.destination
        case .upload:
            localPath = snapshot.source
        }

        id = snapshot.id
        kind = snapshot.kind
        state = snapshot.state
        localFileName = Self.localFileName(from: localPath)
        attemptNumber = snapshot.attemptNumber
        confirmedBytes = snapshot.confirmedBytes
        totalBytes = snapshot.totalBytes
        recentBytesPerSecond = snapshot.recentBytesPerSecond
        retryDelayMilliseconds = snapshot.retryDelayMilliseconds
        fractionCompleted = snapshot.fractionCompleted
        switch snapshot.state {
        case .retrying, .cleaning, .failed, .interrupted:
            failureCategory = snapshot.failureCode.map(TransferQueueFailureCategory.init)
        case .queued, .running, .pausing, .paused, .completed, .cancelled:
            failureCategory = nil
        }
        canPause = snapshot.canPause
        canResume = snapshot.canResume
        canCancel = snapshot.canCancel
        canRemove = snapshot.canRemove
    }

    private static func localFileName(from path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return ProductDisplayText.value(name)
    }
}
