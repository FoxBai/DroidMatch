import DroidMatchCore
import Foundation

/// Platform admission for one native-picker or drag-and-drop upload batch.
///
/// This is an early UX boundary, not the file-ownership authority. The queue
/// adapter still commits one security-scoped bookmark per accepted URL, and
/// Core opens every source with `O_NOFOLLOW` and revalidates its identity before
/// reading. AppSupport owns this check because reading URL resource values is
/// platform file I/O; Presentation remains free of filesystem access.
public enum ProductUploadSelectionPolicy {
    public static let maximumFileCount = 100

    public static func validatedFiles(
        _ urls: [URL],
        directoryPath: String
    ) -> [URL]? {
        guard !urls.isEmpty, urls.count <= maximumFileCount else { return nil }

        var names = Set<String>()
        for url in urls {
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  ProductUploadDestination(
                      directoryPath: directoryPath,
                      fileName: url.lastPathComponent
                  ) != nil,
                  names.insert(normalizedName(url.lastPathComponent)).inserted else {
                return nil
            }
        }
        return urls
    }

    private static func normalizedName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
