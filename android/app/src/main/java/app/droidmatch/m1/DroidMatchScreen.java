package app.droidmatch.m1;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

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
    }

    final TextView readinessTitle;
    final TextView readinessDetail;
    final TextView readinessCounts;
    final TextView connectionStatus;
    final Button enableConnectionButton;
    final Button disableConnectionButton;
    final TextView pairingStatus;
    final TextView pairingClient;
    final TextView pairingCode;
    final Button approveButton;
    final Button rejectButton;
    final Button openWindowButton;
    final LinearLayout storageRoots;
    final LinearLayout pairedDevices;

    private final Context context;
    private final View root;

    DroidMatchScreen(Context context, Actions actions) {
        this.context = context;
        ScrollView scrollView = new ScrollView(context);
        scrollView.setFillViewport(true);
        scrollView.setBackgroundColor(Color.rgb(20, 23, 27));

        LinearLayout content = new LinearLayout(context);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(28), dp(24), dp(32));
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
        LinearLayout connectionActions = actionRow();
        enableConnectionButton = button(R.string.connection_enable);
        disableConnectionButton = button(R.string.connection_disable);
        enableConnectionButton.setOnClickListener(view -> actions.enableSecureConnection());
        disableConnectionButton.setOnClickListener(view -> actions.disableConnection());
        connectionActions.addView(enableConnectionButton, weighted());
        connectionActions.addView(disableConnectionButton, weighted());
        content.addView(connectionActions, matchWidth());

        addHeader(content, R.string.pairing_title, R.string.pairing_explanation,
                HeaderStyle.PAIRING);
        pairingStatus = text("", 16, Color.rgb(133, 224, 190));
        content.addView(pairingStatus);
        pairingClient = text("", 15, Color.rgb(242, 239, 230));
        pairingClient.setPadding(0, dp(16), 0, 0);
        content.addView(pairingClient);
        pairingCode = text(context.getString(R.string.pairing_code_placeholder), 40,
                Color.rgb(255, 177, 92));
        pairingCode.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        pairingCode.setGravity(Gravity.CENTER_HORIZONTAL);
        pairingCode.setLetterSpacing(0.12f);
        pairingCode.setPadding(0, dp(12), 0, dp(16));
        content.addView(pairingCode, matchWidth());
        openWindowButton = button(R.string.pairing_open_window);
        openWindowButton.setOnClickListener(view -> actions.openPairingWindow());
        content.addView(openWindowButton, matchWidth());
        LinearLayout decisions = actionRow();
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
        content.addView(pairedDevices, matchWidth());

        addHeader(content, R.string.storage_title, R.string.storage_explanation,
                HeaderStyle.SECTION);
        storageRoots = new LinearLayout(context);
        storageRoots.setOrientation(LinearLayout.VERTICAL);
        content.addView(storageRoots, matchWidth());
        Button addFolder = button(R.string.storage_add_folder);
        addFolder.setOnClickListener(view -> actions.addFolder());
        content.addView(addFolder, matchWidth());
        root = scrollView;
    }

    View root() {
        return root;
    }

    TextView mutedText(int stringResource) {
        TextView view = text(context.getString(stringResource), 14, Color.rgb(171, 181, 181));
        view.setPadding(0, 0, 0, dp(12));
        return view;
    }

    TextView text(String value, int sp, int color) {
        TextView view = new TextView(context);
        view.setText(value);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        view.setTextColor(color);
        view.setLineSpacing(0, 1.15f);
        return view;
    }

    Button button(int stringResource) {
        Button button = new Button(context);
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

    private void addHeader(
            LinearLayout content,
            int titleResource,
            int explanationResource,
            HeaderStyle style
    ) {
        int titleSize = style == HeaderStyle.INTRO ? 28 : 20;
        TextView title = text(context.getString(titleResource), titleSize, Color.rgb(242, 239, 230));
        title.setTypeface(Typeface.DEFAULT_BOLD);
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

    private LinearLayout.LayoutParams weighted() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, dp(52), 1);
        params.setMarginEnd(dp(6));
        return params;
    }
}
