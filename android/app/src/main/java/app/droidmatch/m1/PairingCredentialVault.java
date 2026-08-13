package app.droidmatch.m1;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Comparator;
import java.util.Collections;
import java.util.List;
import java.util.regex.Pattern;

/**
 * Versioned encrypted pairing-record vault.
 *
 * <p>The backend sees only metadata and AES-GCM ciphertext. The protector must
 * bind encryption to the supplied AAD; Android uses a non-exportable Keystore
 * key while JVM tests inject a normal JCE key.</p>
 */
public final class PairingCredentialVault implements PairingKeyProvider {
    private static final int RECORD_MAGIC = 0x444d5031; // "DMP1"
    private static final byte[] AAD_CONTEXT = "DroidMatch pairing record v1\0"
            .getBytes(StandardCharsets.US_ASCII);
    private static final int MAX_ENCRYPTED_KEY_BYTES = 128;
    private static final int MAX_IV_BYTES = 32;
    private static final Pattern RECORD_KEY = Pattern.compile("record\\.[0-9a-f]{32}");

    private final RecordBackend backend;
    private final KeyProtector protector;

    public PairingCredentialVault(RecordBackend backend, KeyProtector protector) {
        this.backend = backend;
        this.protector = protector;
    }

    public synchronized void save(PairingCredentialRecord record) {
        String recordKey = recordKey(record.pairingId());
        String existingEncoded = backend.get(recordKey);
        if (existingEncoded != null) {
            PairingCredentialRecord existing = load(record.pairingId());
            if (!MessageDigest.isEqual(
                    existing.deviceIdentityFingerprint(),
                    record.deviceIdentityFingerprint()
            )) {
                throw new IllegalArgumentException(
                        "pairing ID is already associated with another device identity"
                );
            }
        }

        byte[] plaintextKey = record.pairingKey();
        try {
            boolean allowKeyCreation = backend.keys().stream()
                    .noneMatch(key -> key.startsWith("record."));
            EncryptedKey encrypted = protector.encrypt(
                    plaintextKey,
                    aad(
                            record.pairingId(),
                            record.deviceIdentityFingerprint(),
                            record.displayName(),
                            record.createdAtUnixMillis(),
                            record.lastUsedAtUnixMillis()
                    ),
                    allowKeyCreation
            );
            backend.put(recordKey, encode(record, encrypted));
        } finally {
            Arrays.fill(plaintextKey, (byte) 0);
        }
    }

    public synchronized PairingCredentialRecord load(byte[] pairingId) {
        requireLength(pairingId, "pairing ID", PairingAuthenticator.PAIRING_ID_LENGTH);
        String encoded = backend.get(recordKey(pairingId));
        if (encoded == null) {
            return null;
        }
        StoredRecord stored = decode(encoded);
        if (!MessageDigest.isEqual(stored.pairingId, pairingId)) {
            throw new IllegalStateException("stored pairing ID does not match record key");
        }
        byte[] plaintextKey = protector.decrypt(
                new EncryptedKey(stored.iv, stored.encryptedKey),
                aad(
                        stored.pairingId,
                        stored.deviceIdentityFingerprint,
                        stored.displayName,
                        stored.createdAtUnixMillis,
                        stored.lastUsedAtUnixMillis
                )
        );
        try {
            return new PairingCredentialRecord(
                    stored.pairingId,
                    stored.deviceIdentityFingerprint,
                    plaintextKey,
                    stored.displayName,
                    stored.createdAtUnixMillis,
                    stored.lastUsedAtUnixMillis
            );
        } finally {
            Arrays.fill(plaintextKey, (byte) 0);
        }
    }

    public synchronized List<PairingCredentialRecord.Metadata> list() {
        Catalog catalog = catalog();
        if (!catalog.isComplete()) {
            throw new IllegalStateException("pairing credential catalog is incomplete");
        }
        return catalog.metadata();
    }

