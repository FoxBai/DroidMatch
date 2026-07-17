import DroidMatchCore
import Foundation
import Testing
@testable import DroidMatchHarness

@Test func harnessExplicitDownloadResumeAlwaysRequiresCheckpoint() throws {
    let sidecar = URL(fileURLWithPath: "/tmp/private-name.transfer.json")

    #expect(throws: HarnessError.self) {
        try HarnessCommand.validateDownloadResumeCheckpoint(
            resume: true,
            record: nil,
            sourcePath: "dm://app-sandbox/private-name",
            requestedOffset: 0,
            sidecarURL: sidecar
        )
    }
}

@Test func harnessDownloadResumeRequiresStrictlyIncompleteKnownTotal() throws {
    let sidecar = URL(fileURLWithPath: "/tmp/private-name.transfer.json")
    let complete = downloadResumeRecord(totalSizeBytes: 4)
    let unknown = downloadResumeRecord(totalSizeBytes: -1)

    let invalidCases: [(DownloadResumeRecord, Int64)] = [
        (complete, 4), (complete, 5), (unknown, 0),
    ]
    for (record, offset) in invalidCases {
        do {
            try HarnessCommand.validateDownloadResumeCheckpoint(
                resume: true,
                record: record,
                sourcePath: record.sourcePath,
                requestedOffset: offset,
                sidecarURL: sidecar
            )
            Issue.record("expected a non-incomplete checkpoint to be rejected")
        } catch let error as HarnessError {
            guard case let .resumeCheckpointNotIncomplete(actual, total) = error else {
                Issue.record("unexpected harness error: \(error)")
                continue
            }
            #expect(actual == offset)
            #expect(total == record.totalSizeBytes)
        }
    }

    try HarnessCommand.validateDownloadResumeCheckpoint(
        resume: true,
        record: complete,
        sourcePath: complete.sourcePath,
        requestedOffset: 3,
        sidecarURL: sidecar
    )
}

private func downloadResumeRecord(totalSizeBytes: Int64) -> DownloadResumeRecord {
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = totalSizeBytes
    fingerprint.modifiedUnixMillis = 1
    return DownloadResumeRecord(
        transferID: "harness-resume",
        sourcePath: "dm://app-sandbox/private-name",
        totalSizeBytes: totalSizeBytes,
        fingerprint: TransferFingerprintRecord(fingerprint)
    )
}
