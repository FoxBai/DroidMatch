package app.droidmatch.m1;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.text.DateFormat;
import java.util.Date;
import java.util.List;

/** Product control surface for secure USB, paired Macs, and folder grants. */
public final class DroidMatchActivity extends Activity {
    private static final int REQUEST_OPEN_TREE = 1;
    private static final long UI_REFRESH_MILLIS = 500;

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
    private boolean hadPendingPairing;
    private boolean pairedDevicesAvailable = true;
    private int pairedDeviceCount;
    private int storageRootCount;
    private TextView readinessTitle;
    private TextView readinessDetail;
    private TextView readinessCounts;
    private TextView connectionStatus;
    private Button enableConnectionButton;
    private Button disableConnectionButton;
    private TextView pairingStatus;
    private TextView pairingClient;
    private TextView pairingCode;
    private Button approveButton;
    private Button rejectButton;
    private Button openWindowButton;
    private LinearLayout storageRoots;
    private LinearLayout pairedDevices;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        DroidMatchApplication application = (DroidMatchApplication) getApplication();
        pairingApprovals = application.pairingApprovalController();
        connectionStatusController = application.connectionStatusController();
        pairedDeviceManager = new PairedDeviceManager(
                application.pairingCredentialRepository(),
                this::disableConnection
        );
        setContentView(buildContentView());
        NotificationPermissionRequester.requestIfNeeded(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshPairedDevices();
        refreshStorageRoots();
        handler.post(refreshRunnable);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(refreshRunnable);
        super.onPause();
    }

