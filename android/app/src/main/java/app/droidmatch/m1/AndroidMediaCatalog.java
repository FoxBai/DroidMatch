package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.ContentValues;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.BaseColumns;
import android.provider.MediaStore;
import android.util.Size;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.SortField;

import java.io.Closeable;
import java.io.ByteArrayOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;

/**
 * MediaStore catalog for flat image/video collections.
 *
 * <p>Read permission is checked for every list/open operation. Uploads are
 * fresh-only: API 29+ rows remain pending until the extracted writer commits,
 * and any failed open removes the provisional row.</p>
 */
final class AndroidMediaCatalog implements DmFileProvider.MediaCatalog {
    private static final int MAX_THUMBNAIL_BYTES = 512 * 1024;
    private static final String[] PROJECTION = new String[] {
            BaseColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.MIME_TYPE
    };
    private static final String[] ALBUM_PROJECTION = new String[] {
            MediaStore.Images.ImageColumns.BUCKET_ID,
            MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_MODIFIED
    };

    private final ContentResolver contentResolver;
    private final PermissionStateProvider permissionStateProvider;

    AndroidMediaCatalog(
            ContentResolver contentResolver,
            PermissionStateProvider permissionStateProvider
    ) {
        this.contentResolver = contentResolver;
        this.permissionStateProvider = permissionStateProvider;
    }

    @Override
    public boolean canUploadMedia(DmFileProvider.RootKind rootKind) {
        return rootKind == DmFileProvider.RootKind.MEDIA_IMAGES
                || rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS;
    }

    @Override
    public DmFileProvider.MediaPage listMedia(
            DmFileProvider.RootKind rootKind,
            DmFileProvider.ProviderQuery query
    ) throws DmFileProvider.ProviderCatalogException {
        requireMediaReadPermission("list " + rootKind);

        return listMedia(rootKind, query, null);
    }