    public synchronized Catalog catalog() {
        List<PairingCredentialRecord.Metadata> result = new ArrayList<>();
        List<DamagedRecord> damaged = new ArrayList<>();
        List<DamagedRecord> unauthenticated = new ArrayList<>();
        boolean incomplete = false;
        for (String key : backend.keys()) {
            if (!key.startsWith("record.")) {
                continue;
            }
            if (!RECORD_KEY.matcher(key).matches()) {
                incomplete = true;
                continue;
            }
            RecordSnapshot snapshot;
            try {
                snapshot = backend.snapshot(key);
            } catch (MalformedRecordException exception) {
                incomplete = true;
                // An invalid backend value type has no exact String snapshot for
                // compare-and-remove, so it makes the catalog incomplete without
                // receiving a cleanup capability.
                continue;
            }
            String encoded = snapshot.value;
            if (encoded == null) {
                continue;
            }
            StoredRecord stored;
            try {
                stored = decode(encoded);
            } catch (MalformedRecordException exception) {
                incomplete = true;
                damaged.add(new DamagedRecord(
                        this, key, encoded, snapshot.revision, DamageKind.STRUCTURAL
                ));
                continue;
            }
            if (!MessageDigest.isEqual(stored.pairingId, pairingIdFromRecordKey(key))) {
                incomplete = true;
                damaged.add(new DamagedRecord(
                        this, key, encoded, snapshot.revision, DamageKind.STRUCTURAL
                ));
                continue;
            }
            byte[] plaintextKey;
            try {
                plaintextKey = protector.decrypt(
                        new EncryptedKey(stored.iv, stored.encryptedKey),
                        aad(
                                stored.pairingId,
                                stored.deviceIdentityFingerprint,
                                stored.displayName,
                                stored.createdAtUnixMillis,
                                stored.lastUsedAtUnixMillis
                        )
                );
            } catch (RecordAuthenticationException exception) {
                unauthenticated.add(new DamagedRecord(
                        this,
                        key,
                        encoded,
                        snapshot.revision,
                        DamageKind.AUTHENTICATION
                ));
                continue;
            }
            try {
                requireLength(plaintextKey, "pairing key", PairingAuthenticator.KEY_LENGTH);
                result.add(new PairingCredentialRecord.Metadata(
                        stored.pairingId,
                        stored.deviceIdentityFingerprint,
                        stored.displayName,
                        stored.createdAtUnixMillis,
                        stored.lastUsedAtUnixMillis
                ));
            } finally {
                Arrays.fill(plaintextKey, (byte) 0);
            }
        }
        // A tag failure is record-specific only after this same scan proves that the
        // current wrapping key can authenticate another record. Otherwise a replaced,
        // invalidated, or temporarily unavailable vault key is indistinguishable.
        if (!unauthenticated.isEmpty() && result.isEmpty()) {
            throw new IllegalStateException("pairing credential vault authentication is unavailable");
        }
        for (DamagedRecord record : unauthenticated) {
            incomplete = true;
            damaged.add(record);
        }
        result.sort(Comparator.comparingLong(PairingCredentialRecord.Metadata::lastUsedAtUnixMillis).reversed());
        return new Catalog(result, damaged, !incomplete);
    }

    public synchronized void revoke(byte[] pairingId) {
        requireLength(pairingId, "pairing ID", PairingAuthenticator.PAIRING_ID_LENGTH);
        backend.remove(recordKey(pairingId));
    }

    public synchronized void removeDamaged(DamagedRecord record) {
        if (record == null || record.owner != this || !RECORD_KEY.matcher(record.recordKey).matches()) {
            throw new IllegalArgumentException("damaged pairing record identity is invalid");
        }
        RecordSnapshot current = backend.snapshot(record.recordKey);
        if (!java.util.Objects.equals(record.observedValue, current.value)
                || record.observedRevision != current.revision) {
            throw new IllegalStateException("damaged pairing record changed before removal");
        }
        Catalog freshCatalog = catalog();
        boolean stillDamaged = freshCatalog.damagedRecords.stream()
                .anyMatch(candidate -> candidate.matches(record));
        if (!stillDamaged) {
            throw new IllegalStateException("damaged pairing record changed before removal");
        }
        if (!backend.removeIfUnchanged(
                record.recordKey,
                record.observedValue,
                record.observedRevision
        )) {
            throw new IllegalStateException("damaged pairing record changed before removal");
        }
    }

