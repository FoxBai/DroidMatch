package app.droidmatch.m1;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

import app.droidmatch.proto.v1.ApkInstallOperation;
import app.droidmatch.proto.v1.ApkInstallState;
import app.droidmatch.proto.v1.ErrorCode;

import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** Process owner: private installer work stays off the Activity thread. */
final class ApkInstallRuntime implements ApkInstallManagerProvider {
    static final class Row {
        final ApkInstallOperation operation;
        final boolean canContinue;
        final boolean unknownDismissed;
        Row(ApkInstallOperation operation, boolean canContinue, boolean unknownDismissed) {
            this.operation = operation;
            this.canContinue = canContinue;
            this.unknownDismissed = unknownDismissed;
        }
    }

    static final class Snapshot {
        final boolean ready, healthy, supported, sourceTrusted, enabled, untracked;
        final List<Row> rows;
        final ErrorCode actionError;
        Snapshot(boolean ready, boolean healthy, boolean supported, boolean sourceTrusted,
                boolean enabled, boolean untracked, List<Row> rows, ErrorCode actionError) {
            this.ready = ready; this.healthy = healthy; this.supported = supported;
            this.sourceTrusted = sourceTrusted; this.enabled = enabled; this.untracked = untracked;
            this.rows = Collections.unmodifiableList(new ArrayList<>(rows));
            this.actionError = actionError;
        }
    }

    private final ApkInstallAccess access = new ApkInstallAccess();
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean refreshPending = new AtomicBoolean();
    private final AtomicBoolean busy = new AtomicBoolean();
    private final ConnectionStatusController connection;
    private volatile ApkInstallManager manager;
    private AndroidApkInstallBackend backend;
    private volatile Snapshot snapshot = new Snapshot(false, false, false, false,
            false, false, Collections.emptyList(), ErrorCode.ERROR_CODE_UNSPECIFIED);
    private volatile long foregroundGeneration;
    private volatile boolean foreground;
    private ErrorCode actionError = ErrorCode.ERROR_CODE_UNSPECIFIED;

    ApkInstallRuntime(Context context, ConnectionStatusController connection) {
        this.connection = connection;
        Context application = context.getApplicationContext();
        worker.execute(() -> {
            try {
                backend = new AndroidApkInstallBackend(application);
                manager = new ApkInstallManager(backend, new AndroidApkInstallJournal(application),
                        access, new SecureRandom());
            } catch (RuntimeException unavailable) {
                actionError = ErrorCode.ERROR_CODE_INTERNAL;
            }
            publish();
        });
    }

    @Override public ApkInstallManager get() throws DmFileProvider.ProviderCatalogException {
        ApkInstallManager current = manager;
        if (current == null) throw ApkInstallPolicy.error(ErrorCode.ERROR_CODE_INTERNAL,
                "installation state is unavailable");
        return current;
    }

    Snapshot snapshot() { return snapshot; }
    boolean busy() { return busy.get(); }

    // Main-thread lifecycle. No Activity is retained by the process runtime.
    void resumed() { foregroundGeneration++; foreground = true; refresh(); }
    void paused() { foreground = false; foregroundGeneration++; }

    void refresh() {
        if (!refreshPending.compareAndSet(false, true)) return;
        worker.execute(() -> {
            try { publish(); } finally { refreshPending.set(false); }
        });
    }

    void toggleIncoming() {
        if (access.currentGrant() >= 0) { disable(); return; }
        long version = access.version();
        runAction(() -> {
            if (!connection.snapshot().secureEndpointReady() || !get().healthy()
                    || backend == null || !backend.sourceTrusted()) {
                throw ApkInstallPolicy.error(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "enable secure connection and Android installation permission");
            }
            // A delayed enable cannot undo Stop or a trust-revocation action.
            // 中文：排队的启用动作不能覆盖稍后的停止连接或撤销信任。
            access.enableIfUnchanged(version);
        });
    }

    void disable() {
        access.disable();
        // Revocation is immediate; bounded private cleanup is serialized off-main.
        worker.execute(() -> {
            try { get().cleanInvalidGrants(); }
            catch (DmFileProvider.ProviderCatalogException failure) { actionError = failure.code; }
            finally { publish(); }
        });
    }

