package app.droidmatch.m1;

import app.droidmatch.proto.v1.ApkInstallOperation;
import app.droidmatch.proto.v1.ApkInstallState;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PrepareApkInstallRequest;

import app.droidmatch.proto.v1.CancelApkInstallRequest;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ListApkInstallsResponse;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PrepareApkInstallResponse;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferChunkAck;
import app.droidmatch.proto.v1.TransferDirection;
import com.google.protobuf.ByteString;
import org.junit.Test;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import static app.droidmatch.proto.v1.ApkInstallState.*;
import static org.junit.Assert.*;

public final class ApkInstallManagerTest {
    private static final String ID = "11111111-1111-4111-8111-111111111111";
    private static final String OTHER_ID = "22222222-2222-4222-8222-222222222222";
    private static final byte[] BYTES = {1, 2, 3, 4};

    @Test public void onlyAuthenticatedOwnerCanSeeOrUploadAnOperation() throws Exception {
        Fixture fixture = new Fixture();
        expect(ErrorCode.ERROR_CODE_UNAUTHORIZED, () -> fixture.manager.prepare(null, request(ID)));
        assertEquals(0, fixture.backend.nextSession);
        fixture.prepare(ID);
        assertEquals(0, fixture.manager.list(owner(2)).getOperationsCount());
        expect(ErrorCode.ERROR_CODE_NOT_FOUND, () -> fixture.manager.openUpload(owner(2),
                ApkInstallPolicy.destination(ID), ID, 0, BYTES.length));
        expect(ErrorCode.ERROR_CODE_NOT_FOUND, () -> fixture.manager.cancel(owner(2), ID));
        assertEquals(0, fixture.backend.opened);
        assertFalse(fixture.journal.records.get(0).toString().contains("fixture.apk"));
        assertEquals("InstallOwner[redacted]", owner(1).toString());
        fixture.writer(ID).close();
    }

    @Test public void wrongDigestAndInterruptedBytesNeverBecomeApprovable() throws Exception {
        Fixture fixture = new Fixture();
        fixture.prepare(ID);
        DmFileProvider.UploadWriter writer = fixture.writer(ID);
        expect(ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH,
                () -> writer.writeChunk(0, new byte[]{1, 2, 3, 5}, true));
        assertEquals(APK_INSTALL_STATE_FAILED, fixture.operation(ID).getState());
        assertEquals(ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH, fixture.operation(ID).getFailureCode());
        assertTrue(fixture.backend.sessions.isEmpty());
        fixture.prepare(OTHER_ID);
        DmFileProvider.UploadWriter partial = fixture.writer(OTHER_ID);
        partial.writeChunk(0, new byte[]{1}, false);
        partial.close();
        assertEquals(APK_INSTALL_STATE_FAILED, fixture.operation(OTHER_ID).getState());
        assertEquals(ErrorCode.ERROR_CODE_TRANSPORT_LOST, fixture.operation(OTHER_ID).getFailureCode());
        assertEquals(0, fixture.backend.submitted);
        assertTrue(fixture.backend.sessions.isEmpty());
    }

    @Test public void failedOrRevokedCommitIntentCannotReachTheSystemInstaller() throws Exception {
        Fixture failed = new Fixture();
        failed.ready();
        failed.journal.failSubmitting = true;
        expect(ErrorCode.ERROR_CODE_INTERNAL, () -> failed.manager.approveOnAndroid(ID));
        assertEquals(0, failed.backend.submitted);
        assertFalse(failed.manager.healthy());
        assertFalse(failed.manager.canStart());

        Fixture revoked = new Fixture();
        revoked.ready();
        revoked.journal.onSubmitting = revoked.access::disable;
        expect(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, () -> revoked.manager.approveOnAndroid(ID));
        assertEquals(0, revoked.backend.submitted);
        assertEquals(APK_INSTALL_STATE_FAILED, revoked.operation(ID).getState());
        assertTrue(revoked.backend.sessions.isEmpty());
    }

