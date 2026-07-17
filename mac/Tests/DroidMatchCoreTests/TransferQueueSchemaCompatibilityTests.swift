import Foundation
import Testing
@testable import DroidMatchCore

@Test func schemaOneQueueRemainsReadableWithoutCleanupFields() throws {
    let id = UUID()
    let current = PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: id,
        sequence: 3,
        label: "schema-one",
        state: .queued
    )])
    let legacyData = try queueData(current, schemaVersion: 1)
    let legacy = try JSONDecoder().decode(PersistedTransferQueue.self, from: legacyData)

    #expect(legacy.schemaVersion == 1)
    try legacy.validate()
    let restored = try AsyncTransferSchedulerPersistence.restore(legacy)
    #expect(restored.records[id]?.state == .queued)
    #expect(restored.records[id]?.uploadPartialIdentity == nil)
    #expect(restored.records[id]?.removeAfterUploadCleanup == false)
}

@Test func schemaOneCannotSmuggleVersionTwoCleanupState() throws {
    let request = uploadRequest("legacy-cleanup")
    let current = PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: UUID(),
        sequence: 0,
        request: PersistedTransferRequest(.upload(request)),
        state: .cleanupPending,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false,
        uploadPartialIdentity: PersistedUploadPartialIdentity(
            AsyncUploadPartialIdentity(
                transferID: request.freshTransferID,
                destinationPath: request.destinationPath,
                expectedSizeBytes: 1
            )
        )
    )])
    let data = try queueData(current, schemaVersion: 1)
    let decoded = try JSONDecoder().decode(PersistedTransferQueue.self, from: data)

    #expect(throws: TransferQueuePersistenceStoreError.self) {
        try decoded.validate()
    }
}

@Test func removalCleanupIntentIsValidOnlyWithExactPendingIdentity() throws {
    let request = uploadRequest("invalid-remove-intent")
    let identity = PersistedUploadPartialIdentity(AsyncUploadPartialIdentity(
        transferID: request.freshTransferID,
        destinationPath: request.destinationPath,
        expectedSizeBytes: 2
    ))
    let invalidState = PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: UUID(),
        sequence: 0,
        request: PersistedTransferRequest(.upload(request)),
        state: .interrupted,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false,
        uploadPartialIdentity: identity,
        removeAfterUploadCleanup: true
    )])
    #expect(throws: TransferQueuePersistenceStoreError.self) {
        try invalidState.validate()
    }

    let mismatchedIdentity = PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: UUID(),
        sequence: 0,
        request: PersistedTransferRequest(.upload(request)),
        state: .cleanupPending,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false,
        uploadPartialIdentity: PersistedUploadPartialIdentity(
            AsyncUploadPartialIdentity(
                transferID: request.freshTransferID,
                destinationPath: "dm://app-sandbox/other.bin",
                expectedSizeBytes: 2
            )
        ),
        removeAfterUploadCleanup: true
    )])
    #expect(throws: TransferQueuePersistenceStoreError.self) {
        try mismatchedIdentity.validate()
    }
}

private func queueData(
    _ queue: PersistedTransferQueue,
    schemaVersion: Int
) throws -> Data {
    let encoded = try JSONEncoder().encode(queue)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw TransferQueuePersistenceStoreError.invalidData
    }
    object["schemaVersion"] = schemaVersion
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
