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

    public init?(directoryPath: String, fileName: String) {
        guard Self.isSafeFileName(fileName) else { return nil }

        if directoryPath.hasPrefix("dm://app-sandbox/"),
           directoryPath.hasSuffix("/") {
            path = directoryPath + fileName
            supportsResume = true
            return
        }

        if directoryPath == "dm://media-images/"
            || directoryPath == "dm://media-videos/" {
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
        let bidirectionalFormatting = CharacterSet(charactersIn:
            "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        return value.unicodeScalars.allSatisfy {
            $0 != "/"
                && $0 != "%"
                && !CharacterSet.controlCharacters.contains($0)
                && !bidirectionalFormatting.contains($0)
        }
    }
}
