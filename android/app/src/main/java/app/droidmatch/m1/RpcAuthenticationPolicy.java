package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.PayloadType;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Pure authentication protocol limits and capability/payload classification. */
final class RpcAuthenticationPolicy {
    static final int PROTOCOL_MAJOR = 1;
    static final int PROTOCOL_MINOR = 0;
    static final int MIN_SESSION_NONCE_BYTES = 16;
    static final int MAX_SESSION_NONCE_BYTES = 32;

    private static final List<Capability> SUPPORTED_CAPABILITIES = Arrays.asList(
            Capability.CAPABILITY_FILE_LIST,
            Capability.CAPABILITY_FILE_READ,
            Capability.CAPABILITY_FILE_WRITE,
            Capability.CAPABILITY_RESUMABLE_TRANSFER,
            Capability.CAPABILITY_DIAGNOSTICS
    );

    private RpcAuthenticationPolicy() {}

    static List<Capability> allCapabilities() {
        return new ArrayList<>(SUPPORTED_CAPABILITIES);
    }

    static List<Capability> grantCapabilities(List<Capability> requestedCapabilities) {
        List<Capability> granted = new ArrayList<>();
        for (Capability supported : SUPPORTED_CAPABILITIES) {
            if (requestedCapabilities.contains(supported)) {
                granted.add(supported);
            }
        }
        return granted;
    }

    static boolean isSessionNonceLengthAllowed(int length) {
        return length >= MIN_SESSION_NONCE_BYTES && length <= MAX_SESSION_NONCE_BYTES;
    }

    static boolean isPairingPayload(PayloadType payloadType) {
        return payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_START_RESPONSE
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_RESPONSE
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_REQUEST
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_RESPONSE;
    }
}
