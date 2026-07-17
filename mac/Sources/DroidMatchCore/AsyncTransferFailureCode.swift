/// Privacy-safe reason codes derived from the scheduler's persisted labels.
///
/// Queue persistence predates this typed view, so snapshots retain their
/// bounded string field for format compatibility. This parser accepts only the
/// exact labels Core itself emits. Unknown or extended text stays unavailable
/// to presentation instead of becoming an accidental path or provider-message
/// channel.
///
/// 中文：持久化格式继续保存既有限定标签；产品层只能看到精确白名单映射后的
/// 类型化原因，未知文本或附加路径一律拒绝。
public enum AsyncTransferFailureCode: Sendable, Equatable {
    case remoteFailure
    case unsupportedVersion
    case unsupportedCapability
    case unauthorized
    case permissionRequired
    case notFound
    case alreadyExists
    case invalidArgument
    case cancelled
    case timeout
    case transportLost
    case checksumMismatch
    case storageReadOnly
    case remoteInternal
    case protocolError
    case downloadTransfer
    case uploadTransfer
    case downloadFile
    case uploadSource
    case transport
    case transfer
    case persistenceWrite
    case manualRestart
    case attemptLimit
    case retryPersistence
    case duplicateDestination
    case restoredDuplicateDestination

    init?(schedulerLabel: String?) {
        guard let schedulerLabel else { return nil }
        switch schedulerLabel {
        case AsyncTransferFailureLabel.remotePrefix + "unspecified":
            self = .remoteFailure
        case AsyncTransferFailureLabel.remotePrefix + "unsupportedVersion":
            self = .unsupportedVersion
        case AsyncTransferFailureLabel.remotePrefix + "unsupportedCapability":
            self = .unsupportedCapability
        case AsyncTransferFailureLabel.remotePrefix + "unauthorized":
            self = .unauthorized
        case AsyncTransferFailureLabel.remotePrefix + "permissionRequired":
            self = .permissionRequired
        case AsyncTransferFailureLabel.remotePrefix + "notFound":
            self = .notFound
        case AsyncTransferFailureLabel.remotePrefix + "alreadyExists":
            self = .alreadyExists
        case AsyncTransferFailureLabel.remotePrefix + "invalidArgument":
            self = .invalidArgument
        case AsyncTransferFailureLabel.remotePrefix + "cancelled":
            self = .cancelled
        case AsyncTransferFailureLabel.remotePrefix + "timeout":
            self = .timeout
        case AsyncTransferFailureLabel.remotePrefix + "transportLost":
            self = .transportLost
        case AsyncTransferFailureLabel.remotePrefix + "checksumMismatch":
            self = .checksumMismatch
        case AsyncTransferFailureLabel.remotePrefix + "storageReadOnly":
            self = .storageReadOnly
        case AsyncTransferFailureLabel.remotePrefix + "internal":
            self = .remoteInternal
        case AsyncTransferFailureLabel.remotePrefix + "protocolError":
            self = .protocolError
        case AsyncTransferFailureLabel.downloadTransfer:
            self = .downloadTransfer
        case AsyncTransferFailureLabel.uploadTransfer:
            self = .uploadTransfer
        case AsyncTransferFailureLabel.downloadFile:
            self = .downloadFile
        case AsyncTransferFailureLabel.uploadSource:
            self = .uploadSource
        case AsyncTransferFailureLabel.transport:
            self = .transport
        case AsyncTransferFailureLabel.transfer:
            self = .transfer
        case AsyncTransferSchedulerPolicy.persistenceWriteFailureDescription:
            self = .persistenceWrite
        case AsyncTransferSchedulerPolicy.interruptedFailureDescription:
            self = .manualRestart
        case AsyncTransferSchedulerPolicy.attemptAccountingFailureDescription:
            self = .attemptLimit
        case AsyncTransferSchedulerPolicy.retryPersistenceFailureDescription:
            self = .retryPersistence
        case AsyncTransferSchedulerPolicy.duplicateDownloadDestinationFailureDescription:
            self = .duplicateDestination
        case AsyncTransferSchedulerPolicy.restoredDuplicateDownloadDestinationFailureDescription:
            self = .restoredDuplicateDestination
        default:
            guard Self.isCanonicalUnrecognizedRemoteLabel(schedulerLabel) else {
                return nil
            }
            self = .remoteFailure
        }
    }

    private static func isCanonicalUnrecognizedRemoteLabel(_ label: String) -> Bool {
        let prefix = AsyncTransferFailureLabel.remotePrefix + "UNRECOGNIZED("
        guard label.hasPrefix(prefix), label.hasSuffix(")") else { return false }
        let valueStart = label.index(label.startIndex, offsetBy: prefix.count)
        let valueEnd = label.index(before: label.endIndex)
        let text = String(label[valueStart..<valueEnd])
        guard let value = Int(text) else { return false }
        return String(value) == text
    }
}
