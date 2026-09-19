package app.droidmatch.m1;

import android.Manifest;
import android.app.Activity;
import android.app.PendingIntent;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;

import java.io.IOException;
import java.io.OutputStream;
import java.util.Base64;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;

/** Ordinary system-confirmed installation; no platform Intent or session ID enters RPC. */
final class AndroidApkInstallBackend implements ApkInstallBackend {
    private static final String ACTION_RESULT = "app.droidmatch.APK_INSTALL_RESULT_V1";
    private static final String RESULT_SCHEME = "droidmatch-install-result";
    private static final String RECEIVER = "app.droidmatch.m1.ApkInstallResultReceiver";
    private static final int MAX_OS_SESSIONS = 64;
    private final Context context;
    private final PackageInstaller installer;
    private final LinkedHashMap<String, Intent> confirmations = new LinkedHashMap<>();

    AndroidApkInstallBackend(Context context) {
        this.context = context.getApplicationContext();
        installer = this.context.getPackageManager().getPackageInstaller();
    }

    @Override public boolean supported() {
        try {
            DevicePolicyManager policy = context.getSystemService(DevicePolicyManager.class);
            return policy != null
                    && context.checkSelfPermission(Manifest.permission.INSTALL_PACKAGES) != PackageManager.PERMISSION_GRANTED
                    && !policy.isDeviceOwnerApp(context.getPackageName())
                    && !policy.isProfileOwnerApp(context.getPackageName());
        } catch (RuntimeException unavailable) { return false; }
    }

    @Override public boolean sourceTrusted() {
        try { return supported() && context.getPackageManager().canRequestPackageInstalls(); }
        catch (RuntimeException unavailable) { return false; }
    }

