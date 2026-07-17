package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
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
        ProviderPagePolicy.PageRequest changedSearch = ProviderPagePolicy.parse(
                first.toBuilder().setSearchQuery("photo").setPageToken(token).build()
        );

        assertEquals(20, secondPage.offset);
        assertEquals(20, secondPage.limit);
        assertNull(secondPage.error);
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, changedPath.error.getError().getCode());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, changedSearch.error.getError().getCode());
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

    @Test
    public void forgedValidHighOffsetFailsWithoutLeakingQuery() {
        String privateQuery = "private-name-filter";
        ListDirRequest request = ListDirRequest.newBuilder()
                .setPath(DmFileProvider.APP_SANDBOX_PATH)
                .setPageSize(1_000)
                .setSortField(SortField.SORT_FIELD_NAME)
                .setSearchQuery(privateQuery)
                .build();
        int highOffset = ProviderPagePolicy.M1_EXACT_QUERY_TOTAL_HORIZON - 999;

        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(
                request.toBuilder()
                        .setPageToken(computedToken(request, highOffset))
                        .build()
        );

        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, page.error.getError().getCode());
        assertEquals("invalid page_token", page.error.getError().getMessage());
        assertFalse(page.error.getError().getMessage().contains(privateQuery));
        assertFalse(page.error.getError().getMessage().contains(request.getPath()));
    }

    @Test
    public void exactQueryHorizonBoundaryFailsClosedInsteadOfSilentlyTruncating() {
        ListDirRequest request = ListDirRequest.newBuilder()
                .setPath(DmFileProvider.APP_SANDBOX_PATH)
                .setPageSize(1_000)
                .setSortField(SortField.SORT_FIELD_NAME)
                .build();
        int boundaryOffset = ProviderPagePolicy.M1_EXACT_QUERY_TOTAL_HORIZON - 1_000;
        ListDirRequest boundaryRequest = request.toBuilder()
                .setPageToken(computedToken(request, boundaryOffset))
                .build();

        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(boundaryRequest);

        assertNull(page.error);
        assertEquals(boundaryOffset, page.offset);
        assertEquals(1_000, page.limit);
        assertEquals("", ProviderPagePolicy.nextToken(boundaryRequest, page));

        ListDirResponse response = ProviderPagePolicy.finishResponse(
                ListDirResponse.newBuilder().addEntries(FileEntry.newBuilder()
                        .setPath("dm://redacted")
                        .setName("redacted")
                        .setKind(FileKind.FILE_KIND_FILE)
                        .build()),
                boundaryRequest,
                page,
                true
        );
        assertEquals(0, response.getEntriesCount());
        assertEquals(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                response.getError().getCode()
        );
        assertEquals(
                "directory query exceeds the M1 result horizon",
                response.getError().getMessage()
        );
    }

    @Test
    public void negativeAndOverflowingComputedOffsetsFailClosed() {
        ListDirRequest request = ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageSize(1_000)
                .build();

        ProviderPagePolicy.PageRequest negative = ProviderPagePolicy.parse(
                request.toBuilder().setPageToken(computedToken(request, -1)).build()
        );
        ProviderPagePolicy.PageRequest overflowing = ProviderPagePolicy.parse(
                request.toBuilder()
                        .setPageToken(computedToken(request, Integer.MAX_VALUE))
                        .build()
        );

        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, negative.error.getError().getCode());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, overflowing.error.getError().getCode());
        assertEquals("invalid page_token", negative.error.getError().getMessage());
        assertEquals("invalid page_token", overflowing.error.getError().getMessage());
    }

    private static String computedToken(ListDirRequest request, int offset) {
        return "v1:" + offset + ":" + ProviderOpaqueIds.stable(
                "page-token\n"
                        + request.getPath() + "\n"
                        + request.getPageSize() + "\n"
                        + request.getSortFieldValue() + "\n"
                        + request.getDescending() + "\n"
                        + request.getSearchQuery() + "\n"
                        + offset,
                8
        );
    }
}
