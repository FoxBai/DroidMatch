import Foundation
@testable import DroidMatchCore

// Shared deterministic fixtures for storage, restoration, and fail-closed persistence tests.
// 中文：供存储、恢复及持久化失败关闭测试共享的确定性 fixture。

func persistedDownloadJob(
    id: UUID,
    sequence: UInt64,
    label: String,
    state: PersistedTransferJobState
) -> PersistedTransferJob {
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/\(label).bin",
        destinationURL: URL(fileURLWithPath: "/tmp/\(label).bin"),
        freshTransferID: "download-\(label)"
    )
    return PersistedTransferJob(
        id: id,
        sequence: sequence,
        request: PersistedTransferRequest(.download(request)),
        state: state,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )
}

func persistedUploadJob(
    id: UUID,
    sequence: UInt64,
    label: String,
    destinationPath: String,
    state: PersistedTransferJobState
) -> PersistedTransferJob {
    let request = AsyncUploadCoordinatorRequest(
        sourceURL: URL(fileURLWithPath: "/tmp/\(label).bin"),
        destinationPath: destinationPath,
        freshTransferID: "upload-\(label)"
    )
    return PersistedTransferJob(
        id: id,
        sequence: sequence,
        request: PersistedTransferRequest(.upload(request)),
        state: state,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )
}

func persistenceDownloadResult(
    _ request: AsyncDownloadCoordinatorRequest,
    finalOffsetBytes: Int64
) -> AsyncDownloadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = request.freshTransferID
    response.totalSizeBytes = finalOffsetBytes
    return AsyncDownloadCoordinatorResult(
        download: DownloadResult(
            openResponse: response,
            chunkCount: 0,
            bytesReceived: finalOffsetBytes,
            finalOffsetBytes: finalOffsetBytes
        ),
        attemptCount: 1
    )
}

func persistenceUploadResult(
    _ request: AsyncUploadCoordinatorRequest,
    finalOffsetBytes: Int64
) -> AsyncUploadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = request.freshTransferID
    response.totalSizeBytes = finalOffsetBytes
    return AsyncUploadCoordinatorResult(
        upload: UploadResult(
            openResponse: response,
            chunkCount: 0,
            bytesSent: finalOffsetBytes,
            finalOffsetBytes: finalOffsetBytes
        ),
        attemptCount: 1
    )
}

func makeTransferQueueTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "droidmatch-transfer-queue-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func waitForPersistenceCondition(
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

func waitForPersistenceSnapshot(
    scheduler: AsyncTransferScheduler,
    id: UUID,
    matching predicate: (AsyncTransferJobSnapshot) -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if let snapshot = try? await scheduler.snapshot(for: id),
           predicate(snapshot) {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

enum TransferQueuePersistenceTestError: Error {
    case retryable
}
