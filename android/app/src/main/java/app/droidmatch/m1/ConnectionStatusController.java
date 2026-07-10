package app.droidmatch.m1;

/**
 * Process-scoped, generation-guarded product endpoint state for the Android UI.
 *
 * <p>Socket and dispatcher ownership stays in {@link ForegroundConnectionService}.
 * This controller publishes only coarse state, port, and authentication mode;
 * it never exposes clients, credentials, pairing identifiers, or exceptions.</p>
 */
public final class ConnectionStatusController {
    public enum State {
        STOPPED,
        STARTING,
        LISTENING,
        FAILED
    }

    private long generation;
    private State state = State.STOPPED;
    private int port;
    private SessionAuthenticationMode authenticationMode = SessionAuthenticationMode.PAIRED_REQUIRED;

    public synchronized long begin(
            SessionAuthenticationMode authenticationMode,
            int requestedPort
    ) {
        generation += 1;
        state = State.STARTING;
        port = requestedPort;
        this.authenticationMode = authenticationMode;
        return generation;
    }

    public synchronized void markListening(long expectedGeneration, int actualPort) {
        if (generation != expectedGeneration || state != State.STARTING) {
            return;
        }
        state = State.LISTENING;
        port = actualPort;
    }

    public synchronized void markFailed(long expectedGeneration) {
        if (generation != expectedGeneration) {
            return;
        }
        state = State.FAILED;
    }

    public synchronized void markStopped(long expectedGeneration) {
        if (generation != expectedGeneration || state == State.FAILED) {
            return;
        }
        state = State.STOPPED;
        port = 0;
    }

    /** Invalidates all endpoint callbacks before service teardown begins. */
    public synchronized void stop() {
        generation += 1;
        state = State.STOPPED;
        port = 0;
    }

    public synchronized Snapshot snapshot() {
        return new Snapshot(state, port, authenticationMode);
    }

    public static final class Snapshot {
        private final State state;
        private final int port;
        private final SessionAuthenticationMode authenticationMode;

        private Snapshot(
                State state,
                int port,
                SessionAuthenticationMode authenticationMode
        ) {
            this.state = state;
            this.port = port;
            this.authenticationMode = authenticationMode;
        }

        public State state() {
            return state;
        }

        public int port() {
            return port;
        }

        public SessionAuthenticationMode authenticationMode() {
            return authenticationMode;
        }

        public boolean secureEndpointReady() {
            return state == State.LISTENING
                    && authenticationMode == SessionAuthenticationMode.PAIRED_REQUIRED;
        }
    }
}
