import Foundation

/// Validated Android destination for one product upload.
///
/// Directory paths originate from authenticated listing rows. This type does
/// not parse SAF tokens or infer platform URIs; it only appends one safe display
/// name according to the documented M1 provider shapes. Percent is rejected
/// until Android and Mac share one segment decoder, avoiding a path that looks
/// encoded on the wire but creates a different literal provider name.
public struct ProductUploadDestination: Sendable, Equatable {
    public let path: String
    public let supportsResume: Bool

    /// Returns the exact filename extensions accepted by both product peers
    /// for a MediaStore root. Non-media directories return nil.
    public static func supportedMediaFileExtensions(
        directoryPath: String
    ) -> [String]? {
        switch directoryPath {
        case "dm://media-images/": return imageFileExtensions.sorted()
        case "dm://media-videos/": return videoFileExtensions.sorted()
        default: return nil
        }
    }

    public init?(directoryPath: String, fileName: String) {
        guard Self.isSafeFileName(fileName) else { return nil }

        if directoryPath.hasPrefix("dm://app-sandbox/"),
           directoryPath.hasSuffix("/") {
            guard !Self.isReservedLegacyAppSandboxPartialName(fileName) else {
                return nil
            }
            path = directoryPath + fileName
            supportsResume = true
            return
        }

        if directoryPath == "dm://media-images/" {
            guard Self.imageFileExtensions.contains(Self.fileExtension(fileName)) else {
                return nil
            }
            path = directoryPath + fileName
            supportsResume = false
            return
        }

        if directoryPath == "dm://media-videos/" {
            guard Self.videoFileExtensions.contains(Self.fileExtension(fileName)) else {
                return nil
            }
            path = directoryPath + fileName
            supportsResume = false
            return
        }

        guard Self.isSafDirectoryPath(directoryPath) else { return nil }
        path = directoryPath.hasSuffix("/")
            ? directoryPath + fileName
            : directoryPath + "/" + fileName
        supportsResume = true
    }

    private static func isSafDirectoryPath(_ path: String) -> Bool {
        let prefix = "dm://saf-"
        guard path.hasPrefix(prefix) else { return false }
        let remainder = path.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: "/") else { return false }
        let rootID = remainder[..<separator]
        let relative = remainder[remainder.index(after: separator)...]
        guard isOpaqueComponent(rootID) else { return false }
        if relative.isEmpty { return true }
        guard relative.hasPrefix("doc/") else { return false }
        let token = relative.dropFirst("doc/".count)
        return isOpaqueComponent(token)
    }

    private static func isOpaqueComponent<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace
                && !CharacterSet.controlCharacters.contains($0)
                && $0 != "/"
                && $0 != "%"
        }
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            $0 != "/"
                && $0 != "%"
                && !CharacterSet.controlCharacters.contains($0)
                && $0.properties.generalCategory != .format
        }
    }

    private static func isReservedLegacyAppSandboxPartialName(_ value: String) -> Bool {
        value.hasPrefix(".") && value.hasSuffix(".droidmatch-upload-part")
    }

    private static func fileExtension(_ value: String) -> String {
        guard let separator = value.lastIndex(of: "."),
              separator < value.index(before: value.endIndex) else { return "" }
        return value[value.index(after: separator)...].lowercased()
    }

    // Keep this filename-level contract aligned with Android
    // ProviderMimeTypes. Without a wire-declared content type, accepting an
    // unknown or cross-category extension would force Android to forge a MIME
    // type and could publish a corrupt MediaStore row.
    private static let imageFileExtensions: Set<String> = [
        "avif", "bmp", "dng", "gif", "heic", "heif", "jpeg", "jpg",
        "png", "tif", "tiff", "webp",
    ]
    private static let videoFileExtensions: Set<String> = [
        "3gp", "3gpp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4",
        "mpeg", "mpg", "ogv", "webm",
    ]
}
