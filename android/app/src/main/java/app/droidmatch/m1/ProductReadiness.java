package app.droidmatch.m1;

/** Pure product-onboarding state derived from connection and trust boundaries. */
final class ProductReadiness {
    enum State {
        TURN_ON_USB,
        STARTING,
        PAIR_MAC,
        READY,
        UNAVAILABLE
    }

    enum CountsState {
        AVAILABLE,
        STORAGE_UNAVAILABLE,
        PAIRED_DEVICES_UNAVAILABLE,
        BOTH_UNAVAILABLE
    }

    private ProductReadiness() {}

    static State evaluate(
            ConnectionStatusController.State connectionState,
            boolean secureEndpointReady,
            boolean pairedDevicesAvailable,
            int pairedDeviceCount
    ) {
        if (connectionState == null || pairedDeviceCount < 0) {
            throw new IllegalArgumentException("readiness input is invalid");
        }
        if (!pairedDevicesAvailable) {
            return State.UNAVAILABLE;
        }
        if (connectionState == ConnectionStatusController.State.STARTING) {
            return State.STARTING;
        }
        if (connectionState != ConnectionStatusController.State.LISTENING) {
            return connectionState == ConnectionStatusController.State.STOPPED
                    ? State.TURN_ON_USB
                    : State.UNAVAILABLE;
        }
        if (!secureEndpointReady) {
            return State.UNAVAILABLE;
        }
        return pairedDeviceCount == 0 ? State.PAIR_MAC : State.READY;
    }

    static CountsState countsState(
            boolean pairedDevicesAvailable,
            boolean storageRootsAvailable
    ) {
        if (pairedDevicesAvailable) {
            return storageRootsAvailable
                    ? CountsState.AVAILABLE
                    : CountsState.STORAGE_UNAVAILABLE;
        }
        return storageRootsAvailable
                ? CountsState.PAIRED_DEVICES_UNAVAILABLE
                : CountsState.BOTH_UNAVAILABLE;
    }
}
