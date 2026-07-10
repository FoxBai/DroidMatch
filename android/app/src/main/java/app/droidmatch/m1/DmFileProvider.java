package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.Context;
import android.net.Uri;

import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.io.Closeable;
import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class DmFileProvider {
    public static final String ROOTS_PATH = "dm://roots/";
    public static final String MEDIA_IMAGES_PATH = "dm://media-images/";
    public static final String MEDIA_VIDEOS_PATH = "dm://media-videos/";
    public static final String APP_SANDBOX_PATH = "dm://app-sandbox/";

    private static final int DEFAULT_PAGE_SIZE = 200;
    private static final int MAX_PAGE_SIZE = 1_000;
    private static final int MAX_SAF_DOCUMENT_CACHE_ENTRIES = 4_096;
    private static final String PAGE_TOKEN_PREFIX = "v1:";
    private static final String SAF_DOCUMENT_PREFIX = "doc/";

    private static final StaticRoot[] STATIC_ROOTS = new StaticRoot[] {
            new StaticRoot("Images", MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES),
            new StaticRoot("Videos", MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS),
            new StaticRoot("App Sandbox", APP_SANDBOX_PATH, RootKind.APP_SANDBOX)
    };

    private final MediaCatalog mediaCatalog;
    private final SafCatalog safCatalog;
    private final AppSandboxCatalog appSandboxCatalog;
    private final Map<String, String> safDocumentIdsByLogicalId;

    public DmFileProvider() {
        this(MediaCatalog.empty(), SafCatalog.empty(), AppSandboxCatalog.empty());
    }

    public DmFileProvider(Context context) {
        this(context, new PermissionStateProvider(context));
    }

    public DmFileProvider(Context context, PermissionStateProvider permissionStateProvider) {
        Context applicationContext = context.getApplicationContext();
        ContentResolver contentResolver = applicationContext.getContentResolver();
        this.mediaCatalog = new AndroidMediaCatalog(contentResolver, permissionStateProvider);
        this.safCatalog = new AndroidSafCatalog(contentResolver);
        this.appSandboxCatalog = new AndroidAppSandboxCatalog(
                new File(applicationContext.getFilesDir(), "droidmatch-sandbox")
        );
        this.safDocumentIdsByLogicalId = safDocumentCache(MAX_SAF_DOCUMENT_CACHE_ENTRIES);
    }

    DmFileProvider(MediaCatalog mediaCatalog) {
        this(mediaCatalog, SafCatalog.empty(), AppSandboxCatalog.empty());
    }

    DmFileProvider(MediaCatalog mediaCatalog, SafCatalog safCatalog) {
        this(mediaCatalog, safCatalog, AppSandboxCatalog.empty());
    }

    DmFileProvider(File appSandboxRootDirectory) {
        this(
                MediaCatalog.empty(),
                SafCatalog.empty(),
                new AndroidAppSandboxCatalog(appSandboxRootDirectory)
        );
    }

    DmFileProvider(MediaCatalog mediaCatalog, SafCatalog safCatalog, AppSandboxCatalog appSandboxCatalog) {
        this(mediaCatalog, safCatalog, appSandboxCatalog, MAX_SAF_DOCUMENT_CACHE_ENTRIES);
    }

    DmFileProvider(
            MediaCatalog mediaCatalog,
            SafCatalog safCatalog,
            AppSandboxCatalog appSandboxCatalog,
            int maxSafDocumentCacheEntries
    ) {
        this.mediaCatalog = mediaCatalog;
        this.safCatalog = safCatalog;
        this.appSandboxCatalog = appSandboxCatalog;
        this.safDocumentIdsByLogicalId = safDocumentCache(maxSafDocumentCacheEntries);
    }

    public String[] listRoots() {
        List<SafRoot> safRoots = safCatalog.roots();
        String[] paths = new String[STATIC_ROOTS.length + safRoots.size()];
        int index = 0;
        for (StaticRoot root : STATIC_ROOTS) {
            paths[index] = root.path;
            index++;
        }
        for (SafRoot root : safRoots) {
            paths[index] = root.path();
            index++;
        }
        return paths;
    }

    public ListDirResponse listDir(ListDirRequest request) {
        if (ROOTS_PATH.equals(request.getPath())) {
            return listRootDirectory(request);
        }

        AppSandboxTarget appSandboxTarget = appSandboxTargetForDirectoryPath(request.getPath());
        if (appSandboxTarget != null) {
            if (appSandboxTarget.error != null) {
                return appSandboxTarget.error;
            }
            return listAppSandboxDirectory(appSandboxTarget.relativePath, request);
        }

        StaticRoot staticRoot = staticRootForPath(request.getPath());
        if (staticRoot != null) {
            return listMediaRoot(staticRoot, request);
        }

        SafTarget safTarget = safTargetForPath(request.getPath());
        if (safTarget != null) {
            if (safTarget.error != null) {
                return safTarget.error;
            }
            return listSafDirectory(safTarget, request);
        }

        return errorResponse(
                ErrorCode.ERROR_CODE_NOT_FOUND,
                "unknown DroidMatch provider path: " + request.getPath()
        );
    }

    public DownloadChunk readDownloadChunk(String path, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException {
        try (DownloadReader reader = openDownload(path, offsetBytes, chunkSizeBytes)) {
            return reader.readNextChunk();
        }
    }

    public DownloadReader openDownload(String path, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException {
        if (offsetBytes < 0) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes must be non-negative"
            );
        }
        if (chunkSizeBytes <= 0) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "chunk_size_bytes must be positive"
            );
        }

        MediaTarget mediaTarget = mediaTargetForPath(path);
        if (mediaTarget != null) {
            if (mediaTarget.error != null) {
                throw mediaTarget.error;
            }
            return mediaCatalog.openMedia(
                    mediaTarget.rootKind,
                    mediaTarget.mediaId,
                    offsetBytes,
                    chunkSizeBytes
            );
        }

        AppSandboxTarget appSandboxTarget = appSandboxTargetForFilePath(path);
        if (appSandboxTarget != null) {
            if (appSandboxTarget.downloadError != null) {
                throw appSandboxTarget.downloadError;
            }
            return appSandboxCatalog.openFile(
                    appSandboxTarget.relativePath,
                    offsetBytes,
                    chunkSizeBytes
            );
        }

        SafTarget safTarget = safTargetForPath(path);
        if (safTarget != null) {
            if (safTarget.error != null) {
                throw new ProviderCatalogException(
                        safTarget.error.getError().getCode(),
                        safTarget.error.getError().getMessage()
                );
            }
            return safCatalog.openDocument(
                    safTarget.root,
                    safTarget.documentId,
                    offsetBytes,
                    chunkSizeBytes
            );
        }

        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_NOT_FOUND,
                "unknown DroidMatch provider path: " + path
        );
    }

    public UploadWriter openUpload(String path, long offsetBytes, long expectedSizeBytes)
            throws ProviderCatalogException {
        return openUpload(path, "", offsetBytes, expectedSizeBytes);
    }

    public UploadWriter openUpload(String path, String transferId, long offsetBytes, long expectedSizeBytes)
            throws ProviderCatalogException {
        if (offsetBytes < 0) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes must be non-negative"
            );
        }
        if (expectedSizeBytes < -1) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "expected_size_bytes must be -1 or non-negative"
            );
        }
        if (expectedSizeBytes >= 0 && offsetBytes > expectedSizeBytes) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes is beyond expected_size_bytes"
            );
        }

        AppSandboxTarget appSandboxTarget = appSandboxTargetForFilePath(path);
        if (appSandboxTarget != null) {
            if (appSandboxTarget.downloadError != null) {
                throw appSandboxTarget.downloadError;
            }
            return appSandboxCatalog.openUploadFile(
                    appSandboxTarget.relativePath,
                    offsetBytes,
                    expectedSizeBytes
            );
        }

        MediaUploadTarget mediaUploadTarget = mediaUploadTargetForUploadPath(path);
        if (mediaUploadTarget != null) {
            if (mediaUploadTarget.error != null) {
                throw mediaUploadTarget.error;
            }
            if (offsetBytes != 0) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "MediaStore upload resume is not supported"
                );
            }
            return mediaCatalog.openUploadMedia(
                    mediaUploadTarget.rootKind,
                    mediaUploadTarget.displayName,
                    offsetBytes,
                    expectedSizeBytes
            );
        }

        SafUploadTarget safUploadTarget = safUploadTargetForUploadPath(path);
        if (safUploadTarget != null) {
            if (safUploadTarget.error != null) {
                throw safUploadTarget.error;
            }
            if (!safUploadTarget.root.canWrite) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF write permission is required to upload this document"
                );
            }
            if (offsetBytes != 0 && transferId.isEmpty()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "SAF upload resume requires a transfer_id"
                );
            }
            return safCatalog.openUploadDocument(
                    safUploadTarget.root,
                    safUploadTarget.parentDocumentId,
                    safUploadTarget.displayName,
                    transferId,
                    offsetBytes,
                    expectedSizeBytes
            );
        }

        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "M1 upload currently supports dm://app-sandbox/, dm://media-images/, dm://media-videos/, and writable dm://saf-.../ destinations only"
        );
    }

    private ListDirResponse listRootDirectory(ListDirRequest request) {
        if (!request.getPageToken().isEmpty()) {
            return errorResponse(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "page_token is not supported by the M1 root provider"
            );
        }

        ListDirResponse.Builder response = ListDirResponse.newBuilder();
        for (StaticRoot root : STATIC_ROOTS) {
            response.addEntries(rootEntry(root.path, root.displayName, rootCanWrite(root)));
        }
        for (SafRoot root : safCatalog.roots()) {
            response.addEntries(rootEntry(root.path(), root.displayName, root.canWrite));
        }
        return response.build();
    }

    private boolean rootCanWrite(StaticRoot root) {
        if (root.kind == RootKind.APP_SANDBOX) {
            return true;
        }
        return mediaCatalog.canUploadMedia(root.kind);
    }

    private static FileEntry rootEntry(String path, String displayName, boolean canWrite) {
        return FileEntry.newBuilder()
                .setPath(path)
                .setName(displayName)
                .setKind(FileKind.FILE_KIND_VIRTUAL)
                .setCanRead(true)
                .setCanWrite(canWrite)
                .setMimeType("vnd.droidmatch.root")
                .build();
    }

    private ListDirResponse listAppSandboxDirectory(String relativePath, ListDirRequest request) {
        PageRequest pageRequest = pageRequest(request);
        if (pageRequest.error != null) {
            return pageRequest.error;
        }

        try {
            AppSandboxPage page = appSandboxCatalog.listDirectory(
                    relativePath,
                    new ProviderQuery(
                            pageRequest.offset,
                            pageRequest.limit,
                            effectiveSortField(request.getSortField()),
                            effectiveDescending(request.getSortField(), request.getDescending())
                    )
            );

            ListDirResponse.Builder response = ListDirResponse.newBuilder();
            for (AppSandboxItem item : page.items) {
                response.addEntries(FileEntry.newBuilder()
                        .setPath(APP_SANDBOX_PATH + item.relativePath + (item.kind == FileKind.FILE_KIND_DIRECTORY ? "/" : ""))
                        .setName(item.displayName)
                        .setKind(item.kind)
                        .setSizeBytes(item.sizeBytes)
                        .setModifiedUnixMillis(item.modifiedUnixMillis)
                        .setCanRead(true)
                        .setCanWrite(item.canWrite)
                        .setMimeType(item.mimeType)
                        .build());
            }
            if (page.hasMore) {
                response.setNextPageToken(nextPageToken(request, pageRequest));
            }
            return response.build();
        } catch (ProviderCatalogException exception) {
            return errorResponse(exception.code, exception.getMessage());
        }
    }

    private ListDirResponse listMediaRoot(StaticRoot root, ListDirRequest request) {
        PageRequest pageRequest = pageRequest(request);
        if (pageRequest.error != null) {
            return pageRequest.error;
        }

        try {
            MediaPage page = mediaCatalog.listMedia(
                    root.kind,
                    new ProviderQuery(
                            pageRequest.offset,
                            pageRequest.limit,
                            effectiveSortField(request.getSortField()),
                            effectiveDescending(request.getSortField(), request.getDescending())
                    )
            );

            ListDirResponse.Builder response = ListDirResponse.newBuilder();
            for (MediaItem item : page.items) {
                response.addEntries(FileEntry.newBuilder()
                        .setPath(root.path + "media/" + item.id)
                        .setName(item.displayName)
                        .setKind(FileKind.FILE_KIND_FILE)
                        .setSizeBytes(item.sizeBytes)
                        .setModifiedUnixMillis(item.modifiedUnixMillis)
                        .setCanRead(true)
                        .setCanWrite(false)
                        .setMimeType(item.mimeType)
                        .build());
            }
            if (page.hasMore) {
                response.setNextPageToken(nextPageToken(request, pageRequest));
            }
            return response.build();
        } catch (ProviderCatalogException exception) {
            return errorResponse(exception.code, exception.getMessage());
        }
    }

    private ListDirResponse listSafDirectory(SafTarget target, ListDirRequest request) {
        PageRequest pageRequest = pageRequest(request);
        if (pageRequest.error != null) {
            return pageRequest.error;
        }

        try {
            SafPage page = safCatalog.listChildren(
                    target.root,
                    target.documentId,
                    new ProviderQuery(
                            pageRequest.offset,
                            pageRequest.limit,
                            effectiveSortField(request.getSortField()),
                            effectiveDescending(request.getSortField(), request.getDescending())
                    )
            );

            ListDirResponse.Builder response = ListDirResponse.newBuilder();
            for (SafItem item : page.items) {
                response.addEntries(FileEntry.newBuilder()
                        .setPath(target.root.path() + SAF_DOCUMENT_PREFIX + cacheSafDocumentId(target.root, item.documentId))
                        .setName(item.displayName)
                        .setKind(item.kind)
                        .setSizeBytes(item.sizeBytes)
                        .setModifiedUnixMillis(item.modifiedUnixMillis)
                        .setCanRead(true)
                        .setCanWrite(item.canWrite)
                        .setMimeType(item.mimeType)
                        .build());
            }
            if (page.hasMore) {
                response.setNextPageToken(nextPageToken(request, pageRequest));
            }
            return response.build();
        } catch (ProviderCatalogException exception) {
            return errorResponse(exception.code, exception.getMessage());
        }
    }

    private static StaticRoot staticRootForPath(String path) {
        for (StaticRoot root : STATIC_ROOTS) {
            if (root.path.equals(path)) {
                return root;
            }
        }
        return null;
    }

    private SafTarget safTargetForPath(String path) {
        for (SafRoot root : safCatalog.roots()) {
            String rootPath = root.path();
            if (rootPath.equals(path)) {
                return SafTarget.directory(root, root.documentId);
            }
            if (path.startsWith(rootPath)) {
                String relative = path.substring(rootPath.length());
                if (!relative.startsWith(SAF_DOCUMENT_PREFIX)) {
                    return SafTarget.error(errorResponse(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "malformed SAF path"
                    ));
                }
                String encodedDocumentId = relative.substring(SAF_DOCUMENT_PREFIX.length());
                if (encodedDocumentId.isEmpty() || encodedDocumentId.contains("/")) {
                    return SafTarget.error(errorResponse(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "malformed SAF path"
                    ));
                }
                String documentId = safDocumentIdsByLogicalId.get(safDocumentCacheKey(root, encodedDocumentId));
                if (documentId == null) {
                    return SafTarget.error(errorResponse(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "unknown SAF document path"
                    ));
                }
                return SafTarget.directory(root, documentId);
            }
        }
        return null;
    }

    private SafUploadTarget safUploadTargetForUploadPath(String path) {
        for (SafRoot root : safCatalog.roots()) {
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
                return safUploadTarget(root, root.documentId, relative);
            }

            String documentRelative = relative.substring(SAF_DOCUMENT_PREFIX.length());
            int separator = documentRelative.indexOf('/');
            if (separator <= 0 || separator == documentRelative.length() - 1) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "SAF upload destination must include a file name after the directory path"
                ));
            }
            String encodedParentId = documentRelative.substring(0, separator);
            String displayName = documentRelative.substring(separator + 1);
            if (displayName.contains("/")) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "malformed SAF upload path"
                ));
            }
            String parentDocumentId = safDocumentIdsByLogicalId.get(safDocumentCacheKey(root, encodedParentId));
            if (parentDocumentId == null) {
                return SafUploadTarget.error(new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown SAF directory path"
                ));
            }
            return safUploadTarget(root, parentDocumentId, displayName);
        }
        return null;
    }

    private static SafUploadTarget safUploadTarget(SafRoot root, String parentDocumentId, String displayName) {
        if (!isValidSafUploadDisplayName(displayName)) {
            return SafUploadTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed SAF upload file name"
            ));
        }
        return SafUploadTarget.file(root, parentDocumentId, displayName);
    }

    private static MediaUploadTarget mediaUploadTargetForUploadPath(String path) {
        MediaUploadTarget target = mediaUploadTarget(path, MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES);
        if (target != null) {
            return target;
        }
        return mediaUploadTarget(path, MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS);
    }

    private static MediaUploadTarget mediaUploadTarget(String path, String rootPath, RootKind rootKind) {
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
        if (!isValidMediaUploadDisplayName(displayName)) {
            return MediaUploadTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "malformed MediaStore upload file name"
            ));
        }
        return MediaUploadTarget.file(rootKind, displayName);
    }

    private static boolean isValidSafUploadDisplayName(String displayName) {
        return !displayName.isEmpty()
                && !".".equals(displayName)
                && !"..".equals(displayName)
                && displayName.indexOf('\0') < 0
                && !displayName.contains("/");
    }

    private static boolean isValidMediaUploadDisplayName(String displayName) {
        return !displayName.isEmpty()
                && !".".equals(displayName)
                && !"..".equals(displayName)
                && displayName.indexOf('\0') < 0
                && !displayName.contains("/");
    }

    private static MediaTarget mediaTargetForPath(String path) {
        if (path.startsWith(MEDIA_IMAGES_PATH + "media/")) {
            return mediaTarget(path, MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES);
        }
        if (path.startsWith(MEDIA_VIDEOS_PATH + "media/")) {
            return mediaTarget(path, MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS);
        }
        if (MEDIA_IMAGES_PATH.equals(path) || MEDIA_VIDEOS_PATH.equals(path)) {
            return MediaTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer source_path must identify a file entry"
            ));
        }
        return null;
    }

    private static AppSandboxTarget appSandboxTargetForDirectoryPath(String path) {
        if (!path.startsWith(APP_SANDBOX_PATH)) {
            return null;
        }
        String relativePath = path.substring(APP_SANDBOX_PATH.length());
        if (!relativePath.isEmpty() && !relativePath.endsWith("/")) {
            return AppSandboxTarget.error(errorResponse(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "ListDirRequest.path must identify an app sandbox directory"
            ));
        }
        return AppSandboxTarget.directory(trimTrailingSlash(relativePath));
    }

    private static AppSandboxTarget appSandboxTargetForFilePath(String path) {
        if (!path.startsWith(APP_SANDBOX_PATH)) {
            return null;
        }
        String relativePath = path.substring(APP_SANDBOX_PATH.length());
        if (relativePath.isEmpty() || relativePath.endsWith("/")) {
            return AppSandboxTarget.error(new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer source_path must identify a file entry"
            ));
        }
        return AppSandboxTarget.file(relativePath);
    }

    private static String trimTrailingSlash(String value) {
        if (value.endsWith("/")) {
            return value.substring(0, value.length() - 1);
        }
        return value;
    }

    private static MediaTarget mediaTarget(String path, String rootPath, RootKind rootKind) {
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

    private String cacheSafDocumentId(SafRoot root, String documentId) {
        String logicalId = ProviderOpaqueIds.stable(root.stableId + "\n" + documentId, 8);
        safDocumentIdsByLogicalId.put(safDocumentCacheKey(root, logicalId), documentId);
        return logicalId;
    }

    private static String safDocumentCacheKey(SafRoot root, String logicalId) {
        return root.stableId + "/" + logicalId;
    }

    private static Map<String, String> safDocumentCache(int maxEntries) {
        final int boundedMaxEntries = Math.max(1, maxEntries);
        return Collections.synchronizedMap(new LinkedHashMap<String, String>(boundedMaxEntries, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, String> eldest) {
                return size() > boundedMaxEntries;
            }
        });
    }

    private static PageRequest pageRequest(ListDirRequest request) {
        long requestedSize = Integer.toUnsignedLong(request.getPageSize());
        int limit = requestedSize == 0 ? DEFAULT_PAGE_SIZE : (int) Math.min(requestedSize, MAX_PAGE_SIZE);
        int offset = 0;
        if (!request.getPageToken().isEmpty()) {
            offset = pageTokenOffset(request);
            if (offset < 0) {
                return PageRequest.error(errorResponse(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "invalid page_token"
                ));
            }
        }
        return PageRequest.page(offset, limit);
    }

    private static String nextPageToken(ListDirRequest request, PageRequest pageRequest) {
        int nextOffset = pageRequest.offset + pageRequest.limit;
        return PAGE_TOKEN_PREFIX + nextOffset + ":" + pageTokenSignature(request, nextOffset);
    }

    private static int pageTokenOffset(ListDirRequest request) {
        String token = request.getPageToken();
        if (!token.startsWith(PAGE_TOKEN_PREFIX)) {
            return -1;
        }

        int signatureSeparator = token.indexOf(':', PAGE_TOKEN_PREFIX.length());
        if (signatureSeparator < 0) {
            return -1;
        }

        int offset;
        try {
            offset = Integer.parseInt(token.substring(PAGE_TOKEN_PREFIX.length(), signatureSeparator));
        } catch (NumberFormatException exception) {
            return -1;
        }
        if (offset < 0) {
            return -1;
        }

        String signature = token.substring(signatureSeparator + 1);
        return pageTokenSignature(request, offset).equals(signature) ? offset : -1;
    }

    private static String pageTokenSignature(ListDirRequest request, int offset) {
        return ProviderOpaqueIds.stable(
                "page-token\n"
                        + request.getPath() + "\n"
                        + request.getPageSize() + "\n"
                        + request.getSortFieldValue() + "\n"
                        + request.getDescending() + "\n"
                        + offset,
                8
        );
    }

    private static SortField effectiveSortField(SortField sortField) {
        return sortField == SortField.SORT_FIELD_UNSPECIFIED
                ? SortField.SORT_FIELD_MODIFIED_TIME
                : sortField;
    }

    private static boolean effectiveDescending(SortField sortField, boolean requestedDescending) {
        return sortField == SortField.SORT_FIELD_UNSPECIFIED || requestedDescending;
    }

    private static ListDirResponse errorResponse(ErrorCode code, String message) {
        return ListDirResponse.newBuilder()
                .setError(DroidMatchError.newBuilder()
                        .setCode(code)
                        .setMessage(message)
                        .build())
                .build();
    }

    interface MediaCatalog {
        MediaPage listMedia(RootKind rootKind, ProviderQuery query) throws ProviderCatalogException;

        DownloadChunk readMedia(RootKind rootKind, long mediaId, long offsetBytes, int chunkSizeBytes)
                throws ProviderCatalogException;

        default boolean canUploadMedia(RootKind rootKind) {
            return false;
        }

        default DownloadReader openMedia(RootKind rootKind, long mediaId, long offsetBytes, int chunkSizeBytes)
                throws ProviderCatalogException {
            return ProviderDownloadReaders.oneShot(
                    readMedia(rootKind, mediaId, offsetBytes, chunkSizeBytes)
            );
        }

        default UploadWriter openUploadMedia(
                RootKind rootKind,
                String displayName,
                long offsetBytes,
                long expectedSizeBytes
        ) throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "MediaStore upload is not available"
            );
        }

        static MediaCatalog empty() {
            return new MediaCatalog() {
                @Override
                public MediaPage listMedia(RootKind rootKind, ProviderQuery query) {
                    return new MediaPage(new ArrayList<>(), false);
                }

                @Override
                public DownloadChunk readMedia(
                        RootKind rootKind,
                        long mediaId,
                        long offsetBytes,
                        int chunkSizeBytes
                ) throws ProviderCatalogException {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "media entry is not available"
                    );
                }
            };
        }
    }

    interface SafCatalog {
        List<SafRoot> roots();

        SafPage listChildren(SafRoot root, String documentId, ProviderQuery query) throws ProviderCatalogException;

        DownloadChunk readDocument(SafRoot root, String documentId, long offsetBytes, int chunkSizeBytes)
                throws ProviderCatalogException;

        default DownloadReader openDocument(SafRoot root, String documentId, long offsetBytes, int chunkSizeBytes)
                throws ProviderCatalogException {
            return ProviderDownloadReaders.oneShot(
                    readDocument(root, documentId, offsetBytes, chunkSizeBytes)
            );
        }

        default UploadWriter openUploadDocument(
                SafRoot root,
                String parentDocumentId,
                String displayName,
                String transferId,
                long offsetBytes,
                long expectedSizeBytes
        ) throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF upload is not available"
            );
        }

        static SafCatalog empty() {
            return new SafCatalog() {
                @Override
                public List<SafRoot> roots() {
                    return Collections.emptyList();
                }

                @Override
                public SafPage listChildren(
                        SafRoot root,
                        String documentId,
                        ProviderQuery query
                ) {
                    return new SafPage(new ArrayList<>(), false);
                }

                @Override
                public DownloadChunk readDocument(
                        SafRoot root,
                        String documentId,
                        long offsetBytes,
                        int chunkSizeBytes
                ) throws ProviderCatalogException {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "SAF document is not available"
                    );
                }
            };
        }
    }

    interface AppSandboxCatalog {
        AppSandboxPage listDirectory(String relativePath, ProviderQuery query) throws ProviderCatalogException;

        DownloadReader openFile(String relativePath, long offsetBytes, int chunkSizeBytes)
                throws ProviderCatalogException;

        UploadWriter openUploadFile(String relativePath, long offsetBytes, long expectedSizeBytes)
                throws ProviderCatalogException;

        static AppSandboxCatalog empty() {
            return new AppSandboxCatalog() {
                @Override
                public AppSandboxPage listDirectory(String relativePath, ProviderQuery query) {
                    return new AppSandboxPage(new ArrayList<>(), false);
                }

                @Override
                public DownloadReader openFile(String relativePath, long offsetBytes, int chunkSizeBytes)
                        throws ProviderCatalogException {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "app sandbox entry is not available"
                    );
                }

                @Override
                public UploadWriter openUploadFile(String relativePath, long offsetBytes, long expectedSizeBytes)
                        throws ProviderCatalogException {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "app sandbox entry is not available"
                    );
                }
            };
        }
    }

    static final class AppSandboxPage {
        private final List<AppSandboxItem> items;
        private final boolean hasMore;

        AppSandboxPage(List<AppSandboxItem> items, boolean hasMore) {
            this.items = items;
            this.hasMore = hasMore;
        }
    }

    static final class AppSandboxItem {
        final String relativePath;
        final String displayName;
        final FileKind kind;
        final long sizeBytes;
        final long modifiedUnixMillis;
        final String mimeType;
        final boolean canWrite;

        AppSandboxItem(
                String relativePath,
                String displayName,
                FileKind kind,
                long sizeBytes,
                long modifiedUnixMillis,
                String mimeType,
                boolean canWrite
        ) {
            this.relativePath = relativePath;
            this.displayName = displayName;
            this.kind = kind;
            this.sizeBytes = sizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.mimeType = mimeType;
            this.canWrite = canWrite;
        }
    }

    static final class ProviderQuery {
        private final int offset;
        private final int limit;
        private final SortField sortField;
        private final boolean descending;

        ProviderQuery(int offset, int limit, SortField sortField, boolean descending) {
            this.offset = offset;
            this.limit = limit;
            this.sortField = sortField;
            this.descending = descending;
        }

        int offset() {
            return offset;
        }

        int limit() {
            return limit;
        }

        SortField sortField() {
            return sortField;
        }

        boolean descending() {
            return descending;
        }
    }

    static final class MediaPage {
        private final List<MediaItem> items;
        private final boolean hasMore;

        MediaPage(List<MediaItem> items, boolean hasMore) {
            this.items = items;
            this.hasMore = hasMore;
        }
    }

    static final class MediaItem {
        private final long id;
        private final String displayName;
        private final long sizeBytes;
        private final long modifiedUnixMillis;
        private final String mimeType;

        MediaItem(
                long id,
                String displayName,
                long sizeBytes,
                long modifiedUnixMillis,
                String mimeType
        ) {
            this.id = id;
            this.displayName = displayName;
            this.sizeBytes = sizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.mimeType = mimeType;
        }
    }

    static final class DownloadChunk {
        final byte[] data;
        final long totalSizeBytes;
        final long modifiedUnixMillis;
        final String providerEtag;
        final boolean finalChunk;

        DownloadChunk(
                byte[] data,
                long totalSizeBytes,
                long modifiedUnixMillis,
                String providerEtag,
                boolean finalChunk
        ) {
            this.data = data;
            this.totalSizeBytes = totalSizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.providerEtag = providerEtag;
            this.finalChunk = finalChunk;
        }
    }

    interface DownloadReader extends AutoCloseable {
        DownloadChunk readNextChunk() throws ProviderCatalogException;

        @Override
        void close();
    }

    interface UploadWriter extends Closeable {
        long nextOffsetBytes();

        void writeChunk(long offsetBytes, byte[] data, boolean finalChunk) throws ProviderCatalogException;

        @Override
        void close();
    }

    static final class SafRoot {
        final String stableId;
        final Uri treeUri;
        final String documentId;
        final String displayName;
        final boolean canWrite;

        SafRoot(String stableId, String documentId, String displayName, boolean canWrite) {
            this(stableId, null, documentId, displayName, canWrite);
        }

        SafRoot(String stableId, Uri treeUri, String documentId, String displayName, boolean canWrite) {
            this.stableId = stableId;
            this.treeUri = treeUri;
            this.documentId = documentId;
            this.displayName = displayName;
            this.canWrite = canWrite;
        }

        private String path() {
            return "dm://saf-" + stableId + "/";
        }
    }

    static final class SafPage {
        private final List<SafItem> items;
        private final boolean hasMore;

        SafPage(List<SafItem> items, boolean hasMore) {
            this.items = items;
            this.hasMore = hasMore;
        }
    }

    static final class SafItem {
        final String documentId;
        final String displayName;
        final FileKind kind;
        final long sizeBytes;
        final long modifiedUnixMillis;
        final String mimeType;
        final boolean canWrite;

        SafItem(
                String documentId,
                String displayName,
                FileKind kind,
                long sizeBytes,
                long modifiedUnixMillis,
                String mimeType,
                boolean canWrite
        ) {
            this.documentId = documentId;
            this.displayName = displayName;
            this.kind = kind;
            this.sizeBytes = sizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.mimeType = mimeType;
            this.canWrite = canWrite;
        }
    }

    static final class ProviderCatalogException extends Exception {
        final ErrorCode code;

        ProviderCatalogException(ErrorCode code, String message) {
            super(message);
            this.code = code;
        }
    }

    enum RootKind {
        MEDIA_IMAGES,
        MEDIA_VIDEOS,
        APP_SANDBOX
    }

    private static final class StaticRoot {
        private final String displayName;
        private final String path;
        private final RootKind kind;

        private StaticRoot(String displayName, String path, RootKind kind) {
            this.displayName = displayName;
            this.path = path;
            this.kind = kind;
        }
    }

    private static final class SafTarget {
        private final SafRoot root;
        private final String documentId;
        private final ListDirResponse error;

        private SafTarget(SafRoot root, String documentId, ListDirResponse error) {
            this.root = root;
            this.documentId = documentId;
            this.error = error;
        }

        private static SafTarget directory(SafRoot root, String documentId) {
            return new SafTarget(root, documentId, null);
        }

        private static SafTarget error(ListDirResponse error) {
            return new SafTarget(null, null, error);
        }
    }

    private static final class SafUploadTarget {
        private final SafRoot root;
        private final String parentDocumentId;
        private final String displayName;
        private final ProviderCatalogException error;

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

        private static SafUploadTarget file(SafRoot root, String parentDocumentId, String displayName) {
            return new SafUploadTarget(root, parentDocumentId, displayName, null);
        }

        private static SafUploadTarget error(ProviderCatalogException error) {
            return new SafUploadTarget(null, null, null, error);
        }
    }

    private static final class MediaTarget {
        private final RootKind rootKind;
        private final long mediaId;
        private final ProviderCatalogException error;

        private MediaTarget(RootKind rootKind, long mediaId, ProviderCatalogException error) {
            this.rootKind = rootKind;
            this.mediaId = mediaId;
            this.error = error;
        }

        private static MediaTarget file(RootKind rootKind, long mediaId) {
            return new MediaTarget(rootKind, mediaId, null);
        }

        private static MediaTarget error(ProviderCatalogException error) {
            return new MediaTarget(null, 0, error);
        }
    }

    private static final class MediaUploadTarget {
        private final RootKind rootKind;
        private final String displayName;
        private final ProviderCatalogException error;

        private MediaUploadTarget(RootKind rootKind, String displayName, ProviderCatalogException error) {
            this.rootKind = rootKind;
            this.displayName = displayName;
            this.error = error;
        }

        private static MediaUploadTarget file(RootKind rootKind, String displayName) {
            return new MediaUploadTarget(rootKind, displayName, null);
        }

        private static MediaUploadTarget error(ProviderCatalogException error) {
            return new MediaUploadTarget(null, null, error);
        }
    }

    private static final class AppSandboxTarget {
        private final String relativePath;
        private final ListDirResponse error;
        private final ProviderCatalogException downloadError;

        private AppSandboxTarget(
                String relativePath,
                ListDirResponse error,
                ProviderCatalogException downloadError
        ) {
            this.relativePath = relativePath;
            this.error = error;
            this.downloadError = downloadError;
        }

        private static AppSandboxTarget directory(String relativePath) {
            return new AppSandboxTarget(relativePath, null, null);
        }

        private static AppSandboxTarget file(String relativePath) {
            return new AppSandboxTarget(relativePath, null, null);
        }

        private static AppSandboxTarget error(ListDirResponse error) {
            return new AppSandboxTarget(null, error, null);
        }

        private static AppSandboxTarget error(ProviderCatalogException error) {
            return new AppSandboxTarget(null, null, error);
        }
    }

    private static final class PageRequest {
        private final int offset;
        private final int limit;
        private final ListDirResponse error;

        private PageRequest(int offset, int limit, ListDirResponse error) {
            this.offset = offset;
            this.limit = limit;
            this.error = error;
        }

        private static PageRequest page(int offset, int limit) {
            return new PageRequest(offset, limit, null);
        }

        private static PageRequest error(ListDirResponse error) {
            return new PageRequest(0, 0, error);
        }
    }

}
