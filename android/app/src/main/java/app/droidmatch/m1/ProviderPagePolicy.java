package app.droidmatch.m1;

import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

/**
 * Pure pagination policy shared by every DroidMatch provider catalog.
 *
 * Tokens bind the offset to the complete query shape, so a client cannot reuse
 * one provider's cursor with another path, page size, or sort order. Keeping
 * this policy free of Android resources makes the stateful provider facade own
 * only catalog dispatch and its bounded SAF identity cache.
 */
final class ProviderPagePolicy {
    private static final int DEFAULT_PAGE_SIZE = 200;
    private static final int MAX_PAGE_SIZE = 1_000;
    private static final String TOKEN_PREFIX = "v1:";

    private ProviderPagePolicy() {
    }

    static PageRequest parse(ListDirRequest request) {
        long requestedSize = Integer.toUnsignedLong(request.getPageSize());
        int limit = requestedSize == 0
                ? DEFAULT_PAGE_SIZE
                : (int) Math.min(requestedSize, MAX_PAGE_SIZE);
        int offset = 0;
        if (!request.getPageToken().isEmpty()) {
            offset = tokenOffset(request);
            if (offset < 0) {
                return PageRequest.error(ListDirResponse.newBuilder()
                        .setError(DroidMatchError.newBuilder()
                                .setCode(ErrorCode.ERROR_CODE_INVALID_ARGUMENT)
                                .setMessage("invalid page_token")
                                .build())
                        .build());
            }
        }
        return PageRequest.page(offset, limit);
    }

    static String nextToken(ListDirRequest request, PageRequest pageRequest) {
        int nextOffset = pageRequest.offset + pageRequest.limit;
        return TOKEN_PREFIX + nextOffset + ":" + signature(request, nextOffset);
    }

    static SortField effectiveSortField(SortField sortField) {
        return sortField == SortField.SORT_FIELD_UNSPECIFIED
                ? SortField.SORT_FIELD_MODIFIED_TIME
                : sortField;
    }

    static boolean effectiveDescending(SortField sortField, boolean requestedDescending) {
        return sortField == SortField.SORT_FIELD_UNSPECIFIED || requestedDescending;
    }

    private static int tokenOffset(ListDirRequest request) {
        String token = request.getPageToken();
        if (!token.startsWith(TOKEN_PREFIX)) {
            return -1;
        }
        int separator = token.indexOf(':', TOKEN_PREFIX.length());
        if (separator < 0) {
            return -1;
        }
        int offset;
        try {
            offset = Integer.parseInt(token.substring(TOKEN_PREFIX.length(), separator));
        } catch (NumberFormatException exception) {
            return -1;
        }
        if (offset < 0) {
            return -1;
        }
        String tokenSignature = token.substring(separator + 1);
        return signature(request, offset).equals(tokenSignature) ? offset : -1;
    }

    private static String signature(ListDirRequest request, int offset) {
        return ProviderOpaqueIds.stable(
                "page-token\n"
                        + request.getPath() + "\n"
                        + request.getPageSize() + "\n"
                        + request.getSortFieldValue() + "\n"
                        + request.getDescending() + "\n"
                        + offset,
                8
        );
    }

    static final class PageRequest {
        final int offset;
        final int limit;
        final ListDirResponse error;

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
}
