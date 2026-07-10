package app.droidmatch.m1;

import android.app.Application;

/** Process-scoped dependencies shared by the pairing UI and connection service. */
public final class DroidMatchApplication extends Application {
    private final PairingApprovalController pairingApprovalController = new PairingApprovalController();
    private final ConnectionStatusController connectionStatusController = new ConnectionStatusController();

    public PairingApprovalController pairingApprovalController() {
        return pairingApprovalController;
    }

    public ConnectionStatusController connectionStatusController() {
        return connectionStatusController;
    }
}
