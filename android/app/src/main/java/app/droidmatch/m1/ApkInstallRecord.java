package app.droidmatch.m1;

import app.droidmatch.proto.v1.ApkInstallOperation;
import app.droidmatch.proto.v1.ApkInstallState;
import app.droidmatch.proto.v1.ErrorCode;

import java.util.Arrays;

/** Immutable private journal record. Only toWire() is a remote projection. */
final class ApkInstallRecord {
    final String id;
    final String displayName;
    final InstallOwner owner;
    final int sessionId;
    final long size;
    final long uploaded;
    final byte[] digest;
    final byte[] callbackKey;
    final ApkInstallState state;
    final ErrorCode failure;
    final boolean dismissedUnknown;

    ApkInstallRecord(String id, String displayName, InstallOwner owner, int sessionId,
            long size, long uploaded, byte[] digest, byte[] callbackKey,
            ApkInstallState state, ErrorCode failure, boolean dismissedUnknown) {
        if (!ApkInstallPolicy.validId(id) || owner == null || sessionId < 0
                || size < 1 || size > ApkInstallPolicy.MAX_BYTES || uploaded < 0 || uploaded > size
                || digest == null || digest.length != 32 || callbackKey == null || callbackKey.length != 32
                || state == null || state == ApkInstallState.UNRECOGNIZED
                || state == ApkInstallState.APK_INSTALL_STATE_UNSPECIFIED
                || failure == null || failure == ErrorCode.UNRECOGNIZED
                || (dismissedUnknown && state != ApkInstallState.APK_INSTALL_STATE_OUTCOME_UNKNOWN)) {
            throw new IllegalArgumentException("installation record is invalid");
        }
        try {
            if (!ApkInstallPolicy.displayName(displayName).equals(displayName)) {
                throw new IllegalArgumentException("installation display name is invalid");
            }
        } catch (DmFileProvider.ProviderCatalogException invalid) {
            throw new IllegalArgumentException("installation display name is invalid");
        }
        if (state == ApkInstallState.APK_INSTALL_STATE_WAITING_FOR_UPLOAD && uploaded != 0) {
            throw new IllegalArgumentException("installation progress is invalid");
        }
        boolean validated = state == ApkInstallState.APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL
                || state == ApkInstallState.APK_INSTALL_STATE_SUBMITTING
                || state == ApkInstallState.APK_INSTALL_STATE_WAITING_FOR_SYSTEM_CONFIRMATION
                || state == ApkInstallState.APK_INSTALL_STATE_INSTALLING
                || state == ApkInstallState.APK_INSTALL_STATE_SUCCEEDED
                || state == ApkInstallState.APK_INSTALL_STATE_OUTCOME_UNKNOWN;
        if (validated && uploaded != size) {
            throw new IllegalArgumentException("installation validation state is invalid");
        }
        boolean failed = state == ApkInstallState.APK_INSTALL_STATE_FAILED
                || state == ApkInstallState.APK_INSTALL_STATE_CANCELLED
                || state == ApkInstallState.APK_INSTALL_STATE_OUTCOME_UNKNOWN
                || state == ApkInstallState.APK_INSTALL_STATE_CLEANUP_REQUIRED;
        if (failed == (failure == ErrorCode.ERROR_CODE_UNSPECIFIED)
                || (state == ApkInstallState.APK_INSTALL_STATE_CANCELLED
                && failure != ErrorCode.ERROR_CODE_CANCELLED)) {
            throw new IllegalArgumentException("installation result state is invalid");
        }
        this.id = id;
        this.displayName = displayName;
        this.owner = owner;
        this.sessionId = sessionId;
        this.size = size;
        this.uploaded = uploaded;
        this.digest = Arrays.copyOf(digest, digest.length);
        this.callbackKey = Arrays.copyOf(callbackKey, callbackKey.length);
        this.state = state;
        this.failure = failure;
        this.dismissedUnknown = dismissedUnknown;
    }

    ApkInstallRecord transition(ApkInstallState state, long uploaded, ErrorCode failure) {
        return new ApkInstallRecord(id, displayName, owner, sessionId, size, uploaded,
                digest, callbackKey, state, failure, false);
    }

    ApkInstallRecord dismissUnknown() {
        return new ApkInstallRecord(id, displayName, owner, sessionId, size, uploaded,
                digest, callbackKey, state, failure, true);
    }

    boolean active() { return !ApkInstallPolicy.terminal(state) && !dismissedUnknown; }

    ApkInstallOperation toWire() {
        return ApkInstallOperation.newBuilder().setOperationId(id).setDisplayName(displayName)
                .setSizeBytes(size).setUploadedBytes(uploaded).setState(state)
                .setFailureCode(failure).build();
    }

    @Override public String toString() { return "ApkInstallRecord[redacted]"; }
}
