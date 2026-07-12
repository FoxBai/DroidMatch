package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.Context;
import android.net.Uri;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileMutationResponse;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;
import app.droidmatch.proto.v1.ThumbnailRequest;
import app.droidmatch.proto.v1.ThumbnailResponse;

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
    public static final String MEDIA_IMAGE_ALBUMS_PATH = ProviderMediaListings.IMAGE_ALBUMS_PATH;
    public static final String MEDIA_VIDEOS_PATH = "dm://media-videos/";
    public static final String APP_SANDBOX_PATH = "dm://app-sandbox/";

    private static final int MAX_SAF_DOCUMENT_CACHE_ENTRIES = 4_096;

    private final MediaCatalog mediaCatalog;
    private final SafCatalog safCatalog;
    private final AppSandboxCatalog appSandboxCatalog;
    private final Map<String, String> safDocumentIdsByLogicalId;
    private final ProviderMutations mutations;
    private final ProviderThumbnails thumbnails;
    // The foreground service can be recreated before an old client executor
    // has fully unwound. Process-wide ownership prevents the replacement
    // facade from opening a second writer onto that still-active destination.
    private static final ProviderUploadLeases PROCESS_UPLOAD_LEASES =
            new ProviderUploadLeases();

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
        this.thumbnails = new ProviderThumbnails(mediaCatalog);
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
        this.thumbnails = new ProviderThumbnails(mediaCatalog);
    }

    public String[] listRoots() {
        return ProviderDirectoryListings.listRoots(safCatalog);
    }

    public ListDirResponse listDir(ListDirRequest request) {
        return ProviderDirectoryListings.list(
                request, mediaCatalog, safCatalog, appSandboxCatalog, safDocumentIdsByLogicalId
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

    public ThumbnailResponse thumbnail(ThumbnailRequest request) {
        return thumbnails.thumbnail(request);
    }

    public DownloadChunk readDownloadChunk(String path, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException {
        try (DownloadReader reader = openDownload(path, offsetBytes, chunkSizeBytes)) {
            return reader.readNextChunk();
        }
    }

    public DownloadReader openDownload(String path, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException {
        return ProviderTransfers.openDownload(
                path,
                offsetBytes,
                chunkSizeBytes,
                mediaCatalog,
                safCatalog,
                appSandboxCatalog,
                safDocumentIdsByLogicalId
        );
    }

    public UploadWriter openUpload(String path, long offsetBytes, long expectedSizeBytes)
            throws ProviderCatalogException {
        return openUpload(path, "", offsetBytes, expectedSizeBytes);
    }

    public UploadWriter openUpload(String path, String transferId, long offsetBytes, long expectedSizeBytes)
            throws ProviderCatalogException {
        return ProviderTransfers.openUpload(
                path,
                transferId,
                offsetBytes,
                expectedSizeBytes,
                mediaCatalog,
                safCatalog,
                appSandboxCatalog,
                safDocumentIdsByLogicalId,
                PROCESS_UPLOAD_LEASES
        );
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


    interface MediaCatalog {
        MediaPage listMedia(RootKind rootKind, ProviderQuery query) throws ProviderCatalogException;

        default ProviderAlbumPage listAlbums(ProviderQuery query) throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "MediaStore albums are not available"
            );
        }

        default MediaPage listMediaInAlbum(String albumToken, ProviderQuery query)
                throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "MediaStore albums are not available"
            );
        }

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

        default ProviderThumbnail thumbnail(RootKind rootKind, long mediaId, int maxDimensionPx)
                throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "MediaStore thumbnail is not available"
            );
        }

        default ProviderThumbnail thumbnailAlbum(String albumToken, int maxDimensionPx)
                throws ProviderCatalogException {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "MediaStore album thumbnails are not available"
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

        UploadWriter openUploadFile(
                String relativePath,
                long offsetBytes,
                long expectedSizeBytes,
                ProviderUploadLeases uploadLeases
        )
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
                public UploadWriter openUploadFile(
                        String relativePath,
                        long offsetBytes,
                        long expectedSizeBytes,
                        ProviderUploadLeases uploadLeases
                )
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

        List<AppSandboxItem> items() {
            return items;
        }

        boolean hasMore() {
            return hasMore;
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
        private final String searchQuery;

        ProviderQuery(int offset, int limit, SortField sortField, boolean descending, String searchQuery) {
            this.offset = offset;
            this.limit = limit;
            this.sortField = sortField;
            this.descending = descending;
            this.searchQuery = searchQuery == null ? "" : searchQuery;
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

        String searchQuery() {
            return searchQuery;
        }
    }

    static final class MediaPage {
        final List<MediaItem> items;
        final boolean hasMore;

        MediaPage(List<MediaItem> items, boolean hasMore) {
            this.items = items;
            this.hasMore = hasMore;
        }
    }

    static final class MediaItem {
        final long id;
        final String displayName;
        final long sizeBytes;
        final long modifiedUnixMillis;
        final String mimeType;

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

        List<SafItem> items() {
            return items;
        }

        boolean hasMore() {
            return hasMore;
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
        MEDIA_IMAGE_ALBUMS,
        MEDIA_VIDEOS,
        APP_SANDBOX
    }

}
