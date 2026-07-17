package app.droidmatch.m1;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.PriorityQueue;

/**
 * Streaming top-prefix selection for providers that cannot push sort/offset to storage.
 *
 * <p>The heap retains at most one admitted {@code offset + limit} prefix under
 * the complete stable comparator. Provider callers account for both matching
 * and filtered rows, so Java metadata memory and one request's scan work remain
 * within separate M1 horizons.</p>
 */
final class ProviderBoundedPageSelector<T> {
    private final Comparator<T> comparator;
    private final int offset;
    private final int limit;
    private final int horizon;
    private final PriorityQueue<T> leadingValues;
    private long inspectedCount;
    private long matchingCount;

    ProviderBoundedPageSelector(Comparator<T> comparator, int offset, int limit) {
        if (!ProviderPagePolicy.isAdmissibleWindow(offset, limit)) {
            throw new IllegalArgumentException("page window exceeds M1 exact-query horizon");
        }
        this.comparator = comparator;
        this.offset = offset;
        this.limit = limit;
        this.horizon = offset + limit;
        this.leadingValues = new PriorityQueue<>(
                Math.min(horizon, 1_024), comparator.reversed()
        );
    }

    void accept(T value) {
        inspectCandidate();
        matchingCount++;
        if (leadingValues.size() < horizon) {
            leadingValues.add(value);
        } else if (comparator.compare(value, leadingValues.peek()) < 0) {
            leadingValues.remove();
            leadingValues.add(value);
        }
    }

    void skipCandidate() {
        inspectCandidate();
    }

    private void inspectCandidate() {
        if (inspectedCount >= ProviderPagePolicy.M1_EXACT_QUERY_SCAN_HORIZON) {
            throw new ScanLimitExceededException();
        }
        inspectedCount++;
    }

    Page<T> page() {
        ArrayList<T> sorted = new ArrayList<>(leadingValues);
        sorted.sort(comparator);
        if (offset >= sorted.size()) {
            return new Page<>(new ArrayList<>(), false);
        }
        int endExclusive = Math.min(sorted.size(), horizon);
        return new Page<>(
                new ArrayList<>(sorted.subList(offset, endExclusive)),
                endExclusive < matchingCount
        );
    }

    int retainedValueCount() {
        return leadingValues.size();
    }

    static final class ScanLimitExceededException extends RuntimeException {
        private static final long serialVersionUID = 1L;
    }

    static final class Page<T> {
        final List<T> items;
        final boolean hasMore;

        Page(List<T> items, boolean hasMore) {
            this.items = items;
            this.hasMore = hasMore;
        }
    }
}
