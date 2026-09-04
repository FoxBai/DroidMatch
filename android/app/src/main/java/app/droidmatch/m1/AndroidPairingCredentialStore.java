package app.droidmatch.m1;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.io.IOException;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

import javax.crypto.Cipher;
import javax.crypto.AEADBadTagException;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Android Keystore-backed adapter for {@link PairingCredentialVault}. */
public final class AndroidPairingCredentialStore implements PairingCredentialRepository {
    private static final String PREFERENCES_NAME = "droidmatch_pairing_credentials_v1";
    private static final String WRAPPING_KEY_ALIAS = "app.droidmatch.pairing.wrap.v1";

    private final PairingCredentialVault vault;

    public AndroidPairingCredentialStore(Context context) {
        this(context, PREFERENCES_NAME, WRAPPING_KEY_ALIAS);
    }

    AndroidPairingCredentialStore(
            Context context,
            String preferencesName,
            String wrappingKeyAlias
    ) {
        if (preferencesName == null || preferencesName.isEmpty()
                || wrappingKeyAlias == null || wrappingKeyAlias.isEmpty()) {
            throw new IllegalArgumentException("pairing store names are required");
        }
        Context applicationContext = context.getApplicationContext();
        SharedPreferences preferences = applicationContext.getSharedPreferences(
                preferencesName,
                Context.MODE_PRIVATE
        );
        vault = new PairingCredentialVault(
                new SharedPreferencesBackend(preferences),
                new AndroidKeystoreProtector(wrappingKeyAlias)
        );
    }

    public void save(PairingCredentialRecord record) {
        vault.save(record);
    }

    public PairingCredentialRecord load(byte[] pairingId) {
        return vault.load(pairingId);
    }

    public List<PairingCredentialRecord.Metadata> list() {
        return vault.list();
    }

    @Override
    public PairingCredentialVault.Catalog catalog() {
        return vault.catalog();
    }

    public void revoke(byte[] pairingId) {
        vault.revoke(pairingId);
    }

    @Override
    public void removeDamaged(PairingCredentialVault.DamagedRecord record) {
        vault.removeDamaged(record);
    }

    @Override
    public void markUsed(byte[] pairingId, long lastUsedAtUnixMillis) {
        vault.markUsed(pairingId, lastUsedAtUnixMillis);
    }

    @Override
    public byte[] pairingKey(byte[] pairingId) {
        return vault.pairingKey(pairingId);
    }

    private static final class SharedPreferencesBackend implements PairingCredentialVault.RecordBackend {
        private static final String REVISION_PREFIX = "revision.";
        private static final Pattern RECORD_KEY = Pattern.compile("record\\.[0-9a-f]{32}");
        private final SharedPreferences preferences;

        private SharedPreferencesBackend(SharedPreferences preferences) {
            this.preferences = preferences;
        }

        @Override
        public PairingCredentialVault.RecordSnapshot snapshot(String key) {
            synchronized (preferences) {
                return snapshotLocked(key);
            }
        }

        @Override
        public void put(String key, String value) {
            synchronized (preferences) {
                long nextRevision = nextRevision(snapshotLocked(key).revision());
                if (!preferences.edit()
                        .putString(key, value)
                        .putLong(revisionKey(key), nextRevision)
                        .commit()) {
                    throw new IllegalStateException("could not persist encrypted pairing record");
                }
            }
        }

        @Override
        public void remove(String key) {
            synchronized (preferences) {
                long nextRevision = nextRevision(snapshotLocked(key).revision());
                if (!preferences.edit()
                        .remove(key)
                        .putLong(revisionKey(key), nextRevision)
                        .commit()) {
                    throw new IllegalStateException("could not revoke pairing record");
                }
            }
        }

        @Override
        public boolean removeIfUnchanged(
                String key,
                String expectedValue,
                long expectedRevision
        ) {
            synchronized (preferences) {
                PairingCredentialVault.RecordSnapshot current = snapshotLocked(key);
                if (!expectedValue.equals(current.value())
                        || expectedRevision != current.revision()) {
                    return false;
                }
                long nextRevision = nextRevision(current.revision());
                return preferences.edit()
                        .remove(key)
                        .putLong(revisionKey(key), nextRevision)
                        .commit();
            }
        }

        @Override
        public List<String> keys() {
            synchronized (preferences) {
                Map<String, ?> all = preferences.getAll();
                return new ArrayList<>(all.keySet());
            }
        }

