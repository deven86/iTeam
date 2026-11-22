package com.jondhale.iteam

import android.util.Base64
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom

/** Byte-for-byte the same scheme as the iPhone app's E2E (CryptoKit):
 *  X25519 → HKDF-SHA256(salt = context, info = "iteam-e2e-v1", 32 bytes) → ChaCha20-Poly1305 (nonce‖ciphertext‖tag). */
object E2E {
    private val rnd = SecureRandom()

    fun b64(d: ByteArray): String = Base64.encodeToString(d, Base64.NO_WRAP)
    fun unb64(s: String): ByteArray = Base64.decode(s, Base64.DEFAULT)

    fun newIdentity(): ByteArray = X25519PrivateKeyParameters(rnd).encoded

    fun publicKey(priv: ByteArray): String = b64(X25519PrivateKeyParameters(priv, 0).generatePublicKey().encoded)

    fun pairwiseKey(priv: ByteArray, theirPublic: String, context: String): ByteArray {
        val agreement = X25519Agreement()
        agreement.init(X25519PrivateKeyParameters(priv, 0))
        val secret = ByteArray(32)
        agreement.calculateAgreement(X25519PublicKeyParameters(unb64(theirPublic), 0), secret, 0)
        val hkdf = HKDFBytesGenerator(SHA256Digest())
        hkdf.init(HKDFParameters(secret, context.toByteArray(), "iteam-e2e-v1".toByteArray()))
        val out = ByteArray(32)
        hkdf.generateBytes(out, 0, 32)
        return out
    }

    fun newKey(): ByteArray = ByteArray(32).also { rnd.nextBytes(it) }

    fun seal(plain: ByteArray, key: ByteArray): ByteArray {
        val nonce = ByteArray(12).also { rnd.nextBytes(it) }
        val c = ChaCha20Poly1305()
        c.init(true, AEADParameters(KeyParameter(key), 128, nonce))
        val out = ByteArray(c.getOutputSize(plain.size))
        val n = c.processBytes(plain, 0, plain.size, out, 0)
        c.doFinal(out, n)
        return nonce + out
    }

    fun open(sealed: ByteArray, key: ByteArray): ByteArray {
        require(sealed.size > 28)
        val c = ChaCha20Poly1305()
        c.init(false, AEADParameters(KeyParameter(key), 128, sealed.copyOfRange(0, 12)))
        val body = sealed.copyOfRange(12, sealed.size)
        val out = ByteArray(c.getOutputSize(body.size))
        val n = c.processBytes(body, 0, body.size, out, 0)
        c.doFinal(out, n)
        return out
    }

    /** [version byte] + sealed box — the format of every envelope body and hint. */
    fun sealVersioned(plain: ByteArray, key: ByteArray, version: Int): ByteArray =
        byteArrayOf(version.coerceIn(0, 255).toByte()) + seal(plain, key)

    fun split(data: ByteArray): Pair<Int, ByteArray>? =
        if (data.size > 1) Pair(data[0].toInt() and 0xFF, data.copyOfRange(1, data.size)) else null
}
