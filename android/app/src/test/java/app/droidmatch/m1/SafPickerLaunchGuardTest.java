package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.content.ActivityNotFoundException;

import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

public final class SafPickerLaunchGuardTest {
    @Test
    public void successfulLaunchRunsExactlyOnce() {
        AtomicInteger calls = new AtomicInteger();

        assertTrue(SafPickerLaunchGuard.launch(calls::incrementAndGet));
        assertEquals(1, calls.get());
    }

    @Test
    public void knownPlatformAvailabilityFailuresStayInsideTheUiBoundary() {
        assertFalse(SafPickerLaunchGuard.launch(() -> {
            throw new ActivityNotFoundException("private OEM detail");
        }));
        assertFalse(SafPickerLaunchGuard.launch(() -> {
            throw new SecurityException("private policy detail");
        }));
    }

    @Test
    public void unrelatedRuntimeFailureStillPropagates() {
        IllegalStateException expected = new IllegalStateException("programming failure");
        try {
            SafPickerLaunchGuard.launch(() -> {
                throw expected;
            });
            fail("Expected unrelated runtime failure");
        } catch (IllegalStateException actual) {
            assertSame(expected, actual);
        }
    }
}
