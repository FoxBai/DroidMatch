package app.droidmatch.m1;

import app.droidmatch.proto.v1.ApkInstallOperation;
import app.droidmatch.proto.v1.ApkInstallState;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListApkInstallsResponse;
import app.droidmatch.proto.v1.PrepareApkInstallRequest;
import app.droidmatch.proto.v1.PrepareApkInstallResponse;

import java.io.IOException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static app.droidmatch.m1.ApkInstallPolicy.error;
import static app.droidmatch.proto.v1.ApkInstallState.*;

/** Serial owner of installation admission, journal transitions and OS-session lifetimes. */
final class ApkInstallManager {
    enum PlatformResult {
        PENDING_USER_ACTION, SUCCESS, CANCELLED, INVALID, DENIED, STORAGE,
        CONFLICT, INCOMPATIBLE, UNCERTAIN, FAILURE
    }

    private final ApkInstallBackend backend;
    private final ApkInstallJournal journal;
    private final ApkInstallAccess access;
    private final SecureRandom random;
    private final LinkedHashMap<String, ApkInstallRecord> records = new LinkedHashMap<>();
    private final Map<String, Long> grants = new HashMap<>();
    private final Map<String, ApkInstallUploadWriter> writers = new HashMap<>();
    private boolean healthy;
    private boolean untrackedSessions;

    ApkInstallManager(ApkInstallBackend backend, ApkInstallJournal journal,
            ApkInstallAccess access, SecureRandom random) {
        this.backend = backend;
        this.journal = journal;
        this.access = access;
        this.random = random;
        restore();
    }

    private void restore() {
        try {
            List<ApkInstallRecord> loaded = journal.load();
            // The codec also validates this boundary; injected stores cannot bypass it.
            loaded = ApkInstallJournalCodec.decode(ApkInstallJournalCodec.encode(loaded));
            for (ApkInstallRecord record : loaded) records.put(record.id, record);
            healthy = true;
            for (ApkInstallRecord record : new ArrayList<>(records.values())) {
                if (ApkInstallPolicy.unsubmitted(record.state)) {
                    abandon(record, ErrorCode.ERROR_CODE_TRANSPORT_LOST);
                } else if (record.active()) {
                    persist(record.transition(APK_INSTALL_STATE_OUTCOME_UNKNOWN,
                            record.size, ErrorCode.ERROR_CODE_INTERNAL));
                }
            }
            refreshUntracked();
        } catch (IOException | RuntimeException | DmFileProvider.ProviderCatalogException failure) {
            healthy = false;
            access.disable();
        }
    }

    synchronized PrepareApkInstallResponse prepare(InstallOwner owner, PrepareApkInstallRequest request)
            throws DmFileProvider.ProviderCatalogException {
        requireOwner(owner);
        requireHealthy();
        long grant = requireAdmission();
        if (!ApkInstallPolicy.validId(request.getOperationId()) || request.getSizeBytes() < 1
                || request.getSizeBytes() > ApkInstallPolicy.MAX_BYTES || request.getSha256().size() != 32) {
            throw ApkInstallPolicy.invalid();
        }
        String displayName = ApkInstallPolicy.displayName(request.getDisplayName());
        byte[] digest = request.getSha256().toByteArray();
        ApkInstallRecord existing = records.get(request.getOperationId());
        if (existing != null) {
            if (!existing.owner.equals(owner)) throw missing();
            if (existing.size != request.getSizeBytes() || !existing.displayName.equals(displayName)
                    || !MessageDigest.isEqual(existing.digest, digest)) throw ApkInstallPolicy.invalid();
            return prepared(existing);
        }
        refreshUntracked();
        if (untrackedSessions || hasActive()) {
            throw error(ErrorCode.ERROR_CODE_ALREADY_EXISTS, "an installation needs attention on Android");
        }
        byte[] callback = new byte[32];
        random.nextBytes(callback);
        int sessionId = -1;
        try {
            sessionId = backend.create(request.getSizeBytes());
            ApkInstallRecord record = new ApkInstallRecord(request.getOperationId(), displayName,
                    owner, sessionId, request.getSizeBytes(), 0, digest, callback,
                    APK_INSTALL_STATE_WAITING_FOR_UPLOAD, ErrorCode.ERROR_CODE_UNSPECIFIED, false);
            persist(record);
            grants.put(record.id, grant);
            // Revocation may run while the OS allocation or journal save was in progress.
            if (!access.permits(grant)) {
                abandon(record, ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
                throw permission();
            }
            return prepared(record);
        } catch (IOException | RuntimeException failure) {
            if (sessionId >= 0) {
                try { backend.abandon(sessionId); } catch (IOException | RuntimeException ignored) {
                    untrackedSessions = true;
                }
            }
            throw internal();
        } catch (DmFileProvider.ProviderCatalogException failure) {
            if ((!healthy || !records.containsKey(request.getOperationId())) && sessionId >= 0) {
                try { backend.abandon(sessionId); } catch (IOException | RuntimeException ignored) {
                    untrackedSessions = true;
                }
            }
            throw failure;
        }
    }

    synchronized ListApkInstallsResponse list(InstallOwner owner)
            throws DmFileProvider.ProviderCatalogException {
        requireOwner(owner);
        requireHealthy();
        reconcilePendingOutcomes();
        ListApkInstallsResponse.Builder response = ListApkInstallsResponse.newBuilder()
                .setIncomingRequestsEnabled(access.currentGrant() >= 0)
                .setSystemSourceTrusted(sourceTrusted())
                .setCanStartInstall(canStart());
        for (ApkInstallRecord record : records.values()) {
            if (record.owner.equals(owner)) response.addOperations(record.toWire());
        }
        return response.build();
    }

    /** Session absence never proves success, even while this process stays alive. */
    synchronized void reconcilePendingOutcomes() throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        try {
            Set<Integer> sessions = backend.ownedSessionIds();
            for (ApkInstallRecord record : new ArrayList<>(records.values())) {
                if (record.active() && !ApkInstallPolicy.unsubmitted(record.state)
                        && record.state != APK_INSTALL_STATE_OUTCOME_UNKNOWN
                        && !sessions.contains(record.sessionId)) {
                    persist(record.transition(APK_INSTALL_STATE_OUTCOME_UNKNOWN,
                            record.size, ErrorCode.ERROR_CODE_INTERNAL));
                }
            }
        } catch (IOException | RuntimeException failure) { throw internal(); }
    }

