package app.droidmatch.m1;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * Process-local, user-visible gate for one first-pairing attempt.
 *
 * <p>The window is closed by default, time-bounded, and single-use. It contains
 * no pairing key or ECDH private key; the dispatcher owns those per-connection
 * secrets and registers only the display name, pairing ID, and six-digit SAS.</p>
 */
public final class PairingApprovalController {
    public static final long DEFAULT_WINDOW_MILLIS = 2 * 60 * 1000L;
    public static final long MAXIMUM_WINDOW_MILLIS = 5 * 60 * 1000L;

    private final Clock clock;
    private long windowExpiresAtMillis;
    private PendingAttempt pendingAttempt;

    public PairingApprovalController() {
        this(System::currentTimeMillis);
    }

    PairingApprovalController(Clock clock) {
        this.clock = clock;
    }

    public synchronized boolean openWindow(long durationMillis) {
        if (durationMillis <= 0 || durationMillis > MAXIMUM_WINDOW_MILLIS || pendingAttempt != null) {
            return false;
        }
        windowExpiresAtMillis = saturatedAdd(clock.nowMillis(), durationMillis);
        notifyAll();
        return true;
    }

    public synchronized void closeWindow() {
        windowExpiresAtMillis = 0;
        if (pendingAttempt != null && pendingAttempt.decision == Decision.PENDING) {
            pendingAttempt.decision = Decision.REJECTED;
        }
        notifyAll();
    }

    public synchronized boolean beginAttempt(
            byte[] pairingId,
            String clientDisplayName,
            String shortAuthenticationString
    ) {
        expireIfNeeded();
        requireLength(pairingId, PairingAuthenticator.PAIRING_ID_LENGTH);
        validateDisplayName(clientDisplayName);
        validateSas(shortAuthenticationString);
        if (windowExpiresAtMillis == 0 || pendingAttempt != null) {
            return false;
        }
        pendingAttempt = new PendingAttempt(
                pairingId,
                // The dispatcher retains the authenticated raw name for the
                // transcript/credential; this controller publishes UI only.
                ProductDisplayName.deviceName(clientDisplayName),
                shortAuthenticationString,
                clock.nowMillis()
        );
        notifyAll();
        return true;
    }

    public synchronized boolean approve(byte[] pairingId) {
        expireIfNeeded();
        if (!matchesPending(pairingId) || pendingAttempt.decision != Decision.PENDING) {
            return false;
        }
        pendingAttempt.decision = Decision.APPROVED;
        notifyAll();
        return true;
    }

    public synchronized boolean reject(byte[] pairingId) {
        expireIfNeeded();
        if (!matchesPending(pairingId) || pendingAttempt.decision != Decision.PENDING) {
            return false;
        }
        pendingAttempt.decision = Decision.REJECTED;
        notifyAll();
        return true;
    }

    public synchronized Decision awaitDecision(byte[] pairingId, long timeoutMillis)
            throws InterruptedException {
        requireLength(pairingId, PairingAuthenticator.PAIRING_ID_LENGTH);
        if (timeoutMillis <= 0 || !matchesPending(pairingId)) {
            return Decision.EXPIRED;
        }
        long deadline = Math.min(
                windowExpiresAtMillis,
                saturatedAdd(clock.nowMillis(), timeoutMillis)
        );
        while (matchesPending(pairingId) && pendingAttempt.decision == Decision.PENDING) {
            long remaining = deadline - clock.nowMillis();
            if (remaining <= 0) {
                pendingAttempt.decision = Decision.EXPIRED;
                windowExpiresAtMillis = 0;
                break;
            }
            wait(Math.min(remaining, 1_000L));
            expireIfNeeded();
        }
        return matchesPending(pairingId) ? pendingAttempt.decision : Decision.EXPIRED;
    }

    public synchronized void finishAttempt(byte[] pairingId) {
        if (!matchesPending(pairingId)) {
            return;
        }
        pendingAttempt = null;
        // A pairing window is single-use even when the registered attempt failed.
        windowExpiresAtMillis = 0;
        notifyAll();
    }

