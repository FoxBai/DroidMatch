@testable import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

@Test func transferQueueItemRedactsMacPathsAndKeepsStructuredState() {
    let id = UUID()
    let download = TransferQueuePresentationItem(snapshot: makeSnapshot(
        id: id,
        kind: .download,
        state: .retrying,
        source: "dm://media-images/private-remote-name.jpg",
        destination: "/Users/example/Desktop/  private\u{202E}\n\u{200B}photo.jpg\u{2069}  ",
        failureDescription: "resume sidecar missing: /Users/example/Desktop/private-photo.jpg.json",
        canPause: true,
        canCancel: true
    ))

    #expect(download.id == id)
    #expect(download.localFileName == "private photo.jpg")
    #expect(download.state == .retrying)
    #expect(download.fractionCompleted == 0.4)
    #expect(download.canPause)
    #expect(download.canCancel)
    #expect(download.failureCategory == nil)
    let reflectedDownload = String(reflecting: download)
    #expect(!reflectedDownload.contains("/Users/example"))
    #expect(!reflectedDownload.contains("private-remote-name"))
    #expect(!Mirror(reflecting: download).children.compactMap(\.label).contains("remotePath"))

    let upload = TransferQueuePresentationItem(snapshot: makeSnapshot(
        kind: .upload,
        source: "/Volumes/Work/client-archive.zip",
        destination: "dm://saf-root/client-archive.zip"
    ))
    #expect(upload.localFileName == "client-archive.zip")
    #expect(!String(reflecting: upload).contains("/Volumes/Work"))
}

@Test func transferQueueItemGroupsEveryPrivacySafeFailureCategory() {
    let expected: [(String, TransferQueueFailureCategory)] = [
        ("transport error", .connection),
        ("remote error: permissionRequired", .androidPermission),
        ("remote error: notFound", .remoteUnavailable),
        ("remote error: alreadyExists", .destinationConflict),
        ("remote error: invalidArgument", .invalidRequest),
        ("remote error: checksumMismatch", .integrity),
        ("remote error: storageReadOnly", .androidStorage),
        ("remote error: unsupportedCapability", .unsupported),
        ("upload source error", .localSource),
        ("download file error", .localDestination),
        ("transfer queue persistence write failed", .queuePersistence),
        ("persisted active transfer requires manual restart", .restartRequired),
        ("remote error: protocolError", .protocolFailure),
        ("transfer error", .generic),
    ]

    for (label, category) in expected {
        let item = TransferQueuePresentationItem(snapshot: makeSnapshot(
            state: .failed,
            failureDescription: label
        ))
        #expect(item.failureCategory == category)
    }
}

@Test func transferQueueFailureCategoryIsStateBoundedAndRejectsRawDetails() {
    let staleCompleted = TransferQueuePresentationItem(snapshot: makeSnapshot(
        state: .completed,
        failureDescription: "transport error"
    ))
    #expect(staleCompleted.failureCategory == nil)

    let privateUnknown = TransferQueuePresentationItem(snapshot: makeSnapshot(
        state: .failed,
        failureDescription: "provider failed at /Users/example/private.txt"
    ))
    #expect(privateUnknown.failureCategory == nil)
    #expect(!String(reflecting: privateUnknown).contains("/Users/example"))

    let interrupted = TransferQueuePresentationItem(snapshot: makeSnapshot(
        state: .interrupted,
        failureDescription: "persisted active transfer requires manual restart"
    ))
    #expect(interrupted.failureCategory == .restartRequired)
}

@Test func transferCompletionPolicyNotifiesOnlyObservedActionableTransitions() {
    let completedID = UUID()
    let failedID = UUID()
    let cancelledID = UUID()
    let newHistoryID = UUID()
    let current = [
        TransferQueuePresentationItem(snapshot: makeSnapshot(
            id: completedID,
            kind: .download,
            state: .completed,
            destination: "/tmp/completed.bin"
        )),
        TransferQueuePresentationItem(snapshot: makeSnapshot(
            id: failedID,
            kind: .upload,
            state: .failed,
            source: "/tmp/ \u{202E}failed\n\u{200B}upload.bin\u{2069} ",
            destination: "dm://app-sandbox/failed.bin"
        )),
        TransferQueuePresentationItem(snapshot: makeSnapshot(
            id: cancelledID,
            state: .cancelled
        )),
        TransferQueuePresentationItem(snapshot: makeSnapshot(
            id: newHistoryID,
            state: .completed
        )),
    ]

    let events = TransferCompletionPolicy.events(
        previousStates: [
            completedID: .running,
            failedID: .retrying,
            cancelledID: .running,
        ],
        currentItems: current
    )

    #expect(events.map(\.id) == [completedID, failedID])
    #expect(events.map(\.state) == [.completed, .failed])
    #expect(events.map(\.localFileName) == ["completed.bin", "failed upload.bin"])
    #expect(TransferCompletionPolicy.events(
        previousStates: TransferCompletionPolicy.states(for: current),
        currentItems: current
    ).isEmpty)
}