    synchronized void markUnansweredSubmission(String id) throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        ApkInstallRecord record = records.get(id);
        if (record != null && record.state == APK_INSTALL_STATE_SUBMITTING) {
            persist(record.transition(APK_INSTALL_STATE_OUTCOME_UNKNOWN,
                    record.size, ErrorCode.ERROR_CODE_INTERNAL));
        }
    }

    synchronized List<ApkInstallOperation> androidOperations() {
        List<ApkInstallOperation> result = new ArrayList<>();
        if (healthy) for (ApkInstallRecord record : records.values()) result.add(record.toWire());
        return result;
    }

    synchronized boolean healthy() { return healthy; }
    synchronized boolean needsUntrackedCleanup() { return untrackedSessions; }
    synchronized boolean unknownDismissed(String id) {
        ApkInstallRecord record = records.get(id);
        return record != null && record.dismissedUnknown;
    }
    synchronized boolean canStart() {
        return healthy && !untrackedSessions && !hasActive()
                && access.currentGrant() >= 0 && sourceTrusted() && supported();
    }

    synchronized ApkInstallOperation cancel(InstallOwner owner, String id)
            throws DmFileProvider.ProviderCatalogException {
        requireOwner(owner);
        requireHealthy();
        ApkInstallRecord record = owned(owner, id);
        if (ApkInstallPolicy.terminal(record.state)) return record.toWire();
        if (!ApkInstallPolicy.unsubmitted(record.state)) {
            throw error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "submitted installation must be resolved on Android");
        }
        abandon(record, ErrorCode.ERROR_CODE_CANCELLED);
        return records.get(id).toWire();
    }

    synchronized void cancelOnAndroid(String id) throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        ApkInstallRecord record = records.get(id);
        if (record == null) throw missing();
        cancel(record.owner, id);
    }

    synchronized DmFileProvider.UploadWriter openUpload(InstallOwner owner, String path,
            String transferId, long offset, long expectedSize)
            throws DmFileProvider.ProviderCatalogException {
        requireOwner(owner);
        requireHealthy();
        ApkInstallRecord record = owned(owner, ApkInstallPolicy.destinationId(path));
        requireGrant(record);
        if (!record.id.equals(transferId) || offset != 0 || expectedSize != record.size) {
            throw ApkInstallPolicy.invalid();
        }
        if (record.state != APK_INSTALL_STATE_WAITING_FOR_UPLOAD || writers.containsKey(record.id)) {
            throw error(ErrorCode.ERROR_CODE_ALREADY_EXISTS, "installation upload is not available");
        }
        ApkInstallBackend.Sink sink = null;
        try {
            sink = backend.openUpload(record.sessionId, record.size);
            persist(record.transition(APK_INSTALL_STATE_UPLOADING, 0, ErrorCode.ERROR_CODE_UNSPECIFIED));
            ApkInstallUploadWriter writer = new ApkInstallUploadWriter(this, record.id, sink);
            writers.put(record.id, writer);
            return writer;
        } catch (IOException | RuntimeException failure) {
            closeSink(sink);
            abandon(record, ErrorCode.ERROR_CODE_INTERNAL);
            throw internal();
        } catch (DmFileProvider.ProviderCatalogException failure) {
            closeSink(sink);
            throw failure;
        }
    }

    synchronized long nextOffset(ApkInstallUploadWriter writer) { return writer.offset; }

    synchronized void write(ApkInstallUploadWriter writer, long offset, byte[] data, boolean last)
            throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        ApkInstallRecord record = records.get(writer.id);
        if (writer.closed || record == null || writers.get(writer.id) != writer
                || record.state != APK_INSTALL_STATE_UPLOADING) throw ApkInstallPolicy.invalid();
        try {
            requireGrant(record);
            long next = ProviderUploadWriters.validatedNextOffset(false, writer.offset,
                    record.size, offset, data, last);
            writer.sink.stream().write(data);
            writer.digest.update(data);
            writer.offset = next;
            records.put(record.id, record.transition(APK_INSTALL_STATE_UPLOADING, next,
                    ErrorCode.ERROR_CODE_UNSPECIFIED));
            if (last) {
                writer.sink.sync();
                writer.sink.close();
                writer.closed = true;
                if (!MessageDigest.isEqual(writer.digest.digest(), record.digest)) {
                    throw error(ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH, "APK transfer digest does not match");
                }
                requireGrant(record);
                persist(record.transition(APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL,
                        record.size, ErrorCode.ERROR_CODE_UNSPECIFIED));
                writers.remove(record.id);
            }
        } catch (IOException | RuntimeException failure) {
            abandon(records.get(record.id), ErrorCode.ERROR_CODE_INTERNAL);
            throw internal();
        } catch (DmFileProvider.ProviderCatalogException failure) {
            if (healthy) abandon(records.get(record.id), failure.code);
            else closeWriterSink(writer);
            throw failure;
        }
    }

    synchronized void closeWriter(ApkInstallUploadWriter writer) {
        if (writers.get(writer.id) != writer) return;
        try {
            if (healthy) abandon(records.get(writer.id), ErrorCode.ERROR_CODE_TRANSPORT_LOST);
            else closeWriterSink(writer);
        } catch (DmFileProvider.ProviderCatalogException ignored) {
            // Cleanup uncertainty stays in the journal; close cannot claim success.
        }
    }

    synchronized void cancelWriter(ApkInstallUploadWriter writer)
            throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        ApkInstallRecord record = records.get(writer.id);
        if (record == null || ApkInstallPolicy.terminal(record.state)) return;
        // A prior failed cancel removed the sink but retained cleanup ownership.
        // Retrying that same writer must verify cleanup instead of returning success.
        if (!ApkInstallPolicy.unsubmitted(record.state)) throw ApkInstallPolicy.invalid();
        abandon(record, ErrorCode.ERROR_CODE_CANCELLED);
    }

    /** Called only from the visible Android action, never from RPC routing. */
    synchronized void approveOnAndroid(String id) throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        ApkInstallRecord record = records.get(id);
        if (record == null) throw missing();
        requireGrant(record);
        if (record.state != APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL) throw ApkInstallPolicy.invalid();
        persist(record.transition(APK_INSTALL_STATE_SUBMITTING, record.size, ErrorCode.ERROR_CODE_UNSPECIFIED));
        if (!supported() || !sourceTrusted()
                || !access.admitSubmission(grants.getOrDefault(id, -1L))) {
            abandon(records.get(id), ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
            throw permission();
        }
        try {
            backend.submit(record.sessionId, record.id, record.callbackKey.clone());
        } catch (IOException | RuntimeException failure) {
            ApkInstallRecord current = records.get(id);
            if (!ApkInstallPolicy.terminal(current.state)) {
                persist(current.transition(APK_INSTALL_STATE_OUTCOME_UNKNOWN,
                        current.size, ErrorCode.ERROR_CODE_INTERNAL));
            }
            throw internal();
        }
    }

    synchronized boolean platformResult(String id, int sessionId, byte[] callbackKey, PlatformResult result) {
        ApkInstallRecord record = records.get(id);
        // A dismissed unknown may settle, but must not take a newer request's active slot.
        // 中文：已处理的旧未知结果可接受终态，但不能被迟到回调重新激活。
        if (!healthy || result == null || record == null || record.sessionId != sessionId || callbackKey == null
                || callbackKey.length != 32 || !MessageDigest.isEqual(record.callbackKey, callbackKey)
                || ApkInstallPolicy.unsubmitted(record.state) || ApkInstallPolicy.terminal(record.state)
                || (record.dismissedUnknown && (result == PlatformResult.PENDING_USER_ACTION
                    || result == PlatformResult.UNCERTAIN))) return false;
        ApkInstallState state;
        ErrorCode failure = ErrorCode.ERROR_CODE_UNSPECIFIED;
        switch (result) {
            case PENDING_USER_ACTION: state = APK_INSTALL_STATE_WAITING_FOR_SYSTEM_CONFIRMATION; break;
            case SUCCESS: state = APK_INSTALL_STATE_SUCCEEDED; break;
            case CANCELLED: state = APK_INSTALL_STATE_CANCELLED; failure = ErrorCode.ERROR_CODE_CANCELLED; break;
            case INVALID: state = APK_INSTALL_STATE_FAILED; failure = ErrorCode.ERROR_CODE_INVALID_ARGUMENT; break;
            case DENIED: state = APK_INSTALL_STATE_FAILED; failure = ErrorCode.ERROR_CODE_PERMISSION_REQUIRED; break;
            case STORAGE: state = APK_INSTALL_STATE_FAILED; failure = ErrorCode.ERROR_CODE_INTERNAL; break;
            case CONFLICT: state = APK_INSTALL_STATE_FAILED; failure = ErrorCode.ERROR_CODE_ALREADY_EXISTS; break;
            case INCOMPATIBLE: state = APK_INSTALL_STATE_FAILED; failure = ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY; break;
            case UNCERTAIN: state = APK_INSTALL_STATE_OUTCOME_UNKNOWN; failure = ErrorCode.ERROR_CODE_INTERNAL; break;
            default: state = APK_INSTALL_STATE_FAILED; failure = ErrorCode.ERROR_CODE_INTERNAL;
        }
        try {
            persist(record.transition(state, record.size, failure));
            return true;
        } catch (DmFileProvider.ProviderCatalogException unavailable) { return false; }
    }

    synchronized void confirmationLaunched(String id) throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        ApkInstallRecord record = records.get(id);
        if (record != null && (record.state == APK_INSTALL_STATE_WAITING_FOR_SYSTEM_CONFIRMATION
                || (record.state == APK_INSTALL_STATE_OUTCOME_UNKNOWN && !record.dismissedUnknown))) {
            persist(record.transition(APK_INSTALL_STATE_INSTALLING, record.size, ErrorCode.ERROR_CODE_UNSPECIFIED));
        }
    }

    /** Immediate revocation uses ApkInstallAccess; cleanup may wait for a bounded chunk write. */
    synchronized void cleanInvalidGrants() throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        for (ApkInstallRecord record : new ArrayList<>(records.values())) {
            if (ApkInstallPolicy.unsubmitted(record.state)
                    && !access.permits(grants.getOrDefault(record.id, -1L))) {
                abandon(record, ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
            }
        }
    }

    /** A phone-side acknowledgement of an unknown outcome; it never labels an install successful. */
    synchronized void dismissUnknownOnAndroid(String id) throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        ApkInstallRecord record = records.get(id);
        if (record == null || record.state != APK_INSTALL_STATE_OUTCOME_UNKNOWN) throw ApkInstallPolicy.invalid();
        try {
            if (backend.ownedSessionIds().contains(record.sessionId)) backend.abandon(record.sessionId);
            if (backend.ownedSessionIds().contains(record.sessionId)) throw internal();
            persist(record.dismissUnknown());
        } catch (IOException | RuntimeException failure) { throw internal(); }
    }

    synchronized void cleanUntrackedOnAndroid() throws DmFileProvider.ProviderCatalogException {
        requireHealthy();
        try {
            Set<Integer> untracked = new HashSet<>(backend.ownedSessionIds());
            for (ApkInstallRecord record : records.values()) untracked.remove(record.sessionId);
            for (int id : untracked) backend.abandon(id);
            refreshUntracked();
        } catch (IOException | RuntimeException failure) { throw internal(); }
    }

    private void abandon(ApkInstallRecord record, ErrorCode reason)
            throws DmFileProvider.ProviderCatalogException {
        ApkInstallUploadWriter writer = writers.remove(record.id);
        closeWriterSink(writer);
        // Persist cleanup ownership before touching the OS session; a crash retries only this session.
        persist(record.transition(APK_INSTALL_STATE_CLEANUP_REQUIRED, record.uploaded, reason));
        try {
            if (backend.ownedSessionIds().contains(record.sessionId)) backend.abandon(record.sessionId);
            if (backend.ownedSessionIds().contains(record.sessionId)) throw internal();
            ApkInstallState terminal = reason == ErrorCode.ERROR_CODE_CANCELLED
                    ? APK_INSTALL_STATE_CANCELLED : APK_INSTALL_STATE_FAILED;
            persist(record.transition(terminal, record.uploaded, reason));
            grants.remove(record.id);
        } catch (IOException | RuntimeException failure) { throw internal(); }
    }

    private void persist(ApkInstallRecord replacement) throws DmFileProvider.ProviderCatalogException {
        LinkedHashMap<String, ApkInstallRecord> next = new LinkedHashMap<>(records);
        if (!next.containsKey(replacement.id)) {
            next.entrySet().removeIf(entry -> !entry.getValue().active()
                    && entry.getValue().sessionId == replacement.sessionId);
        }
        next.put(replacement.id, replacement);
        while (next.size() > ApkInstallPolicy.MAX_RECORDS) {
            String removable = null;
            for (ApkInstallRecord record : next.values()) {
                if (!record.id.equals(replacement.id) && !record.active()) { removable = record.id; break; }
            }
            if (removable == null) throw internal();
            next.remove(removable);
        }
        try { journal.save(new ArrayList<>(next.values())); }
        catch (IOException | RuntimeException failure) {
            healthy = false;
            access.disable();
            throw internal();
        }
        records.clear();
        records.putAll(next);
        grants.keySet().retainAll(records.keySet());
    }

    private PrepareApkInstallResponse prepared(ApkInstallRecord record) {
        PrepareApkInstallResponse.Builder response = PrepareApkInstallResponse.newBuilder().setOperation(record.toWire());
        if (record.state == APK_INSTALL_STATE_WAITING_FOR_UPLOAD) {
            response.setUploadDestination(ApkInstallPolicy.destination(record.id));
        }
        return response.build();
    }

    private void refreshUntracked() throws DmFileProvider.ProviderCatalogException {
        try {
            Set<Integer> ids = new HashSet<>(backend.ownedSessionIds());
            for (ApkInstallRecord record : records.values()) ids.remove(record.sessionId);
            untrackedSessions = !ids.isEmpty();
        } catch (IOException | RuntimeException failure) { throw internal(); }
    }

    private ApkInstallRecord owned(InstallOwner owner, String id) throws DmFileProvider.ProviderCatalogException {
        if (!ApkInstallPolicy.validId(id)) throw ApkInstallPolicy.invalid();
        ApkInstallRecord record = records.get(id);
        if (record == null || !record.owner.equals(owner)) throw missing();
        return record;
    }

    private void requireGrant(ApkInstallRecord record) throws DmFileProvider.ProviderCatalogException {
        if (!access.permits(grants.getOrDefault(record.id, -1L)) || !sourceTrusted() || !supported()) {
            throw permission();
        }
    }

    private long requireAdmission() throws DmFileProvider.ProviderCatalogException {
        if (!supported()) {
            throw error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, "system-confirmed installation is unavailable");
        }
        long grant = access.currentGrant();
        if (grant < 0 || !sourceTrusted()) throw permission();
        return grant;
    }

    private boolean sourceTrusted() {
        try { return backend.sourceTrusted(); } catch (RuntimeException unavailable) { return false; }
    }
    private boolean supported() {
        try { return backend.supported(); } catch (RuntimeException unavailable) { return false; }
    }
    private boolean hasActive() { for (ApkInstallRecord record : records.values()) if (record.active()) return true; return false; }
    private void requireHealthy() throws DmFileProvider.ProviderCatalogException { if (!healthy) throw internal(); }
    private void requireOwner(InstallOwner owner) throws DmFileProvider.ProviderCatalogException {
        if (owner == null) throw error(ErrorCode.ERROR_CODE_UNAUTHORIZED, "paired installation authentication is required");
    }
    private void closeWriterSink(ApkInstallUploadWriter writer) {
        if (writer == null) return;
        writer.closed = true;
        closeSink(writer.sink);
    }
    private static void closeSink(ApkInstallBackend.Sink sink) {
        if (sink != null) try { sink.close(); } catch (IOException | RuntimeException ignored) { }
    }
    private static DmFileProvider.ProviderCatalogException missing() { return error(ErrorCode.ERROR_CODE_NOT_FOUND, "installation operation is unavailable"); }
    private static DmFileProvider.ProviderCatalogException permission() { return error(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "enable APK installation requests on Android"); }
    private static DmFileProvider.ProviderCatalogException internal() { return error(ErrorCode.ERROR_CODE_INTERNAL, "installation state is unavailable"); }
}
