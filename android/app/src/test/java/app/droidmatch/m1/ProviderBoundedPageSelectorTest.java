package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.Arrays;
import java.util.Comparator;

import org.junit.Test;

public final class ProviderBoundedPageSelectorTest {
    @Test
    public void selectsDeepPageFromReverseInputWithBoundedPrefix() {
        ProviderBoundedPageSelector<Integer> selector = new ProviderBoundedPageSelector<>(
                Comparator.<Integer>naturalOrder(), 1_000, 5
        );
        for (int value = 1_999; value >= 0; value--) {
            selector.accept(value);
        }

        ProviderBoundedPageSelector.Page<Integer> page = selector.page();

        assertEquals(Arrays.asList(1_000, 1_001, 1_002, 1_003, 1_004), page.items);
        assertTrue(page.hasMore);
    }

    @Test
    public void exactQueryHorizonBoundsRetainedPrefixGrowth() {
        ProviderBoundedPageSelector<Integer> selector = new ProviderBoundedPageSelector<>(
                Comparator.<Integer>naturalOrder(), 9_000, 1_000
        );
        for (int value = 24_999; value >= 0; value--) {
            selector.accept(value);
        }

        ProviderBoundedPageSelector.Page<Integer> page = selector.page();

        assertEquals(ProviderPagePolicy.M1_EXACT_QUERY_TOTAL_HORIZON, selector.retainedValueCount());
        assertEquals(1_000, page.items.size());
        assertEquals(Integer.valueOf(9_000), page.items.get(0));
        assertEquals(Integer.valueOf(9_999), page.items.get(999));
        assertTrue(page.hasMore);
    }

    @Test
    public void rejectsNegativeOverflowingAndOverHorizonWindows() {
        assertRejected(-1, 1);
        assertRejected(0, 0);
        assertRejected(0, -1);
        assertRejected(0, 1_001);
        assertRejected(Integer.MAX_VALUE, 1);
        assertRejected(ProviderPagePolicy.M1_EXACT_QUERY_TOTAL_HORIZON - 1, 2);
    }

    @Test
    public void scanHorizonCountsMatchingAndFilteredRows() {
        ProviderBoundedPageSelector<Integer> selector = new ProviderBoundedPageSelector<>(
                Comparator.<Integer>naturalOrder(), 0, 1
        );
        for (int index = 0;
                index < ProviderPagePolicy.M1_EXACT_QUERY_SCAN_HORIZON;
                index++) {
            if ((index & 1) == 0) {
                selector.accept(index);
            } else {
                selector.skipCandidate();
            }
        }

        try {
            selector.skipCandidate();
            fail("expected provider scan horizon to reject another row");
        } catch (ProviderBoundedPageSelector.ScanLimitExceededException expected) {
            assertEquals(1, selector.retainedValueCount());
        }
    }

    private static void assertRejected(int offset, int limit) {
        try {
            new ProviderBoundedPageSelector<Integer>(
                    Comparator.naturalOrder(), offset, limit
            );
            fail("expected page window to be rejected");
        } catch (IllegalArgumentException exception) {
            assertEquals("page window exceeds M1 exact-query horizon", exception.getMessage());
        }
    }
}
