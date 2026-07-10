package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.SortField;

import org.junit.Test;

public final class ProviderPagePolicyTest {
    @Test
    public void defaultPolicyUsesBoundedPageAndModifiedDescendingSort() {
        ListDirRequest request = ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageSize(-1)
                .build();

        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(request);

        assertEquals(0, page.offset);
        assertEquals(1_000, page.limit);
        assertNull(page.error);
        assertEquals(
                SortField.SORT_FIELD_MODIFIED_TIME,
                ProviderPagePolicy.effectiveSortField(request.getSortField())
        );
        assertTrue(ProviderPagePolicy.effectiveDescending(
                request.getSortField(),
                request.getDescending()
        ));
    }

    @Test
    public void tokenRoundTripsOnlyWithIdenticalQueryShape() {
        ListDirRequest first = ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageSize(20)
                .setSortField(SortField.SORT_FIELD_NAME)
                .build();
        ProviderPagePolicy.PageRequest firstPage = ProviderPagePolicy.parse(first);
        String token = ProviderPagePolicy.nextToken(first, firstPage);

        ProviderPagePolicy.PageRequest secondPage = ProviderPagePolicy.parse(
                first.toBuilder().setPageToken(token).build()
        );
        ProviderPagePolicy.PageRequest changedPath = ProviderPagePolicy.parse(
                first.toBuilder()
                        .setPath(DmFileProvider.MEDIA_VIDEOS_PATH)
                        .setPageToken(token)
                        .build()
        );

        assertEquals(20, secondPage.offset);
        assertEquals(20, secondPage.limit);
        assertNull(secondPage.error);
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, changedPath.error.getError().getCode());
    }

    @Test
    public void malformedAndNegativeTokensFailClosed() {
        ListDirRequest.Builder request = ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH);

        ProviderPagePolicy.PageRequest malformed = ProviderPagePolicy.parse(
                request.setPageToken("v1:not-a-number:00").build()
        );
        ProviderPagePolicy.PageRequest negative = ProviderPagePolicy.parse(
                request.setPageToken("v1:-1:00").build()
        );

        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, malformed.error.getError().getCode());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, negative.error.getError().getCode());
    }
}
