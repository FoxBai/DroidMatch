package app.droidmatch.m1;

import java.net.URLConnection;
import java.util.Locale;

/** MIME inference and bounded wire-metadata validation shared by provider paths. */
final class ProviderMimeTypes {
    private static final int MAXIMUM_METADATA_UTF8_BYTES = 127;

    private ProviderMimeTypes() {
    }

    static String fromDisplayName(String displayName) {
        String knownMediaType = knownMediaType(displayName);
        if (knownMediaType != null) return knownMediaType;
        String guessed = URLConnection.guessContentTypeFromName(displayName);
        return guessed == null || guessed.isEmpty() ? "application/octet-stream" : guessed;
    }

    static String mediaTypeFor(
            DmFileProvider.RootKind rootKind,
            String displayName
    ) {
        // MediaStore uses the repository's exact cross-platform allowlist.
        // URLConnection is intentionally excluded here because its mapping can
        // vary by runtime (for example SVG or ambiguous .ts), drifting from the
        // Mac admission boundary.
        String mimeType = knownMediaType(displayName);
        if (mimeType == null) return null;
        if (rootKind == DmFileProvider.RootKind.MEDIA_IMAGES) {
            return mimeType.startsWith("image/") ? mimeType : null;
        }
        if (rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS) {
            return mimeType.startsWith("video/") ? mimeType : null;
        }
        return null;
    }

    static boolean isCanonicalVideoMetadata(String rawValue) {
        String canonical = canonicalMetadata(rawValue);
        return canonical != null && canonical.startsWith("video/");
    }

    private static String canonicalMetadata(String rawValue) {
        if (rawValue == null || rawValue.isEmpty()
                || rawValue.length() > MAXIMUM_METADATA_UTF8_BYTES) {
            return null;
        }
        for (int index = 0; index < rawValue.length(); index++) {
            if (rawValue.charAt(index) >= 0x80) return null;
        }
        String canonical = rawValue.toLowerCase(Locale.ROOT);
        int slash = canonical.indexOf('/');
        if (slash <= 0 || slash >= canonical.length() - 1
                || canonical.indexOf('/', slash + 1) >= 0
                || !isRestrictedName(canonical, 0, slash)
                || !isRestrictedName(canonical, slash + 1, canonical.length())) {
            return null;
        }
        return canonical;
    }

    private static boolean isRestrictedName(String value, int start, int end) {
        if (!isAsciiAlphaNumeric(value.charAt(start))
                || !isAsciiAlphaNumeric(value.charAt(end - 1))) {
            return false;
        }
        for (int index = start; index < end; index++) {
            char character = value.charAt(index);
            if (!isAsciiAlphaNumeric(character) && "!#$&+-.^_".indexOf(character) < 0) {
                return false;
            }
        }
        return true;
    }

    private static boolean isAsciiAlphaNumeric(char value) {
        return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'z');
    }

    private static String knownMediaType(String displayName) {
        int separator = displayName.lastIndexOf('.');
        if (separator < 0 || separator == displayName.length() - 1) return null;
        String extension = displayName.substring(separator + 1).toLowerCase(Locale.ROOT);
        switch (extension) {
            case "jpg":
            case "jpeg": return "image/jpeg";
            case "png": return "image/png";
            case "gif": return "image/gif";
            case "bmp": return "image/bmp";
            case "webp": return "image/webp";
            case "heic": return "image/heic";
            case "heif": return "image/heif";
            case "avif": return "image/avif";
            case "dng": return "image/x-adobe-dng";
            case "tif":
            case "tiff": return "image/tiff";
            case "mp4":
            case "m4v": return "video/mp4";
            case "mov": return "video/quicktime";
            case "3gp":
            case "3gpp": return "video/3gpp";
            case "webm": return "video/webm";
            case "mkv": return "video/x-matroska";
            case "mpg":
            case "mpeg": return "video/mpeg";
            case "avi": return "video/x-msvideo";
            case "m2ts": return "video/mp2t";
            case "ogv": return "video/ogg";
            default: return null;
        }
    }
}
