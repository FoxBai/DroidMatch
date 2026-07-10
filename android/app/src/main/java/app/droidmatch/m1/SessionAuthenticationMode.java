package app.droidmatch.m1;

/**
 * Authentication policy for a single RPC endpoint.
 *
 * <p>{@link #NONCE_ONLY} exists only for the current M1/debug transport. It
 * correlates the two hello messages but does not authenticate either peer.
 * Product endpoints must use {@link #PAIRED_REQUIRED} once pairing storage is
 * connected.</p>
 */
public enum SessionAuthenticationMode {
    NONCE_ONLY,
    PAIRED_REQUIRED
}
