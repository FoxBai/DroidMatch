package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import android.content.ContentResolver;
import android.provider.BaseColumns;
import android.provider.MediaStore;

import app.droidmatch.proto.v1.SortField;

import java.util.HashMap;
import java.util.Map;

import org.junit.Test;

public final class AndroidMediaCatalogPolicyTest {
    @Test
    public void everyOffsetPaginationOrderHasAStableIdTieBreaker() {
        assertArrayEquals(
                new String[] {MediaStore.MediaColumns.DISPLAY_NAME, BaseColumns._ID},
                AndroidMediaCatalog.mediaSortColumns(SortField.SORT_FIELD_NAME)
        );
        assertArrayEquals(
                new String[] {MediaStore.MediaColumns.SIZE, BaseColumns._ID},
                AndroidMediaCatalog.mediaSortColumns(SortField.SORT_FIELD_SIZE)
        );
        assertArrayEquals(
                new String[] {MediaStore.MediaColumns.DATE_MODIFIED, BaseColumns._ID},
                AndroidMediaCatalog.mediaSortColumns(SortField.SORT_FIELD_MODIFIED_TIME)
        );
        assertArrayEquals(
                new String[] {BaseColumns._ID},
                AndroidMediaCatalog.mediaSortColumns(SortField.SORT_FIELD_KIND)
        );
    }

    @Test
    public void listingQueryWriterCarriesStableOrderIntoContentResolverArguments() {
        CapturingQueryArgumentSink queryArgs = new CapturingQueryArgumentSink();

        AndroidMediaCatalog.writeMediaPagingQueryArguments(
                new DmFileProvider.ProviderQuery(
                        40,
                        20,
                        SortField.SORT_FIELD_SIZE,
                        true,
                        ""
                ),
                queryArgs
        );

        assertEquals(
                Integer.valueOf(21),
                queryArgs.integers.get(ContentResolver.QUERY_ARG_LIMIT)
        );
        assertEquals(
                Integer.valueOf(40),
                queryArgs.integers.get(ContentResolver.QUERY_ARG_OFFSET)
        );
        assertEquals(
                Integer.valueOf(ContentResolver.QUERY_SORT_DIRECTION_DESCENDING),
                queryArgs.integers.get(ContentResolver.QUERY_ARG_SORT_DIRECTION)
        );
        assertArrayEquals(
                new String[] {MediaStore.MediaColumns.SIZE, BaseColumns._ID},
                queryArgs.stringArrays.get(ContentResolver.QUERY_ARG_SORT_COLUMNS)
        );
    }

    private static final class CapturingQueryArgumentSink
            implements AndroidMediaCatalog.QueryArgumentSink {
        private final Map<String, Integer> integers = new HashMap<>();
        private final Map<String, String[]> stringArrays = new HashMap<>();

        @Override
        public void putInt(String key, int value) {
            integers.put(key, value);
        }

        @Override
        public void putStringArray(String key, String[] value) {
            stringArrays.put(key, value);
        }
    }
}
