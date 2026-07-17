import AppKit
import DroidMatchAppSupport
import DroidMatchCore
import UniformTypeIdentifiers

/// Keeps native picker guidance and the product submission boundary aligned.
/// Android remains authoritative and repeats the filename-category validation.
@MainActor
enum ProductUploadPanelPolicy {
    static let maximumFileCount = ProductUploadSelectionPolicy.maximumFileCount

    static func makePanel(directoryPath: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        guard let extensions = ProductUploadDestination
            .supportedMediaFileExtensions(directoryPath: directoryPath) else {
            return panel
        }
        var identifiers = Set<String>()
        panel.allowedContentTypes = extensions.compactMap { fileExtension in
            guard let type = UTType(filenameExtension: fileExtension),
                  identifiers.insert(type.identifier).inserted else { return nil }
            return type
        }
        return panel
    }

    static func acceptedFiles(_ urls: [URL], directoryPath: String) -> [URL]? {
        ProductUploadSelectionPolicy.validatedFiles(urls, directoryPath: directoryPath)
    }
}
