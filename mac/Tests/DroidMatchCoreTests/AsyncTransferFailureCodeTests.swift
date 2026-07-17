import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncTransferFailureCodeMapsEveryKnownSchedulerLabel() {
    let remoteExpected: [(Droidmatch_V1_ErrorCode, AsyncTransferFailureCode)] = [
        (.unspecified, .remoteFailure),
        (.unsupportedVersion, .unsupportedVersion),
        (.unsupportedCapability, .unsupportedCapability),
        (.unauthorized, .unauthorized),
        (.permissionRequired, .permissionRequired),
        (.notFound, .notFound),
        (.alreadyExists, .alreadyExists),
        (.invalidArgument, .invalidArgument),
        (.cancelled, .cancelled),
        (.timeout, .timeout),
        (.transportLost, .transportLost),
        (.checksumMismatch, .checksumMismatch),
        (.storageReadOnly, .storageReadOnly),
        (.internal, .remoteInternal),
        (.protocolError, .protocolError),
        (.UNRECOGNIZED(77), .remoteFailure),
    ]
    for (remoteCode, failureCode) in remoteExpected {
        var remoteError = Droidmatch_V1_DroidMatchError()
        remoteError.code = remoteCode
        let label = AsyncTransferFailureLabel.label(
            for: RpcControlClientError.remoteError(remoteError)
        )
        #expect(AsyncTransferFailureCode(schedulerLabel: label) == failureCode)
    }

    let expected: [(String, AsyncTransferFailureCode)] = [
        ("download transfer error", .downloadTransfer),
        ("upload transfer error", .uploadTransfer),
        ("download file error", .downloadFile),
        ("upload source error", .uploadSource),
        ("transport error", .transport),
        ("transfer error", .transfer),
        ("transfer queue persistence write failed", .persistenceWrite),
        ("persisted active transfer requires manual restart", .manualRestart),
        ("transfer attempt accounting exceeded its safe limit", .attemptLimit),
        ("transfer retry could not cross its persistence boundary", .retryPersistence),
        ("another download already uses this local destination", .duplicateDestination),
        (
            "persisted duplicate download destination requires manual restart",
            .restoredDuplicateDestination
        ),
    ]

    for (label, code) in expected {
        #expect(AsyncTransferFailureCode(schedulerLabel: label) == code)
    }
}

@Test func asyncTransferFailureCodeRejectsUnknownOrExtendedLabels() {
    for label in [
        nil,
        "",
        "remote error: notFound /Users/example/private.txt",
        "remote error: UNRECOGNIZED(77) provider detail",
        "remote error: UNRECOGNIZED(077)",
        "remote error: UNRECOGNIZED(+77)",
        "remote error: UNRECOGNIZED(77/Users/example)",
        "transfer error: /Users/example/private.txt",
        "persisted active transfer requires manual restart /private/path",
    ] as [String?] {
        #expect(AsyncTransferFailureCode(schedulerLabel: label) == nil)
    }
}
