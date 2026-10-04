package com.example.aura_straton_maxima_ai

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher

/**
 * Android Keystore-backed data-key wrapping.
 *
 * A non-exportable RSA-2048 key ("maxima_dek_wrap") wraps the per-file
 * AES-256-GCM data keys produced by the Dart [SecureRecorderCodec].
 * The wrapped blob is embedded in each `.mxenc` container; the private
 * key never leaves the hardware-backed keystore.
 */
object MaximaKeyVault {
    private const val KEY_ALIAS = "maxima_dek_wrap_v1"
    private const val TRANSFORMATION =
        "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"

    private fun keyStore(): KeyStore =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun ensureKey() {
        val store = keyStore()
        if (store.containsAlias(KEY_ALIAS)) return

        val generator = java.security.KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            "AndroidKeyStore",
        )
        generator.initialize(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or
                    KeyProperties.PURPOSE_DECRYPT,
            )
                .setDigests(
                    KeyProperties.DIGEST_SHA256,
                    KeyProperties.DIGEST_SHA512,
                )
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                .setKeySize(2048)
                .build()
        )
        generator.generateKeyPair()
    }

    /** Wraps a raw DEK; returns Base64 for channel transport. */
    fun wrapDataKey(plainKey: ByteArray): String {
        ensureKey()
        val publicKey = keyStore()
            .getCertificate(KEY_ALIAS).publicKey
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, publicKey)
        return Base64.encodeToString(cipher.doFinal(plainKey), Base64.NO_WRAP)
    }

    /** Unwraps a Base64 wrapped DEK; returns the raw key bytes. */
    fun unwrapDataKey(wrappedBase64: String): ByteArray {
        val entry = keyStore().getEntry(KEY_ALIAS, null)
            as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("Keystore wrap key is missing")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, entry.privateKey)
        return cipher.doFinal(Base64.decode(wrappedBase64, Base64.NO_WRAP))
    }
}
