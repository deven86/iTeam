package com.jondhale.iteam

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.SecureRandom
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.CipherInputStream
import javax.crypto.CipherOutputStream
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encrypted backup for Android: everything (chats, tasks, modules, files, keys) in one file,
 * locked with the user's backup password. Saved wherever the user picks — Google Drive, OneDrive,
 * Dropbox, phone storage — through Android's own "Save to" screen. Nobody can open it without the password.
 * File: "ITMB" magic, version 1, 16-byte salt, 12-byte nonce, then AES-256-GCM(zip).
 */
object Backup {
    private val MAGIC = "ITMB".toByteArray()
    private const val ROUNDS = 210_000

    private fun key(password: String, salt: ByteArray): SecretKeySpec {
        val f = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        return SecretKeySpec(f.generateSecret(PBEKeySpec(password.toCharArray(), salt, ROUNDS, 256)).encoded, "AES")
    }

    fun write(ctx: Context, store: Store, out: OutputStream, password: String, progress: (Float) -> Unit = {}) {
        store.save()
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        out.write(MAGIC); out.write(1); out.write(salt); out.write(nonce)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key(password, salt), GCMParameterSpec(128, nonce)) }
        val files = ctx.filesDir.walkTopDown().filter { it.isFile && !it.name.endsWith(".tmp") }.toList()
        val total = files.sumOf { it.length() }.coerceAtLeast(1)
        var done = 0L
        ZipOutputStream(CipherOutputStream(out, c)).use { zip ->
            zip.putNextEntry(ZipEntry("secrets.json"))
            zip.write(JSONObject(store.exportSecrets()).toString().toByteArray()); zip.closeEntry()
            for (f in files) {
                zip.putNextEntry(ZipEntry("files/" + f.relativeTo(ctx.filesDir).path))
                f.inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
                done += f.length(); progress(done.toFloat() / total)
            }
        }
    }

    /** Restores a backup. Wrong password -> throws "Wrong backup password". The app restarts afterwards. */
    fun restore(ctx: Context, store: Store, input: InputStream, password: String) {
        val head = ByteArray(5 + 16 + 12)
        var n = 0; while (n < head.size) { val r = input.read(head, n, head.size - n); if (r < 0) break; n += r }
        if (n < head.size || !head.copyOfRange(0, 4).contentEquals(MAGIC)) throw IllegalArgumentException("This isn't an iTeam backup file")
        val salt = head.copyOfRange(5, 21); val nonce = head.copyOfRange(21, 33)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(password, salt), GCMParameterSpec(128, nonce)) }
        // Decrypt fully into a temp folder first, so a wrong password never touches current data.
        val tmp = File(ctx.cacheDir, "restore").apply { deleteRecursively(); mkdirs() }
        var secrets: Map<String, String> = emptyMap()
        try {
            ZipInputStream(CipherInputStream(input, c)).use { zip ->
                while (true) {
                    val e = zip.nextEntry ?: break
                    if (e.name == "secrets.json") {
                        val o = JSONObject(zip.readBytes().toString(Charsets.UTF_8))
                        secrets = o.keys().asSequence().associateWith { o.getString(it) }
                    } else if (e.name.startsWith("files/") && !e.name.contains("..")) {
                        File(tmp, e.name.removePrefix("files/")).apply { parentFile?.mkdirs() }.outputStream().use { zip.copyTo(it) }
                    }
                }
            }
        } catch (e: Exception) { tmp.deleteRecursively(); throw IllegalArgumentException("Wrong backup password, or the file is damaged") }
        if (secrets["identity.v1"] == null) { tmp.deleteRecursively(); throw IllegalArgumentException("Backup is incomplete") }
        ctx.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        tmp.copyRecursively(ctx.filesDir, overwrite = true); tmp.deleteRecursively()
        store.importSecrets(secrets)
    }

    /** Daily auto backup to the place the user chose (called from the background worker). */
    fun autoIfDue(ctx: Context) {
        val store = Store.get(ctx)
        val uri = store.secret("backup.uri")?.let(Uri::parse) ?: return
        val pass = store.secret("backup.pass") ?: return
        val last = store.secret("backup.last")?.toLongOrNull() ?: 0
        if (System.currentTimeMillis() - last < 24 * 3600_000L) return
        runCatching {
            ctx.contentResolver.openOutputStream(uri, "wt")?.use { write(ctx, store, it, pass) }
            store.setSecret("backup.last", System.currentTimeMillis().toString())
        }
    }
}
