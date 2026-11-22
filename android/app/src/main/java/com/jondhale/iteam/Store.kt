package com.jondhale.iteam

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class Contact(val userID: String, var name: String, var pubkey: String)
data class Conv(val id: String, var title: String, var members: List<String>, var keyVersion: Int = 0, var updated: Long = 0, var unread: Int = 0) {
    val isGroup get() = id.startsWith("g_")
}
data class Msg(val id: String, val conv: String, val from: String, var text: String, val at: Long, val system: Boolean = false, var deleted: Boolean = false)

/** Local data: chats in a private file, keys in Android's encrypted storage (Keystore-backed). */
class Store private constructor(ctx: Context) {
    companion object {
        @Volatile private var inst: Store? = null
        fun get(ctx: Context) = inst ?: synchronized(this) { inst ?: Store(ctx.applicationContext).also { inst = it } }
    }

    private val secure = EncryptedSharedPreferences.create(ctx, "iteam.keys",
        MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)
    private val file = File(ctx.filesDir, "data.json")

    var webToken: String
        get() = secure.getString("ck.web", "") ?: ""
        set(v) { secure.edit().putString("ck.web", v).apply() }
    var me: String
        get() = secure.getString("me", "") ?: ""
        set(v) { secure.edit().putString("me", v).apply() }
    var myName: String
        get() = secure.getString("name", "") ?: ""
        set(v) { secure.edit().putString("name", v).apply() }
    var identity: ByteArray?
        get() = secure.getString("identity.v1", null)?.let { E2E.unb64(it) }
        set(v) { secure.edit().putString("identity.v1", v?.let { E2E.b64(it) }).apply() }
    val myPublicKey get() = identity?.let { E2E.publicKey(it) } ?: ""

    fun convKey(conv: String, version: Int): ByteArray? = secure.getString("conv.$conv.$version", null)?.let { E2E.unb64(it) }
    fun setConvKey(conv: String, version: Int, key: ByteArray) { secure.edit().putString("conv.$conv.$version", E2E.b64(key)).apply() }

    val contacts = mutableMapOf<String, Contact>()
    val convs = mutableMapOf<String, Conv>()
    val msgs = mutableListOf<Msg>()
    var since: Long = 0
    /** Envelopes whose group key hasn't arrived yet. */
    val pending = mutableListOf<CloudKit.Incoming>()

    init { load() }

    @Synchronized fun load() {
        if (!file.exists()) return
        val o = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        since = o.optLong("since")
        o.optJSONArray("contacts")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).let { c ->
            contacts[c.getString("u")] = Contact(c.getString("u"), c.getString("n"), c.getString("k")) } }
        o.optJSONArray("convs")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).let { c ->
            val m = c.getJSONArray("m"); convs[c.getString("id")] = Conv(c.getString("id"), c.getString("t"),
                (0 until m.length()).map { m.getString(it) }, c.optInt("v"), c.optLong("up"), c.optInt("un")) } }
        o.optJSONArray("msgs")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).let { m ->
            msgs += Msg(m.getString("id"), m.getString("c"), m.getString("f"), m.getString("t"), m.getLong("at"), m.optBoolean("s"), m.optBoolean("d")) } }
        o.optJSONArray("pending")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).let { p ->
            pending += CloudKit.Incoming(p.getString("n"), p.getString("f"), p.getString("cr"), p.getString("c"), p.getInt("k"), E2E.unb64(p.getString("b")), p.getLong("at")) } }
    }

    @Synchronized fun save() {
        val o = JSONObject().put("since", since)
        o.put("contacts", JSONArray(contacts.values.map { JSONObject().put("u", it.userID).put("n", it.name).put("k", it.pubkey) }))
        o.put("convs", JSONArray(convs.values.map { JSONObject().put("id", it.id).put("t", it.title).put("m", JSONArray(it.members)).put("v", it.keyVersion).put("up", it.updated).put("un", it.unread) }))
        o.put("msgs", JSONArray(msgs.takeLast(5000).map { JSONObject().put("id", it.id).put("c", it.conv).put("f", it.from).put("t", it.text).put("at", it.at).put("s", it.system).put("d", it.deleted) }))
        o.put("pending", JSONArray(pending.takeLast(500).map { JSONObject().put("n", it.name).put("f", it.from).put("cr", it.creator).put("c", it.conv).put("k", it.kind).put("b", E2E.b64(it.body)).put("at", it.created) }))
        val tmp = File(file.path + ".tmp"); tmp.writeText(o.toString()); tmp.renameTo(file)
    }

    fun signOut() { secure.edit().remove("ck.web").apply() }
    fun name(of: String): String = if (of == me) "You" else contacts[of]?.name ?: "Someone"
}
