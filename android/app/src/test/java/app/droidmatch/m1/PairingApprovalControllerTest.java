package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class PairingApprovalControllerTest {
    @Test
    public void windowIsClosedByDefaultSingleUseAndRequiresMatchingAttempt() throws Exception {
        FakeClock clock = new FakeClock(1_000);
        PairingApprovalController controller = new PairingApprovalController(clock);
        byte[] pairingId = sequentialBytes(0xa0, 16);

        assertFalse(controller.beginAttempt(pairingId, "DroidMatch Mac", "012345"));
        assertTrue(controller.openWindow(60_000));
        assertTrue(controller.beginAttempt(pairingId, "DroidMatch Mac", "012345"));
        assertFalse(controller.beginAttempt(sequentialBytes(0xb0, 16), "Other Mac", "999999"));
        controller.finishAttempt(sequentialBytes(0xb0, 16));
        assertTrue(controller.snapshot().windowOpen());

        PairingApprovalController.Snapshot snapshot = controller.snapshot();
        assertTrue(snapshot.windowOpen());
        assertTrue(snapshot.hasPendingAttempt());
        assertArrayEquals(pairingId, snapshot.pairingId());
        assertEquals("DroidMatch Mac", snapshot.clientDisplayName());
        assertEquals("012345", snapshot.shortAuthenticationString());
        assertEquals(PairingApprovalController.Decision.PENDING, snapshot.decision());

        assertFalse(controller.approve(sequentialBytes(0xb0, 16)));
        assertTrue(controller.approve(pairingId));
        assertEquals(
                PairingApprovalController.Decision.APPROVED,
                controller.awaitDecision(pairingId, 1_000)
        );
        controller.finishAttempt(pairingId);
        assertFalse(controller.snapshot().windowOpen());
        assertFalse(controller.snapshot().hasPendingAttempt());
    }

    @Test
    public void expiryAndManualCloseNeverImplicitlyApprove() throws Exception {
        FakeClock clock = new FakeClock(10_000);
        PairingApprovalController controller = new PairingApprovalController(clock);
        byte[] pairingId = sequentialBytes(0x10, 16);
        assertTrue(controller.openWindow(1_000));
        assertTrue(controller.beginAttempt(pairingId, "Mac", "123456"));
        clock.advance(1_001);
        assertEquals(
                PairingApprovalController.Decision.EXPIRED,
                controller.awaitDecision(pairingId, 100)
        );
        assertFalse(controller.snapshot().windowOpen());

        controller.finishAttempt(pairingId);
        assertTrue(controller.openWindow(1_000));
        assertTrue(controller.beginAttempt(pairingId, "Mac", "123456"));
        controller.closeWindow();
        assertEquals(
                PairingApprovalController.Decision.REJECTED,
                controller.awaitDecision(pairingId, 100)
        );
    }

    @Test
    public void rejectsUnboundedWindowAndMalformedPresentation() {
        PairingApprovalController controller = new PairingApprovalController(() -> 1L);
        assertFalse(controller.openWindow(0));
        assertFalse(controller.openWindow(PairingApprovalController.MAXIMUM_WINDOW_MILLIS + 1));
        assertTrue(controller.openWindow(1_000));
        try {
            controller.beginAttempt(new byte[16], "Mac", "12AB56");
            throw new AssertionError("expected invalid SAS rejection");
        } catch (IllegalArgumentException expected) {
            // Expected: UI codes are always exactly six ASCII digits.
        }
    }

    private static byte[] sequentialBytes(int start, int count) {
        byte[] result = new byte[count];
        for (int index = 0; index < count; index += 1) {
            result[index] = (byte) (start + index);
        }
        return result;
    }

    private static final class FakeClock implements PairingApprovalController.Clock {
        private long nowMillis;

        private FakeClock(long nowMillis) {
            this.nowMillis = nowMillis;
        }

        @Override
        public long nowMillis() {
            return nowMillis;
        }

        private void advance(long millis) {
            nowMillis += millis;
        }
    }
}
