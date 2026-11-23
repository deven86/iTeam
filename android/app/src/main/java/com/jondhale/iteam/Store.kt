package com.jondhale.iteam

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** A file in a message: the same fields as the iPhone's AttachmentRef. */
data class Att(
    val id: String, val blob: String, val key: String, val name: String, val mime: String, val size: Int, val kind: String,
    val width: Double? = null, val height: Double? = null, val thumb: String? = null, val duration: Double? = null,
) {
    fun json(): JSONObject = JSONObject().put("id", id).put("blob", blob).put("key", key).put("name", name).put("mime", mime)
        .put("size", size).put("kind", kind).also { o ->
            width?.let { o.put("width", it) }; height?.let { o.put("height", it) }
            thumb?.let { o.put("thumb", it) }; duration?.let { o.put("duration", it) }
        }

    companion object {
        fun from(o: JSONObject) = Att(o.optString("id"), o.optString("blob"), o.optString("key"), o.optString("name"), o.optString("mime"),
            o.optInt("size"), o.optString("kind", "file"), o.optDoubleOrNull("width"), o.optDoubleOrNull("height"),
            o.optString("thumb").ifEmpty { null }, o.optDoubleOrNull("duration"))
        fun list(a: JSONArray?): List<Att> = if (a == null) emptyList() else (0 until a.length()).map { from(a.getJSONObject(it)) }
    }
}

fun JSONObject.optDoubleOrNull(k: String): Double? = if (has(k) && !isNull(k)) optDouble(k).takeIf { !it.isNaN() } else null
fun JSONObject.optStringOrNull(k: String): String? = if (has(k) && !isNull(k)) optString(k) else null

data class Contact(val userID: String, var name: String, var pubkey: String, var photo: String = "", var about: String = "")

data class Conv(
    val id: String, var title: String, var members: List<String>, var keyVersion: Int = 0, var updated: Long = 0, var unread: Int = 0,
    var owner: String = "", var admins: List<String> = emptyList(), var left: Boolean = false,
    /** member → [delivered, read] (iPhone time: seconds since 2001). */
    var receipts: MutableMap<String, DoubleArray> = mutableMapOf(),
) {
    val isGroup get() = id.startsWith("g_")
    fun canManage(me: String) = owner == me || admins.contains(me)
}

data class Msg(
    val id: String, val conv: String, val from: String, var text: String, val at: Long, val system: Boolean = false, var deleted: Boolean = false,
    val atts: List<Att> = emptyList(), val replyTo: String? = null, var reactions: MutableMap<String, String> = mutableMapOf(),
    /** "task:<id>" or "game:<id>" for cards in the chat. */
    val card: String? = null, var edited: Boolean = false,
)

/** Business Tasks: the iPhone's TaskPayload kept as JSON, plus acceptance, parts and comments. */
data class TaskRec(
    val id: String, var conv: String?, var p: JSONObject,
    var acceptance: MutableMap<String, String> = mutableMapOf(),
    var doneBy: MutableMap<String, Double> = mutableMapOf(),
    var comments: MutableList<JSONObject> = mutableListOf(),
    var deleted: Boolean = false, var updated: Long = 0,
) {
    val title get() = p.optString("title")
    val status get() = p.optString("status", "open")
    val assignees: List<String> get() = p.optJSONArray("assignees")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
    val createdBy get() = p.optString("createdBy")
    val due: Long? get() = p.optDoubleOrNull("dueAt")?.let { SwiftDate.toMillis(it) }
    val needsAcceptance get() = p.optBoolean("needsAcceptance")
    fun answer(user: String): String? = acceptance[user]?.substringBefore("|")
}

data class Game(
    val id: String, val conv: String, val x: String, val o: String, var board: String = "---------", var status: String = "invite",
    var winner: String = "", val createdBy: String, var updated: Double = 0.0,
) {
    val moves get() = board.count { it != '-' }
    val turn get() = if (moves % 2 == 0) x else o
    fun mark(u: String) = if (u == x) 'X' else 'O'
}

/** A business-module or Builder record: the iPhone's payload kept as JSON, plus where it lives and who made it.
 *  [conv] = "" means only on this phone. */