    @Override
    public ProviderAlbumPage listAlbums(DmFileProvider.ProviderQuery query)
            throws DmFileProvider.ProviderCatalogException {
        requireMediaReadPermission("list image albums");
        ProviderMediaAlbums albums = new ProviderMediaAlbums();
        try (Cursor cursor = contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                ALBUM_PROJECTION,
                null,
                null,
                null
        )) {
            if (cursor == null) return new ProviderAlbumPage(new ArrayList<>(), false);
            int idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.ImageColumns.BUCKET_ID);
            int nameColumn = cursor.getColumnIndexOrThrow(
                    MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME
            );
            int modifiedColumn = cursor.getColumnIndexOrThrow(
                    MediaStore.MediaColumns.DATE_MODIFIED
            );
            while (cursor.moveToNext()) {
                if (cursor.isNull(idColumn)) continue;
                String bucketId = cursor.getString(idColumn);
                String displayName = cursor.isNull(nameColumn) ? "" : cursor.getString(nameColumn);
                long modifiedMillis = cursor.isNull(modifiedColumn)
                        ? 0 : cursor.getLong(modifiedColumn) * 1_000L;
                albums.include(bucketId, displayName, modifiedMillis);
            }
        } catch (SecurityException exception) {
            throw error(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "media permission is required to list image albums");
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore album query failed");
        }

        return albums.page(query);
    }

    @Override
    public DmFileProvider.MediaPage listMediaInAlbum(
            String albumToken,
            DmFileProvider.ProviderQuery query
    ) throws DmFileProvider.ProviderCatalogException {
        String bucketId = resolveAlbumBucketId(albumToken);
        if (bucketId == null) {
            throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "image album is not available");
        }
        return listMedia(DmFileProvider.RootKind.MEDIA_IMAGES, query, bucketId);
    }

    private DmFileProvider.MediaPage listMedia(
            DmFileProvider.RootKind rootKind,
            DmFileProvider.ProviderQuery query,
            String bucketId
    ) throws DmFileProvider.ProviderCatalogException {
        Uri uri = collectionUri(rootKind);
        Bundle queryArgs = new Bundle();
        queryArgs.putInt(ContentResolver.QUERY_ARG_LIMIT, query.limit() + 1);
        queryArgs.putInt(ContentResolver.QUERY_ARG_OFFSET, query.offset());
        queryArgs.putStringArray(
                ContentResolver.QUERY_ARG_SORT_COLUMNS,
                new String[] { mediaSortColumn(query.sortField()) }
        );
        queryArgs.putInt(
                ContentResolver.QUERY_ARG_SORT_DIRECTION,
                query.descending()
                        ? ContentResolver.QUERY_SORT_DIRECTION_DESCENDING
                        : ContentResolver.QUERY_SORT_DIRECTION_ASCENDING
        );
        String selection = null;
        ArrayList<String> selectionArgs = new ArrayList<>();
        if (bucketId != null) {
            selection = MediaStore.Images.ImageColumns.BUCKET_ID + " = ?";
            selectionArgs.add(bucketId);
        }
        if (!query.searchQuery().isEmpty()) {
            selection = selection == null
                    ? MediaStore.MediaColumns.DISPLAY_NAME + " LIKE ? ESCAPE '\\'"
                    : selection + " AND " + MediaStore.MediaColumns.DISPLAY_NAME + " LIKE ? ESCAPE '\\'";
            selectionArgs.add("%" + ProviderNameSearch.escapeSqlLike(query.searchQuery()) + "%");
        }
        if (selection != null) {
            queryArgs.putString(
                    ContentResolver.QUERY_ARG_SQL_SELECTION,
                    selection
            );
            queryArgs.putStringArray(
                    ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS,
                    selectionArgs.toArray(new String[0])
            );
        }

        try (Cursor cursor = contentResolver.query(uri, PROJECTION, queryArgs, null)) {
            if (cursor == null) {
                return new DmFileProvider.MediaPage(new ArrayList<>(), false);
            }
            return readCursor(cursor, query.limit());
        } catch (SecurityException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "media permission is required to list " + rootKind
            );
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore query failed");
        }
    }

    private String resolveAlbumBucketId(String token)
            throws DmFileProvider.ProviderCatalogException {
        requireMediaReadPermission("open this image album");
        try (Cursor cursor = contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                new String[] { MediaStore.Images.ImageColumns.BUCKET_ID },
                null,
                null,
                null
        )) {
            if (cursor == null) return null;
            int column = cursor.getColumnIndexOrThrow(MediaStore.Images.ImageColumns.BUCKET_ID);
            while (cursor.moveToNext()) {
                if (cursor.isNull(column)) continue;
                String bucketId = cursor.getString(column);
                if (ProviderMediaAlbums.token(bucketId).equals(token)) return bucketId;
            }
            return null;
        } catch (SecurityException exception) {
            throw error(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "media permission is required to open this image album");
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore album lookup failed");
        }
    }


    @Override
    public DmFileProvider.DownloadChunk readMedia(
            DmFileProvider.RootKind rootKind,
            long mediaId,
            long offsetBytes,
            int chunkSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        try (DmFileProvider.DownloadReader reader = openMedia(
                rootKind,
                mediaId,
                offsetBytes,
                chunkSizeBytes
        )) {
            return reader.readNextChunk();
        }
    }

    @Override
    public DmFileProvider.DownloadReader openMedia(
            DmFileProvider.RootKind rootKind,
            long mediaId,
            long offsetBytes,
            int chunkSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        requireMediaReadPermission("read this item");

        Uri uri = ContentUris.withAppendedId(collectionUri(rootKind), mediaId);
        MediaMetadata metadata = mediaMetadata(uri);
        String providerEtag = "media:" + rootKind + ":" + mediaId + ":"
                + metadata.modifiedUnixMillis + ":" + metadata.sizeBytes;
        DmFileProvider.DownloadReader seekableReader = ProviderDownloadReaders.seekableOrNull(
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
                throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "media entry is not available");
            }
            ProviderDownloadReaders.skipFully(inputStream, offsetBytes);
            return ProviderDownloadReaders.stream(
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
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "media permission is required to read this item"
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            closeQuietly(inputStream);
            throw exception;
        } catch (IOException exception) {
            closeQuietly(inputStream);
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore read failed");
        }
    }

    @Override
    public ProviderThumbnail thumbnail(
            DmFileProvider.RootKind rootKind,
            long mediaId,
            int maxDimensionPx
    ) throws DmFileProvider.ProviderCatalogException {
        requireMediaReadPermission("preview this item");
        Uri uri = ContentUris.withAppendedId(collectionUri(rootKind), mediaId);
        Bitmap bitmap = null;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                bitmap = contentResolver.loadThumbnail(
                        uri,
                        new Size(maxDimensionPx, maxDimensionPx),
                        null
                );
            } else if (rootKind == DmFileProvider.RootKind.MEDIA_IMAGES) {
                bitmap = MediaStore.Images.Thumbnails.getThumbnail(
                        contentResolver,
                        mediaId,
                        MediaStore.Images.Thumbnails.MINI_KIND,
                        null
                );
            } else {
                bitmap = MediaStore.Video.Thumbnails.getThumbnail(
                        contentResolver,
                        mediaId,
                        MediaStore.Video.Thumbnails.MINI_KIND,
                        null
                );
            }
            if (bitmap == null) {
                throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "media thumbnail is not available");
            }
            return encodeThumbnail(bitmap, maxDimensionPx);
        } catch (SecurityException exception) {
            throw error(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "media permission is required to preview this item");
        } catch (IOException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore thumbnail load failed");
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore thumbnail generation failed");
        } finally {
            if (bitmap != null && !bitmap.isRecycled()) bitmap.recycle();
        }
    }

    private static ProviderThumbnail encodeThumbnail(Bitmap source, int maxDimensionPx)
            throws DmFileProvider.ProviderCatalogException {
        Bitmap current = scaleWithin(source, maxDimensionPx);
        try {
            while (true) {
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                if (!current.compress(Bitmap.CompressFormat.JPEG, 82, output)) {
                    throw error(ErrorCode.ERROR_CODE_INTERNAL, "media thumbnail encoding failed");
                }
                byte[] encoded = output.toByteArray();
                if (encoded.length <= MAX_THUMBNAIL_BYTES) {
                    return new ProviderThumbnail(
                            encoded,
                            "image/jpeg",
                            current.getWidth(),
                            current.getHeight()
                    );
                }
                if (current.getWidth() <= 32 && current.getHeight() <= 32) {
                    throw error(ErrorCode.ERROR_CODE_INTERNAL, "media thumbnail exceeds byte limit");
                }
                Bitmap smaller = Bitmap.createScaledBitmap(
                        current,
                        Math.max(32, current.getWidth() / 2),
                        Math.max(32, current.getHeight() / 2),
                        true
                );
                if (current != source && !current.isRecycled()) current.recycle();
                current = smaller;
            }
        } finally {
            if (current != source && !current.isRecycled()) current.recycle();
        }
    }

    private static Bitmap scaleWithin(Bitmap source, int maxDimensionPx) {
        int width = source.getWidth();
        int height = source.getHeight();
        if (width <= maxDimensionPx && height <= maxDimensionPx) return source;
        float scale = Math.min((float) maxDimensionPx / width, (float) maxDimensionPx / height);
        return Bitmap.createScaledBitmap(
                source,
                Math.max(1, Math.round(width * scale)),
                Math.max(1, Math.round(height * scale)),
                true
        );
    }

    @Override
    public DmFileProvider.UploadWriter openUploadMedia(
            DmFileProvider.RootKind rootKind,
            String displayName,
            long offsetBytes,
            long expectedSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        if (offsetBytes != 0) {
            throw error(
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
                throw error(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "MediaStore upload item could not be created"
                );
            }
            outputStream = contentResolver.openOutputStream(mediaUri, "w");
            if (outputStream == null) {
                throw error(
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
            deleteUriQuietly(mediaUri);
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "MediaStore write permission is required to upload this item"
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            closeQuietly(outputStream);
            deleteUriQuietly(mediaUri);
            throw exception;
        } catch (FileNotFoundException exception) {
            closeQuietly(outputStream);
            deleteUriQuietly(mediaUri);
            throw error(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "MediaStore upload destination is not available"
            );
        } catch (RuntimeException exception) {
            closeQuietly(outputStream);
            deleteUriQuietly(mediaUri);
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore upload failed");
        }
    }

    private static Uri collectionUri(DmFileProvider.RootKind rootKind) {
        if (rootKind == DmFileProvider.RootKind.MEDIA_IMAGES) {
            return MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
        }
        return MediaStore.Video.Media.EXTERNAL_CONTENT_URI;
    }

    private static String mediaRelativePath(DmFileProvider.RootKind rootKind) {
        if (rootKind == DmFileProvider.RootKind.MEDIA_IMAGES) {
            return Environment.DIRECTORY_PICTURES + "/DroidMatch";
        }
        return Environment.DIRECTORY_MOVIES + "/DroidMatch";
    }

    private static String mediaUploadMimeType(
            DmFileProvider.RootKind rootKind,
            String displayName
    ) {
        String guessed = ProviderMimeTypes.fromDisplayName(displayName);
        if (rootKind == DmFileProvider.RootKind.MEDIA_IMAGES) {
            return guessed.startsWith("image/") ? guessed : "image/jpeg";
        }
        if (rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS) {
            return guessed.startsWith("video/") ? guessed : "video/mp4";
        }
        return guessed;
    }

    private void requireMediaReadPermission(String operation)
            throws DmFileProvider.ProviderCatalogException {
        if (permissionStateProvider.publicMediaReadState()
                != PermissionStateProvider.PermissionState.GRANTED) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "media permission is required to " + operation
            );
        }
    }

    private static DmFileProvider.MediaPage readCursor(Cursor cursor, int limit) {
        int idColumn = cursor.getColumnIndexOrThrow(BaseColumns._ID);
        int nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME);
        int sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
        int modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED);
        int mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE);
        ArrayList<DmFileProvider.MediaItem> items = new ArrayList<>();
        boolean hasMore = false;

        while (cursor.moveToNext()) {
            if (items.size() >= limit) {
                hasMore = true;
                break;
            }
            long id = cursor.getLong(idColumn);
            String displayName = cursor.isNull(nameColumn)
                    ? Long.toString(id)
                    : cursor.getString(nameColumn);
            long sizeBytes = cursor.isNull(sizeColumn) ? 0 : cursor.getLong(sizeColumn);
            long modifiedMillis = cursor.isNull(modifiedColumn)
                    ? 0
                    : cursor.getLong(modifiedColumn) * 1_000L;
            String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
            items.add(new DmFileProvider.MediaItem(
                    id,
                    displayName,
                    sizeBytes,
                    modifiedMillis,
                    mimeType
            ));
        }
        return new DmFileProvider.MediaPage(items, hasMore);
    }

    private MediaMetadata mediaMetadata(Uri uri)
            throws DmFileProvider.ProviderCatalogException {
        try (Cursor cursor = contentResolver.query(uri, PROJECTION, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) {
                throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "media entry is not available");
            }
            int sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
            int modifiedColumn = cursor.getColumnIndexOrThrow(
                    MediaStore.MediaColumns.DATE_MODIFIED
            );
            long sizeBytes = cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
            long modifiedMillis = cursor.isNull(modifiedColumn)
                    ? 0
                    : cursor.getLong(modifiedColumn) * 1_000L;
            return new MediaMetadata(sizeBytes, modifiedMillis);
        } catch (SecurityException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "media permission is required to read this item"
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "MediaStore metadata query failed");
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

    private static void closeQuietly(Closeable closeable) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (IOException ignored) {
        }
    }

    private void deleteUriQuietly(Uri uri) {
        if (uri == null) {
            return;
        }
        try {
            contentResolver.delete(uri, null, null);
        } catch (RuntimeException ignored) {
        }
    }

    private static DmFileProvider.ProviderCatalogException error(
            ErrorCode code,
            String message
    ) {
        return new DmFileProvider.ProviderCatalogException(code, message);
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
