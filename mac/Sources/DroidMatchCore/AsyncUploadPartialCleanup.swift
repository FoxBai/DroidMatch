import Foundation

/// Exact wire identity of one resumable provider-owned upload partial.
///
/// The tuple is persisted before the first remote open. It never names the
/// final destination object for deletion; Android derives only its private
/// App Sandbox staging file or hidden SAF sibling from these values.
public struct AsyncUploadPartialIdentity: Sendable, Equatable {
    public let transferID: String
    public let destinationPath: String
    public let expectedSizeBytes: Int64

    public init(
        transferID: String,
        destinationPath: String,
        expectedSizeBytes: Int64
    ) {
        self.transferID = transferID
        self.destinationPath = destinationPath
        self.expectedSizeBytes = expectedSizeBytes
    }

    func validated(for request: AsyncUploadCoordinatorRequest) throws -> Self {
        guard !transferID.isEmpty,
              (!request.managedResumeRecordBindsTransferID
                || transferID == request.freshTransferID),
              !destinationPath.isEmpty,
              destinationPath == request.destinationPath,
              expectedSizeBytes >= 0,
              request.destinationSupportsResume else {
            throw RpcControlClientError.invalidTransferState(
                "upload partial cleanup identity is invalid"
            )
        }
        return self
    }
}

typealias AsyncUploadPartialPreparationObserver = @Sendable (
    AsyncUploadPartialIdentity
) async throws -> Void

typealias AsyncUploadPartialCleanupExecutor = @Sendable (
    AsyncUploadCoordinatorRequest,
    AsyncUploadPartialIdentity
) async throws -> Void
