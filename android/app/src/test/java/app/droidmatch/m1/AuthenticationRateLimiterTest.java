package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class AuthenticationRateLimiterTest {
    @Test
    public void firstPairingUsesExponentialBackoffWithoutExtendingActiveBlock() {
        FakeClock clock = new FakeClock();
        AuthenticationRateLimiter limiter = new AuthenticationRateLimiter(clock);

        for (int failure = 1;
             failure < AuthenticationRateLimiter.FIRST_PAIRING_FAILURES_BEFORE_BACKOFF;
             failure += 1) {
            limiter.recordFirstPairingFailure();
            assertTrue(limiter.firstPairingAllowed());
        }
        limiter.recordFirstPairingFailure();
        assertFalse(limiter.firstPairingAllowed());

        limiter.recordFirstPairingFailure();
        clock.advance(AuthenticationRateLimiter.BASE_BACKOFF_MILLIS - 1);
        assertFalse(limiter.firstPairingAllowed());
        clock.advance(1);
        assertTrue(limiter.firstPairingAllowed());

        limiter.recordFirstPairingFailure();
        clock.advance(AuthenticationRateLimiter.BASE_BACKOFF_MILLIS);
        assertFalse(limiter.firstPairingAllowed());
        clock.advance(AuthenticationRateLimiter.BASE_BACKOFF_MILLIS);
        assertTrue(limiter.firstPairingAllowed());

        limiter.recordFirstPairingSuccess();
        assertTrue(limiter.firstPairingAllowed());
    }

    @Test
    public void reconnectBackoffIsPerIdentifierAndSuccessClearsOnlyThatIdentifier() {
        FakeClock clock = new FakeClock();
        AuthenticationRateLimiter limiter = new AuthenticationRateLimiter(clock);
        byte[] first = pairingId(0x10);
        byte[] second = pairingId(0x40);

        for (int failure = 0;
             failure < AuthenticationRateLimiter.RECONNECT_IDENTIFIER_FAILURES_BEFORE_BACKOFF;
             failure += 1) {
            limiter.recordReconnectFailure(first);
        }
        assertFalse(limiter.reconnectAllowed(first));
        assertTrue(limiter.reconnectAllowed(second));

        limiter.recordReconnectSuccess(first);
        assertTrue(limiter.reconnectAllowed(first));
        assertEquals(0, limiter.trackedIdentifierCountForTest());
    }

    @Test
    public void rotatingIdentifiersEventuallyTriggerGlobalBackoff() {
        FakeClock clock = new FakeClock();
        AuthenticationRateLimiter limiter = new AuthenticationRateLimiter(clock);

        for (int index = 0;
             index < AuthenticationRateLimiter.RECONNECT_GLOBAL_FAILURES_BEFORE_BACKOFF;
             index += 1) {
            limiter.recordReconnectFailure(pairingId(index));
        }
        assertFalse(limiter.reconnectAllowed(pairingId(0x70)));

        clock.advance(AuthenticationRateLimiter.BASE_BACKOFF_MILLIS);
        assertTrue(limiter.reconnectAllowed(pairingId(0x70)));
    }

    @Test
    public void idleFailuresExpireAndIdentifierTrackingIsBounded() {
        FakeClock clock = new FakeClock();
        AuthenticationRateLimiter limiter = new AuthenticationRateLimiter(clock);
        byte[] target = pairingId(0x20);
        for (int failure = 0;
             failure < AuthenticationRateLimiter.RECONNECT_IDENTIFIER_FAILURES_BEFORE_BACKOFF;
             failure += 1) {
            limiter.recordReconnectFailure(target);
        }
        assertFalse(limiter.reconnectAllowed(target));

        clock.advance(AuthenticationRateLimiter.IDLE_RETENTION_MILLIS);
        assertTrue(limiter.reconnectAllowed(target));

        for (int index = 0;
             index < AuthenticationRateLimiter.MAXIMUM_TRACKED_IDENTIFIERS + 20;
             index += 1) {
            limiter.recordReconnectFailure(uniquePairingId(index));
        }
        assertEquals(
                AuthenticationRateLimiter.MAXIMUM_TRACKED_IDENTIFIERS,
                limiter.trackedIdentifierCountForTest()
        );
    }

    private static byte[] pairingId(int seed) {
        byte[] result = new byte[SessionAuthenticator.PAIRING_ID_LENGTH];
        for (int index = 0; index < result.length; index += 1) {
            result[index] = (byte) (seed + index);
        }
        return result;
    }

    private static byte[] uniquePairingId(int value) {
        byte[] result = pairingId(value);
        result[0] = (byte) (value >>> 8);
        result[1] = (byte) value;
        return result;
    }

    private static final class FakeClock implements AuthenticationRateLimiter.Clock {
        private long nowMillis;

        @Override
        public long nowMillis() {
            return nowMillis;
        }

        private void advance(long millis) {
            nowMillis += millis;
        }
    }
}
