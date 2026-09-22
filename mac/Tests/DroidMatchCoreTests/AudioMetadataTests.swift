import Foundation
import Testing
@testable import DroidMatchCore

@Test func audioMetadataBoundsAndProjectsEachUntrustedLabelIndependently() {
    let metadata = AudioMetadata(title: "  Cafe\u{301}\n\u{202E}Song ",
                                 artist: "<UNKNOWN>", album: String(repeating: "a", count: 513))
    #expect(metadata.title == "Café Song")
    #expect(metadata.artist == nil)
    #expect(metadata.album == nil)
    #expect(AudioMetadata(title: "\u{200B}\n\u{1}").isEmpty)
    let bounded = AudioMetadata(title: String(repeating: "🎵", count: 121))
    #expect(bounded.title?.unicodeScalars.count == 120)
    #expect(bounded.title?.hasSuffix("…") == true)
    #expect(AudioMetadata(title: String(repeating: "🎵", count: 129)).title == nil)
}

@Test func audioMetadataWireRoundTripKeepsFilenameIdentityAndOlderPeerFallback() throws {
    var track = Droidmatch_V1_FileEntry()
    track.path = "dm://media-audio/media/42"
    track.name = "original-file.mp3"
    track.kind = .file
    track.mimeType = "AUDIO/MPEG"
    track.canRead = true
    track.audioMetadata.title = "A Song"
    track.audioMetadata.artist = "Artist"
    track.audioMetadata.album = "Album"
    var legacy = track
    legacy.path = "dm://media-audio/media/43"
    legacy.clearAudioMetadata()
    var malformed = track
    malformed.path = "dm://media-audio/media/44"
    malformed.audioMetadata.title = String(repeating: "x", count: 513)
    var response = Droidmatch_V1_ListDirResponse()
    response.entries = [track, legacy, malformed]
    let decoded = try Droidmatch_V1_ListDirResponse(serializedBytes: response.serializedData())
    let page = try DirectoryListingCodec.page(response: decoded, requestedPageToken: nil)
    #expect(page.entries.map(\.name) == Array(repeating: "original-file.mp3", count: 3))
    #expect(page.entries.map(\.path) == response.entries.map(\.path))
    #expect(page.entries[0].audioMetadata == AudioMetadata(title: "A Song", artist: "Artist", album: "Album"))
    #expect(page.entries[1].audioMetadata == nil)
    #expect(page.entries[2].audioMetadata == AudioMetadata(artist: "Artist", album: "Album"))
    #expect(page.entries.allSatisfy { $0.canRead && !$0.canWrite })
}

@Test func audioMetadataRequiresReadableCanonicalAudioFileWithoutGrantingCapabilities() {
    let metadata = AudioMetadata(title: "A Song")
    let invalidPaths = ["dm://media-audio/", "dm://media-images/media/1", "dm://app-sandbox/one.mp3",
                        "dm://media-audio/media/-1", "dm://media-audio/media/١",
                        "dm://media-audio/media/9223372036854775808", "dm://media-audio/media/1/child"]
    for (path, kind, mime, canRead) in invalidPaths.map({ ($0, DirectoryEntryKind.file, "audio/mpeg", true) }) + [
        ("dm://media-audio/media/1", .directory, "audio/mpeg", true),
        ("dm://media-audio/media/1", .file, "video/mp4", true),
        ("dm://media-audio/media/1", .file, "audio/mpeg; x=y", true),
        ("dm://media-audio/media/1", .file, "audio/mpeg", false),
    ] {
        let entry = DirectoryListingEntry(path: path, name: "original.mp3", kind: kind,
            sizeBytes: 1, modifiedUnixMillis: nil, mimeType: mime, canRead: canRead,
            canWrite: false, audioMetadata: metadata)
        #expect(entry.audioMetadata == nil)
        #expect(entry.canRead == canRead)
        #expect(!entry.canWrite)
    }
}
