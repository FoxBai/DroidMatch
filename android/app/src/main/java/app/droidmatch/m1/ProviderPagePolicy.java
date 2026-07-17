package app.droidmatch.m1;

import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

/**
 * Pure pagination policy shared by every DroidMatch provider catalog.
 *
 * Tokens bind the offset to the complete query shape and, when supplied, a
 * provider snapshot identity. A client therefore cannot reuse a cursor with
 * another path, page size, sort order, permission/root snapshot, or search.
 * Keeping this policy free of Android resources makes the provider own how a
 * live snapshot is reduced to its privacy-safe identity.
 */
final class ProviderPagePolicy {
    private static final int DEFAULT_PAGE_SIZE = 200;
    private static final int MAX_PAGE_SIZE = 1_000;
    /** M1 retains at most ten maximum-size pages for one exact sorted query. */
    static final int M1_EXACT_QUERY_TOTAL_HORIZON = 10_000;
    /** Bounds provider rows inspected even when a search rejects every row. */
    static final int M1_EXACT_QUERY_SCAN_HORIZON = 25_000;
    private static final String TOKEN_PREFIX = "v1:";

    private ProviderPagePolicy() {
    }

    static PageRequest parse(ListDirRequest request) {
        return parse(request, "");
    }

    static PageRequest parse(ListDirRequest request, String snapshotIdentity) {
        long requestedSize = Integer.toUnsignedLong(request.getPageSize());
        int limit = requestedSize == 0
                ? DEFAULT_PAGE_SIZE
                : (int) Math.min(requestedSize, MAX_PAGE_SIZE);
        int offset = 0;
        if (!request.getPageToken().isEmpty()) {
            offset = tokenOffset(request, limit, snapshotIdentity);
            if (offset < 0) {
                return invalidPageToken();
            }
        }
        if (!isAdmissibleWindow(offset, limit)) return invalidPageToken();
        return PageRequest.page(offset, limit);
    }

    static String nextToken(ListDirRequest request, PageRequest pageRequest) {
        return nextToken(request, pageRequest, "");
    }

    static String nextToken(
            ListDirRequest request,
            PageRequest pageRequest,
            String snapshotIdentity
    ) {
        if (!isAdmissibleWindow(pageRequest.offset, pageRequest.limit)) return "";
        int nextOffset = pageRequest.offset + pageRequest.limit;
        if (!isAdmissibleWindow(nextOffset, pageRequest.limit)) return "";
        return TOKEN_PREFIX + nextOffset + ":"
                + signature(request, nextOffset, snapshotIdentity);
    }

    /**
     * Finishes one provider page without silently truncating an exact query at
     * the M1 result horizon. A provider that proves more rows exist must either
     * return a usable continuation token or an explicit bounded-capability
     * error; an empty token always means the listing is complete.
     */
    static ListDirResponse finishResponse(
            ListDirResponse.Builder response,
            ListDirRequest request,
            PageRequest pageRequest,
            boolean hasMore
    ) {
        return finishResponse(response, request, pageRequest, hasMore, "");
    }

    static ListDirResponse finishResponse(
            ListDirResponse.Builder response,
            ListDirRequest request,
            PageRequest pageRequest,
            boolean hasMore,
            String snapshotIdentity
    ) {
        if (!hasMore) return response.build();
        String token = nextToken(request, pageRequest, snapshotIdentity);
        if (!token.isEmpty()) return response.setNextPageToken(token).build();
        return ListDirResponse.newBuilder()
                .setError(DroidMatchError.newBuilder()
                        .setCode(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY)
                        .setMessage("directory query exceeds the M1 result horizon")
                        .build())
                .build();
    }

    static boolean isAdmissibleWindow(int offset, int limit) {
        if (offset < 0 || limit <= 0 || limit > MAX_PAGE_SIZE) return false;
        if (offset > Integer.MAX_VALUE - limit) return false;
        return offset + limit <= M1_EXACT_QUERY_TOTAL_HORIZON;
    }

    static SortField effectiveSortField(SortField sortField) {
        return sortField == SortField.SORT_FIELD_UNSPECIFIED
                ? SortField.SORT_FIELD_MODIFIED_TIME
                : sortField;
    }

    static boolean effectiveDescending(SortField sortField, boolean requestedDescending) {
        return sortField == SortField.SORT_FIELD_UNSPECIFIED || requestedDescending;
    }

    private static int tokenOffset(
            ListDirRequest request,
            int limit,
            String snapshotIdentity
    ) {
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
        if (!isAdmissibleWindow(offset, limit)) {
            return -1;
        }
        String tokenSignature = token.substring(separator + 1);
        return signature(request, offset, snapshotIdentity).equals(tokenSignature)
                ? offset
                : -1;
    }

    private static PageRequest invalidPageToken() {
        return PageRequest.error(ListDirResponse.newBuilder()
                .setError(DroidMatchError.newBuilder()
                        .setCode(ErrorCode.ERROR_CODE_INVALID_ARGUMENT)
                        .setMessage("invalid page_token")
                        .build())
                .build());
    }

    private static String signature(
            ListDirRequest request,
            int offset,
            String snapshotIdentity
    ) {
        String material = "page-token\n"
                + request.getPath() + "\n"
                + request.getPageSize() + "\n"
                + request.getSortFieldValue() + "\n"
                + request.getDescending() + "\n"
                + request.getSearchQuery() + "\n"
                + offset;
        if (!snapshotIdentity.isEmpty()) {
            material += "\nsnapshot:"
                    + snapshotIdentity.length()
                    + ":"
                    + snapshotIdentity;
        }
        return ProviderOpaqueIds.stable(material, 8);
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
