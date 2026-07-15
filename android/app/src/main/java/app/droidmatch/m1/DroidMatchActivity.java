package app.droidmatch.m1;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import java.util.List;

/** Product control surface for secure USB, paired Macs, media access, and folder grants. */
public final class DroidMatchActivity extends Activity {
    private static final int REQUEST_OPEN_TREE = 1;
    private static final long UI_REFRESH_MILLIS = 500;
    private static final String STATE_MEDIA_SETTINGS_RECOMMENDED =
            "media_settings_recommended";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable refreshRunnable = new Runnable() {
        @Override
        public void run() {
            refreshConnectionState();
            refreshPairingState();
            handler.postDelayed(this, UI_REFRESH_MILLIS);
        }
    };

    private PairingApprovalController pairingApprovals;
    private ConnectionStatusController connectionStatusController;
    private PairedDeviceManager pairedDeviceManager;
    private PermissionStateProvider permissionStateProvider;
    private MediaPermissionController mediaPermissionController;
    private boolean hadPendingPairing;
    private boolean pairedDevicesAvailable = true;
    private int pairedDeviceCount;
    private int storageRootCount;
    private boolean mediaSettingsRecommended;
    private DroidMatchScreen screen;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        mediaSettingsRecommended = savedInstanceState != null
                && savedInstanceState.getBoolean(STATE_MEDIA_SETTINGS_RECOMMENDED, false);
        DroidMatchApplication application = (DroidMatchApplication) getApplication();
        pairingApprovals = application.pairingApprovalController();
        connectionStatusController = application.connectionStatusController();
        permissionStateProvider = new PermissionStateProvider(this);
        mediaPermissionController = new MediaPermissionController(this, permissionStateProvider);
        pairedDeviceManager = new PairedDeviceManager(
                application.pairingCredentialRepository(),
                this::disableConnection
        );
        screen = new DroidMatchScreen(this, new DroidMatchScreen.Actions() {
            @Override
            public void enableSecureConnection() {
                DroidMatchActivity.this.enableSecureConnection();
            }

            @Override
            public void disableConnection() {
                DroidMatchActivity.this.disableConnection();
            }

            @Override
            public void openPairingWindow() {
                pairingApprovals.openWindow(PairingApprovalController.DEFAULT_WINDOW_MILLIS);
                refreshPairingState();
            }

            @Override
            public void approvePairing() {
                decide(true);
            }

            @Override
            public void rejectPairing() {
                decide(false);
            }

            @Override
            public void addFolder() {
                launchSafPicker();
            }

            @Override
            public void manageMediaAccess() {
                if (!mediaPermissionController.manageAccess(mediaSettingsRecommended)) {
                    showMediaSettingsUnavailable();
                }
            }

            @Override
            public void removeFolder(DmFileProvider.SafRoot root) {
                confirmRemoveRoot(root);
            }

            @Override
            public void revokeDevice(PairedDeviceManager.Device device) {
                confirmRevokeDevice(device);
            }
        });
        setContentView(screen.root());
        NotificationPermissionRequester.requestIfNeeded(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshPairedDevices();
        refreshStorageRoots();
        refreshMediaAccess();
        handler.post(refreshRunnable);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(refreshRunnable);
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        outState.putBoolean(STATE_MEDIA_SETTINGS_RECOMMENDED, mediaSettingsRecommended);
        super.onSaveInstanceState(outState);
    }

    private void enableSecureConnection() {
        Intent serviceIntent = new Intent(this, ForegroundConnectionService.class)
                .setAction(ForegroundConnectionService.ACTION_START_ADB_ENDPOINT)
                .putExtra(
                        ForegroundConnectionService.EXTRA_PORT,
                        ForegroundConnectionService.DEFAULT_ADB_ENDPOINT_PORT
                )
                .putExtra(
                        ForegroundConnectionService.EXTRA_SESSION_AUTHENTICATION_MODE,
                        ForegroundConnectionService.AUTHENTICATION_MODE_PAIRED_REQUIRED
                );
        startForegroundService(serviceIntent);
        refreshConnectionState();
    }

    private void disableConnection() {
        pairingApprovals.closeWindow();
        stopService(new Intent(this, ForegroundConnectionService.class));
        refreshConnectionState();
        refreshPairingState();
    }

    private void refreshConnectionState() {
        if (screen == null) {
            return;
        }
        ConnectionStatusController.Snapshot snapshot = connectionStatusController.snapshot();
        switch (snapshot.state()) {
            case STARTING:
                screen.setTextIfChanged(screen.connectionStatus, R.string.connection_status_starting);
                break;
            case LISTENING:
                screen.setTextIfChanged(screen.connectionStatus, snapshot.secureEndpointReady()
                        ? R.string.connection_status_ready
                        : R.string.connection_status_debug);
                break;
            case FAILED:
                screen.setTextIfChanged(screen.connectionStatus, R.string.connection_status_failed);
                break;
            case STOPPED:
            default:
                screen.setTextIfChanged(screen.connectionStatus, R.string.connection_status_stopped);
                break;
        }
        boolean active = snapshot.state() == ConnectionStatusController.State.STARTING
                || snapshot.state() == ConnectionStatusController.State.LISTENING;
        screen.enableConnectionButton.setEnabled(!active);
        screen.disableConnectionButton.setEnabled(active);
        screen.openWindowButton.setEnabled(snapshot.secureEndpointReady());
        refreshReadiness(snapshot);
    }

