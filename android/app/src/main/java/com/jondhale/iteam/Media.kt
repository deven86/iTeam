package com.jondhale.iteam

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File

/** Files in messages: encrypted with a fresh key per file and uploaded once, exactly like the iPhone. */
object Media {
    const val MAX_BYTES = 100 * 1024 * 1024

    /** A ready-to-send attachment and its encrypted bytes (blob name → bytes). */
    data class Prepared(val att: Att, val blob: Pair<String, ByteArray>)

    private fun prepare(plain: ByteArray, name: String, mime: String, kind: String, w: Double? = null, h: Double? = null,
                        thumb: ByteArray? = null, duration: Double? = null, cache: File? = null): Prepared {
        require(plain.size <= MAX_BYTES) { "Files up to 100 MB" }
        val key = E2E.newKey()
        val blob = "B" + newID()
        val att = Att(newID(), blob, E2E.b64(key), name, mime, plain.size, kind, w, h, thumb?.let { E2E.b64(it) }, duration)
        cache?.let { File(it, att.id).writeBytes(plain) }
        return Prepared(att, blob to E2E.seal(plain, key))
    }

    private fun jpeg(b: Bitmap, q: Int): ByteArray = ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, q, it) }.toByteArray()

    private fun scaled(b: Bitmap, maxSide: Int): Bitmap {
        val s = maxSide.toFloat() / maxOf(b.width, b.height)
        return if (s >= 1f) b else Bitmap.createScaledBitmap(b, (b.width * s).toInt().coerceAtLeast(1), (b.height * s).toInt().coerceAtLeast(1), true)
    }

    fun image(ctx: Context, uri: Uri): Prepared {
        // ImageDecoder applies the photo's rotation (EXIF) for us.
        val bmp = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { d, info, _ ->
            val big = maxOf(info.size.width, info.size.height)
            if (big > 2048) d.setTargetSampleSize((big / 2048).coerceAtLeast(1))
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val full = scaled(bmp, 2048)
        return prepare(jpeg(full, 80), "Photo.jpg", "image/jpeg", "image", full.width.toDouble(), full.height.toDouble(),
            jpeg(scaled(full, 240), 60), cache = cacheDir(ctx))
    }

    fun file(ctx: Context, uri: Uri): Prepared {
        val name = ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: "File"
        val mime = ctx.contentResolver.getType(uri) ?: "application/octet-stream"
        if (mime.startsWith("image/") && !mime.contains("gif")) return image(ctx, uri)
        val bytes = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw IllegalArgumentException("Can't read that file")
        if (mime.startsWith("video/")) {
            val r = MediaMetadataRetriever()
            var thumb: ByteArray? = null; var dur: Double? = null; var w: Double? = null; var h: Double? = null
            runCatching {
                r.setDataSource(ctx, uri)
                r.frameAtTime?.let { f -> thumb = jpeg(scaled(f, 240), 60); w = f.width.toDouble(); h = f.height.toDouble() }
                dur = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull()?.div(1000)
            }
            r.release()
            return prepare(bytes, if (name.contains('.')) name else "Video.mp4", mime, "video", w, h, thumb, dur, cacheDir(ctx))
        }
        return prepare(bytes, name, mime, "file", cache = cacheDir(ctx))
    }

    fun voice(ctx: Context, f: File, seconds: Double): Prepared =
        prepare(f.readBytes(), "Voice note.m4a", "audio/mp4", "audio", duration = seconds, cache = cacheDir(ctx))

    fun cacheDir(ctx: Context) = File(ctx.cacheDir, "att").also { it.mkdirs() }

    fun thumb(att: Att): Bitmap? = att.thumb?.let { E2E.unb64(it) }?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }

    /** Decrypted file (downloaded once, then from the cache). */
    fun load(ctx: Context, cloud: CloudKit, att: Att): File {
        val f = File(cacheDir(ctx), att.id)
        if (f.exists() && f.length() > 0) return f
        val sealed = cloud.downloadBlob(att.blob)
        f.writeBytes(E2E.open(sealed, E2E.unb64(att.key)))
        return f
    }

    fun open(ctx: Context, f: File, att: Att) {
        val ext = att.name.substringAfterLast('.', "").ifEmpty { att.mime.substringAfter('/') }
        val named = File(File(ctx.cacheDir, "open").also { it.mkdirs() }, att.id.take(8) + "." + ext)
        f.copyTo(named, overwrite = true)
        val uri = FileProvider.getUriForFile(ctx, "com.jondhale.iteam.files", named)
        ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_VIEW).setDataAndType(uri, att.mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), att.name)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun size(n: Int): String = when {
        n > 1_000_000 -> String.format("%.1f MB", n / 1_000_000.0)
        n > 1_000 -> "${n / 1000} KB"
        else -> "$n B"
    }
}

/** Voice notes: AAC in an .m4a file, the same as the iPhone. */
class VoiceRecorder(private val ctx: Context) {
    private var rec: MediaRecorder? = null
    private var started = 0L
    val file = File(ctx.cacheDir, "voice.m4a")

    fun start() {
        file.delete()
        val r = if (android.os.Build.VERSION.SDK_INT >= 31) MediaRecorder(ctx) else @Suppress("DEPRECATION") MediaRecorder()
        rec = r.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioSamplingRate(44100); setAudioEncodingBitRate(64000)
            setOutputFile(file.absolutePath)
            prepare(); start()
        }
        started = System.currentTimeMillis()
    }

    /** Seconds recorded, or null if too short. */
    fun stop(): Double? {
        val r = rec ?: return null
        rec = null
        val secs = (System.currentTimeMillis() - started) / 1000.0
        return runCatching { r.stop(); r.release(); secs }.getOrNull()?.takeIf { it >= 0.8 }
    }

    fun cancel() { runCatching { rec?.stop() }; rec?.release(); rec = null; file.delete() }
}

object Player {
    private var mp: MediaPlayer? = null
    var playing: String? = null
        private set

    fun toggle(f: File, id: String, onEnd: () -> Unit) {
        if (playing == id) { stop(); onEnd(); return }
        stop()
        mp = MediaPlayer().apply {
            setDataSource(f.absolutePath); prepare(); start()
            setOnCompletionListener { stop(); onEnd() }
        }
        playing = id
    }

    fun stop() { runCatching { mp?.stop() }; mp?.release(); mp = null; playing = null }
}
