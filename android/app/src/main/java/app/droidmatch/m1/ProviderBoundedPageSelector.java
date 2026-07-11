package app.droidmatch.m1;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.PriorityQueue;

/**
 * Streaming top-prefix selection for providers that cannot push sort/offset to storage.
 *
 * <p>The heap retains at most {@code offset + limit} values under the complete
 * stable comparator. Providers still scan every matching row, but Java metadata
 * memory no longer grows with the full result set.</p>
 */
final class ProviderBoundedPageSelector<T> {
    private final Comparator<T> comparator;
    private final int offset;
    private final int limit;
    private final int horizon;
    private final PriorityQueue<T> leadingValues;
    private int matchingCount;

    ProviderBoundedPageSelector(Comparator<T> comparator, int offset, int limit) {
        this.comparator = comparator;
        this.offset = Math.max(0, offset);
        this.limit = Math.max(1, limit);
        this.horizon = saturatedAdd(this.offset, this.limit);
        this.leadingValues = new PriorityQueue<>(
                Math.min(horizon, 1_024), comparator.reversed()
        );
    }

    void accept(T value) {
        matchingCount++;
        if (leadingValues.size() < horizon) {
            leadingValues.add(value);
        } else if (comparator.compare(value, leadingValues.peek()) < 0) {
            leadingValues.remove();
            leadingValues.add(value);
        }
    }

    Page<T> page() {
        ArrayList<T> sorted = new ArrayList<>(leadingValues);
        sorted.sort(comparator);
        if (offset >= sorted.size()) {
            return new Page<>(new ArrayList<>(), false);
        }
        int endExclusive = Math.min(sorted.size(), saturatedAdd(offset, limit));
        return new Page<>(
                new ArrayList<>(sorted.subList(offset, endExclusive)),
                endExclusive < matchingCount
        );
    }

    private static int saturatedAdd(int first, int second) {
        return first > Integer.MAX_VALUE - second ? Integer.MAX_VALUE : first + second;
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