    private View buildContentView() {
        ScrollView scrollView = new ScrollView(this);
        scrollView.setFillViewport(true);
        scrollView.setBackgroundColor(Color.rgb(20, 23, 27));

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(28), dp(24), dp(32));
        scrollView.addView(content, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT
        ));

        TextView title = text(getString(R.string.connection_title), 28, Color.rgb(242, 239, 230));
        title.setTypeface(Typeface.DEFAULT_BOLD);
        content.addView(title);

        TextView explanation = text(
                getString(R.string.connection_explanation),
                15,
                Color.rgb(171, 181, 181)
        );
        explanation.setPadding(0, dp(8), 0, dp(20));
        content.addView(explanation);

        LinearLayout readiness = new LinearLayout(this);
        readiness.setOrientation(LinearLayout.VERTICAL);
        readiness.setPadding(dp(16), dp(14), dp(16), dp(14));
        readiness.setBackgroundColor(Color.rgb(31, 36, 42));
        readinessTitle = text("", 18, Color.rgb(242, 239, 230));
        readinessTitle.setTypeface(Typeface.DEFAULT_BOLD);
        readiness.addView(readinessTitle);
        readinessDetail = text("", 14, Color.rgb(171, 181, 181));
        readinessDetail.setPadding(0, dp(4), 0, dp(8));
        readiness.addView(readinessDetail);
        readinessCounts = text("", 13, Color.rgb(133, 224, 190));
        readiness.addView(readinessCounts);
        LinearLayout.LayoutParams readinessParams = matchWidth();
        readinessParams.setMargins(0, 0, 0, dp(20));
        content.addView(readiness, readinessParams);

        connectionStatus = text("", 16, Color.rgb(133, 224, 190));
        content.addView(connectionStatus);

        LinearLayout connectionActions = new LinearLayout(this);
        connectionActions.setOrientation(LinearLayout.HORIZONTAL);
        connectionActions.setPadding(0, dp(10), 0, 0);
        enableConnectionButton = button(getString(R.string.connection_enable));
        disableConnectionButton = button(getString(R.string.connection_disable));
        enableConnectionButton.setOnClickListener(view -> enableSecureConnection());
        disableConnectionButton.setOnClickListener(view -> disableConnection());
        connectionActions.addView(enableConnectionButton, weighted());
        connectionActions.addView(disableConnectionButton, weighted());
        content.addView(connectionActions, matchWidth());

        TextView pairingTitle = text(getString(R.string.pairing_title), 20, Color.rgb(242, 239, 230));
        pairingTitle.setTypeface(Typeface.DEFAULT_BOLD);
        pairingTitle.setPadding(0, dp(32), 0, 0);
        content.addView(pairingTitle);

        TextView pairingExplanation = text(
                getString(R.string.pairing_explanation),
                15,
                Color.rgb(171, 181, 181)
        );
        pairingExplanation.setPadding(0, dp(8), 0, dp(20));
        content.addView(pairingExplanation);

        pairingStatus = text("", 16, Color.rgb(133, 224, 190));
        content.addView(pairingStatus);

        pairingClient = text("", 15, Color.rgb(242, 239, 230));
        pairingClient.setPadding(0, dp(16), 0, 0);
        content.addView(pairingClient);

        pairingCode = text(getString(R.string.pairing_code_placeholder), 40, Color.rgb(255, 177, 92));
        pairingCode.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        pairingCode.setGravity(Gravity.CENTER_HORIZONTAL);
        pairingCode.setLetterSpacing(0.12f);
        pairingCode.setPadding(0, dp(12), 0, dp(16));
        content.addView(pairingCode, matchWidth());

        openWindowButton = button(getString(R.string.pairing_open_window));
        openWindowButton.setOnClickListener(view -> {
            pairingApprovals.openWindow(PairingApprovalController.DEFAULT_WINDOW_MILLIS);
            refreshPairingState();
        });
        content.addView(openWindowButton, matchWidth());

        LinearLayout decisions = new LinearLayout(this);
        decisions.setOrientation(LinearLayout.HORIZONTAL);
        decisions.setPadding(0, dp(10), 0, 0);
        approveButton = button(getString(R.string.pairing_approve));
        rejectButton = button(getString(R.string.pairing_reject));
        approveButton.setOnClickListener(view -> decide(true));
        rejectButton.setOnClickListener(view -> decide(false));
        decisions.addView(approveButton, weighted());
        decisions.addView(rejectButton, weighted());
        content.addView(decisions, matchWidth());

        TextView pairedTitle = text(
                getString(R.string.paired_devices_title),
                20,
                Color.rgb(242, 239, 230)
        );
        pairedTitle.setTypeface(Typeface.DEFAULT_BOLD);
        pairedTitle.setPadding(0, dp(32), 0, dp(8));
        content.addView(pairedTitle);

        TextView pairedExplanation = text(
                getString(R.string.paired_devices_explanation),
                15,
                Color.rgb(171, 181, 181)
        );
        pairedExplanation.setPadding(0, 0, 0, dp(12));
        content.addView(pairedExplanation);

        pairedDevices = new LinearLayout(this);
        pairedDevices.setOrientation(LinearLayout.VERTICAL);
        content.addView(pairedDevices, matchWidth());

        TextView storageTitle = text(getString(R.string.storage_title), 20, Color.rgb(242, 239, 230));
        storageTitle.setTypeface(Typeface.DEFAULT_BOLD);
        storageTitle.setPadding(0, dp(32), 0, dp(8));
        content.addView(storageTitle);

        TextView storageExplanation = text(
                getString(R.string.storage_explanation),
                15,
                Color.rgb(171, 181, 181)
        );
        storageExplanation.setPadding(0, 0, 0, dp(12));
        content.addView(storageExplanation);

        storageRoots = new LinearLayout(this);
        storageRoots.setOrientation(LinearLayout.VERTICAL);
        content.addView(storageRoots, matchWidth());

        Button addFolder = button(getString(R.string.storage_add_folder));
        addFolder.setOnClickListener(view -> launchSafPicker());
        content.addView(addFolder, matchWidth());
        return scrollView;
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
        if (connectionStatus == null) {
            return;
        }
        ConnectionStatusController.Snapshot snapshot = connectionStatusController.snapshot();
        switch (snapshot.state()) {
            case STARTING:
                connectionStatus.setText(R.string.connection_status_starting);
                break;
            case LISTENING:
                connectionStatus.setText(snapshot.secureEndpointReady()
                        ? R.string.connection_status_ready
                        : R.string.connection_status_debug);
                break;
            case FAILED:
                connectionStatus.setText(R.string.connection_status_failed);
                break;
            case STOPPED:
            default:
                connectionStatus.setText(R.string.connection_status_stopped);
                break;
        }
        boolean active = snapshot.state() == ConnectionStatusController.State.STARTING
                || snapshot.state() == ConnectionStatusController.State.LISTENING;
        enableConnectionButton.setEnabled(!active);
        disableConnectionButton.setEnabled(active);
        openWindowButton.setEnabled(snapshot.secureEndpointReady());
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
        if (pairingStatus == null) {
            return;
        }
        PairingApprovalController.Snapshot snapshot = pairingApprovals.snapshot();
        boolean pairingJustFinished = hadPendingPairing && !snapshot.hasPendingAttempt();
        hadPendingPairing = snapshot.hasPendingAttempt();
        long seconds = (snapshot.windowRemainingMillis() + 999) / 1000;
        if (!snapshot.windowOpen()) {
            pairingStatus.setText(R.string.pairing_window_closed);
        } else if (!snapshot.hasPendingAttempt()) {
            pairingStatus.setText(getString(R.string.pairing_window_waiting, seconds));
        } else {
            pairingStatus.setText(getString(R.string.pairing_window_pending, seconds));
        }

        boolean pending = snapshot.hasPendingAttempt()
                && snapshot.decision() == PairingApprovalController.Decision.PENDING;
        pairingClient.setText(pending
                ? getString(R.string.pairing_client, snapshot.clientDisplayName())
                : getString(R.string.pairing_no_client));
        pairingCode.setText(pending
                ? snapshot.shortAuthenticationString()
                : getString(R.string.pairing_code_placeholder));
        approveButton.setEnabled(pending);
        rejectButton.setEnabled(pending);
        if (openWindowButton != null) {
            openWindowButton.setEnabled(
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
        if (storageRoots == null) {
            return;
        }
        storageRoots.removeAllViews();
        List<DmFileProvider.SafRoot> roots = new AndroidSafCatalog(getContentResolver()).roots();
        storageRootCount = roots.size();
        refreshReadiness(connectionStatusController.snapshot());
        if (roots.isEmpty()) {
            TextView empty = text(
                    getString(R.string.storage_empty),
                    14,
                    Color.rgb(171, 181, 181)
            );
            empty.setPadding(0, 0, 0, dp(12));
            storageRoots.addView(empty);
            return;
        }

        for (DmFileProvider.SafRoot root : roots) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.VERTICAL);
            row.setPadding(dp(14), dp(12), dp(14), dp(12));
            row.setBackgroundColor(Color.rgb(31, 36, 42));

            TextView name = text(root.displayName, 16, Color.rgb(242, 239, 230));
            name.setTypeface(Typeface.DEFAULT_BOLD);
            row.addView(name);

            TextView access = text(
                    getString(root.canWrite
                            ? R.string.storage_access_read_write
                            : R.string.storage_access_read_only),
                    13,
                    Color.rgb(133, 224, 190)
            );
            access.setPadding(0, dp(3), 0, dp(6));
            row.addView(access);

            Button remove = button(getString(R.string.storage_remove_folder));
            remove.setOnClickListener(view -> confirmRemoveRoot(root));
            row.addView(remove, matchWidth());

            LinearLayout.LayoutParams rowParams = matchWidth();
            rowParams.setMargins(0, 0, 0, dp(10));
            storageRoots.addView(row, rowParams);
        }
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
        if (pairedDevices == null) {
            return;
        }
        pairedDevices.removeAllViews();
        final List<PairedDeviceManager.Device> devices;
        try {
            devices = pairedDeviceManager.devices();
        } catch (RuntimeException exception) {
            pairedDevicesAvailable = false;
            pairedDeviceCount = 0;
            pairedDevices.addView(mutedText(R.string.paired_devices_unavailable));
            refreshReadiness(connectionStatusController.snapshot());
            return;
        }
        pairedDevicesAvailable = true;
        pairedDeviceCount = devices.size();
        refreshReadiness(connectionStatusController.snapshot());
        if (devices.isEmpty()) {
            pairedDevices.addView(mutedText(R.string.paired_devices_empty));
            return;
        }
        DateFormat dateFormat = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT);
        for (PairedDeviceManager.Device device : devices) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.VERTICAL);
            row.setPadding(dp(14), dp(12), dp(14), dp(12));
            row.setBackgroundColor(Color.rgb(31, 36, 42));

            TextView name = text(device.displayName, 16, Color.rgb(242, 239, 230));
            name.setTypeface(Typeface.DEFAULT_BOLD);
            row.addView(name);
            TextView lastUsed = text(
                    getString(
                            R.string.paired_devices_last_used,
                            dateFormat.format(new Date(device.lastUsedAtUnixMillis))
                    ),
                    13,
                    Color.rgb(171, 181, 181)
            );
            lastUsed.setPadding(0, dp(3), 0, dp(6));
            row.addView(lastUsed);
            Button revoke = button(getString(R.string.paired_devices_revoke));
            revoke.setOnClickListener(view -> confirmRevokeDevice(device));
            row.addView(revoke, matchWidth());

            LinearLayout.LayoutParams rowParams = matchWidth();
            rowParams.setMargins(0, 0, 0, dp(10));
            pairedDevices.addView(row, rowParams);
        }
    }

    private TextView mutedText(int stringResource) {
        TextView view = text(getString(stringResource), 14, Color.rgb(171, 181, 181));
        view.setPadding(0, 0, 0, dp(12));
        return view;
    }

    private void refreshReadiness(ConnectionStatusController.Snapshot connection) {
        if (readinessTitle == null) {
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
                readinessTitle.setText(R.string.readiness_starting_title);
                readinessDetail.setText(R.string.readiness_starting_detail);
                break;
            case PAIR_MAC:
                readinessTitle.setText(R.string.readiness_pair_title);
                readinessDetail.setText(R.string.readiness_pair_detail);
                break;
            case READY:
                readinessTitle.setText(R.string.readiness_ready_title);
                readinessDetail.setText(R.string.readiness_ready_detail);
                break;
            case UNAVAILABLE:
                readinessTitle.setText(R.string.readiness_unavailable_title);
                readinessDetail.setText(R.string.readiness_unavailable_detail);
                break;
            case TURN_ON_USB:
            default:
                readinessTitle.setText(R.string.readiness_turn_on_title);
                readinessDetail.setText(R.string.readiness_turn_on_detail);
                break;
        }
        readinessCounts.setText(getString(
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
        // Notification permission is independent from pairing and SAF actions.
    }

    private TextView text(String value, int sp, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        view.setTextColor(color);
        view.setLineSpacing(0, 1.15f);
        return view;
    }

    private Button button(String value) {
        Button button = new Button(this);
        button.setText(value);
        button.setAllCaps(false);
        button.setMinHeight(dp(50));
        return button;
    }

    private LinearLayout.LayoutParams matchWidth() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
    }

    private LinearLayout.LayoutParams weighted() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, dp(52), 1);
        params.setMarginEnd(dp(6));
        return params;
    }

    private int dp(int value) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                value,
                getResources().getDisplayMetrics()
        ));
    }
}
