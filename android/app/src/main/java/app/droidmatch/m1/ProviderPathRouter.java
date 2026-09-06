package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.RootKind;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirResponse;

import java.util.List;

/**
 * Resolves wire-safe {@code dm://} paths into provider targets.
 *
 * <p>SAF document IDs remain process-local: callers own the bounded token map,
 * while this router is the only layer that turns logical path tokens back into
 * platform document IDs. Raw document IDs and content URIs never cross the
 * protocol boundary.</p>
 */
final class ProviderPathRouter {
    static final String SAF_DOCUMENT_PREFIX = "doc/";

    private ProviderPathRouter() {
    }

    static AppSandboxTarget appSandboxDirectory(String path) {
        if (!path.startsWith(DmFileProvider.APP_SANDBOX_PATH)) {
            return null;
        }
        String relativePath = path.substring(DmFileProvider.APP_SANDBOX_PATH.length());
        if (!relativePath.isEmpty() && !relativePath.endsWith("/")) {
            return AppSandboxTarget.error(listError(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "ListDirRequest.path must identify an app sandbox directory"
            ));
        }
        String trimmedPath = trimTrailingSlash(relativePath);
        if ((!relativePath.isEmpty() && trimmedPath.isEmpty())
                || !isCanonicalAppSandboxRelativePath(trimmedPath)) {
            return AppSandboxTarget.error(listError(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed app sandbox path"
            ));
        }
        return AppSandboxTarget.directory(trimmedPath);
    }

