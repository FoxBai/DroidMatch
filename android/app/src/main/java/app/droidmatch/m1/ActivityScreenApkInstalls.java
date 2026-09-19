package app.droidmatch.m1;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.text.format.Formatter;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import app.droidmatch.proto.v1.ApkInstallOperation;
import app.droidmatch.proto.v1.ApkInstallState;
import app.droidmatch.proto.v1.ErrorCode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Stable rows retain accessibility focus while bounded upload progress changes. */
final class ActivityScreenApkInstalls {
    interface Actions {
        void toggleIncoming();
        void sourceSettings();
        void approve(String id);
        void cancel(String id);
        void continueInstallation(String id);
        void dismissUnknown(String id);
        void cleanUntracked();
    }

    final LinearLayout root;
    private final Context context;
    private final Actions actions;
    private final TextView status, source, error, empty;
    private final Button toggle, settings, cleanup;
    private final LinearLayout operations;
    private final Map<String, RowViews> rows = new LinkedHashMap<>();

    ActivityScreenApkInstalls(Context context, Actions actions) {
        this.context = context;
        this.actions = actions;
        root = column();
        root.setId(R.id.apk_install_section);
        root.setPadding(0, dp(28), 0, 0);
        TextView title = text(21, Color.rgb(242, 239, 230));
        title.setText(R.string.apk_install_title);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        if (android.os.Build.VERSION.SDK_INT >= 28) title.setAccessibilityHeading(true);
        root.addView(title);
        TextView explanation = text(14, Color.rgb(171, 181, 181));
        explanation.setText(R.string.apk_install_explanation);
        root.addView(explanation);
        status = text(15, Color.rgb(133, 224, 190));
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        root.addView(status);
        source = text(14, Color.rgb(171, 181, 181));
        root.addView(source);
        settings = button(R.string.apk_install_source_settings, actions::sourceSettings);
        root.addView(settings);
        toggle = button(R.string.apk_install_enable, actions::toggleIncoming);
        toggle.setId(R.id.apk_install_toggle);
        root.addView(toggle);
        cleanup = button(R.string.apk_install_cleanup, actions::cleanUntracked);
        root.addView(cleanup);
        error = text(14, Color.rgb(255, 177, 92));
        error.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        root.addView(error);
        empty = text(14, Color.rgb(171, 181, 181));
        empty.setText(R.string.apk_install_empty);
        root.addView(empty);
        operations = column();
        root.addView(operations);
    }

    void render(ApkInstallRuntime.Snapshot snapshot, boolean secureConnection, boolean busy) {
        int statusLabel = !snapshot.ready ? R.string.apk_install_loading
                : !snapshot.healthy ? R.string.apk_install_unavailable
                : !snapshot.supported ? R.string.apk_install_unsupported
                : snapshot.enabled ? R.string.apk_install_enabled : R.string.apk_install_disabled;
        set(status, context.getText(statusLabel));
        set(source, context.getText(snapshot.sourceTrusted ? R.string.apk_install_source_allowed
                : R.string.apk_install_source_required));
        source.setVisibility(snapshot.healthy && snapshot.supported ? View.VISIBLE : View.GONE);
        settings.setVisibility(snapshot.healthy && snapshot.supported && !snapshot.sourceTrusted
                ? View.VISIBLE : View.GONE);
        set(toggle, context.getText(snapshot.enabled ? R.string.apk_install_disable : R.string.apk_install_enable));
        toggle.setEnabled(snapshot.enabled || (!busy && snapshot.healthy && snapshot.supported
                && snapshot.sourceTrusted && secureConnection));
        cleanup.setVisibility(snapshot.healthy && snapshot.untracked ? View.VISIBLE : View.GONE);
        cleanup.setEnabled(!busy);
        error.setVisibility(snapshot.actionError == ErrorCode.ERROR_CODE_UNSPECIFIED ? View.GONE : View.VISIBLE);
        set(error, context.getText(snapshot.actionError == ErrorCode.ERROR_CODE_PERMISSION_REQUIRED
                ? R.string.apk_install_permission_hint : R.string.apk_install_action_failed));
        empty.setVisibility(snapshot.rows.isEmpty() && snapshot.healthy ? View.VISIBLE : View.GONE);
        List<String> ids = new ArrayList<>();
        for (int i = snapshot.rows.size() - 1; i >= 0; i--) ids.add(snapshot.rows.get(i).operation.getOperationId());
        if (!new ArrayList<>(rows.keySet()).equals(ids)) {
            rows.clear(); operations.removeAllViews();
            for (String id : ids) {
                RowViews row = new RowViews(id);
                rows.put(id, row); operations.addView(row.root);
            }
        }
        for (ApkInstallRuntime.Row row : snapshot.rows) {
            rows.get(row.operation.getOperationId()).render(row, snapshot, busy);
        }
    }

