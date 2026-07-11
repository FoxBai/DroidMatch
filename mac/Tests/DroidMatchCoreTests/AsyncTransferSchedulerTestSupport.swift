import Foundation
import Testing
@testable import DroidMatchCore

/// Shared scheduler fixture construction kept separate from behavioral tests.
func makeScheduler(
    maxConcurrentJobs: Int,
    probe: SchedulerExecutionProbe
) -> AsyncTransferScheduler {
    AsyncTransferScheduler(
        maxConcurrentJobs: maxConcurrentJobs,
        downloadExecutor: { request, _, _ in
            try await probe.execute(request.sourcePath)
            return downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _, _ in
            try await probe.execute(request.sourceURL.lastPathComponent)
            return uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
}

func downloadRequest(_ label: String) -> AsyncDownloadCoordinatorRequest {
    AsyncDownloadCoordinatorRequest(
        sourcePath: label,
        destinationURL: URL(fileURLWithPath: "/tmp/\(label).bin"),
        freshTransferID: "download-\(label)"
    )
}

func uploadRequest(_ label: String) -> AsyncUploadCoordinatorRequest {
    AsyncUploadCoordinatorRequest(
        sourceURL: URL(fileURLWithPath: "/tmp/\(label)"),
        destinationPath: "dm://app-sandbox/\(label)",
        freshTransferID: "upload-\(label)"
    )
}

func downloadResult(
    _ label: String,
    attemptCount: Int,
    totalBytes: Int64 = 0,
    finalOffsetBytes: Int64 = 0
) -> AsyncDownloadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = label
    response.totalSizeBytes = totalBytes
    return AsyncDownloadCoordinatorResult(
        download: DownloadResult(
            openResponse: response,
            chunkCount: 0,
            bytesReceived: 0,
            finalOffsetBytes: finalOffsetBytes
        ),
        attemptCount: attemptCount
    )
}

func waitForSchedulerSnapshot(
    scheduler: AsyncTransferScheduler,
    id: UUID,
    matching predicate: (AsyncTransferJobSnapshot) -> Bool
) async throws -> AsyncTransferJobSnapshot? {
    for _ in 0..<200 {
        let snapshot = try await scheduler.snapshot(for: id)
        if predicate(snapshot) { return snapshot }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return nil
}

func uploadResult(
    _ label: String,
    attemptCount: Int
) -> AsyncUploadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = label
    return AsyncUploadCoordinatorResult(
        upload: UploadResult(
            openResponse: response,
            chunkCount: 0,
            bytesSent: 0,
            finalOffsetBytes: 0
        ),
        attemptCount: attemptCount
    )
}

func assertSuccess(
    _ outcome: AsyncTransferJobOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .success = outcome else {
        Issue.record("expected successful scheduler outcome", sourceLocation: sourceLocation)
        return
    }
}

func assertCancelled(
    _ outcome: AsyncTransferJobOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .cancelled = outcome else {
        Issue.record("expected cancelled scheduler outcome", sourceLocation: sourceLocation)
        return
    }
}
