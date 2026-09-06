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
    #expect(ProductUploadDestination(
        directoryPath: "dm://media-images/",
        fileName: "photo.HEIC"
    )?.path == "dm://media-images/photo.HEIC")
    #expect(ProductUploadDestination(
        directoryPath: "dm://media-videos/",
        fileName: "clip.webm"
    )?.path == "dm://media-videos/clip.webm")
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
    #expect(ProductUploadDestination.supportedMediaFileExtensions(directoryPath: "dm://media-audio/")
        == ["aac", "flac", "m4a", "mp3", "oga", "ogg", "opus", "wav"])
    for ext in ["aac", "flac", "m4a", "mp3", "oga", "ogg", "opus", "wav"] {
        let destination = try #require(ProductUploadDestination(
            directoryPath: "dm://media-audio/", fileName: "Track.\(ext.uppercased())"
        ))
        #expect(destination.path == "dm://media-audio/Track.\(ext.uppercased())")
        #expect(!destination.supportsResume)
        let request = AsyncUploadCoordinatorRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/Track.\(ext)"),
            destinationPath: destination.path
        )
        #expect(!request.destinationSupportsResume)
        #expect(request.isFreshOnlyMediaStoreDestination)
    }
}

@Test func productUploadDestinationRejectsAmbiguousOrSpoofedSegments() {
    let invalidNames = [
        "", ".", "..", "nested/file", "100%done.bin", "line\nbreak",
        "safe\u{202E}gpj.exe", "zero\u{200D}width.bin",
        "tag\u{E0001}name.bin", ".payload.droidmatch-upload-part",
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

    for (directory, fileName) in [
        ("dm://media-images/", "clip.mp4"),
        ("dm://media-videos/", "photo.jpg"),
        ("dm://media-images/", "unknown.bin"),
        ("dm://media-videos/", "no-extension"),
        ("dm://media-videos/", "ambiguous.ts"),
        ("dm://media-audio/", "clip.mp4"),
        ("dm://media-audio/", "photo.jpg"),
        ("dm://media-audio/", "track.bin"),
        ("dm://media-audio/", "nested/track.mp3"),
        ("dm://media-audio/media/42/", "track.mp3"),
        ("dm://media-images/", "track.mp3"),
        ("dm://media-videos/", "track.mp3"),
    ] {
        #expect(ProductUploadDestination(
            directoryPath: directory,
            fileName: fileName
        ) == nil)
    }
    #expect(ProductUploadDestination(
        directoryPath: "dm://app-sandbox/",
        fileName: "source.ts"
    ) != nil)
}