    public synchronized void markUsed(byte[] pairingId, long lastUsedAtUnixMillis) {
        requireLength(pairingId, "pairing ID", PairingAuthenticator.PAIRING_ID_LENGTH);
        if (lastUsedAtUnixMillis < 0) {
            throw new IllegalArgumentException("last-used timestamp must be non-negative");
        }
        PairingCredentialRecord existing = load(pairingId);
        if (existing == null || lastUsedAtUnixMillis <= existing.lastUsedAtUnixMillis()) {
            return;
        }
        byte[] pairingKey = existing.pairingKey();
        try {
            save(new PairingCredentialRecord(
                    existing.pairingId(),
                    existing.deviceIdentityFingerprint(),
                    pairingKey,
                    existing.displayName(),
                    existing.createdAtUnixMillis(),
                    lastUsedAtUnixMillis
            ));
        } finally {
            Arrays.fill(pairingKey, (byte) 0);
        }
    }

    @Override
    public byte[] pairingKey(byte[] pairingId) {
        try {
            PairingCredentialRecord record = load(pairingId);
            return record == null ? null : record.pairingKey();
        } catch (RuntimeException exception) {
            // Authentication deliberately treats invalidated/tampered storage as
            // an unknown pairing. Detailed causes stay in local diagnostics only.
            return null;
        }
    }