    void approve(String id) {
        runAction(() -> {
            get().approveOnAndroid(id);
            // A missing first callback must not leave an unresolvable "submitting"
            // row. Late authenticated results can still settle this unknown outcome.
            // 中文：首个系统回调丢失时转为未知；迟到的有效结果仍可更新状态。
            main.postDelayed(() -> worker.execute(() -> {
                try { get().markUnansweredSubmission(id); }
                catch (DmFileProvider.ProviderCatalogException failure) { actionError = failure.code; }
                finally { publish(); }
            }), 10_000);
        });
    }
    void cancel(String id) { runAction(() -> get().cancelOnAndroid(id)); }
    void dismissUnknown(String id) {
        runAction(() -> { get().dismissUnknownOnAndroid(id); backend.forgetConfirmation(id); });
    }
    void cleanUntracked() { runAction(() -> get().cleanUntrackedOnAndroid()); }

    void continueOnAndroid(Activity activity, String id) {
        if (!foreground || busy.get() || backend == null) return;
        // Only this explicit foreground button opens the system-provided Intent.
        // A callback/reconnect/restart never opens UI or commits another installation.
        // 中文：仅手机前台点击可打开系统确认；回调和重连都不会自动发起安装。
        if (backend.launchConfirmation(activity, id)) {
            runAction(() -> get().confirmationLaunched(id), false);
        } else {
            runAction(() -> { throw ApkInstallPolicy.error(ErrorCode.ERROR_CODE_INTERNAL,
                    "system confirmation is unavailable"); });
        }
    }

    void receive(Intent intent, Runnable finished) {
        worker.execute(() -> {
            try {
                if (backend != null && manager != null) backend.receive(intent, manager);
                publish();
            } finally { finished.run(); }
        });
    }

    private interface Action { void run() throws DmFileProvider.ProviderCatalogException; }

    private void runAction(Action action) { runAction(action, true); }

    private void runAction(Action action, boolean requireForeground) {
        long generation = foregroundGeneration;
        if ((requireForeground && !foreground) || !busy.compareAndSet(false, true)) return;
        worker.execute(() -> {
            try {
                if (!requireForeground || (foreground && foregroundGeneration == generation)) {
                    actionError = ErrorCode.ERROR_CODE_UNSPECIFIED;
                    action.run();
                }
            } catch (DmFileProvider.ProviderCatalogException failure) {
                actionError = failure.code;
            } catch (RuntimeException unavailable) {
                actionError = ErrorCode.ERROR_CODE_INTERNAL;
            } finally {
                publish();
                main.post(() -> busy.set(false));
            }
        });
    }

    private void publish() {
        ApkInstallManager current = manager;
        if (current == null || backend == null) {
            snapshot = new Snapshot(true, false, false, false, false, false,
                    Collections.emptyList(), actionError);
            return;
        }
        boolean sourceTrusted = backend.sourceTrusted();
        // Live OS trust and endpoint loss also close admission without a UI gesture.
        if ((!sourceTrusted || !connection.snapshot().secureEndpointReady())
                && access.currentGrant() >= 0) {
            access.disable();
            try { current.cleanInvalidGrants(); }
            catch (DmFileProvider.ProviderCatalogException failure) { actionError = failure.code; }
        }
        List<Row> rows = new ArrayList<>();
        if (current.healthy()) {
            try { current.reconcilePendingOutcomes(); }
            catch (DmFileProvider.ProviderCatalogException failure) { actionError = failure.code; }
        }
        for (ApkInstallOperation operation : current.androidOperations()) {
            ApkInstallState state = operation.getState();
            boolean dismissed = current.unknownDismissed(operation.getOperationId());
            boolean canContinue = !dismissed && (state == ApkInstallState.APK_INSTALL_STATE_WAITING_FOR_SYSTEM_CONFIRMATION
                    || state == ApkInstallState.APK_INSTALL_STATE_OUTCOME_UNKNOWN
                    || state == ApkInstallState.APK_INSTALL_STATE_INSTALLING)
                    && backend.hasConfirmation(operation.getOperationId());
            rows.add(new Row(operation, canContinue, dismissed));
        }
        snapshot = new Snapshot(true, current.healthy(), backend.supported(), sourceTrusted,
                access.currentGrant() >= 0, current.needsUntrackedCleanup(), rows, actionError);
    }
}