    private final class RowViews {
        final LinearLayout root = column();
        final TextView name = text(16, Color.rgb(242, 239, 230));
        final TextView state = text(14, Color.rgb(133, 224, 190));
        final Button approve, cancel, proceed, acknowledge;
        RowViews(String id) {
            root.setPadding(dp(12), dp(12), dp(12), dp(12));
            root.setBackgroundColor(Color.rgb(31, 36, 42));
            LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, -2);
            layout.setMargins(0, dp(12), 0, 0); root.setLayoutParams(layout);
            name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
            root.addView(name); root.addView(state);
            approve = button(R.string.apk_install_approve, () -> actions.approve(id));
            proceed = button(R.string.apk_install_continue, () -> actions.continueInstallation(id));
            cancel = button(R.string.apk_install_cancel, () -> actions.cancel(id));
            acknowledge = button(R.string.apk_install_acknowledge, () -> actions.dismissUnknown(id));
            root.addView(approve); root.addView(proceed); root.addView(cancel); root.addView(acknowledge);
        }

        void render(ApkInstallRuntime.Row row, ApkInstallRuntime.Snapshot snapshot, boolean busy) {
            ApkInstallOperation operation = row.operation;
            ApkInstallState value = operation.getState();
            set(name, context.getString(R.string.apk_install_file, operation.getDisplayName(),
                    Formatter.formatShortFileSize(context, operation.getSizeBytes())));
            CharSequence label = context.getText(stateLabel(value));
            if (value == ApkInstallState.APK_INSTALL_STATE_UPLOADING) {
                label = context.getString(R.string.apk_install_uploading_progress,
                        Formatter.formatShortFileSize(context, operation.getUploadedBytes()),
                        Formatter.formatShortFileSize(context, operation.getSizeBytes()));
            } else if (row.unknownDismissed) {
                label = context.getText(R.string.apk_install_unknown_acknowledged);
            }
            set(state, label);
            approve.setVisibility(value == ApkInstallState.APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL
                    ? View.VISIBLE : View.GONE);
            approve.setEnabled(!busy && snapshot.enabled && snapshot.sourceTrusted && snapshot.healthy);
            proceed.setVisibility(row.canContinue ? View.VISIBLE : View.GONE);
            proceed.setEnabled(!busy && snapshot.healthy);
            cancel.setVisibility(ApkInstallPolicy.unsubmitted(value) ? View.VISIBLE : View.GONE);
            set(cancel, context.getText(value == ApkInstallState.APK_INSTALL_STATE_CLEANUP_REQUIRED
                    ? R.string.apk_install_cleanup : R.string.apk_install_cancel));
            cancel.setEnabled(!busy && snapshot.healthy);
            acknowledge.setVisibility(value == ApkInstallState.APK_INSTALL_STATE_OUTCOME_UNKNOWN && !row.unknownDismissed
                    ? View.VISIBLE : View.GONE);
            acknowledge.setEnabled(!busy && snapshot.healthy);
        }
    }

    static int stateLabel(ApkInstallState state) {
        switch (state) {
            case APK_INSTALL_STATE_WAITING_FOR_UPLOAD: return R.string.apk_install_waiting_upload;
            case APK_INSTALL_STATE_UPLOADING: return R.string.apk_install_uploading;
            case APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL: return R.string.apk_install_waiting_approval;
            case APK_INSTALL_STATE_SUBMITTING: return R.string.apk_install_submitting;
            case APK_INSTALL_STATE_WAITING_FOR_SYSTEM_CONFIRMATION: return R.string.apk_install_waiting_system;
            case APK_INSTALL_STATE_INSTALLING: return R.string.apk_install_waiting_result;
            case APK_INSTALL_STATE_SUCCEEDED: return R.string.apk_install_succeeded;
            case APK_INSTALL_STATE_FAILED: return R.string.apk_install_failed;
            case APK_INSTALL_STATE_CANCELLED: return R.string.apk_install_cancelled;
            case APK_INSTALL_STATE_CLEANUP_REQUIRED: return R.string.apk_install_cleanup_required;
            default: return R.string.apk_install_unknown;
        }
    }

    private LinearLayout column() {
        LinearLayout view = new LinearLayout(context); view.setOrientation(LinearLayout.VERTICAL);
        view.setLayoutParams(new LinearLayout.LayoutParams(-1, -2)); return view;
    }
    private TextView text(int size, int color) {
        TextView view = new TextView(context); view.setTextSize(size); view.setTextColor(color);
        view.setPadding(0, dp(4), 0, dp(6)); return view;
    }
    private Button button(int label, Runnable action) {
        Button button = new Button(context); button.setText(label); button.setAllCaps(false);
        button.setMinHeight(dp(48)); button.setLayoutParams(new LinearLayout.LayoutParams(-1, -2));
        button.setOnClickListener(view -> action.run()); return button;
    }
    private static void set(TextView view, CharSequence text) {
        if (!android.text.TextUtils.equals(view.getText(), text)) view.setText(text);
    }
    private int dp(int value) { return Math.round(value * context.getResources().getDisplayMetrics().density); }
}