    private static String encode(PairingCredentialRecord record, EncryptedKey encrypted) {
        byte[] displayName = record.displayName().getBytes(StandardCharsets.UTF_8);
        byte[] pairingId = record.pairingId();
        byte[] fingerprint = record.deviceIdentityFingerprint();
        validateEncryptedPayload(encrypted);
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream output = new DataOutputStream(bytes);
            output.writeInt(RECORD_MAGIC);
            output.write(pairingId);
            output.write(fingerprint);
            output.writeLong(record.createdAtUnixMillis());
            output.writeLong(record.lastUsedAtUnixMillis());
            output.writeShort(displayName.length);
            output.write(displayName);
            output.writeShort(encrypted.iv.length);
            output.write(encrypted.iv);
            output.writeShort(encrypted.ciphertext.length);
            output.write(encrypted.ciphertext);
            output.flush();
            return Base64.getEncoder().encodeToString(bytes.toByteArray());
        } catch (IOException exception) {
            throw new IllegalStateException("could not encode pairing record", exception);
        }
    }

    private static StoredRecord decode(String encoded) {
        try {
            byte[] bytes = Base64.getDecoder().decode(encoded);
            DataInputStream input = new DataInputStream(new ByteArrayInputStream(bytes));
            if (input.readInt() != RECORD_MAGIC) {
                throw new IllegalArgumentException("unsupported pairing record version");
            }
            byte[] pairingId = readFixed(input, PairingAuthenticator.PAIRING_ID_LENGTH);
            byte[] fingerprint = readFixed(input, PairingAuthenticator.DIGEST_LENGTH);
            long createdAt = input.readLong();
            long lastUsedAt = input.readLong();
            byte[] displayNameBytes = readBounded(
                    input,
                    PairingAuthenticator.MAXIMUM_DISPLAY_NAME_BYTES,
                    "display name"
            );
            byte[] iv = readBounded(input, MAX_IV_BYTES, "AES-GCM IV");
            byte[] ciphertext = readBounded(input, MAX_ENCRYPTED_KEY_BYTES, "encrypted pairing key");
            if (input.available() != 0) {
                throw new IllegalArgumentException("pairing record has trailing bytes");
            }
            String displayName = new String(displayNameBytes, StandardCharsets.UTF_8);
            // Reuse record validation without ever placing decrypted key material here.
            new PairingCredentialRecord(
                    pairingId,
                    fingerprint,
                    new byte[PairingAuthenticator.KEY_LENGTH],
                    displayName,
                    createdAt,
                    lastUsedAt
            );
            return new StoredRecord(
                    pairingId,
                    fingerprint,
                    displayName,
                    createdAt,
                    lastUsedAt,
                    iv,
                    ciphertext
            );
        } catch (IOException | IllegalArgumentException exception) {
            throw new MalformedRecordException(exception);
        }
    }

    private static byte[] pairingIdFromRecordKey(String recordKey) {
        byte[] result = new byte[PairingAuthenticator.PAIRING_ID_LENGTH];
        int offset = "record.".length();
        for (int index = 0; index < result.length; index += 1) {
            result[index] = (byte) Integer.parseInt(
                    recordKey.substring(offset + index * 2, offset + index * 2 + 2),
                    16
            );
        }
        return result;
    }

    private static byte[] readFixed(DataInputStream input, int length) throws IOException {
        byte[] result = new byte[length];
        input.readFully(result);
        return result;
    }

    private static byte[] readBounded(DataInputStream input, int maximum, String field) throws IOException {
        int length = input.readUnsignedShort();
        if (length == 0 || length > maximum) {
            throw new EOFException("invalid " + field + " length: " + length);
        }
        return readFixed(input, length);
    }

    private static byte[] aad(
            byte[] pairingId,
            byte[] fingerprint,
            String displayName,
            long createdAtUnixMillis,
            long lastUsedAtUnixMillis
    ) {
        byte[] displayNameBytes = displayName.getBytes(StandardCharsets.UTF_8);
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream output = new DataOutputStream(bytes);
            output.write(AAD_CONTEXT);
            output.write(pairingId);
            output.write(fingerprint);
            output.writeLong(createdAtUnixMillis);
            output.writeLong(lastUsedAtUnixMillis);
            output.writeShort(displayNameBytes.length);
            output.write(displayNameBytes);
            output.flush();
            return bytes.toByteArray();
        } catch (IOException exception) {
            throw new IllegalStateException("could not build pairing-record AAD", exception);
        }
    }

    private static String recordKey(byte[] pairingId) {
        requireLength(pairingId, "pairing ID", PairingAuthenticator.PAIRING_ID_LENGTH);
        StringBuilder result = new StringBuilder("record.");
        for (byte value : pairingId) {
            result.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
        }
        return result.toString();
    }

    private static void validateEncryptedPayload(EncryptedKey encrypted) {
        if (encrypted.iv.length == 0 || encrypted.iv.length > MAX_IV_BYTES
                || encrypted.ciphertext.length == 0
                || encrypted.ciphertext.length > MAX_ENCRYPTED_KEY_BYTES) {
            throw new IllegalArgumentException("invalid encrypted pairing-key payload");
        }
    }

    private static void requireLength(byte[] value, String field, int expected) {
        if (value.length != expected) {
            throw new IllegalArgumentException(
                    "invalid " + field + " length: expected " + expected + " bytes, got " + value.length
            );
        }
    }

    public interface RecordBackend {
        RecordSnapshot snapshot(String key);
        default String get(String key) {
            return snapshot(key).value();
        }
        void put(String key, String value);
        void remove(String key);
        List<String> keys();
        boolean removeIfUnchanged(String key, String expectedValue, long expectedRevision);
    }

    public interface KeyProtector {
        EncryptedKey encrypt(byte[] plaintext, byte[] aad);
        default EncryptedKey encrypt(byte[] plaintext, byte[] aad, boolean allowKeyCreation) {
            return encrypt(plaintext, aad);
        }
        byte[] decrypt(EncryptedKey encrypted, byte[] aad);
    }

    /** Exact AES-GCM tag failure; other protector failures remain vault-wide. */
    public static final class RecordAuthenticationException extends IllegalStateException {
        public RecordAuthenticationException(Throwable cause) {
            super("pairing credential record authentication failed", cause);
        }
    }

    public static final class DamagedRecord {
        private final PairingCredentialVault owner;
        private final String recordKey;
        private final String observedValue;
        private final long observedRevision;
        private final DamageKind damageKind;

        private DamagedRecord(
                PairingCredentialVault owner,
                String recordKey,
                String observedValue,
                long observedRevision,
                DamageKind damageKind
        ) {
            this.owner = owner;
            this.recordKey = recordKey;
            this.observedValue = observedValue;
            this.observedRevision = observedRevision;
            this.damageKind = damageKind;
        }

        private boolean matches(DamagedRecord other) {
            return owner == other.owner
                    && recordKey.equals(other.recordKey)
                    && observedValue.equals(other.observedValue)
                    && observedRevision == other.observedRevision
                    && damageKind == other.damageKind;
        }
    }

    public static final class RecordSnapshot {
        private final String value;
        private final long revision;

        public RecordSnapshot(String value, long revision) {
            if (revision < 0 || revision >= Long.MAX_VALUE - 1) {
                throw new MalformedRecordException(
                        new IllegalStateException("pairing record revision is invalid")
                );
            }
            this.value = value;
            this.revision = revision;
        }

        public String value() {
            return value;
        }

        public long revision() {
            return revision;
        }
    }

    private enum DamageKind {
        STRUCTURAL,
        AUTHENTICATION
    }

    public static final class Catalog {
        private final List<PairingCredentialRecord.Metadata> metadata;
        private final List<DamagedRecord> damagedRecords;
        private final boolean complete;

        private Catalog(
                List<PairingCredentialRecord.Metadata> metadata,
                List<DamagedRecord> damagedRecords,
                boolean complete
        ) {
            this.metadata = Collections.unmodifiableList(new ArrayList<>(metadata));
            this.damagedRecords = Collections.unmodifiableList(new ArrayList<>(damagedRecords));
            this.complete = complete;
        }

        public static Catalog complete(List<PairingCredentialRecord.Metadata> metadata) {
            return new Catalog(metadata, Collections.emptyList(), true);
        }

        public List<PairingCredentialRecord.Metadata> metadata() {
            return metadata;
        }

        public List<DamagedRecord> damagedRecords() {
            return damagedRecords;
        }

        public boolean isComplete() {
            return complete;
        }
    }

    /** Permanent structural failure for one exact backend record, never a vault outage. */
    public static final class MalformedRecordException extends IllegalStateException {
        public MalformedRecordException(Throwable cause) {
            super("pairing credential record is malformed", cause);
        }
    }

    public static final class EncryptedKey {
        private final byte[] iv;
        private final byte[] ciphertext;

        public EncryptedKey(byte[] iv, byte[] ciphertext) {
            this.iv = Arrays.copyOf(iv, iv.length);
            this.ciphertext = Arrays.copyOf(ciphertext, ciphertext.length);
        }

        public byte[] iv() {
            return Arrays.copyOf(iv, iv.length);
        }

        public byte[] ciphertext() {
            return Arrays.copyOf(ciphertext, ciphertext.length);
        }
    }

    private static final class StoredRecord {
        private final byte[] pairingId;
        private final byte[] deviceIdentityFingerprint;
        private final String displayName;
        private final long createdAtUnixMillis;
        private final long lastUsedAtUnixMillis;
        private final byte[] iv;
        private final byte[] encryptedKey;

        private StoredRecord(
                byte[] pairingId,
                byte[] deviceIdentityFingerprint,
                String displayName,
                long createdAtUnixMillis,
                long lastUsedAtUnixMillis,
                byte[] iv,
                byte[] encryptedKey
        ) {
            this.pairingId = pairingId;
            this.deviceIdentityFingerprint = deviceIdentityFingerprint;
            this.displayName = displayName;
            this.createdAtUnixMillis = createdAtUnixMillis;
            this.lastUsedAtUnixMillis = lastUsedAtUnixMillis;
            this.iv = iv;
            this.encryptedKey = encryptedKey;
        }
    }
}
