package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public final class ProductReadinessTest {
    @Test
    public void readinessGuidesEveryProductOnboardingBoundary() {
        assertEquals(
                ProductReadiness.State.TURN_ON_USB,
                ProductReadiness.evaluate(
                        ConnectionStatusController.State.STOPPED,
                        false,
                        true,
                        0
                )
        );
        assertEquals(
                ProductReadiness.State.STARTING,
                ProductReadiness.evaluate(
                        ConnectionStatusController.State.STARTING,
                        false,
                        true,
                        0
                )
        );
        assertEquals(
                ProductReadiness.State.PAIR_MAC,
                ProductReadiness.evaluate(
                        ConnectionStatusController.State.LISTENING,
                        true,
                        true,
                        0
                )
        );
        assertEquals(
                ProductReadiness.State.READY,
                ProductReadiness.evaluate(
                        ConnectionStatusController.State.LISTENING,
                        true,
                        true,
                        2
                )
        );
        assertEquals(
                ProductReadiness.State.UNAVAILABLE,
                ProductReadiness.evaluate(
                        ConnectionStatusController.State.LISTENING,
                        true,
                        false,
                        0
                )
        );
        assertEquals(
                ProductReadiness.State.UNAVAILABLE,
                ProductReadiness.evaluate(
                        ConnectionStatusController.State.FAILED,
                        false,
                        true,
                        0
                )
        );

        assertEquals(
                ProductReadiness.CountsState.AVAILABLE,
                ProductReadiness.countsState(true, true)
        );
        assertEquals(
                ProductReadiness.CountsState.STORAGE_UNAVAILABLE,
                ProductReadiness.countsState(true, false)
        );
        assertEquals(
                ProductReadiness.CountsState.PAIRED_DEVICES_UNAVAILABLE,
                ProductReadiness.countsState(false, true)
        );
        assertEquals(
                ProductReadiness.CountsState.BOTH_UNAVAILABLE,
                ProductReadiness.countsState(false, false)
        );
    }
}