    @Test public void restartAndMissingSessionDoNotInventSuccessOrRepeatSubmission() throws Exception {
        Fixture fixture = new Fixture();
        fixture.ready();
        fixture.backend.onSubmit = () -> assertEquals(APK_INSTALL_STATE_SUBMITTING,
                fixture.journal.records.get(0).state);
        fixture.manager.approveOnAndroid(ID);
        ApkInstallRecord saved = fixture.journal.records.get(0);
        byte[] wrongCallback = saved.callbackKey.clone();
        wrongCallback[0] ^= 1;
        assertFalse(fixture.manager.platformResult(ID, saved.sessionId, wrongCallback,
                ApkInstallManager.PlatformResult.SUCCESS));
        assertFalse(fixture.manager.platformResult(ID, saved.sessionId + 1, saved.callbackKey,
                ApkInstallManager.PlatformResult.SUCCESS));
        assertTrue(fixture.manager.platformResult(ID, saved.sessionId, saved.callbackKey,
                ApkInstallManager.PlatformResult.PENDING_USER_ACTION));
        fixture.manager.confirmationLaunched(ID);
        fixture.backend.sessions.clear();

        ApkInstallManager restored = new ApkInstallManager(fixture.backend, fixture.journal,
                new ApkInstallAccess(), new SecureRandom());
        assertEquals(APK_INSTALL_STATE_OUTCOME_UNKNOWN, restored.list(owner(1)).getOperations(0).getState());
        assertEquals(1, fixture.backend.submitted);
        assertTrue(restored.platformResult(ID, saved.sessionId, saved.callbackKey,
                ApkInstallManager.PlatformResult.SUCCESS));
        assertEquals(APK_INSTALL_STATE_SUCCEEDED, restored.list(owner(1)).getOperations(0).getState());
        assertFalse(restored.platformResult(ID, saved.sessionId, saved.callbackKey,
                ApkInstallManager.PlatformResult.FAILURE));
        assertEquals(0, restored.list(owner(2)).getOperationsCount());
    }

    @Test public void failedWriterCancellationRemainsRetryableUntilCleanupIsVerified() throws Exception {
        Fixture fixture = new Fixture();
        fixture.prepare(ID);
        DmFileProvider.UploadWriter writer = fixture.writer(ID);
        writer.writeChunk(0, new byte[]{1}, false);
        fixture.backend.failAbandonOnce = true;
        expect(ErrorCode.ERROR_CODE_INTERNAL, writer::cancel);
        assertEquals(APK_INSTALL_STATE_CLEANUP_REQUIRED, fixture.operation(ID).getState());
        assertFalse(fixture.backend.sessions.isEmpty());
        writer.cancel();
        assertEquals(APK_INSTALL_STATE_CANCELLED, fixture.operation(ID).getState());
        assertTrue(fixture.backend.sessions.isEmpty());
        assertEquals(2, fixture.backend.abandoned.size());
        assertEquals(fixture.backend.abandoned.get(0), fixture.backend.abandoned.get(1));
    }

    @Test public void consentRegrantDoesNotReviveAnOldWriterOrApproval() throws Exception {
        Fixture fixture = new Fixture();
        fixture.prepare(ID);
        DmFileProvider.UploadWriter writer = fixture.writer(ID);
        fixture.access.disable();
        fixture.access.enable();
        expect(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, () -> writer.writeChunk(0, BYTES, true));
        assertEquals(APK_INSTALL_STATE_FAILED, fixture.operation(ID).getState());
        assertEquals(0, fixture.backend.submitted);
        assertTrue(fixture.manager.canStart());
    }

