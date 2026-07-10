import Foundation
import Testing
@testable import DroidMatchCore

@Test func productUploadDestinationBuildsOnlyDocumentedProviderShapes() {
    #expect(ProductUploadDestination(
        directoryPath: "dm://app-sandbox/exports/",
        fileName: "report.pdf"
    )?.path == "dm://app-sandbox/exports/report.pdf")
    #expect(ProductUploadDestination(
        directoryPath: "dm://saf-a1b2/",
        fileName: "archive.zip"
    )?.path == "dm://saf-a1b2/archive.zip")
    #expect(ProductUploadDestination(
        directoryPath: "dm://saf-a1b2/doc/0123456789abcdef",
        fileName: "archive.zip"
    )?.path == "dm://saf-a1b2/doc/0123456789abcdef/archive.zip")
    #expect(ProductUploadDestination(
        directoryPath: "dm://media-images/",
        fileName: "photo.jpg"
    )?.path == "dm://media-images/photo.jpg")
}

@Test func productUploadDestinationSelectsProviderSafeResumePolicy() throws {
    #expect(try #require(ProductUploadDestination(
        directoryPath: "dm://app-sandbox/",
        fileName: "payload.bin"
    )).supportsResume)
    #expect(try #require(ProductUploadDestination(
        directoryPath: "dm://saf-a1b2/",
        fileName: "payload.bin"
    )).supportsResume)
    #expect(!(try #require(ProductUploadDestination(
        directoryPath: "dm://media-videos/",
        fileName: "clip.mp4"
    )).supportsResume))
}

@Test func productUploadDestinationRejectsAmbiguousOrSpoofedSegments() {
    let invalidNames = [
        "", ".", "..", "nested/file", "100%done.bin", "line\nbreak",
        "safe\u{202E}gpj.exe",
    ]
    for name in invalidNames {
        #expect(ProductUploadDestination(
            directoryPath: "dm://app-sandbox/",
            fileName: name
        ) == nil)
    }

    let invalidDirectories = [
        "dm://roots/",
        "dm://media-images/album/",
        "dm://app-sandbox/file.bin",
        "dm://saf-/",
        "dm://saf-a1b2/doc/",
        "dm://saf-a1b2/doc/token/child",
        "dm://saf-a1b2/not-doc/token",
    ]
    for directory in invalidDirectories {
        #expect(ProductUploadDestination(
            directoryPath: directory,
            fileName: "payload.bin"
        ) == nil)
    }
}