data class Rec(val id: String, var conv: String, var owner: String, var by: String, val created: Long, var p: JSONObject, var updated: Double = 0.0, var deletedBy: String = "") {
    fun s(k: String) = p.optString(k)
    val deleted get() = p.optBoolean("deleted")
    fun copyDeep() = copy(p = JSONObject(p.toString()))
}

/** Local data: chats in a private file, keys in Android's encrypted storage (Keystore-backed). */
class Store private constructor(ctx: Context) {
    companion object {
        @Volatile private var inst: Store? = null
        fun get(ctx: Context) = inst ?: synchronized(this) { inst ?: Store(ctx.applicationContext).also { inst = it } }
    }

    val dir: File = ctx.filesDir
    val cacheDir: File = ctx.cacheDir
    private val secure = EncryptedSharedPreferences.create(ctx, "iteam.keys",
        MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)
    private val file = File(ctx.filesDir, "data.json")

    // Encrypted storage is slow to read, so values are kept in memory after the first read.
    private val cache = java.util.concurrent.ConcurrentHashMap<String, String>()
    fun secret(k: String): String? = cache[k] ?: secure.getString(k, null)?.also { cache[k] = it }
    fun setSecret(k: String, v: String?) {
        if (v == null) cache.remove(k) else cache[k] = v
        secure.edit().putString(k, v).apply()
    }

    var webToken: String
        get() = secret("ck.web") ?: ""
        set(v) { setSecret("ck.web", v) }
    var me: String
        get() = secret("me") ?: ""
        set(v) { setSecret("me", v) }
    var myName: String
        get() = secret("name") ?: ""
        set(v) { setSecret("name", v) }
    var identity: ByteArray?
        get() = secret("identity.v1")?.let { E2E.unb64(it) }
        set(v) { setSecret("identity.v1", v?.let { E2E.b64(it) }); pubCache = null }
    @Volatile private var pubCache: String? = null
    val myPublicKey: String get() = pubCache ?: (identity?.let { E2E.publicKey(it) } ?: "").also { if (it.isNotEmpty()) pubCache = it }

    fun convKey(conv: String, version: Int): ByteArray? = secret("conv.$conv.$version")?.let { E2E.unb64(it) }
    fun setConvKey(conv: String, version: Int, key: ByteArray) { setSecret("conv.$conv.$version", E2E.b64(key)) }

    val contacts = mutableMapOf<String, Contact>()
    val convs = mutableMapOf<String, Conv>()
    val msgs = mutableListOf<Msg>()
    val tasks = mutableMapOf<String, TaskRec>()
    val games = mutableMapOf<String, Game>()
    val biz = mutableMapOf<String, Rec>()
    val build = mutableMapOf<String, Rec>()
    var since: Long = 0
    /** Envelopes whose group key hasn't arrived yet. */
    val pending = mutableListOf<CloudKit.Incoming>()
    /** Rooms state (personas, joined rooms, private threads) as JSON — see Rooms.kt. */
    var rooms: JSONObject = JSONObject()
    /** My details and app settings (name parts, age, sex, mobile, email, photo, about, privacy, look, bottom bar, modules). */
    var prefs: JSONObject = JSONObject()
    @Volatile var lastSync: Long = 0

    init { load() }