    @Test public void untrackedSessionsRequireExplicitAndroidCleanupAndBadJournalFailsClosed() throws Exception {
        MemoryBackend backend = new MemoryBackend();
        backend.sessions.add(99);
        MemoryJournal journal = new MemoryJournal();
        ApkInstallAccess access = new ApkInstallAccess();
        ApkInstallManager manager = new ApkInstallManager(backend, journal, access, new SecureRandom());
        access.enable();
        assertTrue(manager.needsUntrackedCleanup());
        expect(ErrorCode.ERROR_CODE_ALREADY_EXISTS, () -> manager.prepare(owner(1), request(ID)));
        assertTrue(backend.abandoned.isEmpty());
        manager.cleanUntrackedOnAndroid();
        assertTrue(manager.canStart());
        assertEquals(Arrays.asList(99), backend.abandoned);

        backend.sessions.add(100);
        journal.unreadable = true;
        ApkInstallManager corrupt = new ApkInstallManager(backend, journal, access, new SecureRandom());
        assertFalse(corrupt.healthy());
        assertFalse(corrupt.canStart());
        assertTrue(backend.sessions.contains(100));
        expect(ErrorCode.ERROR_CODE_INTERNAL, () -> corrupt.prepare(owner(1), request(ID)));
    }

    @Test public void boundedJournalRejectsNoncanonicalAndInconsistentRecords() throws Exception {
        Fixture fixture = new Fixture();
        fixture.ready();
        String encoded = ApkInstallJournalCodec.encode(fixture.journal.records);
        List<ApkInstallRecord> decoded = ApkInstallJournalCodec.decode(encoded);
        assertEquals(fixture.journal.records.get(0).owner, decoded.get(0).owner);
        assertEquals(APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL, decoded.get(0).state);
        assertThrows(IOException.class, () -> ApkInstallJournalCodec.decode(encoded + "\n"));
        assertThrows(IOException.class, () -> ApkInstallJournalCodec.decode("A".repeat(30_000)));
        List<ApkInstallRecord> duplicate = new ArrayList<>(decoded);
        duplicate.add(decoded.get(0));
        assertThrows(IOException.class, () -> ApkInstallJournalCodec.encode(duplicate));
        fixture.manager.cancelOnAndroid(ID);
    }

    private static InstallOwner owner(int seed) {
        byte[] bytes = new byte[SessionAuthenticator.PAIRING_ID_LENGTH];
        Arrays.fill(bytes, (byte) seed);
        return InstallOwner.authenticated(bytes);
    }

    @Test public void unknownResultNeedsPhoneResolutionAndNeverResubmits() throws Exception {
        Fixture fixture = new Fixture();
        fixture.ready();
        fixture.manager.approveOnAndroid(ID);
        ApkInstallRecord saved = fixture.journal.records.get(0);
        fixture.manager.markUnansweredSubmission(ID);
        assertEquals(APK_INSTALL_STATE_OUTCOME_UNKNOWN, fixture.operation(ID).getState());
        assertFalse(fixture.manager.canStart());
        expect(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, () -> fixture.manager.cancel(owner(1), ID));
        fixture.backend.failAbandonOnce = true;
        expect(ErrorCode.ERROR_CODE_INTERNAL, () -> fixture.manager.dismissUnknownOnAndroid(ID));
        assertFalse(fixture.manager.canStart());
        fixture.manager.dismissUnknownOnAndroid(ID);
        assertTrue(fixture.manager.canStart());
        assertEquals(APK_INSTALL_STATE_OUTCOME_UNKNOWN, fixture.operation(ID).getState());
        assertFalse(fixture.manager.platformResult(ID, saved.sessionId, saved.callbackKey,
                ApkInstallManager.PlatformResult.PENDING_USER_ACTION));
        fixture.prepare(OTHER_ID);
        assertFalse(fixture.manager.platformResult(ID, saved.sessionId, saved.callbackKey,
                ApkInstallManager.PlatformResult.UNCERTAIN));
        assertTrue(fixture.manager.healthy());
        assertEquals(APK_INSTALL_STATE_WAITING_FOR_UPLOAD, fixture.operation(OTHER_ID).getState());
        assertTrue(fixture.manager.platformResult(ID, saved.sessionId, saved.callbackKey,
                ApkInstallManager.PlatformResult.SUCCESS));
        assertEquals(APK_INSTALL_STATE_SUCCEEDED, fixture.operation(ID).getState());
        assertEquals(1, fixture.backend.submitted);
        fixture.manager.cancelOnAndroid(OTHER_ID);
    }

