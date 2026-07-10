package app.droidmatch.m1;

import java.util.Arrays;
import java.util.LinkedHashMap;

/**
 * Process-local exponential backoff for first pairing and paired reconnect.
 *
 * <p>Reconnect uses both a per-identifier bucket and a global bucket. The global
 * bucket prevents an attacker from bypassing backoff by rotating random pairing
 * identifiers; the per-identifier bucket avoids penalizing every paired device
 * after a small number of failures against one record. Callers must still run the
 * normal challenge/proof exchange and return the same external authentication
 * error while blocked so this class does not become an identifier oracle.</p>
 *
 * <p>State is intentionally process-local. It contains only non-secret pairing
 * identifiers, is bounded, and expires after idle time. Persisting attacker-driven
 * lockout state would let a transient local process create a durable denial of
 * service across app restarts.</p>
 */
final class AuthenticationRateLimiter {
    static final int FIRST_PAIRING_FAILURES_BEFORE_BACKOFF = 3;
    static final int RECONNECT_IDENTIFIER_FAILURES_BEFORE_BACKOFF = 3;
    static final int RECONNECT_GLOBAL_FAILURES_BEFORE_BACKOFF = 10;
    static final long BASE_BACKOFF_MILLIS = 1_000L;
    static final long MAXIMUM_BACKOFF_MILLIS = 60_000L;
    static final long IDLE_RETENTION_MILLIS = 5 * 60_000L;
    static final int MAXIMUM_TRACKED_IDENTIFIERS = 256;

    private final Clock clock;
    private final BackoffState firstPairing = new BackoffState();
    private final BackoffState reconnectGlobal = new BackoffState();
    private final LinkedHashMap<PairingIdentifier, BackoffState> reconnectIdentifiers =
            new LinkedHashMap<>(16, 0.75f, true);

    AuthenticationRateLimiter() {
        this(new ProcessMonotonicClock());
    }

    AuthenticationRateLimiter(Clock clock) {
        this.clock = clock;
    }

    synchronized boolean firstPairingAllowed() {
        return firstPairing.allowed(clock.nowMillis());
    }

    synchronized void recordFirstPairingFailure() {
        firstPairing.recordFailure(
                clock.nowMillis(),
                FIRST_PAIRING_FAILURES_BEFORE_BACKOFF
        );
    }

    synchronized void recordFirstPairingSuccess() {
        firstPairing.reset();
    }

    synchronized boolean reconnectAllowed(byte[] pairingId) {
        requirePairingId(pairingId);
        long now = clock.nowMillis();
        if (!reconnectGlobal.allowed(now)) {
            return false;
        }
        BackoffState identifier = reconnectIdentifiers.get(new PairingIdentifier(pairingId));
        return identifier == null || identifier.allowed(now);
    }

    synchronized void recordReconnectFailure(byte[] pairingId) {
        requirePairingId(pairingId);
        long now = clock.nowMillis();
        reconnectGlobal.recordFailure(now, RECONNECT_GLOBAL_FAILURES_BEFORE_BACKOFF);

        PairingIdentifier key = new PairingIdentifier(pairingId);
        BackoffState identifier = reconnectIdentifiers.computeIfAbsent(
                key,
                ignored -> new BackoffState()
        );
        identifier.recordFailure(now, RECONNECT_IDENTIFIER_FAILURES_BEFORE_BACKOFF);
        trimIdentifierBuckets();
    }

    synchronized void recordReconnectSuccess(byte[] pairingId) {
        requirePairingId(pairingId);
        // A valid proof clears only its own failures. Clearing the global bucket
        // would let one valid credential mask an ongoing random-ID spray.
        reconnectIdentifiers.remove(new PairingIdentifier(pairingId));
    }

    synchronized int trackedIdentifierCountForTest() {
        return reconnectIdentifiers.size();
    }

    private void trimIdentifierBuckets() {
        while (reconnectIdentifiers.size() > MAXIMUM_TRACKED_IDENTIFIERS) {
            PairingIdentifier eldest = reconnectIdentifiers.keySet().iterator().next();
            reconnectIdentifiers.remove(eldest);
        }
    }

    private static void requirePairingId(byte[] pairingId) {
        if (pairingId == null || pairingId.length != SessionAuthenticator.PAIRING_ID_LENGTH) {
            throw new IllegalArgumentException("pairing ID must be 16 bytes");
        }
    }

    interface Clock {
        long nowMillis();
    }

    private static final class ProcessMonotonicClock implements Clock {
        private final long originNanos = System.nanoTime();

        @Override
        public long nowMillis() {
            // System.nanoTime() has an arbitrary, potentially negative origin.
            // Only a relative difference is meaningful and starts our limiter at 0.
            return Math.max(0L, (System.nanoTime() - originNanos) / 1_000_000L);
        }
    }

    private static final class BackoffState {
        private int failures;
        private long blockedUntilMillis;
        private long lastFailureMillis;
        private boolean hasFailure;

        private boolean allowed(long nowMillis) {
            expireIfIdle(nowMillis);
            return nowMillis >= blockedUntilMillis;
        }

        private void recordFailure(long nowMillis, int failuresBeforeBackoff) {
            expireIfIdle(nowMillis);
            // Attempts made during a block do not extend it. This keeps the retry
            // boundary deterministic and prevents a packet flood from pinning the
            // app at the maximum delay without ever waiting for one retry slot.
            if (nowMillis < blockedUntilMillis) {
                return;
            }
            failures = Math.min(failures + 1, failuresBeforeBackoff + 62);
            lastFailureMillis = nowMillis;
            hasFailure = true;
            if (failures < failuresBeforeBackoff) {
                return;
            }
            int exponent = Math.min(failures - failuresBeforeBackoff, 62);
            long delay = BASE_BACKOFF_MILLIS;
            for (int index = 0; index < exponent && delay < MAXIMUM_BACKOFF_MILLIS; index += 1) {
                delay = Math.min(delay * 2, MAXIMUM_BACKOFF_MILLIS);
            }
            blockedUntilMillis = saturatedAdd(nowMillis, delay);
        }

        private void expireIfIdle(long nowMillis) {
            if (hasFailure
                    && nowMillis >= lastFailureMillis
                    && nowMillis - lastFailureMillis >= IDLE_RETENTION_MILLIS) {
                reset();
            }
        }

        private void reset() {
            failures = 0;
            blockedUntilMillis = 0;
            lastFailureMillis = 0;
            hasFailure = false;
        }

        private static long saturatedAdd(long first, long second) {
            if (second > 0 && first > Long.MAX_VALUE - second) {
                return Long.MAX_VALUE;
            }
            return first + second;
        }
    }

    private static final class PairingIdentifier {
        private final byte[] value;
        private final int hashCode;

        private PairingIdentifier(byte[] value) {
            this.value = Arrays.copyOf(value, value.length);
            this.hashCode = Arrays.hashCode(this.value);
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof PairingIdentifier
                    && Arrays.equals(value, ((PairingIdentifier) other).value);
        }

        @Override
        public int hashCode() {
            return hashCode;
        }
    }
}
