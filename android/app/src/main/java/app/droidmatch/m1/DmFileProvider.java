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
import java.util.List;

public final class DmFileProvider {
    public static final String ROOTS_PATH = "dm://roots/";
    public static final String MEDIA_IMAGES_PATH = "dm://media-images/";
    public static final String MEDIA_IMAGE_ALBUMS_PATH = ProviderMediaListings.IMAGE_ALBUMS_PATH;
    public static final String MEDIA_VIDEOS_PATH = "dm://media-videos/";
    public static final String APP_SANDBOX_PATH = "dm://app-sandbox/";

    private static final int MAX_SAF_DOCUMENT_CACHE_ENTRIES = 4_096;

    private final ProviderMediaCatalog mediaCatalog;
    private final ProviderSafCatalog safCatalog;
    private final ProviderAppSandboxCatalog appSandboxCatalog;
    private final ProviderSafDocumentCache safDocumentCache;
    private final ProviderMutations mutations;
    private final ProviderThumbnails thumbnails;
    // The foreground service can be recreated before an old client executor
    // has fully unwound. Process-wide ownership prevents the replacement
    // facade from opening a second writer onto that still-active destination.
    private static final ProviderUploadLeases PROCESS_UPLOAD_LEASES =
            new ProviderUploadLeases();

    public DmFileProvider() {
        this(ProviderMediaCatalog.empty(), ProviderSafCatalog.empty(), ProviderAppSandboxCatalog.empty());
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
                new File(applicationContext.getFilesDir(), "droidmatch-sandbox"),
                new AndroidAppSandboxOpenedFileMetadataReader()
        );
        this.safDocumentCache = new ProviderSafDocumentCache(MAX_SAF_DOCUMENT_CACHE_ENTRIES);
        this.mutations = new ProviderMutations(
                safCatalog,
                appSandboxCatalog,
                safDocumentCache
        );
        this.thumbnails = new ProviderThumbnails(mediaCatalog);
    }

    DmFileProvider(ProviderMediaCatalog mediaCatalog) {
        this(mediaCatalog, ProviderSafCatalog.empty(), ProviderAppSandboxCatalog.empty());
    }

    DmFileProvider(ProviderMediaCatalog mediaCatalog, ProviderSafCatalog safCatalog) {
        this(mediaCatalog, safCatalog, ProviderAppSandboxCatalog.empty());
    }

    DmFileProvider(File appSandboxRootDirectory) {
        this(
                ProviderMediaCatalog.empty(),
                ProviderSafCatalog.empty(),
                new AndroidAppSandboxCatalog(appSandboxRootDirectory)
        );
    }

    DmFileProvider(
            ProviderMediaCatalog mediaCatalog,
            ProviderSafCatalog safCatalog,
            ProviderAppSandboxCatalog appSandboxCatalog
    ) {
        this(mediaCatalog, safCatalog, appSandboxCatalog, MAX_SAF_DOCUMENT_CACHE_ENTRIES);
    }

    DmFileProvider(
            ProviderMediaCatalog mediaCatalog,
            ProviderSafCatalog safCatalog,
            ProviderAppSandboxCatalog appSandboxCatalog,
            int maxSafDocumentCacheEntries
    ) {
        this.mediaCatalog = mediaCatalog;
        this.safCatalog = safCatalog;
        this.appSandboxCatalog = appSandboxCatalog;
        this.safDocumentCache = new ProviderSafDocumentCache(maxSafDocumentCacheEntries);
        this.mutations = new ProviderMutations(
                safCatalog,
                appSandboxCatalog,
                safDocumentCache
        );
        this.thumbnails = new ProviderThumbnails(mediaCatalog);
    }

    public String[] listRoots() {
        return ProviderDirectoryListings.listRoots(safCatalog);
    }

    public ListDirResponse listDir(ListDirRequest request) {
        return ProviderDirectoryListings.list(
                request, mediaCatalog, safCatalog, appSandboxCatalog, safDocumentCache
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
                safDocumentCache
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
                safDocumentCache,
                PROCESS_UPLOAD_LEASES
        );
    }

    public void discardUploadPartial(
            String path,
            String transferId,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        ProviderTransfers.discardUploadPartial(
                path,
                transferId,
                expectedSizeBytes,
                safCatalog,
                appSandboxCatalog,
                safDocumentCache,
                PROCESS_UPLOAD_LEASES
        );
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
        final long durationMillis;

        MediaItem(
                long id,
                String displayName,
                long sizeBytes,
                long modifiedUnixMillis,
                String mimeType,
                long durationMillis
        ) {
            this.id = id;
            this.displayName = displayName;
            this.sizeBytes = sizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.mimeType = mimeType;
            this.durationMillis = Math.max(0, durationMillis);
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
