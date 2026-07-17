import Foundation

/// Canonical, bounded MIME metadata safe for product presentation and hints.
///
/// Provider MIME values are descriptive only; they never grant capability or
/// authorize an operation. Invalid optional metadata degrades to nil so one
/// malformed label cannot suppress an otherwise valid directory entry.
public enum ProductMimeType {
    public static let maximumUTF8Length = 127

    private static let productLabels: Set<String> = [
        "vnd.droidmatch.root",
        "vnd.droidmatch.media-album",
    ]

    public static func value(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let bytes = Array(rawValue.utf8)
        guard bytes.count <= maximumUTF8Length,
              bytes.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }

        let canonical = rawValue.lowercased()
        if productLabels.contains(canonical) {
            return canonical
        }

        let canonicalBytes = Array(canonical.utf8)
        guard let slash = canonicalBytes.firstIndex(of: 0x2F),
              slash > canonicalBytes.startIndex,
              slash < canonicalBytes.index(before: canonicalBytes.endIndex),
              canonicalBytes[canonicalBytes.index(after: slash)...].allSatisfy({ $0 != 0x2F }),
              isRestrictedName(canonicalBytes[..<slash]),
              isRestrictedName(canonicalBytes[canonicalBytes.index(after: slash)...]) else {
            return nil
        }
        return canonical
    }

    private static func isRestrictedName(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let first = bytes.first,
              let last = bytes.last,
              isAlphaNumeric(first),
              isAlphaNumeric(last) else {
            return false
        }
        return bytes.allSatisfy { byte in
            isAlphaNumeric(byte) || restrictedPunctuation.contains(byte)
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static let restrictedPunctuation: Set<UInt8> = [
        0x21, // !
        0x23, // #
        0x24, // $
        0x26, // &
        0x2B, // +
        0x2D, // -
        0x2E, // .
        0x5E, // ^
        0x5F, // _
    ]
}