    @Synchronized fun load() {
        if (!file.exists()) return
        val o = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        since = o.optLong("since")
        o.optJSONArray("contacts")?.forEachObj { c -> contacts[c.getString("u")] = Contact(c.getString("u"), c.getString("n"), c.getString("k"), c.optString("p"), c.optString("ab")) }
        o.optJSONArray("convs")?.forEachObj { c ->
            val rec = mutableMapOf<String, DoubleArray>()
            c.optJSONObject("rc")?.let { r -> r.keys().forEach { k -> r.optJSONArray(k)?.let { a -> rec[k] = doubleArrayOf(a.optDouble(0, 0.0), a.optDouble(1, 0.0)) } } }
            convs[c.getString("id")] = Conv(c.getString("id"), c.getString("t"), c.getJSONArray("m").strings(), c.optInt("v"), c.optLong("up"), c.optInt("un"),
                c.optString("o"), c.optJSONArray("a")?.strings() ?: emptyList(), c.optBoolean("l"), rec)
        }
        o.optJSONArray("msgs")?.forEachObj { m ->
            val r = mutableMapOf<String, String>()
            m.optJSONObject("r")?.let { x -> x.keys().forEach { k -> r[k] = x.getString(k) } }
            msgs += Msg(m.getString("id"), m.getString("c"), m.getString("f"), m.getString("t"), m.getLong("at"), m.optBoolean("s"), m.optBoolean("d"),
                Att.list(m.optJSONArray("a")), m.optStringOrNull("re"), r, m.optStringOrNull("card"), m.optBoolean("e"))
        }
        o.optJSONArray("tasks")?.forEachObj { t ->
            val acc = mutableMapOf<String, String>(); t.optJSONObject("acc")?.let { x -> x.keys().forEach { acc[it] = x.getString(it) } }
            val parts = mutableMapOf<String, Double>(); t.optJSONObject("parts")?.let { x -> x.keys().forEach { parts[it] = x.getDouble(it) } }
            val com = mutableListOf<JSONObject>(); t.optJSONArray("com")?.forEachObj { com += it }
            tasks[t.getString("id")] = TaskRec(t.getString("id"), t.optStringOrNull("conv"), t.getJSONObject("p"), acc, parts, com, t.optBoolean("del"), t.optLong("up"))
        }
        o.optJSONArray("games")?.forEachObj { g ->
            games[g.getString("id")] = Game(g.getString("id"), g.getString("c"), g.getString("x"), g.getString("o"), g.getString("b"), g.getString("s"),
                g.optString("w"), g.optString("by"), g.optDouble("up", 0.0))
        }
        o.optJSONArray("pending")?.forEachObj { p ->
            pending += CloudKit.Incoming(p.getString("n"), p.getString("f"), p.getString("cr"), p.getString("c"), p.getInt("k"), E2E.unb64(p.getString("b")), p.getLong("at"))
        }
        rooms = o.optJSONObject("rooms") ?: JSONObject()
        prefs = o.optJSONObject("prefs") ?: JSONObject()
        fun recs(key: String, into: MutableMap<String, Rec>) = o.optJSONArray(key)?.forEachObj { r ->
            into[r.getString("id")] = Rec(r.getString("id"), r.optString("c"), r.optString("o"), r.optString("by"), r.optLong("cr"), r.getJSONObject("p"), r.optDouble("up", 0.0), r.optString("db"))
        }
        recs("biz", biz); recs("build", build)
    }

    @Synchronized fun save() {
        val o = JSONObject().put("since", since)
        o.put("contacts", JSONArray(contacts.values.map { JSONObject().put("u", it.userID).put("n", it.name).put("k", it.pubkey).put("p", it.photo).put("ab", it.about) }))
        o.put("convs", JSONArray(convs.values.map { c ->
            val rc = JSONObject(); c.receipts.forEach { (k, v) -> rc.put(k, JSONArray().put(v[0]).put(v[1])) }
            JSONObject().put("id", c.id).put("t", c.title).put("m", JSONArray(c.members)).put("v", c.keyVersion).put("up", c.updated)
                .put("un", c.unread).put("o", c.owner).put("a", JSONArray(c.admins)).put("l", c.left).put("rc", rc)
        }))
        o.put("msgs", JSONArray(msgs.takeLast(8000).map { m ->
            val j = JSONObject().put("id", m.id).put("c", m.conv).put("f", m.from).put("t", m.text).put("at", m.at).put("s", m.system).put("d", m.deleted)
            if (m.atts.isNotEmpty()) j.put("a", JSONArray(m.atts.map { it.json() }))
            m.replyTo?.let { j.put("re", it) }; m.card?.let { j.put("card", it) }
            if (m.reactions.isNotEmpty()) j.put("r", JSONObject(m.reactions as Map<*, *>))
            if (m.edited) j.put("e", true)
            j
        }))
        o.put("tasks", JSONArray(tasks.values.map { t ->
            JSONObject().put("id", t.id).put("conv", t.conv).put("p", t.p).put("acc", JSONObject(t.acceptance as Map<*, *>))
                .put("parts", JSONObject(t.doneBy as Map<*, *>)).put("com", JSONArray(t.comments)).put("del", t.deleted).put("up", t.updated)
        }))
        o.put("games", JSONArray(games.values.map { g ->
            JSONObject().put("id", g.id).put("c", g.conv).put("x", g.x).put("o", g.o).put("b", g.board).put("s", g.status).put("w", g.winner).put("by", g.createdBy).put("up", g.updated)
        }))
        o.put("pending", JSONArray(pending.takeLast(500).map { JSONObject().put("n", it.name).put("f", it.from).put("cr", it.creator).put("c", it.conv).put("k", it.kind).put("b", E2E.b64(it.body)).put("at", it.created) }))
        o.put("rooms", rooms)
        o.put("prefs", prefs)
        fun recs(m: Map<String, Rec>) = JSONArray(m.values.map { r ->
            JSONObject().put("id", r.id).put("c", r.conv).put("o", r.owner).put("by", r.by).put("cr", r.created).put("p", r.p).put("up", r.updated).put("db", r.deletedBy)
        })
        o.put("biz", recs(biz)); o.put("build", recs(build))
        val tmp = File(file.path + ".tmp"); tmp.writeText(o.toString()); tmp.renameTo(file)
    }

