package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.RootKind;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListDirResponse;

import java.util.List;
import java.util.Map;

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
        return AppSandboxTarget.directory(trimTrailingSlash(relativePath));
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
        return AppSandboxTarget.file(relativePath);
    }

    static MediaTarget mediaDownload(String path) {
        if (path.startsWith(DmFileProvider.MEDIA_IMAGES_PATH + "media/")) {
            return mediaDownload(path, DmFileProvider.MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES);
        }
        if (path.startsWith(DmFileProvider.MEDIA_VIDEOS_PATH + "media/")) {
            return mediaDownload(path, DmFileProvider.MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS);
        }
        if (DmFileProvider.MEDIA_IMAGES_PATH.equals(path) || DmFileProvider.MEDIA_VIDEOS_PATH.equals(path)) {
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
        return mediaUpload(path, DmFileProvider.MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS);
    }

    static SafTarget safDirectory(
            String path,
            List<SafRoot> roots,
            Map<String, String> documentIdsByLogicalId
    ) {
        for (SafRoot root : roots) {
            String rootPath = root.path();
            if (rootPath.equals(path)) {
                return SafTarget.directory(root, root.documentId);
            }
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
            String logicalDocumentId = relative.substring(SAF_DOCUMENT_PREFIX.length());
            if (logicalDocumentId.isEmpty() || logicalDocumentId.contains("/")) {
                return SafTarget.error(listError(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "malformed SAF path"
                ));
            }
            String documentId = documentIdsByLogicalId.get(safDocumentCacheKey(root, logicalDocumentId));
            if (documentId == null) {
                return SafTarget.error(listError(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown SAF document path"
                ));
            }
            return SafTarget.directory(root, documentId);
        }
        return null;
    }

    static SafUploadTarget safUpload(
            String path,
            List<SafRoot> roots,
            Map<String, String> documentIdsByLogicalId
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
                return safUpload(root, root.documentId, relative);
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
            String parentDocumentId = documentIdsByLogicalId.get(safDocumentCacheKey(root, logicalParentId));
            if (parentDocumentId == null) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown SAF directory path"
                ));
            }
            return safUpload(root, parentDocumentId, displayName);
        }
        return null;
    }

    static String cacheSafDocumentId(
            Map<String, String> documentIdsByLogicalId,
            SafRoot root,
            String documentId
    ) {
        String logicalId = ProviderOpaqueIds.stable(root.stableId + "\n" + documentId, 8);
        documentIdsByLogicalId.put(safDocumentCacheKey(root, logicalId), documentId);
        return logicalId;
    }

    private static SafUploadTarget safUpload(SafRoot root, String parentDocumentId, String displayName) {
        if (!isValidUploadDisplayName(displayName)) {
            return SafUploadTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed SAF upload file name"
            ));
        }
        return SafUploadTarget.file(root, parentDocumentId, displayName);
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
        if (rawId.isEmpty() || rawId.contains("/")) {
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
        return !displayName.isEmpty()
                && !".".equals(displayName)
                && !"..".equals(displayName)
                && displayName.indexOf('\0') < 0
                && !displayName.contains("/");
    }

    private static String trimTrailingSlash(String value) {
        return value.endsWith("/") ? value.substring(0, value.length() - 1) : value;
    }

    private static String safDocumentCacheKey(SafRoot root, String logicalId) {
        return root.stableId + "/" + logicalId;
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
        final String documentId;
        final ListDirResponse error;

        private SafTarget(SafRoot root, String documentId, ListDirResponse error) {
            this.root = root;
            this.documentId = documentId;
            this.error = error;
        }

        static SafTarget directory(SafRoot root, String documentId) {
            return new SafTarget(root, documentId, null);
        }

        static SafTarget error(ListDirResponse error) {
            return new SafTarget(null, null, error);
        }
    }

    static final class SafUploadTarget {
        final SafRoot root;
        final String parentDocumentId;
        final String displayName;
        final ProviderCatalogException error;

        private SafUploadTarget(
                SafRoot root,
                String parentDocumentId,
                String displayName,
                ProviderCatalogException error
        ) {
            this.root = root;
            this.parentDocumentId = parentDocumentId;
            this.displayName = displayName;
            this.error = error;
        }

        static SafUploadTarget file(SafRoot root, String parentDocumentId, String displayName) {
            return new SafUploadTarget(root, parentDocumentId, displayName, null);
        }

        static SafUploadTarget error(ProviderCatalogException error) {
            return new SafUploadTarget(null, null, null, error);
        }
    }
}
