package app.droidmatch.m1;

import android.database.Cursor;
import android.provider.BaseColumns;
import android.provider.MediaStore;

import java.util.ArrayList;

/**
 * Stateless decoding of already-open MediaStore cursors.
 *
 * <p>The caller retains resolver, URI, permission, cursor lifetime, cache,
 * and error-mapping ownership. This boundary only scans platform rows and
 * converts their documented null/default units into provider values.</p>
 *
 * <p>中文：调用方继续持有 resolver、URI、权限、cursor 生命周期、缓存与错误映射；
 * 本边界只扫描平台行，并把已约定的 null/default 与时间单位转换为 provider 值。</p>
 */
final class MediaStoreCursorReader {
    private MediaStoreCursorReader() {}

    static String[] mediaProjection() {
        return new String[] {
                BaseColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.MIME_TYPE
        };
    }

    static String[] videoProjection() {
        return new String[] {
                BaseColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.Video.VideoColumns.DURATION
        };
    }

    static String[] listingProjection(DmFileProvider.RootKind rootKind) {
        return rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS
                ? videoProjection()
                : mediaProjection();
    }

    static String[] albumProjection() {
        return new String[] {
                MediaStore.Images.ImageColumns.BUCKET_ID,
                MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_MODIFIED
        };
    }

    static String[] bucketIdProjection() {
        return new String[] { MediaStore.Images.ImageColumns.BUCKET_ID };
    }

    static String[] mediaIdProjection() {
        return new String[] { BaseColumns._ID };
    }

    static DmFileProvider.MediaPage readPage(Cursor cursor, int limit) {
        int idColumn = cursor.getColumnIndexOrThrow(BaseColumns._ID);
        int nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME);
        int sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
        int modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED);
        int mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE);
        int durationColumn = cursor.getColumnIndex(MediaStore.Video.VideoColumns.DURATION);
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
            long durationMillis = durationColumn < 0 || cursor.isNull(durationColumn)
                    ? 0
                    : Math.max(0, cursor.getLong(durationColumn));
            items.add(new DmFileProvider.MediaItem(
                    id,
                    displayName,
                    sizeBytes,
                    modifiedMillis,
                    mimeType,
                    durationMillis
            ));
        }
        return new DmFileProvider.MediaPage(items, hasMore);
    }

    static void readAlbums(
            Cursor cursor,
            ProviderMediaAlbums albums,
            BucketObserver observer
    ) {
        int idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.ImageColumns.BUCKET_ID);
        int nameColumn = cursor.getColumnIndexOrThrow(
                MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME
        );
        int modifiedColumn = cursor.getColumnIndexOrThrow(
                MediaStore.MediaColumns.DATE_MODIFIED
        );
        while (cursor.moveToNext()) {
            if (cursor.isNull(idColumn)) {
                continue;
            }
            String bucketId = cursor.getString(idColumn);
            String displayName = cursor.isNull(nameColumn) ? "" : cursor.getString(nameColumn);
            long modifiedMillis = cursor.isNull(modifiedColumn)
                    ? 0
                    : cursor.getLong(modifiedColumn) * 1_000L;
            if (albums.include(bucketId, displayName, modifiedMillis)) {
                observer.observe(bucketId);
            }
        }
    }

    static String findBucketId(Cursor cursor, String token, BucketObserver observer) {
        int column = cursor.getColumnIndexOrThrow(MediaStore.Images.ImageColumns.BUCKET_ID);
        while (cursor.moveToNext()) {
            if (cursor.isNull(column)) {
                continue;
            }
            String bucketId = cursor.getString(column);
            observer.observe(bucketId);
            if (ProviderMediaAlbums.token(bucketId).equals(token)) {
                return bucketId;
            }
        }
        return null;
    }

    static Long firstMediaId(Cursor cursor) {
        if (!cursor.moveToFirst()) {
            return null;
        }
        return cursor.getLong(cursor.getColumnIndexOrThrow(BaseColumns._ID));
    }

    static Metadata firstMetadata(Cursor cursor) {
        if (!cursor.moveToFirst()) {
            return null;
        }
        int sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
        int modifiedColumn = cursor.getColumnIndexOrThrow(
                MediaStore.MediaColumns.DATE_MODIFIED
        );
        long sizeBytes = cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
        long modifiedMillis = cursor.isNull(modifiedColumn)
                ? 0
                : cursor.getLong(modifiedColumn) * 1_000L;
        return new Metadata(sizeBytes, modifiedMillis);
    }

    interface BucketObserver {
        void observe(String bucketId);
    }

    static final class Metadata {
        final long sizeBytes;
        final long modifiedUnixMillis;

        private Metadata(long sizeBytes, long modifiedUnixMillis) {
            this.sizeBytes = sizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
        }
    }
}