    private void decide(boolean approved) {
        PairingApprovalController.Snapshot snapshot = pairingApprovals.snapshot();
        byte[] pairingId = snapshot.pairingId();
        if (pairingId != null) {
            if (approved) {
                pairingApprovals.approve(pairingId);
            } else {
                pairingApprovals.reject(pairingId);
            }
        }
        refreshPairingState();
    }

    private void refreshPairingState() {
        if (screen == null) {
            return;
        }
        PairingApprovalController.Snapshot snapshot = pairingApprovals.snapshot();
        boolean pairingJustFinished = hadPendingPairing && !snapshot.hasPendingAttempt();
        hadPendingPairing = snapshot.hasPendingAttempt();
        long seconds = (snapshot.windowRemainingMillis() + 999) / 1000;
        if (!snapshot.windowOpen()) {
            screen.setTextIfChanged(screen.pairingStatus, R.string.pairing_window_closed);
        } else if (!snapshot.hasPendingAttempt()) {
            screen.setTextIfChanged(
                    screen.pairingStatus,
                    getString(R.string.pairing_window_waiting, seconds)
            );
        } else {
            screen.setTextIfChanged(
                    screen.pairingStatus,
                    getString(R.string.pairing_window_pending, seconds)
            );
        }

        boolean pending = snapshot.hasPendingAttempt()
                && snapshot.decision() == PairingApprovalController.Decision.PENDING;
        screen.pairingClient.setText(pending
                ? getString(R.string.pairing_client, snapshot.clientDisplayName())
                : getString(R.string.pairing_no_client));
        screen.pairingCode.setText(pending
                ? snapshot.shortAuthenticationString()
                : getString(R.string.pairing_code_placeholder));
        screen.approveButton.setEnabled(pending);
        screen.rejectButton.setEnabled(pending);
        if (screen.openWindowButton != null) {
            screen.openWindowButton.setEnabled(
                    connectionStatusController.snapshot().secureEndpointReady()
                            && !snapshot.hasPendingAttempt()
            );
        }
        if (pairingJustFinished) {
            refreshPairedDevices();
        }
    }

