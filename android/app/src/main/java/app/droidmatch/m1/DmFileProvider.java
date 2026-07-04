package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.provider.BaseColumns;
import android.provider.DocumentsContract;
import android.provider.MediaStore;

import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.URLConnection;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
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
        Context applicationContext = context.getApplicationContext();
        ContentResolver contentResolver = applicationContext.getContentResolver();
        this.mediaCatalog = new AndroidMediaCatalog(contentResolver);
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
        String logicalId = stableOpaqueId(root.stableId + "\n" + documentId, 8);
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
        return stableOpaqueId(
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

    private static String stableOpaqueId(String value, int byteCount) {
        byte[] hash = sha256(value);
        StringBuilder builder = new StringBuilder();
        for (int index = 0; index < byteCount; index++) {
            int unsignedByte = hash[index] & 0xff;
            builder.append(Character.forDigit((unsignedByte >> 4) & 0xf, 16));
            builder.append(Character.forDigit(unsignedByte & 0xf, 16));
        }
        return builder.toString();
    }

    private static byte[] sha256(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return digest.digest(value.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 unavailable", exception);
        }
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
            return new OneShotDownloadReader(readMedia(rootKind, mediaId, offsetBytes, chunkSizeBytes));
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
            return new OneShotDownloadReader(readDocument(root, documentId, offsetBytes, chunkSizeBytes));
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
        private final String relativePath;
        private final String displayName;
        private final FileKind kind;
        private final long sizeBytes;
        private final long modifiedUnixMillis;
        private final String mimeType;
        private final boolean canWrite;

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

    private static final class OneShotDownloadReader implements DownloadReader {
        private final DownloadChunk chunk;
        private boolean consumed;

        private OneShotDownloadReader(DownloadChunk chunk) {
            this.chunk = chunk;
        }

        @Override
        public DownloadChunk readNextChunk() throws ProviderCatalogException {
            if (consumed) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "download reader has no remaining chunks"
                );
            }
            consumed = true;
            return chunk;
        }

        @Override
        public void close() {
        }
    }

    static final class SafRoot {
        private final String stableId;
        private final Uri treeUri;
        private final String documentId;
        private final String displayName;
        private final boolean canWrite;

        SafRoot(String stableId, String documentId, String displayName, boolean canWrite) {
            this(stableId, null, documentId, displayName, canWrite);
        }

        private SafRoot(String stableId, Uri treeUri, String documentId, String displayName, boolean canWrite) {
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
        private final String documentId;
        private final String displayName;
        private final FileKind kind;
        private final long sizeBytes;
        private final long modifiedUnixMillis;
        private final String mimeType;
        private final boolean canWrite;

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

    private static final class AndroidAppSandboxCatalog implements AppSandboxCatalog {
        private final File rootDirectory;

        private AndroidAppSandboxCatalog(File rootDirectory) {
            this.rootDirectory = rootDirectory;
        }

        @Override
        public AppSandboxPage listDirectory(String relativePath, ProviderQuery query) throws ProviderCatalogException {
            File directory = resolve(relativePath);
            if (!directory.exists()) {
                if (relativePath.isEmpty()) {
                    return new AppSandboxPage(new ArrayList<>(), false);
                }
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "app sandbox directory is not available"
                );
            }
            if (!directory.isDirectory()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "ListDirRequest.path must identify an app sandbox directory"
                );
            }

            File[] childFiles = directory.listFiles();
            if (childFiles == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "app sandbox listing failed"
                );
            }

            ArrayList<AppSandboxItem> items = new ArrayList<>();
            for (File child : childFiles) {
                if (isUploadPartialFileName(child.getName())) {
                    continue;
                }
                items.add(appSandboxItem(relativePath, child));
            }
            items.sort(appSandboxComparator(query.sortField, query.descending));
            return pageAppSandboxItems(items, query.offset, query.limit);
        }

        @Override
        public DownloadReader openFile(String relativePath, long offsetBytes, int chunkSizeBytes)
                throws ProviderCatalogException {
            File file = resolve(relativePath);
            if (!file.exists()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "app sandbox file is not available"
                );
            }
            if (!file.isFile()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer source_path must identify a file entry"
                );
            }
            if (offsetBytes > file.length()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "requested_offset_bytes is beyond end of file"
                );
            }

            try {
                FileInputStream inputStream = new FileInputStream(file);
                FileChannel channel = inputStream.getChannel();
                channel.position(offsetBytes);
                return new StreamDownloadReader(
                        inputStream,
                        offsetBytes,
                        chunkSizeBytes,
                        file.length(),
                        file.lastModified(),
                        providerEtag(relativePath, file),
                        "app sandbox read failed"
                );
            } catch (FileNotFoundException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "app sandbox file is not available"
                );
            } catch (IllegalArgumentException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "requested_offset_bytes must be non-negative"
                );
            } catch (IOException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "app sandbox read failed"
                );
            }
        }

        @Override
        public UploadWriter openUploadFile(String relativePath, long offsetBytes, long expectedSizeBytes)
                throws ProviderCatalogException {
            File destination = resolve(relativePath);
            if (destination.exists() && destination.isDirectory()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer destination_path must identify a file entry"
                );
            }
            File parent = destination.getParentFile();
            if (parent == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "app sandbox upload path has no parent"
                );
            }
            if (!parent.exists() && !parent.mkdirs()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "app sandbox upload directory could not be created"
                );
            }
            if (!parent.isDirectory()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer destination_path parent must identify a directory"
                );
            }

            try {
                File partialFile = uploadPartialFile(destination);
                if (offsetBytes == 0) {
                    partialFile.delete();
                } else if (!partialFile.isFile()) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "app sandbox upload partial is not available"
                    );
                } else if (partialFile.length() < offsetBytes) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "requested_offset_bytes does not match app sandbox upload partial"
                    );
                } else if (partialFile.length() > offsetBytes) {
                    try (RandomAccessFile partialAccess = new RandomAccessFile(partialFile, "rw")) {
                        partialAccess.setLength(offsetBytes);
                    }
                }
                return new AppSandboxUploadWriter(
                        destination,
                        partialFile,
                        new FileOutputStream(partialFile, offsetBytes > 0),
                        expectedSizeBytes,
                        offsetBytes
                );
            } catch (ProviderCatalogException exception) {
                throw exception;
            } catch (IOException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "app sandbox upload could not be opened"
                );
            }
        }

        private File resolve(String relativePath) throws ProviderCatalogException {
            if (relativePath.indexOf('\0') >= 0 || relativePath.startsWith("/") || relativePath.contains("//")) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "malformed app sandbox path"
                );
            }
            try {
                File canonicalRoot = rootDirectory.getCanonicalFile();
                File candidate = relativePath.isEmpty()
                        ? canonicalRoot
                        : new File(canonicalRoot, relativePath).getCanonicalFile();
                String rootPath = canonicalRoot.getPath();
                String candidatePath = candidate.getPath();
                if (!candidatePath.equals(rootPath)
                        && !candidatePath.startsWith(rootPath + File.separator)) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "malformed app sandbox path"
                    );
                }
                return candidate;
            } catch (IOException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "app sandbox path resolution failed"
                );
            }
        }

        private static AppSandboxItem appSandboxItem(String parentRelativePath, File file) {
            String relativePath = parentRelativePath.isEmpty()
                    ? file.getName()
                    : parentRelativePath + "/" + file.getName();
            boolean directory = file.isDirectory();
            return new AppSandboxItem(
                    relativePath,
                    file.getName(),
                    directory ? FileKind.FILE_KIND_DIRECTORY : FileKind.FILE_KIND_FILE,
                    directory ? 0 : file.length(),
                    file.lastModified(),
                    directory ? "inode/directory" : "application/octet-stream",
                    file.canWrite()
            );
        }

        private static AppSandboxPage pageAppSandboxItems(List<AppSandboxItem> items, int offset, int limit) {
            if (offset >= items.size()) {
                return new AppSandboxPage(new ArrayList<>(), false);
            }
            int endExclusive = Math.min(items.size(), offset + limit);
            boolean hasMore = endExclusive < items.size();
            return new AppSandboxPage(new ArrayList<>(items.subList(offset, endExclusive)), hasMore);
        }

        private static Comparator<AppSandboxItem> appSandboxComparator(SortField sortField, boolean descending) {
            Comparator<AppSandboxItem> comparator;
            switch (sortField) {
                case SORT_FIELD_NAME:
                    comparator = Comparator.comparing(item -> item.displayName, String.CASE_INSENSITIVE_ORDER);
                    break;
                case SORT_FIELD_SIZE:
                    comparator = Comparator.comparingLong(item -> item.sizeBytes);
                    break;
                case SORT_FIELD_KIND:
                    comparator = Comparator.comparingInt(item -> item.kind.getNumber());
                    break;
                case SORT_FIELD_MODIFIED_TIME:
                case SORT_FIELD_UNSPECIFIED:
                case UNRECOGNIZED:
                default:
                    comparator = Comparator.comparingLong(item -> item.modifiedUnixMillis);
                    break;
            }
            if (descending) {
                comparator = comparator.reversed();
            }
            return comparator
                    .thenComparing(item -> item.displayName, String.CASE_INSENSITIVE_ORDER)
                    .thenComparing(item -> item.relativePath);
        }

        private static String providerEtag(String relativePath, File file) {
            return "app-sandbox:" + stableOpaqueId(relativePath, 8) + ":"
                    + file.lastModified() + ":" + file.length();
        }

        private static File uploadPartialFile(File destination) {
            return new File(destination.getParentFile(), "." + destination.getName() + ".droidmatch-upload-part");
        }

        private static boolean isUploadPartialFileName(String fileName) {
            return fileName.startsWith(".") && fileName.endsWith(".droidmatch-upload-part");
        }
    }

    private static final class AppSandboxUploadWriter implements UploadWriter {
        private final File destinationFile;
        private final File tempFile;
        private final OutputStream outputStream;
        private final long expectedSizeBytes;
        private long nextOffsetBytes;
        private boolean closed;

        private AppSandboxUploadWriter(
                File destinationFile,
                File tempFile,
                OutputStream outputStream,
                long expectedSizeBytes,
                long nextOffsetBytes
        ) {
            this.destinationFile = destinationFile;
            this.tempFile = tempFile;
            this.outputStream = outputStream;
            this.expectedSizeBytes = expectedSizeBytes;
            this.nextOffsetBytes = nextOffsetBytes;
        }

        @Override
        public long nextOffsetBytes() {
            return nextOffsetBytes;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk) throws ProviderCatalogException {
            if (closed) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "upload writer is closed"
                );
            }
            if (offsetBytes != nextOffsetBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk offset does not match the expected write boundary"
                );
            }
            if (data.length == 0 && !finalChunk) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "empty upload chunks must be final"
                );
            }
            long nextOffset = nextOffsetBytes + data.length;
            if (expectedSizeBytes >= 0 && nextOffset > expectedSizeBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "upload chunk exceeds expected_size_bytes"
                );
            }
            if (finalChunk && expectedSizeBytes >= 0 && nextOffset != expectedSizeBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "final upload chunk does not match expected_size_bytes"
                );
            }

            try {
                outputStream.write(data);
                nextOffsetBytes = nextOffset;
                if (finalChunk) {
                    commit();
                }
            } catch (IOException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "app sandbox upload write failed"
                );
            }
        }

        private void commit() throws IOException {
            outputStream.flush();
            outputStream.close();
            try {
                Files.move(
                        tempFile.toPath(),
                        destinationFile.toPath(),
                        StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.ATOMIC_MOVE
                );
            } catch (AtomicMoveNotSupportedException exception) {
                Files.move(
                        tempFile.toPath(),
                        destinationFile.toPath(),
                        StandardCopyOption.REPLACE_EXISTING
                );
            }
            closed = true;
        }

        @Override
        public void close() {
            if (closed) {
                return;
            }
            closed = true;
            try {
                outputStream.close();
            } catch (IOException ignored) {
            }
            // Keep the partial file so a later OpenTransfer(upload) can resume from this offset.
        }
    }

    private static final class SafUploadWriter implements UploadWriter {
        private final ContentResolver contentResolver;
        private final Uri documentUri;
        private final OutputStream outputStream;
        private final long expectedSizeBytes;
        private final String finalDisplayName;
        private final boolean deleteOnNonFinalClose;
        private long nextOffsetBytes;
        private boolean closed;
        private boolean committed;

        private SafUploadWriter(
                ContentResolver contentResolver,
                Uri documentUri,
                OutputStream outputStream,
                long expectedSizeBytes,
                long initialOffsetBytes,
                String finalDisplayName,
                boolean deleteOnNonFinalClose
        ) {
            this.contentResolver = contentResolver;
            this.documentUri = documentUri;
            this.outputStream = outputStream;
            this.expectedSizeBytes = expectedSizeBytes;
            this.nextOffsetBytes = initialOffsetBytes;
            this.finalDisplayName = finalDisplayName;
            this.deleteOnNonFinalClose = deleteOnNonFinalClose;
        }

        @Override
        public long nextOffsetBytes() {
            return nextOffsetBytes;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk) throws ProviderCatalogException {
            if (closed) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "upload writer is closed"
                );
            }
            if (offsetBytes != nextOffsetBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk offset does not match the expected write boundary"
                );
            }
            if (data.length == 0 && !finalChunk) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "empty upload chunks must be final"
                );
            }
            long nextOffset = nextOffsetBytes + data.length;
            if (expectedSizeBytes >= 0 && nextOffset > expectedSizeBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "upload chunk exceeds expected_size_bytes"
                );
            }
            if (finalChunk && expectedSizeBytes >= 0 && nextOffset != expectedSizeBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "final upload chunk does not match expected_size_bytes"
                );
            }

            try {
                outputStream.write(data);
                nextOffsetBytes = nextOffset;
                if (finalChunk) {
                    commit();
                }
            } catch (IOException | RuntimeException exception) {
                close();
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF upload write failed"
                );
            }
        }

        private void commit() throws IOException {
            outputStream.flush();
            outputStream.close();
            if (finalDisplayName != null
                    && DocumentsContract.renameDocument(contentResolver, documentUri, finalDisplayName) == null) {
                throw new IOException("SAF upload document could not be renamed");
            }
            committed = true;
            closed = true;
        }

        @Override
        public void close() {
            if (closed) {
                return;
            }
            closed = true;
            closeQuietly(outputStream);
            if (!committed && deleteOnNonFinalClose) {
                deleteDocumentQuietly(contentResolver, documentUri);
            }
        }
    }

    private static final class MediaStoreUploadWriter implements UploadWriter {
        private final ContentResolver contentResolver;
        private final Uri mediaUri;
        private final OutputStream outputStream;
        private final long expectedSizeBytes;
        private final boolean publishOnCommit;
        private long nextOffsetBytes;
        private boolean closed;
        private boolean committed;

        private MediaStoreUploadWriter(
                ContentResolver contentResolver,
                Uri mediaUri,
                OutputStream outputStream,
                long expectedSizeBytes,
                boolean publishOnCommit
        ) {
            this.contentResolver = contentResolver;
            this.mediaUri = mediaUri;
            this.outputStream = outputStream;
            this.expectedSizeBytes = expectedSizeBytes;
            this.publishOnCommit = publishOnCommit;
        }

        @Override
        public long nextOffsetBytes() {
            return nextOffsetBytes;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk) throws ProviderCatalogException {
            if (closed) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "upload writer is closed"
                );
            }
            if (offsetBytes != nextOffsetBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk offset does not match the expected write boundary"
                );
            }
            if (data.length == 0 && !finalChunk) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "empty upload chunks must be final"
                );
            }
            long nextOffset = nextOffsetBytes + data.length;
            if (expectedSizeBytes >= 0 && nextOffset > expectedSizeBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "upload chunk exceeds expected_size_bytes"
                );
            }
            if (finalChunk && expectedSizeBytes >= 0 && nextOffset != expectedSizeBytes) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "final upload chunk does not match expected_size_bytes"
                );
            }

            try {
                outputStream.write(data);
                nextOffsetBytes = nextOffset;
                if (finalChunk) {
                    commit();
                }
            } catch (IOException exception) {
                close();
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore upload write failed"
                );
            } catch (RuntimeException exception) {
                close();
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore upload failed"
                );
            }
        }

        private void commit() throws IOException {
            outputStream.flush();
            outputStream.close();
            if (publishOnCommit) {
                ContentValues values = new ContentValues();
                values.put(MediaStore.MediaColumns.IS_PENDING, 0);
                contentResolver.update(mediaUri, values, null, null);
            }
            committed = true;
            closed = true;
        }

        @Override
        public void close() {
            if (closed) {
                return;
            }
            closed = true;
            closeQuietly(outputStream);
            if (!committed) {
                deleteUriQuietly(contentResolver, mediaUri);
            }
        }
    }

    private static final class AndroidMediaCatalog implements MediaCatalog {
        private static final String[] PROJECTION = new String[] {
                BaseColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.MIME_TYPE
        };

        private final ContentResolver contentResolver;

        private AndroidMediaCatalog(ContentResolver contentResolver) {
            this.contentResolver = contentResolver;
        }

        @Override
        public boolean canUploadMedia(RootKind rootKind) {
            return rootKind == RootKind.MEDIA_IMAGES || rootKind == RootKind.MEDIA_VIDEOS;
        }

        @Override
        public MediaPage listMedia(RootKind rootKind, ProviderQuery query) throws ProviderCatalogException {
            Uri uri = collectionUri(rootKind);
            Bundle queryArgs = new Bundle();
            queryArgs.putInt(ContentResolver.QUERY_ARG_LIMIT, query.limit + 1);
            queryArgs.putInt(ContentResolver.QUERY_ARG_OFFSET, query.offset);
            queryArgs.putStringArray(
                    ContentResolver.QUERY_ARG_SORT_COLUMNS,
                    new String[] { mediaSortColumn(query.sortField) }
            );
            queryArgs.putInt(
                    ContentResolver.QUERY_ARG_SORT_DIRECTION,
                    query.descending
                            ? ContentResolver.QUERY_SORT_DIRECTION_DESCENDING
                            : ContentResolver.QUERY_SORT_DIRECTION_ASCENDING
            );

            try (Cursor cursor = contentResolver.query(uri, PROJECTION, queryArgs, null)) {
                if (cursor == null) {
                    return new MediaPage(new ArrayList<>(), false);
                }
                return readCursor(cursor, query.limit);
            } catch (SecurityException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "media permission is required to list " + rootKind
                );
            } catch (RuntimeException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore query failed"
                );
            }
        }

        @Override
        public DownloadChunk readMedia(
                RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws ProviderCatalogException {
            try (DownloadReader reader = openMedia(rootKind, mediaId, offsetBytes, chunkSizeBytes)) {
                return reader.readNextChunk();
            }
        }

        @Override
        public DownloadReader openMedia(
                RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws ProviderCatalogException {
            Uri uri = ContentUris.withAppendedId(collectionUri(rootKind), mediaId);
            MediaMetadata metadata = mediaMetadata(uri);
            String providerEtag = "media:" + rootKind + ":" + mediaId + ":"
                    + metadata.modifiedUnixMillis + ":" + metadata.sizeBytes;
            DownloadReader seekableReader = seekableReaderOrNull(
                    contentResolver,
                    uri,
                    offsetBytes,
                    chunkSizeBytes,
                    metadata.sizeBytes,
                    metadata.modifiedUnixMillis,
                    providerEtag,
                    "media permission is required to read this item",
                    "MediaStore read failed"
            );
            if (seekableReader != null) {
                return seekableReader;
            }

            InputStream inputStream = null;
            try {
                inputStream = contentResolver.openInputStream(uri);
                if (inputStream == null) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "media entry is not available"
                    );
                }
                skipFully(inputStream, offsetBytes);
                return new StreamDownloadReader(
                        inputStream,
                        offsetBytes,
                        chunkSizeBytes,
                        metadata.sizeBytes,
                        metadata.modifiedUnixMillis,
                        providerEtag,
                        "MediaStore read failed"
                );
            } catch (SecurityException exception) {
                closeQuietly(inputStream);
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "media permission is required to read this item"
                );
            } catch (ProviderCatalogException exception) {
                closeQuietly(inputStream);
                throw exception;
            } catch (IOException exception) {
                closeQuietly(inputStream);
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore read failed"
                );
            }
        }

        @Override
        public UploadWriter openUploadMedia(
                RootKind rootKind,
                String displayName,
                long offsetBytes,
                long expectedSizeBytes
        ) throws ProviderCatalogException {
            if (offsetBytes != 0) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "MediaStore upload resume is not supported"
                );
            }

            ContentValues values = new ContentValues();
            values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
            values.put(MediaStore.MediaColumns.MIME_TYPE, mediaUploadMimeType(rootKind, displayName));
            boolean publishOnCommit = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
            if (publishOnCommit) {
                values.put(MediaStore.MediaColumns.RELATIVE_PATH, mediaRelativePath(rootKind));
                values.put(MediaStore.MediaColumns.IS_PENDING, 1);
            }

            Uri mediaUri = null;
            OutputStream outputStream = null;
            try {
                mediaUri = contentResolver.insert(collectionUri(rootKind), values);
                if (mediaUri == null) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INTERNAL,
                            "MediaStore upload item could not be created"
                    );
                }
                outputStream = contentResolver.openOutputStream(mediaUri, "w");
                if (outputStream == null) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INTERNAL,
                            "MediaStore upload item could not be opened"
                    );
                }
                return new MediaStoreUploadWriter(
                        contentResolver,
                        mediaUri,
                        outputStream,
                        expectedSizeBytes,
                        publishOnCommit
                );
            } catch (SecurityException exception) {
                closeQuietly(outputStream);
                deleteUriQuietly(contentResolver, mediaUri);
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "MediaStore write permission is required to upload this item"
                );
            } catch (ProviderCatalogException exception) {
                closeQuietly(outputStream);
                deleteUriQuietly(contentResolver, mediaUri);
                throw exception;
            } catch (FileNotFoundException exception) {
                closeQuietly(outputStream);
                deleteUriQuietly(contentResolver, mediaUri);
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "MediaStore upload destination is not available"
                );
            } catch (RuntimeException exception) {
                closeQuietly(outputStream);
                deleteUriQuietly(contentResolver, mediaUri);
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore upload failed"
                );
            }
        }

        private static Uri collectionUri(RootKind rootKind) {
            if (rootKind == RootKind.MEDIA_IMAGES) {
                return MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
            }
            return MediaStore.Video.Media.EXTERNAL_CONTENT_URI;
        }

        private static String mediaRelativePath(RootKind rootKind) {
            if (rootKind == RootKind.MEDIA_IMAGES) {
                return Environment.DIRECTORY_PICTURES + "/DroidMatch";
            }
            return Environment.DIRECTORY_MOVIES + "/DroidMatch";
        }

        private static String mediaUploadMimeType(RootKind rootKind, String displayName) {
            String guessed = uploadMimeType(displayName);
            if (rootKind == RootKind.MEDIA_IMAGES) {
                return guessed.startsWith("image/") ? guessed : "image/jpeg";
            }
            if (rootKind == RootKind.MEDIA_VIDEOS) {
                return guessed.startsWith("video/") ? guessed : "video/mp4";
            }
            return guessed;
        }

        private static MediaPage readCursor(Cursor cursor, int limit) {
            int idColumn = cursor.getColumnIndexOrThrow(BaseColumns._ID);
            int nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME);
            int sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
            int modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED);
            int mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE);
            ArrayList<MediaItem> items = new ArrayList<>();
            boolean hasMore = false;

            while (cursor.moveToNext()) {
                if (items.size() >= limit) {
                    hasMore = true;
                    break;
                }
                long id = cursor.getLong(idColumn);
                String displayName = cursor.isNull(nameColumn) ? Long.toString(id) : cursor.getString(nameColumn);
                long sizeBytes = cursor.isNull(sizeColumn) ? 0 : cursor.getLong(sizeColumn);
                long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn) * 1_000L;
                String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
                items.add(new MediaItem(id, displayName, sizeBytes, modifiedMillis, mimeType));
            }
            return new MediaPage(items, hasMore);
        }

        private MediaMetadata mediaMetadata(Uri uri) throws ProviderCatalogException {
            try (Cursor cursor = contentResolver.query(uri, PROJECTION, null, null, null)) {
                if (cursor == null || !cursor.moveToFirst()) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "media entry is not available"
                    );
                }
                int sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
                int modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED);
                long sizeBytes = cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
                long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn) * 1_000L;
                return new MediaMetadata(sizeBytes, modifiedMillis);
            } catch (SecurityException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "media permission is required to read this item"
                );
            } catch (ProviderCatalogException exception) {
                throw exception;
            } catch (RuntimeException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore metadata query failed"
                );
            }
        }

        private byte[] readBytes(Uri uri, long offsetBytes, int chunkSizeBytes) throws ProviderCatalogException {
            try (InputStream inputStream = contentResolver.openInputStream(uri)) {
                if (inputStream == null) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "media entry is not available"
                    );
                }
                skipFully(inputStream, offsetBytes);
                return readAtMost(inputStream, chunkSizeBytes);
            } catch (SecurityException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "media permission is required to read this item"
                );
            } catch (ProviderCatalogException exception) {
                throw exception;
            } catch (IOException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore read failed"
                );
            }
        }

        private static String mediaSortColumn(SortField sortField) {
            switch (sortField) {
                case SORT_FIELD_NAME:
                    return MediaStore.MediaColumns.DISPLAY_NAME;
                case SORT_FIELD_SIZE:
                    return MediaStore.MediaColumns.SIZE;
                case SORT_FIELD_KIND:
                    return BaseColumns._ID;
                case SORT_FIELD_MODIFIED_TIME:
                case SORT_FIELD_UNSPECIFIED:
                case UNRECOGNIZED:
                default:
                    return MediaStore.MediaColumns.DATE_MODIFIED;
            }
        }

        private static final class MediaMetadata {
            private final long sizeBytes;
            private final long modifiedUnixMillis;

            private MediaMetadata(long sizeBytes, long modifiedUnixMillis) {
                this.sizeBytes = sizeBytes;
                this.modifiedUnixMillis = modifiedUnixMillis;
            }
        }
    }

    private static final class AndroidSafCatalog implements SafCatalog {
        private static final String[] DOCUMENT_PROJECTION = new String[] {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_FLAGS
        };

        private final ContentResolver contentResolver;

        private AndroidSafCatalog(ContentResolver contentResolver) {
            this.contentResolver = contentResolver;
        }

        @Override
        public List<SafRoot> roots() {
            ArrayList<SafRoot> roots = new ArrayList<>();
            for (UriPermission permission : contentResolver.getPersistedUriPermissions()) {
                if (!permission.isReadPermission()) {
                    continue;
                }
                Uri treeUri = permission.getUri();
                String documentId;
                try {
                    documentId = DocumentsContract.getTreeDocumentId(treeUri);
                } catch (RuntimeException exception) {
                    continue;
                }
                String stableId = stableOpaqueId(treeUri.toString(), 6);
                String displayName = documentDisplayName(
                        treeUri,
                        documentId,
                        "SAF Root " + stableId
                );
                roots.add(new SafRoot(stableId, treeUri, documentId, displayName, permission.isWritePermission()));
            }
            Collections.sort(roots, Comparator.comparing(root -> root.displayName, String.CASE_INSENSITIVE_ORDER));
            return roots;
        }

        @Override
        public SafPage listChildren(
                SafRoot root,
                String documentId,
                ProviderQuery query
        ) throws ProviderCatalogException {
            if (root.treeUri == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF root is missing its platform URI"
                );
            }

            Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(root.treeUri, documentId);
            try (Cursor cursor = contentResolver.query(childrenUri, DOCUMENT_PROJECTION, null, null, null)) {
                if (cursor == null) {
                    return new SafPage(new ArrayList<>(), false);
                }
                ArrayList<SafItem> allItems = readSafCursor(cursor, root.canWrite);
                Collections.sort(allItems, safComparator(query.sortField, query.descending));
                return pageSafItems(allItems, query.offset, query.limit);
            } catch (SecurityException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF permission is required to list this root"
                );
            } catch (RuntimeException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF query failed"
                );
            }
        }

        @Override
        public DownloadChunk readDocument(
                SafRoot root,
                String documentId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws ProviderCatalogException {
            try (DownloadReader reader = openDocument(root, documentId, offsetBytes, chunkSizeBytes)) {
                return reader.readNextChunk();
            }
        }

        @Override
        public DownloadReader openDocument(
                SafRoot root,
                String documentId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws ProviderCatalogException {
            if (root.treeUri == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF root is missing its platform URI"
                );
            }

            SafDocumentMetadata metadata = safDocumentMetadata(root.treeUri, documentId);
            if (metadata.kind == FileKind.FILE_KIND_DIRECTORY) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer source_path must identify a file entry"
                );
            }
            if (metadata.kind != FileKind.FILE_KIND_FILE) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "SAF virtual documents are not supported for transfer"
                );
            }

            Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, documentId);
            String providerEtag = "saf:" + root.stableId + ":" + stableOpaqueId(documentId, 8) + ":"
                    + metadata.modifiedUnixMillis + ":" + metadata.sizeBytes;
            DownloadReader seekableReader = seekableReaderOrNull(
                    contentResolver,
                    documentUri,
                    offsetBytes,
                    chunkSizeBytes,
                    metadata.sizeBytes,
                    metadata.modifiedUnixMillis,
                    providerEtag,
                    "SAF permission is required to read this document",
                    "SAF read failed"
            );
            if (seekableReader != null) {
                return seekableReader;
            }

            InputStream inputStream = null;
            try {
                inputStream = contentResolver.openInputStream(documentUri);
                if (inputStream == null) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "SAF document is not available"
                    );
                }
                skipFully(inputStream, offsetBytes);
                return new StreamDownloadReader(
                        inputStream,
                        offsetBytes,
                        chunkSizeBytes,
                        metadata.sizeBytes,
                        metadata.modifiedUnixMillis,
                        providerEtag,
                        "SAF read failed"
                );
            } catch (SecurityException exception) {
                closeQuietly(inputStream);
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF permission is required to read this document"
                );
            } catch (ProviderCatalogException exception) {
                closeQuietly(inputStream);
                throw exception;
            } catch (IOException exception) {
                closeQuietly(inputStream);
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF read failed"
                );
            }
        }

        @Override
        public UploadWriter openUploadDocument(
                SafRoot root,
                String parentDocumentId,
                String displayName,
                String transferId,
                long offsetBytes,
                long expectedSizeBytes
        ) throws ProviderCatalogException {
            if (root.treeUri == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF root is missing its platform URI"
                );
            }
            if (!root.canWrite) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF write permission is required to upload this document"
                );
            }
            SafDocumentMetadata parentMetadata = safDocumentMetadata(root.treeUri, parentDocumentId);
            if (parentMetadata.kind != FileKind.FILE_KIND_DIRECTORY) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "SAF upload destination parent must identify a directory"
                );
            }
            if (!parentMetadata.canCreate) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "SAF directory does not support creating files"
                );
            }

            Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, parentDocumentId);
            Uri documentUri = null;
            OutputStream outputStream = null;
            long initialOffsetBytes = offsetBytes;
            String finalDisplayName = null;
            boolean deleteOnNonFinalClose = true;
            boolean deleteDocumentOnOpenFailure = false;
            try {
                if (transferId.isEmpty()) {
                    if (offsetBytes != 0) {
                        throw new ProviderCatalogException(
                                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                                "SAF upload resume requires a transfer_id"
                        );
                    }
                    documentUri = createSafDocument(parentUri, displayName, displayName);
                    deleteDocumentOnOpenFailure = true;
                } else {
                    String partialDisplayName = safUploadPartialDisplayName(
                            root,
                            parentDocumentId,
                            displayName,
                            transferId
                    );
                    finalDisplayName = displayName;
                    deleteOnNonFinalClose = false;
                    if (offsetBytes == 0) {
                        deleteSafChildByDisplayName(root, parentDocumentId, partialDisplayName);
                        documentUri = createSafDocument(parentUri, displayName, partialDisplayName);
                        deleteDocumentOnOpenFailure = true;
                    } else {
                        SafChildDocument partialDocument = safChildByDisplayName(
                                root,
                                parentDocumentId,
                                partialDisplayName
                        );
                        if (partialDocument == null) {
                            throw new ProviderCatalogException(
                                    ErrorCode.ERROR_CODE_NOT_FOUND,
                                    "SAF upload partial is not available"
                            );
                        }
                        if (partialDocument.kind != FileKind.FILE_KIND_FILE) {
                            throw new ProviderCatalogException(
                                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                    "SAF upload partial must identify a file entry"
                            );
                        }
                        if (partialDocument.sizeBytes != offsetBytes) {
                            throw new ProviderCatalogException(
                                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                    "requested_offset_bytes does not match SAF upload partial"
                            );
                        }
                        documentUri = DocumentsContract.buildDocumentUriUsingTree(
                                root.treeUri,
                                partialDocument.documentId
                        );
                    }
                }
                outputStream = contentResolver.openOutputStream(documentUri, offsetBytes == 0 ? "w" : "wa");
                if (outputStream == null) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INTERNAL,
                            "SAF upload document could not be opened"
                    );
                }
                return new SafUploadWriter(
                        contentResolver,
                        documentUri,
                        outputStream,
                        expectedSizeBytes,
                        initialOffsetBytes,
                        finalDisplayName,
                        deleteOnNonFinalClose
                );
            } catch (SecurityException exception) {
                closeQuietly(outputStream);
                if (deleteDocumentOnOpenFailure) {
                    deleteDocumentQuietly(contentResolver, documentUri);
                }
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF write permission is required to upload this document"
                );
            } catch (ProviderCatalogException exception) {
                closeQuietly(outputStream);
                if (deleteDocumentOnOpenFailure) {
                    deleteDocumentQuietly(contentResolver, documentUri);
                }
                throw exception;
            } catch (FileNotFoundException exception) {
                closeQuietly(outputStream);
                if (deleteDocumentOnOpenFailure) {
                    deleteDocumentQuietly(contentResolver, documentUri);
                }
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "SAF upload destination is not available"
                );
            } catch (RuntimeException exception) {
                closeQuietly(outputStream);
                if (deleteDocumentOnOpenFailure) {
                    deleteDocumentQuietly(contentResolver, documentUri);
                }
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF upload failed"
                );
            }
        }

        private Uri createSafDocument(Uri parentUri, String finalDisplayName, String displayName)
                throws ProviderCatalogException {
            try {
                Uri documentUri = DocumentsContract.createDocument(
                        contentResolver,
                        parentUri,
                        uploadMimeType(finalDisplayName),
                        displayName
                );
                if (documentUri == null) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INTERNAL,
                            "SAF upload document could not be created"
                    );
                }
                return documentUri;
            } catch (FileNotFoundException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "SAF upload destination is not available"
                );
            }
        }

        private void deleteSafChildByDisplayName(SafRoot root, String parentDocumentId, String displayName)
                throws ProviderCatalogException {
            SafChildDocument child = safChildByDisplayName(root, parentDocumentId, displayName);
            if (child != null) {
                deleteDocumentQuietly(
                        contentResolver,
                        DocumentsContract.buildDocumentUriUsingTree(root.treeUri, child.documentId)
                );
            }
        }

        private SafChildDocument safChildByDisplayName(SafRoot root, String parentDocumentId, String displayName)
                throws ProviderCatalogException {
            Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(root.treeUri, parentDocumentId);
            try (Cursor cursor = contentResolver.query(childrenUri, DOCUMENT_PROJECTION, null, null, null)) {
                if (cursor == null) {
                    return null;
                }
                int idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID);
                int nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
                int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
                int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
                int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
                while (cursor.moveToNext()) {
                    String candidateName = cursor.isNull(nameColumn) ? "" : cursor.getString(nameColumn);
                    if (!displayName.equals(candidateName)) {
                        continue;
                    }
                    String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
                    int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
                    boolean isDirectory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
                    FileKind kind = isDirectory
                            ? FileKind.FILE_KIND_DIRECTORY
                            : ((flags & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                                    ? FileKind.FILE_KIND_VIRTUAL
                                    : FileKind.FILE_KIND_FILE);
                    long sizeBytes = isDirectory || cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
                    return new SafChildDocument(cursor.getString(idColumn), kind, sizeBytes);
                }
                return null;
            } catch (SecurityException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF permission is required to read this root"
                );
            } catch (RuntimeException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF query failed"
                );
            }
        }

        private static String safUploadPartialDisplayName(
                SafRoot root,
                String parentDocumentId,
                String displayName,
                String transferId
        ) {
            return ".droidmatch-upload-"
                    + stableOpaqueId(
                            root.stableId + "\n" + parentDocumentId + "\n" + displayName + "\n" + transferId,
                            10
                    )
                    + ".part";
        }

        private String documentDisplayName(Uri treeUri, String documentId, String fallback) {
            Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId);
            try (Cursor cursor = contentResolver.query(
                    documentUri,
                    new String[] { DocumentsContract.Document.COLUMN_DISPLAY_NAME },
                    null,
                    null,
                    null
            )) {
                if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) {
                    return cursor.getString(0);
                }
            } catch (RuntimeException exception) {
                return fallback;
            }
            return fallback;
        }

        private SafDocumentMetadata safDocumentMetadata(Uri treeUri, String documentId) throws ProviderCatalogException {
            Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId);
            try (Cursor cursor = contentResolver.query(documentUri, DOCUMENT_PROJECTION, null, null, null)) {
                if (cursor == null || !cursor.moveToFirst()) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_NOT_FOUND,
                            "SAF document is not available"
                    );
                }
                int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
                int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
                int modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
                int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
                String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
                int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
                boolean isDirectory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
                FileKind kind = isDirectory
                        ? FileKind.FILE_KIND_DIRECTORY
                        : ((flags & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                                ? FileKind.FILE_KIND_VIRTUAL
                                : FileKind.FILE_KIND_FILE);
                long sizeBytes = isDirectory || cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
                long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn);
                boolean canCreate = isDirectory
                        && (flags & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) != 0;
                return new SafDocumentMetadata(kind, sizeBytes, modifiedMillis, canCreate);
            } catch (SecurityException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF permission is required to read this document"
                );
            } catch (ProviderCatalogException exception) {
                throw exception;
            } catch (RuntimeException exception) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF metadata query failed"
                );
            }
        }

        private static ArrayList<SafItem> readSafCursor(Cursor cursor, boolean rootCanWrite) {
            int idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID);
            int nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
            int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
            int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
            int modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
            int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
            ArrayList<SafItem> items = new ArrayList<>();

            while (cursor.moveToNext()) {
                String documentId = cursor.getString(idColumn);
                String displayName = cursor.isNull(nameColumn) ? documentId : cursor.getString(nameColumn);
                String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
                boolean isDirectory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
                int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
                FileKind kind = isDirectory
                        ? FileKind.FILE_KIND_DIRECTORY
                        : ((flags & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                                ? FileKind.FILE_KIND_VIRTUAL
                                : FileKind.FILE_KIND_FILE);
                long sizeBytes = isDirectory || cursor.isNull(sizeColumn) ? 0 : cursor.getLong(sizeColumn);
                long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn);
                boolean canWrite = rootCanWrite && supportsWrite(kind, flags);
                items.add(new SafItem(
                        documentId,
                        displayName,
                        kind,
                        sizeBytes,
                        modifiedMillis,
                        mimeType,
                        canWrite
                ));
            }
            return items;
        }

        private static boolean supportsWrite(FileKind kind, int flags) {
            if (kind == FileKind.FILE_KIND_DIRECTORY) {
                return (flags & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) != 0;
            }
            return (flags & (DocumentsContract.Document.FLAG_SUPPORTS_WRITE
                    | DocumentsContract.Document.FLAG_SUPPORTS_DELETE)) != 0;
        }

        private static SafPage pageSafItems(List<SafItem> items, int offset, int limit) {
            if (offset >= items.size()) {
                return new SafPage(new ArrayList<>(), false);
            }
            int endExclusive = Math.min(items.size(), offset + limit);
            boolean hasMore = endExclusive < items.size();
            return new SafPage(new ArrayList<>(items.subList(offset, endExclusive)), hasMore);
        }

        private static Comparator<SafItem> safComparator(SortField sortField, boolean descending) {
            Comparator<SafItem> comparator;
            switch (sortField) {
                case SORT_FIELD_NAME:
                    comparator = Comparator.comparing(item -> item.displayName, String.CASE_INSENSITIVE_ORDER);
                    break;
                case SORT_FIELD_SIZE:
                    comparator = Comparator.comparingLong(item -> item.sizeBytes);
                    break;
                case SORT_FIELD_KIND:
                    comparator = Comparator.comparingInt(item -> item.kind.getNumber());
                    break;
                case SORT_FIELD_MODIFIED_TIME:
                case SORT_FIELD_UNSPECIFIED:
                case UNRECOGNIZED:
                default:
                    comparator = Comparator.comparingLong(item -> item.modifiedUnixMillis);
                    break;
            }
            if (descending) {
                comparator = comparator.reversed();
            }
            return comparator
                    .thenComparing(item -> item.displayName, String.CASE_INSENSITIVE_ORDER)
                    .thenComparing(item -> item.documentId);
        }

        private static final class SafDocumentMetadata {
            private final FileKind kind;
            private final long sizeBytes;
            private final long modifiedUnixMillis;
            private final boolean canCreate;

            private SafDocumentMetadata(
                    FileKind kind,
                    long sizeBytes,
                    long modifiedUnixMillis,
                    boolean canCreate
            ) {
                this.kind = kind;
                this.sizeBytes = sizeBytes;
                this.modifiedUnixMillis = modifiedUnixMillis;
                this.canCreate = canCreate;
            }
        }

        private static final class SafChildDocument {
            private final String documentId;
            private final FileKind kind;
            private final long sizeBytes;

            private SafChildDocument(String documentId, FileKind kind, long sizeBytes) {
                this.documentId = documentId;
                this.kind = kind;
                this.sizeBytes = sizeBytes;
            }
        }

    }

    private static final class StreamDownloadReader implements DownloadReader {
        private final InputStream inputStream;
        private final Closeable extraCloseable;
        private final int chunkSizeBytes;
        private final long totalSizeBytes;
        private final long modifiedUnixMillis;
        private final String providerEtag;
        private final String readFailureMessage;
        private long nextOffsetBytes;
        private boolean closed;

        private StreamDownloadReader(
                InputStream inputStream,
                long nextOffsetBytes,
                int chunkSizeBytes,
                long totalSizeBytes,
                long modifiedUnixMillis,
                String providerEtag,
                String readFailureMessage
        ) {
            this(
                    inputStream,
                    null,
                    nextOffsetBytes,
                    chunkSizeBytes,
                    totalSizeBytes,
                    modifiedUnixMillis,
                    providerEtag,
                    readFailureMessage
            );
        }

        private StreamDownloadReader(
                InputStream inputStream,
                Closeable extraCloseable,
                long nextOffsetBytes,
                int chunkSizeBytes,
                long totalSizeBytes,
                long modifiedUnixMillis,
                String providerEtag,
                String readFailureMessage
        ) {
            this.inputStream = inputStream;
            this.extraCloseable = extraCloseable;
            this.nextOffsetBytes = nextOffsetBytes;
            this.chunkSizeBytes = chunkSizeBytes;
            this.totalSizeBytes = totalSizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.providerEtag = providerEtag;
            this.readFailureMessage = readFailureMessage;
        }

        @Override
        public DownloadChunk readNextChunk() throws ProviderCatalogException {
            if (closed) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "download reader is closed"
                );
            }

            try {
                byte[] data = readAtMost(inputStream, chunkSizeBytes);
                boolean finalChunk = data.length < chunkSizeBytes
                        || (totalSizeBytes >= 0 && nextOffsetBytes + data.length >= totalSizeBytes);
                nextOffsetBytes += data.length;
                if (finalChunk) {
                    close();
                }
                return new DownloadChunk(
                        data,
                        totalSizeBytes,
                        modifiedUnixMillis,
                        providerEtag,
                        finalChunk
                );
            } catch (IOException exception) {
                close();
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        readFailureMessage
                );
            }
        }

        @Override
        public void close() {
            if (closed) {
                return;
            }
            closed = true;
            closeQuietly(inputStream);
            closeQuietly(extraCloseable);
        }
    }

    private static DownloadReader seekableReaderOrNull(
            ContentResolver contentResolver,
            Uri uri,
            long offsetBytes,
            int chunkSizeBytes,
            long totalSizeBytes,
            long modifiedUnixMillis,
            String providerEtag,
            String permissionMessage,
            String readFailureMessage
    ) throws ProviderCatalogException {
        if (totalSizeBytes >= 0 && offsetBytes > totalSizeBytes) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes is beyond end of file"
            );
        }

        ParcelFileDescriptor parcelFileDescriptor = null;
        FileInputStream inputStream = null;
        try {
            parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "r");
            if (parcelFileDescriptor == null) {
                return null;
            }
            inputStream = new FileInputStream(parcelFileDescriptor.getFileDescriptor());
            FileChannel channel = inputStream.getChannel();
            channel.position(offsetBytes);
            return new StreamDownloadReader(
                    inputStream,
                    parcelFileDescriptor,
                    offsetBytes,
                    chunkSizeBytes,
                    totalSizeBytes,
                    modifiedUnixMillis,
                    providerEtag,
                    readFailureMessage
            );
        } catch (SecurityException exception) {
            closeQuietly(inputStream);
            closeQuietly(parcelFileDescriptor);
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    permissionMessage
            );
        } catch (IOException exception) {
            closeQuietly(inputStream);
            closeQuietly(parcelFileDescriptor);
            return null;
        } catch (RuntimeException exception) {
            closeQuietly(inputStream);
            closeQuietly(parcelFileDescriptor);
            return null;
        }
    }

    private static void closeQuietly(Closeable closeable) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (IOException ignored) {
        }
    }

    private static void deleteDocumentQuietly(ContentResolver contentResolver, Uri documentUri) {
        if (documentUri == null) {
            return;
        }
        try {
            DocumentsContract.deleteDocument(contentResolver, documentUri);
        } catch (FileNotFoundException | RuntimeException ignored) {
        }
    }

    private static void deleteUriQuietly(ContentResolver contentResolver, Uri uri) {
        if (uri == null) {
            return;
        }
        try {
            contentResolver.delete(uri, null, null);
        } catch (RuntimeException ignored) {
        }
    }

    private static String uploadMimeType(String displayName) {
        String guessed = URLConnection.guessContentTypeFromName(displayName);
        return guessed == null || guessed.isEmpty() ? "application/octet-stream" : guessed;
    }

    private static void skipFully(InputStream inputStream, long offsetBytes)
            throws IOException, ProviderCatalogException {
        long remaining = offsetBytes;
        while (remaining > 0) {
            long skipped = inputStream.skip(remaining);
            if (skipped > 0) {
                remaining -= skipped;
                continue;
            }
            if (inputStream.read() == -1) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "requested_offset_bytes is beyond end of file"
                );
            }
            remaining--;
        }
    }

    private static byte[] readAtMost(InputStream inputStream, int byteCount) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(byteCount, 64 * 1024));
        byte[] buffer = new byte[Math.min(byteCount, 64 * 1024)];
        int remaining = byteCount;
        while (remaining > 0) {
            int read = inputStream.read(buffer, 0, Math.min(buffer.length, remaining));
            if (read == -1) {
                break;
            }
            output.write(buffer, 0, read);
            remaining -= read;
        }
        return output.toByteArray();
    }
}
