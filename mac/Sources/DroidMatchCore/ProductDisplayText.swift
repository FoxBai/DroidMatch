import Foundation

/// Bounded UI-only text derived from platform- or peer-controlled metadata.
///
/// Callers must retain a separate stable identity for every action. This value
/// is presentation only and must never retarget a protocol or storage request.
public enum ProductDisplayText {
    public static func value(
        _ rawValue: String?,
        maximumScalars: Int = 120
    ) -> String? {
        guard let rawValue, maximumScalars > 0 else { return nil }
        let normalized = rawValue.precomposedStringWithCanonicalMapping
        var visible: [Unicode.Scalar] = []
        visible.reserveCapacity(min(normalized.unicodeScalars.count, maximumScalars))
        var pendingSpace = false
        var wasTruncated = false

        for scalar in normalized.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !visible.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate:
                continue
            default:
                break
            }
            let requiredScalars = pendingSpace ? 2 : 1
            guard visible.count + requiredScalars <= maximumScalars else {
                wasTruncated = true
                break
            }
            if pendingSpace {
                visible.append(Unicode.Scalar(0x20)!)
                pendingSpace = false
            }
            visible.append(scalar)
        }

        guard !visible.isEmpty else { return nil }
        if wasTruncated, maximumScalars > 1 {
            if visible.count == maximumScalars {
                visible.removeLast()
            }
            visible.append(Unicode.Scalar(0x2026)!)
        }
        return String(String.UnicodeScalarView(visible))
    }
}
