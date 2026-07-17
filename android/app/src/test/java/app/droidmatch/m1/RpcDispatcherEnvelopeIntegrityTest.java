package app.droidmatch.m1;

import static app.droidmatch.m1.RpcDispatcherTestFixtures.clientHelloEnvelope;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.heartbeatEnvelope;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import com.google.protobuf.ByteString;

import java.util.zip.CRC32;

import org.junit.Test;

public final class RpcDispatcherEnvelopeIntegrityTest {
    @Test
    public void flaggedPayloadWithCorrectUnsignedCrcIsAccepted() throws Exception {
        RpcDispatcher dispatcher = dispatcher(new DiagnosticsReporter(() -> 1L, () -> "test-thread"));
        RpcEnvelope heartbeat = heartbeatEnvelope(1);
        int checksum = crc32(heartbeat.getPayload());
        assertTrue("fixture must cover a CRC with its high bit set", checksum < 0);

        RpcEnvelope response = dispatcher.dispatchForTest(
                withFlagsAndChecksum(heartbeat, 1, checksum).toByteArray(),
                true,
                1
        )[0];

        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, response.getPayloadType());
        assertEquals(1, HeartbeatResponse.parseFrom(response.getPayload()).getMonotonicMillis());
    }

    @Test
    public void checksumMismatchRejectsBeforeHandlerAndKeepsControlSessionUsable() throws Exception {
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = dispatcher(reporter);
        RpcDispatcher.SessionState state = dispatcher.newSessionStateForTest();
        RpcEnvelope hello = clientHelloEnvelope(1, new byte[32], new byte[0]);
        assertEquals(
                PayloadType.PAYLOAD_TYPE_SERVER_HELLO,
                dispatcher.dispatchForTest(hello.toByteArray(), state, 7)[0].getPayloadType()
        );
        RpcEnvelope heartbeat = heartbeatEnvelope(7);

        RpcEnvelope rejected = dispatcher.dispatchForTest(
                withFlagsAndChecksum(heartbeat, 1, crc32(heartbeat.getPayload()) ^ 1).toByteArray(),
                state,
                7
        )[0];

        assertError(rejected, 7, ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH);
        assertEquals(null, reporter.counters().get("rpc.heartbeat.requests"));
        RpcEnvelope recovered = dispatcher.dispatchForTest(heartbeat.toByteArray(), state, 7)[0];
        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, recovered.getPayloadType());
    }

    @Test
    public void checksumMismatchDuringSetupClosesSessionAndCannotRecover() {
        RpcDispatcher dispatcher = dispatcher(new DiagnosticsReporter(() -> 1L, () -> "test-thread"));
        RpcDispatcher.SessionState state = dispatcher.newSessionStateForTest();
        RpcEnvelope hello = clientHelloEnvelope(3, new byte[32], new byte[0]);

        RpcEnvelope rejected = dispatcher.dispatchForTest(
                withFlagsAndChecksum(hello, 1, crc32(hello.getPayload()) ^ 1).toByteArray(),
                state,
                9
        )[0];
        assertError(rejected, 3, ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH);
        assertEquals(RpcSessionState.Phase.CLOSED, state.phase);

        RpcEnvelope replay = dispatcher.dispatchForTest(hello.toByteArray(), state, 9)[0];
        assertError(replay, 3, ErrorCode.ERROR_CODE_UNAUTHORIZED);
        assertEquals(RpcSessionState.Phase.CLOSED, state.phase);
    }

    @Test
    public void absentChecksumFlagAndUnknownFlagsIgnoreChecksumField() {
        RpcDispatcher dispatcher = dispatcher(new DiagnosticsReporter(() -> 1L, () -> "test-thread"));

        RpcEnvelope absentFlag = withFlagsAndChecksum(heartbeatEnvelope(11), 0, 0x12345678);
        RpcEnvelope unknownFlag = withFlagsAndChecksum(heartbeatEnvelope(12), 1 << 4, 0x76543210);

        assertEquals(
                PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE,
                dispatcher.dispatchForTest(absentFlag.toByteArray(), true, 11)[0].getPayloadType()
        );
        assertEquals(
                PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE,
                dispatcher.dispatchForTest(unknownFlag.toByteArray(), true, 12)[0].getPayloadType()
        );
    }

    @Test
    public void frameVersionPrecedesChecksumAndEmptyPayloadUsesZeroCrc() {
        RpcDispatcher dispatcher = dispatcher(new DiagnosticsReporter(() -> 1L, () -> "test-thread"));
        RpcEnvelope unsupported = withFlagsAndChecksum(
                heartbeatEnvelope(13).toBuilder().setFrameVersion(2).build(),
                1,
                1
        );
        assertError(
                dispatcher.dispatchForTest(unsupported.toByteArray(), true, 13)[0],
                13,
                ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION
        );

        RpcEnvelope emptyHeartbeat = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(14)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                .setFlags(1)
                .setPayloadCrc32(0)
                .build();
        assertEquals(
                PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE,
                dispatcher.dispatchForTest(emptyHeartbeat.toByteArray(), true, 14)[0].getPayloadType()
        );
        assertError(
                dispatcher.dispatchForTest(
                        emptyHeartbeat.toBuilder().setRequestId(15).setPayloadCrc32(1).build().toByteArray(),
                        true,
                        15
                )[0],
                15,
                ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH
        );

        RpcEnvelope inboundError = RpcDispatcher.errorEnvelope(
                16,
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                "peer rejected request"
        ).toBuilder().setFlags(1).setPayloadCrc32(0).build();
        assertError(
                dispatcher.dispatchForTest(inboundError.toByteArray(), true, 16)[0],
                16,
                ErrorCode.ERROR_CODE_PROTOCOL_ERROR
        );
        assertError(
                dispatcher.dispatchForTest(
                        inboundError.toBuilder().setRequestId(17).setPayloadCrc32(1).build().toByteArray(),
                        true,
                        17
                )[0],
                17,
                ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH
        );
    }

    private static RpcDispatcher dispatcher(DiagnosticsReporter reporter) {
        return new RpcDispatcher(reporter, null, null, null);
    }

    private static RpcEnvelope withFlagsAndChecksum(RpcEnvelope envelope, int flags, int checksum) {
        return envelope.toBuilder()
                .setFlags(flags)
                .setPayloadCrc32(checksum)
                .build();
    }

    private static int crc32(ByteString payload) {
        CRC32 checksum = new CRC32();
        checksum.update(payload.toByteArray());
        return (int) checksum.getValue();
    }

    private static void assertError(RpcEnvelope envelope, long requestId, ErrorCode code) {
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, envelope.getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR, envelope.getPayloadType());
        assertEquals(requestId, envelope.getRequestId());
        assertEquals(code, envelope.getError().getCode());
    }
}
