import Foundation
import Testing
@testable import DroidMatchAppSupport

@Test
func uploadSelectionAcceptsRegularFilesInStableOrder() throws {
    try withUploadSelectionDirectory { directory in
        let first = try makeUploadFile(directory, name: "first.bin")
        let second = try makeUploadFile(directory, name: "second.bin")

        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [second, first],
            directoryPath: "dm://app-sandbox/imports/"
        ) == [second, first])
    }
}

@Test
func uploadSelectionRejectsEmptyAndOversizedBatches() throws {
    #expect(ProductUploadSelectionPolicy.validatedFiles(
        [],
        directoryPath: "dm://app-sandbox/"
    ) == nil)

    try withUploadSelectionDirectory { directory in
        let file = try makeUploadFile(directory, name: "source.bin")
        #expect(ProductUploadSelectionPolicy.validatedFiles(
            Array(repeating: file, count: ProductUploadSelectionPolicy.maximumFileCount + 1),
            directoryPath: "dm://app-sandbox/"
        ) == nil)
    }
}

@Test
func uploadSelectionRejectsCanonicalCaseAndWidthDuplicateNames() throws {
    try withUploadSelectionDirectory { directory in
        let firstDirectory = directory.appendingPathComponent("a", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("b", isDirectory: true)
        let thirdDirectory = directory.appendingPathComponent("c", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: thirdDirectory, withIntermediateDirectories: false)
        let first = try makeUploadFile(firstDirectory, name: "Photo.JPG")
        let second = try makeUploadFile(secondDirectory, name: "photo.jpg")
        let widthVariant = try makeUploadFile(thirdDirectory, name: "ｐｈｏｔｏ.jpg")

        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [first, second],
            directoryPath: "dm://media-images/"
        ) == nil)
        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [first, widthVariant],
            directoryPath: "dm://media-images/"
        ) == nil)
    }
}

@Test
func uploadSelectionRejectsDirectoriesAndSymbolicLinks() throws {
    try withUploadSelectionDirectory { directory in
        let file = try makeUploadFile(directory, name: "source.bin")
        let childDirectory = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: false)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [childDirectory],
            directoryPath: "dm://app-sandbox/"
        ) == nil)
        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [link],
            directoryPath: "dm://app-sandbox/"
        ) == nil)
    }
}

@Test
func uploadSelectionEnforcesMediaCategoryExtensions() throws {
    try withUploadSelectionDirectory { directory in
        let image = try makeUploadFile(directory, name: "photo.jpg")
        let video = try makeUploadFile(directory, name: "clip.mp4")

        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [image],
            directoryPath: "dm://media-images/"
        ) == [image])
        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [video],
            directoryPath: "dm://media-images/"
        ) == nil)
    }
}

@Test
func uploadSelectionRejectsUnsafeDestinationNames() throws {
    try withUploadSelectionDirectory { directory in
        let file = try makeUploadFile(directory, name: "100%done.bin")
        #expect(ProductUploadSelectionPolicy.validatedFiles(
            [file],
            directoryPath: "dm://app-sandbox/"
        ) == nil)
    }
}

private func withUploadSelectionDirectory(
    _ operation: (URL) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidmatch-upload-selection-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func makeUploadFile(_ directory: URL, name: String) throws -> URL {
    let file = directory.appendingPathComponent(name, isDirectory: false)
    try Data([0x44, 0x4d]).write(to: file, options: .withoutOverwriting)
    return file
}
