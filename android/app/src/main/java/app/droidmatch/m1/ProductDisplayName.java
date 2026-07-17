package app.droidmatch.m1;

import java.text.Normalizer;

/** UI-only projection for peer-controlled names on security-sensitive screens. */
final class ProductDisplayName {
    static final int MAXIMUM_VISIBLE_CODE_POINTS = 120;
    private static final String DEVICE_FALLBACK = "Mac";
    private static final int ELLIPSIS_CODE_POINT = 0x2026;

    private ProductDisplayName() {
    }

    static String deviceName(String rawName) {
        return name(rawName, DEVICE_FALLBACK);
    }

    static String name(String rawName, String fallback) {
        if (rawName == null) {
            return fallback;
        }
        String normalized = Normalizer.normalize(rawName, Normalizer.Form.NFC);
        StringBuilder visible = new StringBuilder(
                Math.min(normalized.length(), MAXIMUM_VISIBLE_CODE_POINTS * 2)
        );
        boolean pendingSpace = false;
        boolean wasTruncated = false;
        int visibleCodePoints = 0;
        for (int index = 0; index < normalized.length();) {
            int codePoint = normalized.codePointAt(index);
            index += Character.charCount(codePoint);

            if (Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint)) {
                pendingSpace = visible.length() > 0;
                continue;
            }
            int type = Character.getType(codePoint);
            if (type == Character.CONTROL
                    || type == Character.FORMAT
                    || type == Character.SURROGATE) {
                continue;
            }
            int requiredCodePoints = pendingSpace ? 2 : 1;
            if (visibleCodePoints + requiredCodePoints > MAXIMUM_VISIBLE_CODE_POINTS) {
                wasTruncated = true;
                break;
            }
            if (pendingSpace) {
                visible.append(' ');
                visibleCodePoints += 1;
                pendingSpace = false;
            }
            visible.appendCodePoint(codePoint);
            visibleCodePoints += 1;
        }
        if (wasTruncated && MAXIMUM_VISIBLE_CODE_POINTS > 1) {
            if (visibleCodePoints == MAXIMUM_VISIBLE_CODE_POINTS) {
                int lastCodePoint = visible.codePointBefore(visible.length());
                visible.setLength(visible.length() - Character.charCount(lastCodePoint));
            }
            visible.appendCodePoint(ELLIPSIS_CODE_POINT);
        }
        return visible.length() == 0 ? fallback : visible.toString();
    }
}
