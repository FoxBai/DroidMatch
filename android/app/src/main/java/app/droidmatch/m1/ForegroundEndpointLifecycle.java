package app.droidmatch.m1;

/**
 * Generation-guarded policy joining endpoint state to foreground-service effects.
 *
 * <p>The Android service owns notifications and shutdown. This pure boundary
 * ensures a late callback from an old endpoint cannot update or stop its
 * replacement.</p>
 */
final class ForegroundEndpointLifecycle {
    enum NotificationState {
        STARTING,
        READY
    }

    interface Actions {
        void showNotification(NotificationState state);

        void stopAfterEndpointExit();
    }

    private final ConnectionStatusController connectionStatus;
    private final Actions actions;

    ForegroundEndpointLifecycle(
            ConnectionStatusController connectionStatus,
            Actions actions
    ) {
        this.connectionStatus = connectionStatus;
        this.actions = actions;
    }

    long begin(SessionAuthenticationMode authenticationMode, int requestedPort) {
        long generation = connectionStatus.begin(authenticationMode, requestedPort);
        actions.showNotification(NotificationState.STARTING);
        return generation;
    }

    void onListening(long generation, int actualPort) {
        if (connectionStatus.markListening(generation, actualPort)) {
            actions.showNotification(NotificationState.READY);
        }
    }

    void onFailed(long generation) {
        if (connectionStatus.markFailed(generation)) {
            actions.stopAfterEndpointExit();
        }
    }

    void onStopped(long generation) {
        if (connectionStatus.markStopped(generation)) {
            actions.stopAfterEndpointExit();
        }
    }
}