    public synchronized Snapshot snapshot() {
        expireIfNeeded();
        long remainingMillis = Math.max(0, windowExpiresAtMillis - clock.nowMillis());
        if (pendingAttempt == null) {
            return new Snapshot(remainingMillis, null, null, null, null);
        }
        return new Snapshot(
                remainingMillis,
                pendingAttempt.pairingId,
                pendingAttempt.clientDisplayName,
                pendingAttempt.shortAuthenticationString,
                pendingAttempt.decision
        );
    }

    private void expireIfNeeded() {
        if (windowExpiresAtMillis != 0 && clock.nowMillis() >= windowExpiresAtMillis) {
            windowExpiresAtMillis = 0;
            if (pendingAttempt != null && pendingAttempt.decision == Decision.PENDING) {
                pendingAttempt.decision = Decision.EXPIRED;
            }
            notifyAll();
        }
    }

    private boolean matchesPending(byte[] pairingId) {
        return pendingAttempt != null && Arrays.equals(pendingAttempt.pairingId, pairingId);
    }

    private static void validateDisplayName(String name) {
        int length = name.getBytes(StandardCharsets.UTF_8).length;
        if (length == 0 || length > PairingAuthenticator.MAXIMUM_DISPLAY_NAME_BYTES) {
            throw new IllegalArgumentException("invalid pairing client display name length");
        }
    }

    private static void validateSas(String sas) {
        if (sas.length() != 6) {
            throw new IllegalArgumentException("pairing SAS must contain six digits");
        }
        for (int index = 0; index < sas.length(); index += 1) {
            if (sas.charAt(index) < '0' || sas.charAt(index) > '9') {
                throw new IllegalArgumentException("pairing SAS must contain six digits");
            }
        }
    }

    private static void requireLength(byte[] value, int expected) {
        if (value.length != expected) {
            throw new IllegalArgumentException("invalid pairing ID length");
        }
    }

    private static long saturatedAdd(long first, long second) {
        if (second > 0 && first > Long.MAX_VALUE - second) {
            return Long.MAX_VALUE;
        }
        return first + second;
    }

    interface Clock {
        long nowMillis();
    }

    public enum Decision {
        PENDING,
        APPROVED,
        REJECTED,
        EXPIRED
    }

    public static final class Snapshot {
        private final long windowRemainingMillis;
        private final byte[] pairingId;
        private final String clientDisplayName;
        private final String shortAuthenticationString;
        private final Decision decision;

        private Snapshot(
                long windowRemainingMillis,
                byte[] pairingId,
                String clientDisplayName,
                String shortAuthenticationString,
                Decision decision
        ) {
            this.windowRemainingMillis = windowRemainingMillis;
            this.pairingId = pairingId == null ? null : Arrays.copyOf(pairingId, pairingId.length);
            this.clientDisplayName = clientDisplayName;
            this.shortAuthenticationString = shortAuthenticationString;
            this.decision = decision;
        }

        public boolean windowOpen() {
            return windowRemainingMillis > 0;
        }

        public long windowRemainingMillis() {
            return windowRemainingMillis;
        }

        public boolean hasPendingAttempt() {
            return pairingId != null;
        }

        public byte[] pairingId() {
            return pairingId == null ? null : Arrays.copyOf(pairingId, pairingId.length);
        }

        public String clientDisplayName() {
            return clientDisplayName;
        }

        public String shortAuthenticationString() {
            return shortAuthenticationString;
        }

        public Decision decision() {
            return decision;
        }
    }

    private static final class PendingAttempt {
        private final byte[] pairingId;
        private final String clientDisplayName;
        private final String shortAuthenticationString;
        @SuppressWarnings("unused")
        private final long startedAtMillis;
        private Decision decision = Decision.PENDING;

        private PendingAttempt(
                byte[] pairingId,
                String clientDisplayName,
                String shortAuthenticationString,
                long startedAtMillis
        ) {
            this.pairingId = Arrays.copyOf(pairingId, pairingId.length);
            this.clientDisplayName = clientDisplayName;
            this.shortAuthenticationString = shortAuthenticationString;
            this.startedAtMillis = startedAtMillis;
        }
    }
}
