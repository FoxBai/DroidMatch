package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import org.junit.Test;

public final class RpcDispatcherTimeoutTest {
    @Test
    public void sessionErrorLogLabelOmitsThrowableDetails() {
        String label = AndroidLogLabel.error(
                "session crashed",
                new IllegalStateException("content://com.example.documents/private.jpg")
        );

        assertEquals("session crashed [IllegalStateException]", label);
        assertFalse(label.contains("content://"));
        assertFalse(label.contains("private.jpg"));
    }

    @Test
    public void pairingApprovalWaitOutlivesOrdinaryIdleTimeout() {
        assertEquals(
                125_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.PAIRING_AWAITING_CONFIRM,
                        30_000
                )
        );
        assertEquals(
                30_000,
                RpcDispatcher.readTimeoutMillis(RpcSessionState.Phase.READY, 30_000)
        );
    }

    @Test
    public void callerMayProvideLongerPairingTimeout() {
        assertEquals(
                180_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.PAIRING_AWAITING_CONFIRM,
                        180_000
                )
        );
    }
}
