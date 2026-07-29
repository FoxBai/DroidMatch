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

@Test func downloadPublicationPolicySurvivesPersistenceAndResume() throws {
    #expect(PersistedTransferQueue.currentSchemaVersion == 3)
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/no-clobber.bin",
        destinationURL: URL(fileURLWithPath: "/tmp/no-clobber.bin"),
        publicationPolicy: .mustBeAbsent,
        freshTransferID: "no-clobber"
    )
    let encoded = try JSONEncoder().encode(
        PersistedTransferRequest(.download(request))
    )
    let persisted = try JSONDecoder().decode(
        PersistedTransferRequest.self,
        from: encoded
    )
    guard case let .download(restored) = try persisted.value(),
          case let .download(resumed) = AsyncTransferSchedulerPolicy.resumedRequest(
              .download(restored)
          ) else {
        Issue.record("expected restored and resumed downloads")
        return
    }

    #expect(restored.publicationPolicy == .mustBeAbsent)
    #expect(resumed.publicationPolicy == .mustBeAbsent)
    #expect(resumed.resume)
}

@Test func legacyDownloadWithoutPublicationPolicyRestoresFailClosed() throws {
    let request = AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/legacy.bin",
        destinationURL: URL(fileURLWithPath: "/tmp/legacy.bin"),
        publicationPolicy: .replaceExisting,
        freshTransferID: "legacy"
    )
    let id = UUID()
    let current = PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: id,
        sequence: 0,
        request: PersistedTransferRequest(.download(request)),
        state: .paused,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )])
    let legacy = try JSONDecoder().decode(
        PersistedTransferQueue.self,
        from: queueData(current, schemaVersion: 2)
    )
    try legacy.validate()
    let state = try AsyncTransferSchedulerPersistence.restore(legacy)
    guard let record = state.records[id],
          case let .download(restored) = record.request else {
        Issue.record("expected restored download")
        return
    }

    #expect(restored.publicationPolicy == .mustBeAbsent)
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
    if schemaVersion < 3,
       var jobs = object["jobs"] as? [[String: Any]] {
        for index in jobs.indices {
            guard var request = jobs[index]["request"] as? [String: Any] else {
                throw TransferQueuePersistenceStoreError.invalidData
            }
            request.removeValue(forKey: "downloadPublicationPolicy")
            jobs[index]["request"] = request
        }
        object["jobs"] = jobs
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