    @Override public int create(long size) throws IOException {
        requireSource();
        if (size < 1 || size > ApkInstallPolicy.MAX_BYTES) throw unavailable();
        try {
            PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL);
            params.setSize(size);
            params.setInstallReason(PackageManager.INSTALL_REASON_USER);
            if (Build.VERSION.SDK_INT >= 31) {
                params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED);
            }
            if (Build.VERSION.SDK_INT >= 33) {
                params.setPackageSource(PackageInstaller.PACKAGE_SOURCE_LOCAL_FILE);
            }
            return installer.createSession(params);
        } catch (IOException | RuntimeException failure) { throw unavailable(); }
    }

    @Override public Sink openUpload(int sessionId, long size) throws IOException {
        requireSource();
        PackageInstaller.Session session = null;
        try {
            session = installer.openSession(sessionId);
            OutputStream output = session.openWrite("base.apk", 0, size);
            return new SessionSink(session, output);
        } catch (IOException | RuntimeException failure) {
            if (session != null) try { session.close(); } catch (RuntimeException ignored) { }
            throw unavailable();
        }
    }

    @Override public void submit(int sessionId, String operationId, byte[] callbackKey) throws IOException {
        requireSource();
        if (!ApkInstallPolicy.validId(operationId) || callbackKey == null || callbackKey.length != 32) {
            throw unavailable();
        }
        try (PackageInstaller.Session session = installer.openSession(sessionId)) {
            Intent result = new Intent(ACTION_RESULT)
                    .setComponent(new ComponentName(context.getPackageName(), RECEIVER))
                    .setData(callbackUri(operationId, callbackKey));
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_MUTABLE;
            // PackageInstaller fills status extras and uses this sender for both
            // pending confirmation and the terminal result; ONE_SHOT would lose the latter.
            // 中文：系统需填入状态并回调多次；不能使用一次性或不可变 PendingIntent。
            PendingIntent callback = PendingIntent.getBroadcast(context, sessionId, result, flags);
            session.commit(callback.getIntentSender());
        } catch (IOException | RuntimeException failure) { throw unavailable(); }
    }

    @Override public void abandon(int sessionId) throws IOException {
        try {
            if (!ownedSessionIds().contains(sessionId)) return;
            installer.abandonSession(sessionId);
        } catch (RuntimeException failure) { throw unavailable(); }
    }

    @Override public Set<Integer> ownedSessionIds() throws IOException {
        try {
            List<PackageInstaller.SessionInfo> sessions = installer.getMySessions();
            if (sessions == null || sessions.size() > MAX_OS_SESSIONS) throw unavailable();
            Set<Integer> result = new HashSet<>();
            for (PackageInstaller.SessionInfo info : sessions) {
                if (info == null || info.getSessionId() < 0
                        || !context.getPackageName().equals(info.getInstallerPackageName())
                        || !result.add(info.getSessionId())) throw unavailable();
            }
            return result;
        } catch (RuntimeException failure) { throw unavailable(); }
    }

    /** The receiver is non-exported; the private nonce additionally binds the exact operation. */
    String receive(Intent intent, ApkInstallManager manager) {
        try {
            if (intent == null || !ACTION_RESULT.equals(intent.getAction())) return null;
            String data = intent.getDataString();
            if (data == null || data.length() > 160) return null;
            Uri uri = intent.getData();
            if (uri == null || !RESULT_SCHEME.equals(uri.getScheme())
                    || !"callback".equals(uri.getAuthority()) || uri.getQuery() != null
                    || uri.getFragment() != null || uri.getPathSegments().size() != 2) return null;
            String id = uri.getPathSegments().get(0);
            String encoded = uri.getPathSegments().get(1);
            if (!ApkInstallPolicy.validId(id) || encoded.length() != 43) return null;
            byte[] callback = Base64.getUrlDecoder().decode(encoded);
            if (callback.length != 32 || !data.equals(callbackUri(id, callback).toString())) return null;
            int sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1);
            int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Integer.MIN_VALUE);
            if (sessionId < 0 || status == Integer.MIN_VALUE) return null;
            ApkInstallManager.PlatformResult result = result(status);
            Intent confirmation = null;
            if (result == ApkInstallManager.PlatformResult.PENDING_USER_ACTION) {
                try { confirmation = confirmation(intent); } catch (RuntimeException invalid) { confirmation = null; }
                if (confirmation == null) result = ApkInstallManager.PlatformResult.UNCERTAIN;
            }
            if (!manager.platformResult(id, sessionId, callback, result)) return null;
            synchronized (confirmations) {
                if (confirmation != null) {
                    confirmations.put(id, new Intent(confirmation));
                    while (confirmations.size() > ApkInstallPolicy.MAX_RECORDS) {
                        confirmations.remove(confirmations.keySet().iterator().next());
                    }
                } else if (result != ApkInstallManager.PlatformResult.UNCERTAIN) {
                    confirmations.remove(id);
                }
            }
            return id;
        } catch (RuntimeException invalid) { return null; }
    }

    boolean hasConfirmation(String id) {
        synchronized (confirmations) { return confirmations.containsKey(id); }
    }

    boolean launchConfirmation(Activity activity, String id) {
        Intent intent;
        synchronized (confirmations) { intent = confirmations.get(id); }
        if (intent == null || activity.isFinishing() || activity.isDestroyed()) return false;
        try { activity.startActivity(new Intent(intent)); return true; }
        catch (RuntimeException unavailable) { return false; }
    }

    void forgetConfirmation(String id) {
        synchronized (confirmations) { confirmations.remove(id); }
    }

    @SuppressWarnings("deprecation")
    private static Intent confirmation(Intent result) {
        if (Build.VERSION.SDK_INT >= 33) return result.getParcelableExtra(Intent.EXTRA_INTENT, Intent.class);
        Object value = result.getParcelableExtra(Intent.EXTRA_INTENT);
        return value instanceof Intent ? (Intent) value : null;
    }

    private static Uri callbackUri(String id, byte[] key) {
        return new Uri.Builder().scheme(RESULT_SCHEME).authority("callback")
                .appendPath(id).appendPath(Base64.getUrlEncoder().withoutPadding().encodeToString(key)).build();
    }

    private static ApkInstallManager.PlatformResult result(int status) {
        switch (status) {
            case PackageInstaller.STATUS_PENDING_USER_ACTION: return ApkInstallManager.PlatformResult.PENDING_USER_ACTION;
            case PackageInstaller.STATUS_SUCCESS: return ApkInstallManager.PlatformResult.SUCCESS;
            case PackageInstaller.STATUS_FAILURE_ABORTED: return ApkInstallManager.PlatformResult.CANCELLED;
            case PackageInstaller.STATUS_FAILURE_INVALID: return ApkInstallManager.PlatformResult.INVALID;
            case PackageInstaller.STATUS_FAILURE_BLOCKED: return ApkInstallManager.PlatformResult.DENIED;
            case PackageInstaller.STATUS_FAILURE_STORAGE: return ApkInstallManager.PlatformResult.STORAGE;
            case PackageInstaller.STATUS_FAILURE_CONFLICT: return ApkInstallManager.PlatformResult.CONFLICT;
            case PackageInstaller.STATUS_FAILURE_INCOMPATIBLE: return ApkInstallManager.PlatformResult.INCOMPATIBLE;
            case PackageInstaller.STATUS_FAILURE: return ApkInstallManager.PlatformResult.FAILURE;
            default: return ApkInstallManager.PlatformResult.UNCERTAIN;
        }
    }

    private void requireSource() throws IOException {
        if (!sourceTrusted()) throw unavailable();
    }
    private static IOException unavailable() { return new IOException("system installation is unavailable"); }

    private static final class SessionSink implements Sink {
        private final PackageInstaller.Session session;
        private final OutputStream output;
        private boolean closed;
        SessionSink(PackageInstaller.Session session, OutputStream output) {
            this.session = session;
            this.output = output;
        }
        @Override public OutputStream stream() { return output; }
        @Override public void sync() throws IOException {
            try { session.fsync(output); } catch (RuntimeException failure) { throw unavailable(); }
        }
        @Override public void close() throws IOException {
            if (closed) return;
            closed = true;
            try { output.close(); }
            finally { try { session.close(); } catch (RuntimeException failure) { throw unavailable(); } }
        }
    }
}
