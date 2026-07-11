package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

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
}
