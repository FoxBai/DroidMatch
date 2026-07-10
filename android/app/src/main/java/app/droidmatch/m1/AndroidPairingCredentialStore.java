package app.droidmatch.m1;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.io.IOException;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import javax.crypto.Cipher;
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

    public void revoke(byte[] pairingId) {
        vault.revoke(pairingId);
    }

    @Override
    public byte[] pairingKey(byte[] pairingId) {
        return vault.pairingKey(pairingId);
    }

    private static final class SharedPreferencesBackend implements PairingCredentialVault.RecordBackend {
        private final SharedPreferences preferences;

        private SharedPreferencesBackend(SharedPreferences preferences) {
            this.preferences = preferences;
        }

        @Override
        public String get(String key) {
            return preferences.getString(key, null);
        }

        @Override
        public void put(String key, String value) {
            if (!preferences.edit().putString(key, value).commit()) {
                throw new IllegalStateException("could not persist encrypted pairing record");
            }
        }

        @Override
        public void remove(String key) {
            if (!preferences.edit().remove(key).commit()) {
                throw new IllegalStateException("could not revoke pairing record");
            }
        }

        @Override
        public List<String> keys() {
            Map<String, ?> all = preferences.getAll();
            return new ArrayList<>(all.keySet());
        }
    }

    private static final class AndroidKeystoreProtector implements PairingCredentialVault.KeyProtector {
        private final String alias;

        private AndroidKeystoreProtector(String alias) {
            this.alias = alias;
        }

        @Override
        public PairingCredentialVault.EncryptedKey encrypt(byte[] plaintext, byte[] aad) {
            try {
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.ENCRYPT_MODE, wrappingKey());
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
                cipher.init(
                        Cipher.DECRYPT_MODE,
                        wrappingKey(),
                        new GCMParameterSpec(128, encrypted.iv())
                );
                cipher.updateAAD(aad);
                return cipher.doFinal(encrypted.ciphertext());
            } catch (GeneralSecurityException | IOException exception) {
                throw new IllegalStateException(
                        "Android Keystore pairing-key decryption failed; re-pairing is required",
                        exception
                );
            }
        }

        private SecretKey wrappingKey() throws GeneralSecurityException, IOException {
            KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
            keyStore.load(null);
            java.security.Key existing = keyStore.getKey(alias, null);
            if (existing instanceof SecretKey) {
                return (SecretKey) existing;
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
    }
}