        private PairingCredentialVault.RecordSnapshot snapshotLocked(String key) {
            Map<String, ?> all = preferences.getAll();
            Object value = all.get(key);
            if (value != null && !(value instanceof String)) {
                throw malformed("encrypted pairing record has an invalid storage type");
            }
            String revisionKey = revisionKey(key);
            Object revisionValue = all.get(revisionKey);
            long revision = 0;
            if (revisionValue != null) {
                if (!(revisionValue instanceof Long)
                        || (Long) revisionValue <= 0
                        || (Long) revisionValue >= Long.MAX_VALUE - 1) {
                    throw malformed("pairing record revision is invalid");
                }
                revision = (Long) revisionValue;
            }
            return new PairingCredentialVault.RecordSnapshot((String) value, revision);
        }

        private static long nextRevision(long revision) {
            if (revision >= Long.MAX_VALUE - 1) {
                throw malformed("pairing record revision is exhausted");
            }
            return revision + 1;
        }

        private static String revisionKey(String recordKey) {
            if (!RECORD_KEY.matcher(recordKey).matches()) {
                throw new IllegalArgumentException("pairing record key is invalid");
            }
            return REVISION_PREFIX + recordKey.substring("record.".length());
        }

        private static PairingCredentialVault.MalformedRecordException malformed(String message) {
            return new PairingCredentialVault.MalformedRecordException(
                    new IllegalStateException(message)
            );
        }
    }

    private static final class AndroidKeystoreProtector implements PairingCredentialVault.KeyProtector {
        private final String alias;

        private AndroidKeystoreProtector(String alias) {
            this.alias = alias;
        }

        @Override
        public PairingCredentialVault.EncryptedKey encrypt(byte[] plaintext, byte[] aad) {
            return encrypt(plaintext, aad, true);
        }

        @Override
        public PairingCredentialVault.EncryptedKey encrypt(
                byte[] plaintext,
                byte[] aad,
                boolean allowKeyCreation
        ) {
            try {
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.ENCRYPT_MODE, wrappingKeyForEncryption(allowKeyCreation));
                cipher.updateAAD(aad);
                return new PairingCredentialVault.EncryptedKey(cipher.getIV(), cipher.doFinal(plaintext));
            } catch (GeneralSecurityException | IOException exception) {
                throw new IllegalStateException("Android Keystore pairing-key encryption failed", exception);
            }
        }

        @Override
        public byte[] decrypt(PairingCredentialVault.EncryptedKey encrypted, byte[] aad) {
            try {
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.DECRYPT_MODE, existingWrappingKey(),
                        new GCMParameterSpec(128, encrypted.iv()));
                cipher.updateAAD(aad);
                try {
                    return cipher.doFinal(encrypted.ciphertext());
                } catch (AEADBadTagException exception) {
                    throw new PairingCredentialVault.RecordAuthenticationException(exception);
                }
            } catch (GeneralSecurityException | IOException exception) {
                throw new IllegalStateException(
                        "Android Keystore pairing-key decryption is unavailable",
                        exception
                );
            }
        }

        private SecretKey existingWrappingKey() throws GeneralSecurityException, IOException {
            KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
            keyStore.load(null);
            java.security.Key existing = keyStore.getKey(alias, null);
            if (existing instanceof SecretKey) {
                return (SecretKey) existing;
            }
            if (existing == null) {
                throw new MissingWrappingKeyException();
            }
            throw new KeyStoreException("pairing wrapping key has an unexpected type");
        }

        private SecretKey wrappingKeyForEncryption(boolean allowKeyCreation)
                throws GeneralSecurityException, IOException {
            try {
                return existingWrappingKey();
            } catch (MissingWrappingKeyException missing) {
                // A new wrapping key is valid only while creating a new encrypted record.
                // Reads never auto-create because that would turn vault loss into apparent
                // per-record corruption and offer unsafe cleanup.
                if (!allowKeyCreation) {
                    throw missing;
                }
            }

            KeyGenerator generator = KeyGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_AES,
                    "AndroidKeyStore"
            );
            generator.init(new KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT
            )
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .setUserAuthenticationRequired(false)
                    .build());
            return generator.generateKey();
        }

        private static final class MissingWrappingKeyException extends GeneralSecurityException {
            private MissingWrappingKeyException() {
                super("pairing wrapping key is missing");
            }
        }
    }
}
