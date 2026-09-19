package app.droidmatch.m1;

/** Short, non-I/O consent lock so revocation closes admission before cleanup waits. */
final class ApkInstallAccess {
    private boolean enabled;
    private long generation;

    synchronized void enable() {
        if (!enabled) generation++;
        enabled = true;
    }

    synchronized void disable() {
        generation++;
        enabled = false;
    }

    synchronized long currentGrant() { return enabled ? generation : -1; }

    synchronized long version() { return generation; }

    synchronized void enableIfUnchanged(long version) {
        if (generation == version) enable();
    }

    synchronized boolean permits(long grant) { return enabled && generation == grant; }

    // Linearizes an already journaled, phone-approved submission against revoke.
    // Once admitted, its system outcome must be reconciled even if consent closes.
    synchronized boolean admitSubmission(long grant) { return enabled && generation == grant; }
}
