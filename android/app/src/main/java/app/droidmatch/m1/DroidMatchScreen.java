package app.droidmatch.m1;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.os.Build;
import android.text.Layout;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.text.DateFormat;
import java.util.Date;
import java.util.List;

/**
 * Builds the product launcher's static view hierarchy.
 *
 * <p>Runtime state and security-sensitive actions remain owned by
 * {@link DroidMatchActivity}; this boundary only owns presentation construction
 * and exposes the controls whose values change while the Activity is visible.
 */
final class DroidMatchScreen {
    private enum HeaderStyle {
        INTRO,
        PAIRING,
        SECTION
    }

    interface Actions {
        void enableSecureConnection();

        void disableConnection();

        void openPairingWindow();

        void approvePairing();

        void rejectPairing();

        void addFolder();

        void refreshFolders();

        void refreshPairedDevices();

        void manageMediaAccess();

        void removeFolder(DmFileProvider.SafRoot root);

        void revokeDevice(PairedDeviceManager.Device device);
    }

    final TextView readinessTitle;
    final TextView readinessDetail;
    final TextView readinessCounts;
    final TextView connectionStatus;
    final Button enableConnectionButton;
    final Button disableConnectionButton;
    final TextView pairingStatus;
    final TextView pairingCountdown;
    final TextView pairingClient;
    final TextView pairingCode;
    final Button approveButton;
    final Button rejectButton;
    final Button openWindowButton;
    final TextView mediaAccessStatus;
    final Button mediaAccessButton;
    final LinearLayout storageRoots;
    final LinearLayout pairedDevices;

    private final Context context;
    private final Actions actions;
    private final View root;