    @SuppressWarnings("deprecation")
    private void launchSafPicker() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                .addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                .addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        startActivityForResult(intent, REQUEST_OPEN_TREE);
    }

    @Override
    @android.annotation.SuppressLint("WrongConstant")
    @SuppressWarnings("deprecation")
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_OPEN_TREE && resultCode == RESULT_OK && data != null) {
            Uri uri = data.getData();
            if (uri != null) {
                int flags = data.getFlags()
                        & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                if (flags != 0) {
                    // Lint cannot infer that this runtime value contains only the
                    // two allowed grant bits after masking the system result.
                    getContentResolver().takePersistableUriPermission(uri, flags);
                }
                refreshStorageRoots();
            }
        }
    }

    /**
     * Rebuilds the small authorization summary from live persisted permissions.
     * Platform tree URIs stay Android-local; the user sees only provider names
     * and the same capability boundary exposed to the authenticated Mac.
     */
    private void refreshStorageRoots() {
        if (screen == null) {
            return;
        }
        List<DmFileProvider.SafRoot> roots = new AndroidSafCatalog(getContentResolver()).roots();
        storageRootCount = roots.size();
        refreshReadiness(connectionStatusController.snapshot());
        screen.showStorageRoots(roots);
    }

    private void refreshMediaAccess() {
        if (screen == null) {
            return;
        }
        MediaPermissionPolicy.LibraryAccess access =
                permissionStateProvider.publicMediaLibraryAccess();
        if (mediaSettingsRecommended
                && !mediaPermissionController.settingsFallbackStillAppropriate()) {
            mediaSettingsRecommended = false;
        }
        switch (access) {
            case FULL:
                screen.setTextIfChanged(
                        screen.mediaAccessStatus,
                        R.string.media_access_status_full
                );
                screen.setTextIfChanged(
                        screen.mediaAccessButton,
                        R.string.media_access_manage
                );
                break;
            case LIMITED:
                screen.setTextIfChanged(
                        screen.mediaAccessStatus,
                        R.string.media_access_status_limited
                );
                screen.setTextIfChanged(
                        screen.mediaAccessButton,
                        mediaSettingsRecommended
                                ? R.string.media_access_settings_open
                                : R.string.media_access_manage
                );
                break;
            case DENIED:
            default:
                screen.setTextIfChanged(
                        screen.mediaAccessStatus,
                        R.string.media_access_status_denied
                );
                screen.setTextIfChanged(
                        screen.mediaAccessButton,
                        mediaSettingsRecommended
                                ? R.string.media_access_settings_open
                                : R.string.media_access_choose
                );
                break;
        }
    }

    private void showMediaSettingsUnavailable() {
        new AlertDialog.Builder(this)
                .setTitle(R.string.media_access_settings_unavailable_title)
                .setMessage(R.string.media_access_settings_unavailable_message)
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }

    private void confirmRemoveRoot(DmFileProvider.SafRoot root) {
        new AlertDialog.Builder(this)
                .setTitle(R.string.storage_remove_title)
                .setMessage(getString(R.string.storage_remove_message, root.displayName))
                .setNegativeButton(R.string.storage_remove_cancel, null)
                .setPositiveButton(R.string.storage_remove_confirm, (dialog, which) -> removeRoot(root))
                .show();
    }

    private void removeRoot(DmFileProvider.SafRoot root) {
        if (root.treeUri == null) {
            return;
        }
        int flags = Intent.FLAG_GRANT_READ_URI_PERMISSION;
        if (root.canWrite) {
            flags |= Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
        }
        try {
            getContentResolver().releasePersistableUriPermission(root.treeUri, flags);
        } catch (SecurityException ignored) {
            // The provider may have already revoked the grant. Re-reading the
            // resolver is authoritative and safely removes stale UI state.
        }
        refreshStorageRoots();
    }

    private void refreshPairedDevices() {
        if (screen == null) {
            return;
        }
        final List<PairedDeviceManager.Device> devices;
        try {
            devices = pairedDeviceManager.devices();
        } catch (RuntimeException exception) {
            pairedDevicesAvailable = false;
            pairedDeviceCount = 0;
            screen.showPairedDevicesUnavailable();
            refreshReadiness(connectionStatusController.snapshot());
            return;
        }
        pairedDevicesAvailable = true;
        pairedDeviceCount = devices.size();
        refreshReadiness(connectionStatusController.snapshot());
        screen.showPairedDevices(devices);
    }

    private void refreshReadiness(ConnectionStatusController.Snapshot connection) {
        if (screen == null) {
            return;
        }
        ProductReadiness.State state = ProductReadiness.evaluate(
                connection.state(),
                connection.secureEndpointReady(),
                pairedDevicesAvailable,
                pairedDeviceCount
        );
        switch (state) {
            case STARTING:
                screen.setTextIfChanged(screen.readinessTitle, R.string.readiness_starting_title);
                screen.setTextIfChanged(screen.readinessDetail, R.string.readiness_starting_detail);
                break;
            case PAIR_MAC:
                screen.setTextIfChanged(screen.readinessTitle, R.string.readiness_pair_title);
                screen.setTextIfChanged(screen.readinessDetail, R.string.readiness_pair_detail);
                break;
            case READY:
                screen.setTextIfChanged(screen.readinessTitle, R.string.readiness_ready_title);
                screen.setTextIfChanged(screen.readinessDetail, R.string.readiness_ready_detail);
                break;
            case UNAVAILABLE:
                screen.setTextIfChanged(screen.readinessTitle, R.string.readiness_unavailable_title);
                screen.setTextIfChanged(screen.readinessDetail, R.string.readiness_unavailable_detail);
                break;
            case TURN_ON_USB:
            default:
                screen.setTextIfChanged(screen.readinessTitle, R.string.readiness_turn_on_title);
                screen.setTextIfChanged(screen.readinessDetail, R.string.readiness_turn_on_detail);
                break;
        }
        screen.setTextIfChanged(screen.readinessCounts, getString(
                R.string.readiness_counts,
                pairedDeviceCount,
                storageRootCount
        ));
    }

    private void confirmRevokeDevice(PairedDeviceManager.Device device) {
        new AlertDialog.Builder(this)
                .setTitle(R.string.paired_devices_revoke_title)
                .setMessage(getString(R.string.paired_devices_revoke_message, device.displayName))
                .setNegativeButton(R.string.paired_devices_revoke_cancel, null)
                .setPositiveButton(R.string.paired_devices_revoke_confirm, (dialog, which) -> {
                    try {
                        pairedDeviceManager.revoke(device);
                        refreshPairedDevices();
                    } catch (RuntimeException exception) {
                        new AlertDialog.Builder(this)
                                .setMessage(R.string.paired_devices_revoke_failed)
                                .setPositiveButton(android.R.string.ok, null)
                                .show();
                    }
                })
                .show();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == MediaPermissionController.REQUEST_MEDIA_READ) {
            mediaSettingsRecommended = mediaPermissionController.requestNeedsSettingsFallback(
                    permissions,
                    grantResults
            );
            refreshMediaAccess();
        }
        // Notification permission remains independent from pairing, media, and SAF actions.
    }

}
