package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.Context;
import android.net.Uri;

import app.droidmatch.m1.ProviderPathRouter.AppSandboxTarget;
import app.droidmatch.m1.ProviderPathRouter.MediaTarget;
import app.droidmatch.m1.ProviderPathRouter.MediaUploadTarget;
import app.droidmatch.m1.ProviderPathRouter.SafTarget;
import app.droidmatch.m1.ProviderPathRouter.SafUploadTarget;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileMutationResponse;
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

    private static final int MAX_SAF_DOCUMENT_CACHE_ENTRIES = 4_096;

    private static final StaticRoot[] STATIC_ROOTS = new StaticRoot[] {
            new StaticRoot("Images", MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES),
            new StaticRoot("Videos", MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS),
            new StaticRoot("App Sandbox", APP_SANDBOX_PATH, RootKind.APP_SANDBOX)
    };

    private final MediaCatalog mediaCatalog;
    private final SafCatalog safCatalog;
    private final AppSandboxCatalog appSandboxCatalog;
    private final Map<String, String> safDocumentIdsByLogicalId;
    private final ProviderMutations mutations;

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
        this.mutations = new ProviderMutations(
                safCatalog,
                appSandboxCatalog,
                safDocumentIdsByLogicalId
        );
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
        this.mutations = new ProviderMutations(
                safCatalog,
                appSandboxCatalog,
                safDocumentIdsByLogicalId
        );
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

        AppSandboxTarget appSandboxTarget = ProviderPathRouter.appSandboxDirectory(request.getPath());
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

        SafTarget safTarget = ProviderPathRouter.safDirectory(
                request.getPath(),
                safCatalog.roots(),
                safDocumentIdsByLogicalId
        );
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

    /** Creates one directory without ever accepting a platform path or content URI. */
    public FileMutationResponse createDirectory(String path) {
        return mutations.createDirectory(path);
    }

    public FileMutationResponse renamePath(String sourcePath, String destinationPath) {
        return mutations.renamePath(sourcePath, destinationPath);
    }

    public FileMutationResponse deletePath(String path, boolean recursive) {
        return mutations.deletePath(path, recursive);
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

        MediaTarget mediaTarget = ProviderPathRouter.mediaDownload(path);
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

        AppSandboxTarget appSandboxTarget = ProviderPathRouter.appSandboxFile(path);
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

        SafTarget safTarget = ProviderPathRouter.safDirectory(
                path,
                safCatalog.roots(),
                safDocumentIdsByLogicalId
        );
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

        AppSandboxTarget appSandboxTarget = ProviderPathRouter.appSandboxFile(path);
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

        MediaUploadTarget mediaUploadTarget = ProviderPathRouter.mediaUpload(path);
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

        SafUploadTarget safUploadTarget = ProviderPathRouter.safUpload(
                path,
                safCatalog.roots(),
                safDocumentIdsByLogicalId
        );
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
        ProviderPagePolicy.PageRequest pageRequest = ProviderPagePolicy.parse(request);
        if (pageRequest.error != null) {
            return pageRequest.error;
        }

        try {
            AppSandboxPage page = appSandboxCatalog.listDirectory(
                    relativePath,
                    new ProviderQuery(
                            pageRequest.offset,
                            pageRequest.limit,
                            ProviderPagePolicy.effectiveSortField(request.getSortField()),
                            ProviderPagePolicy.effectiveDescending(request.getSortField(), request.getDescending())
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
                response.setNextPageToken(ProviderPagePolicy.nextToken(request, pageRequest));
            }
            return response.build();
        } catch (ProviderCatalogException exception) {
            return errorResponse(exception.code, exception.getMessage());
        }
    }

    private ListDirResponse listMediaRoot(StaticRoot root, ListDirRequest request) {
        ProviderPagePolicy.PageRequest pageRequest = ProviderPagePolicy.parse(request);
        if (pageRequest.error != null) {
            return pageRequest.error;
        }

        try {
            MediaPage page = mediaCatalog.listMedia(
                    root.kind,
                    new ProviderQuery(
                            pageRequest.offset,
                            pageRequest.limit,
                            ProviderPagePolicy.effectiveSortField(request.getSortField()),
                            ProviderPagePolicy.effectiveDescending(request.getSortField(), request.getDescending())
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
                response.setNextPageToken(ProviderPagePolicy.nextToken(request, pageRequest));
            }
            return response.build();
        } catch (ProviderCatalogException exception) {
            return errorResponse(exception.code, exception.getMessage());
        }
    }

    private ListDirResponse listSafDirectory(SafTarget target, ListDirRequest request) {
        ProviderPagePolicy.PageRequest pageRequest = ProviderPagePolicy.parse(request);
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
                            ProviderPagePolicy.effectiveSortField(request.getSortField()),
                            ProviderPagePolicy.effectiveDescending(request.getSortField(), request.getDescending())
                    )
            );

            ListDirResponse.Builder response = ListDirResponse.newBuilder();
            for (SafItem item : page.items) {
                response.addEntries(FileEntry.newBuilder()
                        .setPath(target.root.path()
                                + ProviderPathRouter.SAF_DOCUMENT_PREFIX
                                + ProviderPathRouter.cacheSafDocumentId(
                                        safDocumentIdsByLogicalId,
                                        target.root,
                                        item.documentId
                                ))
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
                response.setNextPageToken(ProviderPagePolicy.nextToken(request, pageRequest));
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

    private static Map<String, String> safDocumentCache(int maxEntries) {
        final int boundedMaxEntries = Math.max(1, maxEntries);
        return Collections.synchronizedMap(new LinkedHashMap<String, String>(boundedMaxEntries, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, String> eldest) {
                return size() > boundedMaxEntries;
            }
        });
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

        default void createDirectory(SafRoot root, String parentDocumentId, String displayName)
                throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF directory creation is not available"
            );
        }

        default void renameDocument(SafRoot root, String documentId, String displayName)
                throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF rename is not available"
            );
        }

        default void deleteDocument(SafRoot root, String documentId, boolean recursive)
                throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF delete is not available"
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

        void createDirectory(String relativePath) throws ProviderCatalogException;

        void renamePath(String sourceRelativePath, String destinationRelativePath, boolean directory)
                throws ProviderCatalogException;

        void deletePath(String relativePath, boolean directory, boolean recursive)
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

                @Override
                public void createDirectory(String relativePath) throws ProviderCatalogException {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                            "app sandbox directory creation is not available"
                    );
                }

                @Override
                public void renamePath(String sourceRelativePath, String destinationRelativePath, boolean directory)
                        throws ProviderCatalogException {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                            "app sandbox rename is not available"
                    );
                }

                @Override
                public void deletePath(String relativePath, boolean directory, boolean recursive)
                        throws ProviderCatalogException {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                            "app sandbox delete is not available"
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

        String path() {
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

}
