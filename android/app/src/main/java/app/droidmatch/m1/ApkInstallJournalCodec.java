package app.droidmatch.m1;

import app.droidmatch.proto.v1.ApkInstallState;
import app.droidmatch.proto.v1.ErrorCode;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Versioned private record encoding; malformed data is never partially restored. */
final class ApkInstallJournalCodec {
    private static final int MAGIC = 0x444d4149;
    private static final int VERSION = 1;
    private static final int MAX_BYTES = 16_384;
    private static final int MAX_TEXT = ((MAX_BYTES + 2) / 3) * 4;

    private ApkInstallJournalCodec() {}

    static String encode(List<ApkInstallRecord> records) throws IOException {
        if (records == null || records.size() > ApkInstallPolicy.MAX_RECORDS) throw unavailable();
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream output = new DataOutputStream(bytes)) {
            output.writeInt(MAGIC);
            output.writeInt(VERSION);
            output.writeInt(records.size());
            Set<String> ids = new HashSet<>();
            Set<Integer> sessions = new HashSet<>();
            int active = 0;
            for (ApkInstallRecord record : records) {
                if (record == null || !ids.add(record.id) || !sessions.add(record.sessionId)) {
                    throw unavailable();
                }
                if (record.active() && ++active > 1) throw unavailable();
                output.writeUTF(record.id);
                output.writeUTF(record.displayName);
                output.writeUTF(record.owner.storageKey());
                output.writeInt(record.sessionId);
                output.writeLong(record.size);
                output.writeLong(record.uploaded);
                output.write(record.digest);
                output.write(record.callbackKey);
                output.writeInt(record.state.getNumber());
                output.writeInt(record.failure.getNumber());
                output.writeBoolean(record.dismissedUnknown);
            }
        }
        if (bytes.size() > MAX_BYTES) throw unavailable();
        return Base64.getEncoder().encodeToString(bytes.toByteArray());
    }

    static List<ApkInstallRecord> decode(String encoded) throws IOException {
        if (encoded == null || encoded.isEmpty() || encoded.length() > MAX_TEXT) throw unavailable();
        try {
            byte[] bytes = Base64.getDecoder().decode(encoded);
            if (bytes.length > MAX_BYTES || !Base64.getEncoder().encodeToString(bytes).equals(encoded)) {
                throw unavailable();
            }
            try (DataInputStream input = new DataInputStream(new ByteArrayInputStream(bytes))) {
                if (input.readInt() != MAGIC || input.readInt() != VERSION) throw unavailable();
                int count = input.readInt();
                if (count < 0 || count > ApkInstallPolicy.MAX_RECORDS) throw unavailable();
                List<ApkInstallRecord> result = new ArrayList<>(count);
                Set<String> ids = new HashSet<>();
                Set<Integer> sessions = new HashSet<>();
                int active = 0;
                for (int i = 0; i < count; i++) {
                    String id = input.readUTF();
                    String displayName = input.readUTF();
                    InstallOwner owner = InstallOwner.restore(input.readUTF());
                    int session = input.readInt();
                    long size = input.readLong();
                    long uploaded = input.readLong();
                    byte[] digest = new byte[32];
                    byte[] callback = new byte[32];
                    input.readFully(digest);
                    input.readFully(callback);
                    ApkInstallState state = ApkInstallState.forNumber(input.readInt());
                    ErrorCode failure = ErrorCode.forNumber(input.readInt());
                    int dismissed = input.readUnsignedByte();
                    if (dismissed > 1 || !ids.add(id) || !sessions.add(session)) throw unavailable();
                    ApkInstallRecord record = new ApkInstallRecord(id, displayName, owner, session,
                            size, uploaded, digest, callback, state, failure, dismissed == 1);
                    if (record.active() && ++active > 1) throw unavailable();
                    result.add(record);
                }
                if (input.read() != -1) throw unavailable();
                return result;
            }
        } catch (IllegalArgumentException | IOException invalid) {
            // Do not include encoded private state or parser/platform messages.
            throw unavailable();
        }
    }

    private static IOException unavailable() {
        return new IOException("installation journal is unavailable");
    }
}