    fun signOut() { cache.remove("ck.web"); secure.edit().remove("ck.web").apply() }
    fun name(of: String): String = if (of == me) "You" else contacts[of]?.name ?: "Someone"

    /** Safe copies for the screen while the background check may be writing. */
    @Synchronized fun convList(): List<Conv> = convs.values.filter { !it.left || it.isGroup }.map { it.copy() }.sortedByDescending { it.updated }
    @Synchronized fun lastMessages(): Map<String, Msg> { val m = HashMap<String, Msg>(); for (x in msgs) m[x.conv] = x; return m }
    @Synchronized fun messages(conv: String): List<Msg> = msgs.filter { it.conv == conv }.sortedBy { it.at }.map { it.copy(reactions = it.reactions.toMutableMap()) }
    @Synchronized fun message(id: String): Msg? = msgs.firstOrNull { it.id == id }?.copy()
    @Synchronized fun conv(id: String): Conv? = convs[id]?.copy()
    @Synchronized fun markRead(id: String) { convs[id]?.let { if (it.unread > 0) { it.unread = 0; save() } } }
    @Synchronized fun taskList(): List<TaskRec> = tasks.values.filter { !it.deleted }.map { it.copy(p = JSONObject(it.p.toString())) }
    @Synchronized fun task(id: String): TaskRec? = tasks[id]?.let { it.copy(p = JSONObject(it.p.toString()), comments = it.comments.toMutableList()) }
    @Synchronized fun game(id: String): Game? = games[id]?.copy()
    @Synchronized fun contactList(): List<Contact> = contacts.values.map { it.copy() }.sortedBy { it.name.lowercase() }
    @Synchronized fun bizList(module: String? = null): List<Rec> = biz.values.filter { module == null || it.s("module") == module }.map { it.copyDeep() }
    @Synchronized fun bizRec(id: String): Rec? = biz[id]?.copyDeep()
    @Synchronized fun buildList(): List<Rec> = build.values.map { it.copyDeep() }
    @Synchronized fun buildRec(id: String): Rec? = build[id]?.copyDeep()
    @Synchronized fun pref(k: String, def: String = ""): String = prefs.optString(k, def)
    @Synchronized fun prefBool(k: String, def: Boolean): Boolean = if (prefs.has(k)) prefs.optBoolean(k) else def
    @Synchronized fun prefList(k: String, def: List<String>): List<String> = prefs.optJSONArray(k)?.strings() ?: def
    @Synchronized fun setPref(k: String, v: Any?) { if (v == null) prefs.remove(k) else prefs.put(k, if (v is List<*>) JSONArray(v) else v); save() }
    @Synchronized fun photoOf(user: String): String = if (user == me) pref("photo") else contacts[user]?.photo ?: ""
    @Synchronized fun unreadTotal(): Int = convs.values.sumOf { it.unread }
}

inline fun JSONArray.forEachObj(f: (JSONObject) -> Unit) { for (i in 0 until length()) optJSONObject(i)?.let(f) }
fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