    @Test public void delayedEnableCannotUndoAnImmediateRevoke() {
        ApkInstallAccess access = new ApkInstallAccess();
        long queuedEnable = access.version();
        access.disable();
        access.enableIfUnchanged(queuedEnable);
        assertEquals(-1, access.currentGrant());
        access.enableIfUnchanged(access.version());
        assertTrue(access.currentGrant() >= 0);
    }

    @Test public void dispatcherRoutesOpaqueUploadWithoutSubmittingInstallation() throws Exception {
        Fixture fixture = new Fixture();
        RpcDispatcher dispatcher = new RpcDispatcher(new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null, null, null, SessionAuthenticationMode.PAIRED_REQUIRED, id -> null,
                null, null, RpcDispatcherTestFixtures.testDeviceIdentity(), null, () -> fixture.manager);
        RpcDispatcher.SessionState session = new RpcDispatcher.SessionState();
        session.markReadyAndClear(Arrays.asList(Capability.CAPABILITY_APK_INSTALL,
                Capability.CAPABILITY_FILE_WRITE), owner(1));
        RpcEnvelope prepared = dispatch(dispatcher, session, 1,
                PayloadType.PAYLOAD_TYPE_PREPARE_APK_INSTALL_REQUEST, request(ID).toByteString());
        assertEquals(ApkInstallPolicy.destination(ID), PrepareApkInstallResponse
                .parseFrom(prepared.getPayload()).getUploadDestination());
        OpenTransferRequest open = OpenTransferRequest.newBuilder()
                .setTransferId(ID).setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                .setSourcePath("mac-local-upload").setDestinationPath(ApkInstallPolicy.destination(ID))
                .setExpectedSizeBytes(BYTES.length).setPreferredChunkSizeBytes(512 * 1024).build();
        OpenTransferResponse opened = OpenTransferResponse.parseFrom(
                dispatch(dispatcher, session, 2, PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST,
                        open.toByteString()).getPayload());
        assertFalse(opened.hasError());
        java.util.zip.CRC32 crc = new java.util.zip.CRC32(); crc.update(BYTES);
        TransferChunk chunk = TransferChunk.newBuilder()
                .setTransferId(ID).setData(ByteString.copyFrom(BYTES)).setFinalChunk(true).setCrc32((int) crc.getValue()).build();
        RpcEnvelope streamed = RpcEnvelope.newBuilder()
                .setFrameVersion(1).setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(2).setStreamId(opened.getStreamId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK)
                .setPayload(chunk.toByteString()).build();
        RpcEnvelope ack = dispatcher.dispatchForTest(streamed.toByteArray(), session, 1)[0];
        assertTrue(TransferChunkAck.parseFrom(ack.getPayload()).getFinalAck());
        ListApkInstallsResponse listed = ListApkInstallsResponse.parseFrom(
                dispatch(dispatcher, session, 3, PayloadType.PAYLOAD_TYPE_LIST_APK_INSTALLS_REQUEST,
                        ByteString.EMPTY).getPayload());
        assertEquals(APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL, listed.getOperations(0).getState());
        assertEquals(0, fixture.backend.submitted);
        fixture.manager.approveOnAndroid(ID);
        RpcEnvelope denied = dispatch(dispatcher, session, 4,
                PayloadType.PAYLOAD_TYPE_CANCEL_APK_INSTALL_REQUEST,
                CancelApkInstallRequest.newBuilder().setOperationId(ID).build().toByteString());
        assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, denied.getError().getCode());
        assertEquals(1, fixture.backend.submitted);
    }

    private static RpcEnvelope dispatch(RpcDispatcher dispatcher,
            RpcDispatcher.SessionState session, long id, PayloadType type, ByteString payload) {
        return dispatcher.dispatchForTest(RpcEnvelope.newBuilder().setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST).setRequestId(id)
                .setPayloadType(type).setPayload(payload).build().toByteArray(), session, 1)[0];
    }

    private static PrepareApkInstallRequest request(String id) throws Exception {
        return PrepareApkInstallRequest.newBuilder().setOperationId(id).setDisplayName("fixture.apk")
                .setSizeBytes(BYTES.length).setSha256(ByteString.copyFrom(
                        MessageDigest.getInstance("SHA-256").digest(BYTES))).build();
    }

    private interface Operation { void run() throws Exception; }
    private static void expect(ErrorCode code, Operation operation) throws Exception {
        try { operation.run(); fail("expected a bounded installation failure"); }
        catch (DmFileProvider.ProviderCatalogException failure) { assertEquals(code, failure.code); }
    }

    private static final class Fixture {
        final MemoryBackend backend = new MemoryBackend();
        final MemoryJournal journal = new MemoryJournal();
        final ApkInstallAccess access = new ApkInstallAccess();
        final ApkInstallManager manager = new ApkInstallManager(backend, journal, access, new SecureRandom());
        Fixture() { access.enable(); }
        void prepare(String id) throws Exception { manager.prepare(owner(1), request(id)); }
        DmFileProvider.UploadWriter writer(String id) throws Exception {
            return manager.openUpload(owner(1), ApkInstallPolicy.destination(id), id, 0, BYTES.length);
        }
        void ready() throws Exception { prepare(ID); writer(ID).writeChunk(0, BYTES, true); }
        ApkInstallOperation operation(String id) throws Exception {
            for (ApkInstallOperation operation : manager.list(owner(1)).getOperationsList()) {
                if (operation.getOperationId().equals(id)) return operation;
            }
            throw new AssertionError("missing fixture operation");
        }
    }

    private static final class MemoryJournal implements ApkInstallJournal {
        List<ApkInstallRecord> records = new ArrayList<>();
        boolean failSubmitting;
        boolean unreadable;
        Runnable onSubmitting;
        @Override public List<ApkInstallRecord> load() throws IOException {
            if (unreadable) throw new IOException("synthetic journal failure");
            return new ArrayList<>(records);
        }
        @Override public void save(List<ApkInstallRecord> next) throws IOException {
            boolean submitting = next.stream().anyMatch(r -> r.state == APK_INSTALL_STATE_SUBMITTING);
            if (submitting && failSubmitting) throw new IOException("synthetic journal failure");
            records = ApkInstallJournalCodec.decode(ApkInstallJournalCodec.encode(next));
            if (submitting && onSubmitting != null) onSubmitting.run();
        }
    }

    private static final class MemoryBackend implements ApkInstallBackend {
        final Set<Integer> sessions = new HashSet<>();
        final List<Integer> abandoned = new ArrayList<>();
        int nextSession;
        int opened;
        int submitted;
        boolean failAbandonOnce;
        Runnable onSubmit;
        @Override public boolean supported() { return true; }
        @Override public boolean sourceTrusted() { return true; }
        @Override public int create(long size) { sessions.add(++nextSession); return nextSession; }
        @Override public Sink openUpload(int sessionId, long size) {
            assertTrue(sessions.contains(sessionId));
            opened++;
            return new Sink() {
                private final ByteArrayOutputStream output = new ByteArrayOutputStream();
                @Override public OutputStream stream() { return output; }
                @Override public void sync() { }
                @Override public void close() { }
            };
        }
        @Override public void submit(int sessionId, String id, byte[] callback) {
            assertTrue(sessions.contains(sessionId));
            if (onSubmit != null) onSubmit.run();
            submitted++;
        }
        @Override public void abandon(int sessionId) throws IOException {
            abandoned.add(sessionId);
            if (failAbandonOnce) { failAbandonOnce = false; throw new IOException("synthetic cleanup failure"); }
            sessions.remove(sessionId);
        }
        @Override public Set<Integer> ownedSessionIds() { return new HashSet<>(sessions); }
    }
}
