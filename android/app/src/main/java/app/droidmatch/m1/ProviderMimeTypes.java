package app.droidmatch.m1;

import java.net.URLConnection;
import java.util.Locale;

/** MIME inference shared by provider upload catalogs. */
final class ProviderMimeTypes {
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
