import DroidMatchCore
import Foundation

/// Immutable, privacy-bounded state for one native transfer-row presentation.
///
/// The Core snapshot must retain exact local paths for file ownership and resume
/// validation. Presentation exposes only the local basename; raw failure strings
/// are also omitted because Foundation/coordinator errors may contain POSIX paths.
public struct TransferQueuePresentationItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: AsyncTransferJobKind
    public let state: AsyncTransferJobState
    public let localFileName: String?
    public let remotePath: String?
    public let attemptNumber: Int
    public let confirmedBytes: Int64
    public let totalBytes: Int64?
    public let recentBytesPerSecond: Double?
    public let retryDelayMilliseconds: Int64?
    public let fractionCompleted: Double?
    public let canPause: Bool
    public let canResume: Bool
    public let canCancel: Bool
    public let canRemove: Bool

    public init(snapshot: AsyncTransferJobSnapshot) {
        let localPath: String
        let candidateRemotePath: String
        switch snapshot.kind {
        case .download:
            localPath = snapshot.destination
            candidateRemotePath = snapshot.source
        case .upload:
            localPath = snapshot.source
            candidateRemotePath = snapshot.destination
        }

        id = snapshot.id
        kind = snapshot.kind
        state = snapshot.state
        localFileName = Self.localFileName(from: localPath)
        remotePath = Self.remotePath(from: candidateRemotePath)
        attemptNumber = snapshot.attemptNumber
        confirmedBytes = snapshot.confirmedBytes
        totalBytes = snapshot.totalBytes
        recentBytesPerSecond = snapshot.recentBytesPerSecond
        retryDelayMilliseconds = snapshot.retryDelayMilliseconds
        fractionCompleted = snapshot.fractionCompleted
        canPause = snapshot.canPause
        canResume = snapshot.canResume
        canCancel = snapshot.canCancel
        canRemove = snapshot.canRemove
    }

    private static func localFileName(from path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func remotePath(from path: String) -> String? {
        path.hasPrefix("dm://") ? path : nil
    }
}
