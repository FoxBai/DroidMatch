import Foundation

/// A transfer checkpoint that is safe to present as product progress.
///
/// `confirmedBytes` is an absolute offset, not a per-attempt byte count. A
/// download reports it only after the partial-file write and protocol ACK; an
/// upload reports it only after the remote ACK and, when resumable, the local
/// sidecar commit. This keeps progress aligned with the offset a retry may use.
public struct AsyncTransferProgress: Sendable, Equatable {
    public let confirmedBytes: Int64
    public let totalBytes: Int64

    public init(confirmedBytes: Int64, totalBytes: Int64) {
        self.confirmedBytes = confirmedBytes
        self.totalBytes = totalBytes
    }

    /// Returns nil until a positive total is known. Completion state remains
    /// authoritative for a valid zero-byte transfer.
    public var fractionCompleted: Double? {
        guard totalBytes > 0,
              confirmedBytes >= 0,
              confirmedBytes <= totalBytes else {
            return nil
        }
        return Double(confirmedBytes) / Double(totalBytes)
    }
}

/// Observers are awaited to preserve checkpoint ordering and should return
/// promptly; expensive aggregation belongs in a separate consumer task.
public typealias AsyncTransferProgressObserver = @Sendable (
    AsyncTransferProgress
) async -> Void
