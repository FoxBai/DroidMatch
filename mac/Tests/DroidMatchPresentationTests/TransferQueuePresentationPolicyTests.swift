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
        source: "dm://media-images/media/123",
        destination: "/Users/example/Desktop/private-photo.jpg",
        failureDescription: "resume sidecar missing: /Users/example/Desktop/private-photo.jpg.json",
        canPause: true,
        canCancel: true
    ))

    #expect(download.id == id)
    #expect(download.localFileName == "private-photo.jpg")
    #expect(download.remotePath == "dm://media-images/media/123")
    #expect(download.state == .retrying)
    #expect(download.fractionCompleted == 0.4)
    #expect(download.canPause)
    #expect(download.canCancel)
    #expect(!String(reflecting: download).contains("/Users/example"))

    let upload = TransferQueuePresentationItem(snapshot: makeSnapshot(
        kind: .upload,
        source: "/Volumes/Work/client-archive.zip",
        destination: "dm://saf-root/client-archive.zip"
    ))
    #expect(upload.localFileName == "client-archive.zip")
    #expect(upload.remotePath == "dm://saf-root/client-archive.zip")
    #expect(!String(reflecting: upload).contains("/Volumes/Work"))

    let malformedRemote = TransferQueuePresentationItem(snapshot: makeSnapshot(
        source: "/Users/example/must-not-become-remote-state.bin",
        destination: "/tmp/local.bin"
    ))
    #expect(malformedRemote.remotePath == nil)
    #expect(!String(reflecting: malformedRemote).contains("/Users/example"))
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
            source: "/tmp/failed.bin",
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
    #expect(events.map(\.localFileName) == ["completed.bin", "failed.bin"])
    #expect(TransferCompletionPolicy.events(
        previousStates: TransferCompletionPolicy.states(for: current),
        currentItems: current
    ).isEmpty)
}