    static AppSandboxTarget appSandboxFile(String path) {
        if (!path.startsWith(DmFileProvider.APP_SANDBOX_PATH)) {
            return null;
        }
        String relativePath = path.substring(DmFileProvider.APP_SANDBOX_PATH.length());
        if (relativePath.isEmpty() || relativePath.endsWith("/")) {
            return AppSandboxTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer source_path must identify a file entry"
            ));
        }
        if (!isCanonicalAppSandboxRelativePath(relativePath)) {
            return AppSandboxTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed app sandbox path"
            ));
        }
        return AppSandboxTarget.file(relativePath);
    }

    static AppSandboxTarget appSandboxUploadFile(String path) {
        AppSandboxTarget target = appSandboxFile(path);
        if (target == null || target.downloadError != null) {
            return target;
        }
        int separator = target.relativePath.lastIndexOf('/');
        String displayName = target.relativePath.substring(separator + 1);
        if (!isValidUploadDisplayName(displayName)) {
            return AppSandboxTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed app sandbox upload file name"
            ));
        }
        return target;
    }

    /** Validates the lexical path before any filesystem canonicalization can erase aliases. */
    static boolean isCanonicalAppSandboxRelativePath(String relativePath) {
        if (relativePath == null) return false;
        if (relativePath.isEmpty()) return true;
        if (relativePath.indexOf('\0') >= 0
                || relativePath.startsWith("/")
                || relativePath.endsWith("/")) {
            return false;
        }
        for (String segment : relativePath.split("/", -1)) {
            if (segment.isEmpty()
                    || ".".equals(segment)
                    || "..".equals(segment)
                    || isReservedLegacyUploadPartialName(segment)) {
                return false;
            }
        }
        return true;
    }

    static boolean isReservedLegacyUploadPartialName(String name) {
        return name.startsWith(".") && name.endsWith(".droidmatch-upload-part");
    }

    static MediaTarget mediaDownload(String path) {
        if (path.startsWith(DmFileProvider.MEDIA_IMAGES_PATH + "media/")) {
            return mediaDownload(path, DmFileProvider.MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES);
        }
        if (path.startsWith(DmFileProvider.MEDIA_VIDEOS_PATH + "media/")) {
            return mediaDownload(path, DmFileProvider.MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS);
        }
        if (path.startsWith(DmFileProvider.MEDIA_AUDIO_PATH + "media/")) {
            return mediaDownload(path, DmFileProvider.MEDIA_AUDIO_PATH, RootKind.MEDIA_AUDIO);
        }
        if (DmFileProvider.MEDIA_IMAGES_PATH.equals(path) || DmFileProvider.MEDIA_VIDEOS_PATH.equals(path)
                || DmFileProvider.MEDIA_AUDIO_PATH.equals(path)) {
            return MediaTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer source_path must identify a file entry"
            ));
        }
        return null;
    }

    static MediaUploadTarget mediaUpload(String path) {
        MediaUploadTarget target = mediaUpload(
                path,
                DmFileProvider.MEDIA_IMAGES_PATH,
                RootKind.MEDIA_IMAGES
        );
        if (target != null) {
            return target;
        }
        target = mediaUpload(path, DmFileProvider.MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS);
        return target != null ? target
                : mediaUpload(path, DmFileProvider.MEDIA_AUDIO_PATH, RootKind.MEDIA_AUDIO);
    }

    static SafTarget safDirectory(
            String path,
            final List<SafRoot> roots,
            ProviderSafDocumentCache safDocumentCache
    ) {
        for (SafRoot root : roots) {
            String rootPath = root.path();
            String logicalDocumentId;
            if (rootPath.equals(path)) {
                logicalDocumentId = null;
            } else {
                if (!path.startsWith(rootPath)) {
                    continue;
                }
                String relative = path.substring(rootPath.length());
                if (!relative.startsWith(SAF_DOCUMENT_PREFIX)) {
                    return SafTarget.error(listError(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "malformed SAF path"
                    ));
                }
                logicalDocumentId = relative.substring(SAF_DOCUMENT_PREFIX.length());
                if (logicalDocumentId.isEmpty() || logicalDocumentId.contains("/")) {
                    return SafTarget.error(listError(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "malformed SAF path"
                    ));
                }
            }
            ProviderSafDocumentCache.ListingResolution resolution =
                    safDocumentCache.resolveForListing(root, logicalDocumentId);
            if (resolution == null) {
                return SafTarget.error(listError(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown SAF document path"
                ));
            }
            return SafTarget.directory(
                    root,
                    roots,
                    resolution.target.documentId,
                    resolution.target.parentDocumentId,
                    resolution.target.displayName,
                    resolution.target.kind,
                    resolution.epoch
            );
        }
        return null;
    }

    static SafUploadTarget safUpload(
            String path,
            final List<SafRoot> roots,
            ProviderSafDocumentCache safDocumentCache
    ) {
        for (SafRoot root : roots) {
            String rootPath = root.path();
            if (!path.startsWith(rootPath)) {
                continue;
            }

            String relative = path.substring(rootPath.length());
            if (relative.isEmpty() || relative.endsWith("/")) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer destination_path must identify a SAF file entry"
                ));
            }
            if (!relative.startsWith(SAF_DOCUMENT_PREFIX)) {
                if (relative.contains("/")) {
                    return SafUploadTarget.error(new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "malformed SAF upload path"
                    ));
                }
                return safUpload(root, roots, root.documentId, relative);
            }

            String documentRelative = relative.substring(SAF_DOCUMENT_PREFIX.length());
            int separator = documentRelative.indexOf('/');
            if (separator <= 0 || separator == documentRelative.length() - 1) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "SAF upload destination must include a file name after the directory path"
                ));
            }
            String logicalParentId = documentRelative.substring(0, separator);
            String displayName = documentRelative.substring(separator + 1);
            if (displayName.contains("/")) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "malformed SAF upload path"
                ));
            }
            String parentDocumentId = safDocumentCache.documentId(root, logicalParentId);
            if (parentDocumentId == null) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown SAF directory path"
                ));
            }
            return safUpload(root, roots, parentDocumentId, displayName);
        }
        return null;
    }

    /** Resolves a new-directory path using the same opaque parent token shape as uploads. */
    static SafUploadTarget safCreateDirectory(
            String path,
            final List<SafRoot> roots,
            ProviderSafDocumentCache safDocumentCache
    ) {
        if (path == null || !path.endsWith("/")) {
            return null;
        }
        return safUpload(path.substring(0, path.length() - 1), roots, safDocumentCache);
    }

    private static SafUploadTarget safUpload(
            SafRoot root,
            final List<SafRoot> roots,
            String parentDocumentId,
            String displayName
    ) {
        if (!isValidUploadDisplayName(displayName)
                || SafDocumentPolicy.isUploadPartialDisplayName(displayName)) {
            return SafUploadTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed SAF upload file name"
            ));
        }
        return SafUploadTarget.file(root, roots, parentDocumentId, displayName);
    }

    private static MediaUploadTarget mediaUpload(String path, String rootPath, RootKind rootKind) {
        if (!path.startsWith(rootPath)) {
            return null;
        }

        String displayName = path.substring(rootPath.length());
        if (displayName.isEmpty() || displayName.endsWith("/")) {
            return MediaUploadTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer destination_path must identify a MediaStore file entry"
            ));
        }
        if (!isValidUploadDisplayName(displayName)) {
            return MediaUploadTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed MediaStore upload file name"
            ));
        }
        return MediaUploadTarget.file(rootKind, displayName);
    }

    private static MediaTarget mediaDownload(String path, String rootPath, RootKind rootKind) {
        String rawId = path.substring((rootPath + "media/").length());
        if (rawId.isEmpty() || !rawId.chars().allMatch(value -> value >= '0' && value <= '9')) {
            return MediaTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed media path"
            ));
        }
        try {
            long mediaId = Long.parseLong(rawId);
            if (mediaId < 0) {
                return MediaTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "malformed media path"
                ));
            }
            return MediaTarget.file(rootKind, mediaId);
        } catch (NumberFormatException exception) {
            return MediaTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed media path"
            ));
        }
    }

    private static boolean isValidUploadDisplayName(String displayName) {
        if (displayName.isEmpty()
                || ".".equals(displayName)
                || "..".equals(displayName)
                || displayName.indexOf('%') >= 0
                || displayName.contains("/")) {
            return false;
        }
        for (int index = 0; index < displayName.length();) {
            int codePoint = displayName.codePointAt(index);
            int type = Character.getType(codePoint);
            if (type == Character.CONTROL
                    || type == Character.FORMAT
                    || isBidirectionalFormatting(codePoint)) {
                return false;
            }
            index += Character.charCount(codePoint);
        }
        return true;
    }

    private static boolean isBidirectionalFormatting(int codePoint) {
        switch (codePoint) {
            case 0x061C:
            case 0x200E:
            case 0x200F:
            case 0x202A:
            case 0x202B:
            case 0x202C:
            case 0x202D:
            case 0x202E:
            case 0x2066:
            case 0x2067:
            case 0x2068:
            case 0x2069:
                return true;
            default:
                return false;
        }
    }

    private static String trimTrailingSlash(String value) {
        return value.endsWith("/") ? value.substring(0, value.length() - 1) : value;
    }

    private static ListDirResponse listError(ErrorCode code, String message) {
        return ListDirResponse.newBuilder()
                .setError(DroidMatchError.newBuilder()
                        .setCode(code)
                        .setMessage(message)
                        .build())
                .build();
    }

    static final class AppSandboxTarget {
        final String relativePath;
        final ListDirResponse error;
        final ProviderCatalogException downloadError;

        private AppSandboxTarget(
                String relativePath,
                ListDirResponse error,
                ProviderCatalogException downloadError
        ) {
            this.relativePath = relativePath;
            this.error = error;
            this.downloadError = downloadError;
        }

        static AppSandboxTarget directory(String relativePath) {
            return new AppSandboxTarget(relativePath, null, null);
        }

        static AppSandboxTarget file(String relativePath) {
            return new AppSandboxTarget(relativePath, null, null);
        }

        static AppSandboxTarget error(ListDirResponse error) {
            return new AppSandboxTarget(null, error, null);
        }

        static AppSandboxTarget error(ProviderCatalogException error) {
            return new AppSandboxTarget(null, null, error);
        }
    }

    static final class MediaTarget {
        final RootKind rootKind;
        final long mediaId;
        final ProviderCatalogException error;

        private MediaTarget(RootKind rootKind, long mediaId, ProviderCatalogException error) {
            this.rootKind = rootKind;
            this.mediaId = mediaId;
            this.error = error;
        }

        static MediaTarget file(RootKind rootKind, long mediaId) {
            return new MediaTarget(rootKind, mediaId, null);
        }

        static MediaTarget error(ProviderCatalogException error) {
            return new MediaTarget(null, 0, error);
        }
    }

    static final class MediaUploadTarget {
        final RootKind rootKind;
        final String displayName;
        final ProviderCatalogException error;

        private MediaUploadTarget(RootKind rootKind, String displayName, ProviderCatalogException error) {
            this.rootKind = rootKind;
            this.displayName = displayName;
            this.error = error;
        }

        static MediaUploadTarget file(RootKind rootKind, String displayName) {
            return new MediaUploadTarget(rootKind, displayName, null);
        }

        static MediaUploadTarget error(ProviderCatalogException error) {
            return new MediaUploadTarget(null, null, error);
        }
    }

    static final class SafTarget {
        final SafRoot root;
        final List<SafRoot> rootsSnapshot;
        final String documentId;
        final String parentDocumentId;
        final String displayName;
        final FileKind kind;
        final Object cacheEpoch;
        final ListDirResponse error;

        private SafTarget(
                SafRoot root,
                final List<SafRoot> rootsSnapshot,
                String documentId,
                String parentDocumentId,
                String displayName,
                FileKind kind,
                final Object cacheEpoch,
                ListDirResponse error
        ) {
            this.root = root;
            this.rootsSnapshot = rootsSnapshot;
            this.documentId = documentId;
            this.parentDocumentId = parentDocumentId;
            this.displayName = displayName;
            this.kind = kind;
            this.cacheEpoch = cacheEpoch;
            this.error = error;
        }

        private static SafTarget directory(
                SafRoot root,
                final List<SafRoot> rootsSnapshot,
                String documentId,
                String parentDocumentId,
                String displayName,
                FileKind kind,
                final Object cacheEpoch
        ) {
            return new SafTarget(
                    root,
                    rootsSnapshot,
                    documentId,
                    parentDocumentId,
                    displayName,
                    kind,
                    cacheEpoch,
                    null
            );
        }

        static SafTarget error(ListDirResponse error) {
            return new SafTarget(null, null, null, null, null, null, null, error);
        }
    }

    static final class SafUploadTarget {
        final SafRoot root;
        final List<SafRoot> rootsSnapshot;
        final String parentDocumentId;
        final String displayName;
        final ProviderCatalogException error;

        private SafUploadTarget(
                SafRoot root,
                final List<SafRoot> rootsSnapshot,
                String parentDocumentId,
                String displayName,
                ProviderCatalogException error
        ) {
            this.root = root;
            this.rootsSnapshot = rootsSnapshot;
            this.parentDocumentId = parentDocumentId;
            this.displayName = displayName;
            this.error = error;
        }

        private static SafUploadTarget file(
                SafRoot root,
                final List<SafRoot> rootsSnapshot,
                String parentDocumentId,
                String displayName
        ) {
            return new SafUploadTarget(
                    root,
                    rootsSnapshot,
                    parentDocumentId,
                    displayName,
                    null
            );
        }

        static SafUploadTarget error(ProviderCatalogException error) {
            return new SafUploadTarget(null, null, null, null, error);
        }
    }
}
