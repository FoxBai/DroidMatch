package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.BaseColumns;
import android.provider.MediaStore;

import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.util.ArrayList;
import java.util.List;

public final class DmFileProvider {
    public static final String ROOTS_PATH = "dm://roots/";
    public static final String MEDIA_IMAGES_PATH = "dm://media-images/";
    public static final String MEDIA_VIDEOS_PATH = "dm://media-videos/";
    public static final String APP_SANDBOX_PATH = "dm://app-sandbox/";

    private static final int DEFAULT_PAGE_SIZE = 200;
    private static final int MAX_PAGE_SIZE = 1_000;

    private static final Root[] ROOTS = new Root[] {
            new Root("Images", MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES),
            new Root("Videos", MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS),
            new Root("App Sandbox", APP_SANDBOX_PATH, RootKind.EMPTY)
    };

    private final MediaCatalog mediaCatalog;

    public DmFileProvider() {
        this(MediaCatalog.empty());
    }

    public DmFileProvider(Context context) {
        this(new AndroidMediaCatalog(context.getApplicationContext().getContentResolver()));
    }

    DmFileProvider(MediaCatalog mediaCatalog) {
        this.mediaCatalog = mediaCatalog;
    }

    public String[] listRoots() {
        String[] paths = new String[ROOTS.length];
        for (int index = 0; index < ROOTS.length; index++) {
            paths[index] = ROOTS[index].path;
        }
        return paths;
    }

    public ListDirResponse listDir(ListDirRequest request) {
        if (ROOTS_PATH.equals(request.getPath())) {
            return listRootDirectory(request);
        }

        Root root = rootForPath(request.getPath());
        if (root == null) {
            return errorResponse(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "unknown DroidMatch provider path: " + request.getPath()
            );
        }

        if (root.kind == RootKind.EMPTY) {
            return emptyDirectory(request);
        }
        return listMediaRoot(root, request);
    }

    private ListDirResponse listRootDirectory(ListDirRequest request) {
        if (!request.getPageToken().isEmpty()) {
            return errorResponse(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "page_token is not supported by the M1 root provider"
            );
        }

        ListDirResponse.Builder response = ListDirResponse.newBuilder();
        for (Root root : ROOTS) {
            response.addEntries(FileEntry.newBuilder()
                    .setPath(root.path)
                    .setName(root.displayName)
                    .setKind(FileKind.FILE_KIND_VIRTUAL)
                    .setCanRead(true)
                    .setCanWrite(false)
                    .setMimeType("vnd.droidmatch.root")
                    .build());
        }
        return response.build();
    }

    private ListDirResponse emptyDirectory(ListDirRequest request) {
        PageRequest pageRequest = pageRequest(request);
        if (pageRequest.error != null) {
            return pageRequest.error;
        }
        return ListDirResponse.newBuilder().build();
    }

    private ListDirResponse listMediaRoot(Root root, ListDirRequest request) {
        PageRequest pageRequest = pageRequest(request);
        if (pageRequest.error != null) {
            return pageRequest.error;
        }

        try {
            MediaPage page = mediaCatalog.listMedia(
                    root.kind,
                    new MediaQuery(
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
                response.setNextPageToken(Integer.toString(pageRequest.offset + pageRequest.limit));
            }
            return response.build();
        } catch (MediaCatalogException exception) {
            return errorResponse(exception.code, exception.getMessage());
        }
    }

    private static Root rootForPath(String path) {
        for (Root root : ROOTS) {
            if (root.path.equals(path)) {
                return root;
            }
        }
        return null;
    }

    private static PageRequest pageRequest(ListDirRequest request) {
        int offset = 0;
        if (!request.getPageToken().isEmpty()) {
            try {
                offset = Integer.parseInt(request.getPageToken());
            } catch (NumberFormatException exception) {
                return PageRequest.error(errorResponse(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "invalid page_token"
                ));
            }
            if (offset < 0) {
                return PageRequest.error(errorResponse(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "invalid page_token"
                ));
            }
        }

        long requestedSize = Integer.toUnsignedLong(request.getPageSize());
        int limit = requestedSize == 0 ? DEFAULT_PAGE_SIZE : (int) Math.min(requestedSize, MAX_PAGE_SIZE);
        return PageRequest.page(offset, limit);
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
        MediaPage listMedia(RootKind rootKind, MediaQuery query) throws MediaCatalogException;

        static MediaCatalog empty() {
            return (rootKind, query) -> new MediaPage(new ArrayList<>(), false);
        }
    }

    static final class MediaQuery {
        private final int offset;
        private final int limit;
        private final SortField sortField;
        private final boolean descending;

        MediaQuery(int offset, int limit, SortField sortField, boolean descending) {
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

    static final class MediaCatalogException extends Exception {
        private final ErrorCode code;

        MediaCatalogException(ErrorCode code, String message) {
            super(message);
            this.code = code;
        }
    }

    enum RootKind {
        MEDIA_IMAGES,
        MEDIA_VIDEOS,
        EMPTY
    }

    private static final class Root {
        private final String displayName;
        private final String path;
        private final RootKind kind;

        private Root(String displayName, String path, RootKind kind) {
            this.displayName = displayName;
            this.path = path;
            this.kind = kind;
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
        public MediaPage listMedia(RootKind rootKind, MediaQuery query) throws MediaCatalogException {
            Uri uri = collectionUri(rootKind);
            Bundle queryArgs = new Bundle();
            queryArgs.putInt(ContentResolver.QUERY_ARG_LIMIT, query.limit + 1);
            queryArgs.putInt(ContentResolver.QUERY_ARG_OFFSET, query.offset);
            queryArgs.putStringArray(
                    ContentResolver.QUERY_ARG_SORT_COLUMNS,
                    new String[] { sortColumn(query.sortField) }
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
                throw new MediaCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "media permission is required to list " + rootKind
                );
            } catch (RuntimeException exception) {
                throw new MediaCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore query failed"
                );
            }
        }

        private static Uri collectionUri(RootKind rootKind) {
            if (rootKind == RootKind.MEDIA_IMAGES) {
                return MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
            }
            return MediaStore.Video.Media.EXTERNAL_CONTENT_URI;
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

        private static String sortColumn(SortField sortField) {
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
    }
}