    DroidMatchScreen(Context context, Actions actions) {
        this.context = context;
        this.actions = actions;
        ScrollView scrollView = new ScrollView(context);
        scrollView.setFillViewport(true);
        scrollView.setBackgroundColor(Color.rgb(20, 23, 27));

        LinearLayout content = new LinearLayout(context);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(28), dp(24), dp(32));
        installEdgeToEdgeInsets(scrollView, content);
        scrollView.addView(content, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT
        ));

        addHeader(content, R.string.connection_title, R.string.connection_explanation,
                HeaderStyle.INTRO);

        LinearLayout readiness = new LinearLayout(context);
        readiness.setOrientation(LinearLayout.VERTICAL);
        readiness.setPadding(dp(16), dp(14), dp(16), dp(14));
        readiness.setBackgroundColor(Color.rgb(31, 36, 42));
        readinessTitle = text("", 18, Color.rgb(242, 239, 230));
        readinessTitle.setTypeface(Typeface.DEFAULT_BOLD);
        markHeading(readinessTitle);
        readiness.addView(readinessTitle);
        readinessDetail = text("", 14, Color.rgb(171, 181, 181));
        readinessDetail.setPadding(0, dp(4), 0, dp(8));
        readiness.addView(readinessDetail);
        readinessCounts = text("", 13, Color.rgb(133, 224, 190));
        readiness.addView(readinessCounts);
        readiness.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        LinearLayout.LayoutParams readinessParams = matchWidth();
        readinessParams.setMargins(0, 0, 0, dp(20));
        content.addView(readiness, readinessParams);

        connectionStatus = text("", 16, Color.rgb(133, 224, 190));
        connectionStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        content.addView(connectionStatus);
        LinearLayout connectionActions = actionRow();
        connectionActions.setId(R.id.connection_actions);
        enableConnectionButton = button(R.string.connection_enable);
        enableConnectionButton.setId(R.id.connection_enable_button);
        disableConnectionButton = button(R.string.connection_disable);
        enableConnectionButton.setOnClickListener(view -> actions.enableSecureConnection());
        disableConnectionButton.setOnClickListener(view -> actions.disableConnection());
        connectionActions.addView(enableConnectionButton, weighted());
        connectionActions.addView(disableConnectionButton, weighted());
        content.addView(connectionActions, matchWidth());

        addHeader(content, R.string.pairing_title, R.string.pairing_explanation,
                HeaderStyle.PAIRING);
        pairingStatus = text(
                context.getString(R.string.pairing_window_closed),
                16,
                Color.rgb(133, 224, 190)
        );
        pairingStatus.setContentDescription(context.getString(R.string.pairing_window_closed));
        pairingStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        content.addView(pairingStatus);
        pairingCountdown = text("", 13, Color.rgb(171, 181, 181));
        pairingCountdown.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        pairingCountdown.setPadding(0, dp(3), 0, 0);
        content.addView(pairingCountdown);
        pairingClient = text("", 15, Color.rgb(242, 239, 230));
        pairingClient.setPadding(0, dp(16), 0, 0);
        content.addView(pairingClient);
        pairingCode = text(context.getString(R.string.pairing_code_placeholder), 40,
                Color.rgb(255, 177, 92));
        pairingCode.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        pairingCode.setGravity(Gravity.CENTER_HORIZONTAL);
        pairingCode.setLetterSpacing(0.12f);
        pairingCode.setPadding(0, dp(12), 0, dp(16));
        pairingCode.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        content.addView(pairingCode, matchWidth());
        openWindowButton = button(R.string.pairing_open_window);
        openWindowButton.setOnClickListener(view -> actions.openPairingWindow());
        content.addView(openWindowButton, matchWidth());
        LinearLayout decisions = actionRow();
        decisions.setId(R.id.pairing_decisions);
        approveButton = button(R.string.pairing_approve);
        rejectButton = button(R.string.pairing_reject);
        approveButton.setOnClickListener(view -> actions.approvePairing());
        rejectButton.setOnClickListener(view -> actions.rejectPairing());
        decisions.addView(approveButton, weighted());
        decisions.addView(rejectButton, weighted());
        content.addView(decisions, matchWidth());

        addHeader(content, R.string.paired_devices_title,
                R.string.paired_devices_explanation, HeaderStyle.SECTION);
        pairedDevices = new LinearLayout(context);
        pairedDevices.setOrientation(LinearLayout.VERTICAL);
        pairedDevices.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        content.addView(pairedDevices, matchWidth());

        addHeader(content, R.string.media_access_title,
                R.string.media_access_explanation, HeaderStyle.SECTION);
        mediaAccessStatus = text("", 15, Color.rgb(133, 224, 190));
        mediaAccessStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        content.addView(mediaAccessStatus);
        mediaAccessButton = button(R.string.media_access_choose);
        mediaAccessButton.setOnClickListener(view -> actions.manageMediaAccess());
        content.addView(mediaAccessButton, matchWidth());

        addHeader(content, R.string.storage_title, R.string.storage_explanation,
                HeaderStyle.SECTION);
        storageRoots = new LinearLayout(context);
        storageRoots.setOrientation(LinearLayout.VERTICAL);
        storageRoots.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        content.addView(storageRoots, matchWidth());
        Button addFolder = button(R.string.storage_add_folder);
        addFolder.setId(R.id.storage_add_folder_button);
        addFolder.setOnClickListener(view -> actions.addFolder());
        content.addView(addFolder, matchWidth());
        root = scrollView;
    }

    View root() {
        return root;
    }

    void showStorageRoots(List<DmFileProvider.SafRoot> roots) {
        storageRoots.removeAllViews();
        if (roots.isEmpty()) {
            storageRoots.addView(mutedText(R.string.storage_empty));
            return;
        }
        for (DmFileProvider.SafRoot root : roots) {
            LinearLayout row = cardRow();
            TextView name = text(
                    ProductDisplayName.name(
                            root.displayName,
                            context.getString(R.string.storage_unnamed_folder)
                    ),
                    16,
                    Color.rgb(242, 239, 230)
            );
            name.setTypeface(Typeface.DEFAULT_BOLD);
            markHeading(name);
            row.addView(name);
            TextView access = text(
                    context.getString(root.canWrite
                            ? R.string.storage_access_read_write
                            : R.string.storage_access_read_only),
                    13,
                    Color.rgb(133, 224, 190)
            );
            access.setPadding(0, dp(3), 0, dp(6));
            row.addView(access);
            Button remove = button(R.string.storage_remove_folder);
            remove.setOnClickListener(view -> actions.removeFolder(root));
            row.addView(remove, matchWidth());
            storageRoots.addView(row, cardLayoutParams());
        }
    }

    void showStorageRootsUnavailable() {
        storageRoots.removeAllViews();
        storageRoots.addView(mutedText(R.string.storage_unavailable));
        Button retry = button(R.string.storage_retry);
        retry.setOnClickListener(view -> actions.refreshFolders());
        storageRoots.addView(retry, matchWidth());
    }

    void showPairedDevices(List<PairedDeviceManager.Device> devices) {
        pairedDevices.removeAllViews();
        if (devices.isEmpty()) {
            pairedDevices.addView(mutedText(R.string.paired_devices_empty));
            return;
        }
        DateFormat dateFormat = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT);
        for (PairedDeviceManager.Device device : devices) {
            LinearLayout row = cardRow();
            TextView name = text(device.displayName, 16, Color.rgb(242, 239, 230));
            name.setTypeface(Typeface.DEFAULT_BOLD);
            markHeading(name);
            row.addView(name);
            TextView lastUsed = text(
                    context.getString(
                            R.string.paired_devices_last_used,
                            dateFormat.format(new Date(device.lastUsedAtUnixMillis))
                    ),
                    13,
                    Color.rgb(171, 181, 181)
            );
            lastUsed.setPadding(0, dp(3), 0, dp(6));
            row.addView(lastUsed);
            Button revoke = button(R.string.paired_devices_revoke);
            revoke.setOnClickListener(view -> actions.revokeDevice(device));
            row.addView(revoke, matchWidth());
            pairedDevices.addView(row, cardLayoutParams());
        }
    }

    void showPairedDevicesUnavailable() {
        pairedDevices.removeAllViews();
        pairedDevices.addView(mutedText(R.string.paired_devices_unavailable));
        Button retry = button(R.string.paired_devices_retry);
        retry.setOnClickListener(view -> actions.refreshPairedDevices());
        pairedDevices.addView(retry, matchWidth());
    }

    void setTextIfChanged(TextView view, int stringResource) {
        setTextIfChanged(view, context.getText(stringResource));
    }

    void setTextIfChanged(TextView view, CharSequence value) {
        // The Activity polls live state every 500 ms. Avoid emitting duplicate
        // accessibility events for stable live-region text.
        if (!TextUtils.equals(view.getText(), value)) {
            view.setText(value);
        }
    }

    void setContentDescriptionIfChanged(View view, CharSequence value) {
        if (!TextUtils.equals(view.getContentDescription(), value)) {
            view.setContentDescription(value);
        }
    }

    void setImportantForAccessibilityIfChanged(View view, int mode) {
        if (view.getImportantForAccessibility() != mode) {
            view.setImportantForAccessibility(mode);
        }
    }

    TextView mutedText(int stringResource) {
        TextView view = text(context.getString(stringResource), 14, Color.rgb(171, 181, 181));
        view.setPadding(0, 0, 0, dp(12));
        return view;
    }

    TextView text(String value, int sp, int color) {
        TextView view = new TextView(context);
        applyReadableWrapping(view);
        view.setText(value);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        view.setTextColor(color);
        view.setLineSpacing(0, 1.15f);
        return view;
    }

    Button button(int stringResource) {
        Button button = new Button(context);
        applyReadableWrapping(button);
        button.setText(stringResource);
        button.setAllCaps(false);
        button.setMinHeight(dp(50));
        return button;
    }

    LinearLayout.LayoutParams matchWidth() {
        return new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
    }

    int dp(int value) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                value,
                context.getResources().getDisplayMetrics()
        ));
    }

    private void installEdgeToEdgeInsets(ScrollView scrollView, LinearLayout content) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            return;
        }
        scrollView.setOnApplyWindowInsetsListener((view, windowInsets) -> {
            Insets safeInsets = windowInsets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()
            );
            content.setPadding(
                    dp(24) + safeInsets.left,
                    dp(28) + safeInsets.top,
                    dp(24) + safeInsets.right,
                    dp(32) + safeInsets.bottom
            );
            return windowInsets;
        });
    }

    private void addHeader(
            LinearLayout content,
            int titleResource,
            int explanationResource,
            HeaderStyle style
    ) {
        int titleSize = style == HeaderStyle.INTRO ? 28 : 20;
        TextView title = text(context.getString(titleResource), titleSize, Color.rgb(242, 239, 230));
        title.setTypeface(Typeface.DEFAULT_BOLD);
        markHeading(title);
        if (style != HeaderStyle.INTRO) {
            title.setPadding(0, dp(32), 0, style == HeaderStyle.SECTION ? dp(8) : 0);
        }
        content.addView(title);
        TextView explanation = text(
                context.getString(explanationResource),
                15,
                Color.rgb(171, 181, 181)
        );
        explanation.setPadding(
                0,
                style == HeaderStyle.SECTION ? 0 : dp(8),
                0,
                dp(style == HeaderStyle.SECTION ? 12 : 20)
        );
        content.addView(explanation);
    }

    private LinearLayout actionRow() {
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(10), 0, 0);
        return row;
    }

    private static void markHeading(TextView view) {
        // setAccessibilityHeading was added in API 28; older supported devices
        // still retain the visible bold title without a compatibility dependency.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            view.setAccessibilityHeading(true);
        }
    }

    @SuppressLint("WrongConstant")
    private static void applyReadableWrapping(TextView view) {
        // API 26's default line breaker can insert visible hyphens into ordinary
        // main-screen prose (for example, "sys- / tem") on compact displays.
        // compileSdk 36 annotates setBreakStrategy with API 29 LineBreaker constants,
        // but the identical Layout constant and TextView method both exist since API 23.
        // Keep the API 26-compatible symbol rather than introducing an inlined-new-API
        // lint warning. Unusually long tokens may still wrap without an invented hyphen.
        view.setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE);
        view.setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE);
    }

    private LinearLayout cardRow() {
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setPadding(dp(14), dp(12), dp(14), dp(12));
        row.setBackgroundColor(Color.rgb(31, 36, 42));
        return row;
    }

    private LinearLayout.LayoutParams cardLayoutParams() {
        LinearLayout.LayoutParams params = matchWidth();
        params.setMargins(0, 0, 0, dp(10));
        return params;
    }

    private LinearLayout.LayoutParams weighted() {
        // Product labels can wrap at accessibility font scales on compact
        // devices. MATCH_PARENT participates in LinearLayout's uniform-height
        // remeasure, so both actions follow the taller label without clipping.
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.MATCH_PARENT,
                1
        );
        params.setMarginEnd(dp(6));
        return params;
    }
}
