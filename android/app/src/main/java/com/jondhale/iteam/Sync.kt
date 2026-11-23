package com.jondhale.iteam

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Same events as the iPhone app (Swift Codable JSON). Dates are seconds since 1 Jan 2001. */
object SwiftDate {
    private const val REF = 978307200.0
    fun now(): Double = System.currentTimeMillis() / 1000.0 - REF
    fun toMillis(d: Double): Long = ((d + REF) * 1000).toLong()
}

class Sync(private val store: Store, private val cloud: CloudKit = CloudKit(store)) {
    data class Notice(val conv: String, val title: String, val text: String)

    val me get() = store.me

    fun directID(a: String, b: String) = "d_" + listOf(a, b).sorted().joinToString("|")
    private fun peer(conv: String): String? = if (conv.startsWith("d_")) conv.drop(2).split("|").firstOrNull { it != me } else null

    /** Sign-in step: who am I, and is this Apple ID already used on an iPhone with another key? */
    fun connect(name: String, replaceIfConflict: Boolean): String? {
        val id = cloud.me(); store.me = id
        if (name.isNotBlank()) store.myName = name.trim()
        val remote = cloud.profile(id)
        if (store.identity == null) {
            if (remote != null && !replaceIfConflict) return "conflict"
            store.identity = E2E.newIdentity()
        }
        if (remote == null || remote.pubkey != store.myPublicKey) {
            if (remote != null && !replaceIfConflict) return "conflict"
            cloud.saveProfile(id, store.myName.ifBlank { "Android user" }, store.myPublicKey, replace = true)
        } else if (name.isNotBlank() && remote.name != store.myName) {
            cloud.saveProfile(id, store.myName, store.myPublicKey, replace = false)
        }
        if (store.myName.isBlank() && remote != null) store.myName = remote.name
        store.save()
        return null
    }

    fun inviteLink(): String {
        fun safe(s: String) = s.replace('+', '-').replace('/', '_').trimEnd('=')
        return "iteam://add?u=${me}&k=${safe(store.myPublicKey)}&n=" + java.net.URLEncoder.encode(store.myName, "UTF-8").replace("+", "%20")
    }

    /** Adds a contact from an "iteam://add?…" link; the key is checked against their iCloud profile. */
    fun addContact(text: String): String = synchronized(store) { addLocked(text) }

    private fun addLocked(text: String): String {
        val link = Regex("iteam://add\\?\\S+").find(text)?.value ?: throw IllegalArgumentException("Paste an iTeam invite link")
        val q = android.net.Uri.parse(link)
        val u = q.getQueryParameter("u") ?: throw IllegalArgumentException("Invite link is incomplete")
        val p = cloud.profile(u) ?: throw IllegalArgumentException("That person isn't on iTeam yet")
        store.contacts[u] = Contact(u, p.name, p.pubkey)
        val conv = directID(me, u)
        store.convs.getOrPut(conv) { Conv(conv, p.name, listOf(me, u), updated = System.currentTimeMillis()) }
        store.save()
        return conv
    }

    private fun contact(id: String): Contact {
        store.contacts[id]?.let { return it }
        val p = cloud.profile(id) ?: throw CloudError("unknown user")
        return Contact(id, p.name, p.pubkey).also { store.contacts[id] = it }
    }

    private fun key(conv: String, version: Int): ByteArray? {
        if (conv.startsWith("g_")) return store.convKey(conv, version)
        store.convKey(conv, 0)?.let { return it }
        val other = if (conv.startsWith("s_")) me else peer(conv) ?: return null
        val pub = if (other == me) store.myPublicKey else contact(other).pubkey
        return E2E.pairwiseKey(store.identity ?: return null, pub, conv).also { store.setConvKey(conv, 0, it) }
    }

    // MARK: Send

    fun sendText(convID: String, text: String) = synchronized(store) { sendLocked(convID, text) }

    private fun sendLocked(convID: String, text: String) {
        val conv = store.convs[convID] ?: return
        val mid = UUID.randomUUID().toString().uppercase()
        val payload = JSONObject().put("id", mid).put("text", text).put("attachments", JSONArray())
        val event = JSONObject().put("id", UUID.randomUUID().toString().uppercase()).put("conv", convID).put("from", me)
            .put("at", SwiftDate.now()).put("body", JSONObject().put("message", JSONObject().put("_0", payload)))
        val version = if (conv.isGroup) conv.keyVersion else 0
        val k = key(convID, version) ?: throw CloudError("No key for this chat yet")
        val body = E2E.sealVersioned(event.toString().toByteArray(), k, version)
        val hint = JSONObject().put("n", store.myName).put("b", text.take(120)).put("k", "message")
        if (conv.isGroup) hint.put("t", conv.title)
        val sealedHint = E2E.b64(E2E.sealVersioned(hint.toString().toByteArray(), k, version))
        val to = conv.members.filter { it != me }
        cloud.modify(to.map { cloud.envelope(it, me, convID, 0, true, body, sealedHint) })
        store.msgs += Msg(mid, convID, me, text, System.currentTimeMillis())
        conv.updated = System.currentTimeMillis()
        store.save()
    }

    // MARK: Receive

    /** Returns the new notifications; [changed] is true when anything was added. */
    var changed = false
        private set

    fun poll(): List<Notice> {
        // Network first, outside the lock, so the screen never waits on it.
        val fresh = cloud.inbox(me, store.since)
        return synchronized(store) { pollLocked(fresh) }
    }

    private fun pollLocked(fresh: List<CloudKit.Incoming>): List<Notice> {
        val notices = mutableListOf<Notice>()
        val before = store.msgs.size + store.convs.size
        val retry = store.pending.toList()
        val incoming = retry + fresh.filter { f -> retry.none { it.name == f.name } }
        store.lastSync = System.currentTimeMillis()
        if (incoming.isEmpty()) { changed = false; return notices }
        store.pending.clear()
        for (inc in incoming) {
            if (inc.created > store.since) store.since = inc.created
            if (inc.creator.isNotEmpty() && inc.creator != inc.from) continue
            val ok = runCatching { process(inc, notices) }.getOrDefault(true)
            if (!ok && System.currentTimeMillis() - inc.created < 7L * 86_400_000) store.pending += inc
        }
        store.save()
        changed = notices.isNotEmpty() || store.msgs.size + store.convs.size != before || incoming.isNotEmpty()
        return notices
    }

    /** false = keep for later (key not here yet). */
    private fun process(inc: CloudKit.Incoming, notices: MutableList<Notice>): Boolean {
        val (version, sealed) = E2E.split(inc.body) ?: return true
        if (inc.kind == 1) {
            val pub = if (inc.from == me) store.myPublicKey else contact(inc.from).pubkey
            val pk = E2E.pairwiseKey(store.identity ?: return false, pub, "key:" + inc.conv)
            val share = JSONObject(String(E2E.open(sealed, pk)))
            if (share.getString("conv") != inc.conv) return true
            store.setConvKey(inc.conv, share.getInt("version"), E2E.unb64(share.getString("key")))
            store.convs[inc.conv]?.let { if (share.getInt("version") > it.keyVersion) it.keyVersion = share.getInt("version") }
            return true
        }
        val k = key(inc.conv, version) ?: return false
        val plain = runCatching { E2E.open(sealed, k) }.getOrNull() ?: return false
        val e = runCatching { JSONObject(String(plain)) }.getOrNull() ?: return true
        apply(e, inc.from, inc.conv, notices)
        return true
    }

    private fun ensureConv(id: String, from: String): Conv = store.convs.getOrPut(id) {
        val p = peer(id)
        Conv(id, if (p != null) contact(p).name else "Group", if (p != null) listOf(me, p) else listOf(me, from))
    }

    private fun apply(e: JSONObject, from: String, convID: String, notices: MutableList<Notice>) {
        val body = e.optJSONObject("body") ?: return
        val case = body.keys().asSequence().firstOrNull() ?: return
        val v = body.optJSONObject(case) ?: JSONObject()
        val p = v.optJSONObject("_0")
        val at = SwiftDate.toMillis(e.optDouble("at", SwiftDate.now()))
        val conv = ensureConv(convID, from)
        fun line(text: String, system: Boolean, id: String = UUID.randomUUID().toString()) {
            if (store.msgs.any { it.id == id }) return
            store.msgs += Msg(id, convID, from, text, at, system)
            conv.updated = maxOf(conv.updated, at)
            if (from != me) { conv.unread += 1; notices += Notice(convID, if (conv.isGroup) "${store.name(from)} · ${conv.title}" else store.name(from), text) }
        }
        when (case) {
            "message" -> if (p != null) {
                val files = p.optJSONArray("attachments")?.length() ?: 0
                var text = p.optString("text")
                if (files > 0) text = (if (text.isBlank()) "" else "$text\n") + "📎 $files attachment(s) — open on iPhone/iPad"
                if (p.optBoolean("once")) text = "👁 View-once media — open on iPhone/iPad"
                line(text, false, p.getString("id"))
            }
            "edit" -> store.msgs.firstOrNull { it.id == v.optString("id") && it.from == from }?.text = v.optString("text")
            "unsend" -> store.msgs.firstOrNull { it.id == v.optString("id") && it.from == from }?.let { it.text = "This message was deleted"; it.deleted = true }
            "group" -> if (p != null) {
                conv.title = p.optString("title", conv.title)
                val m = p.optJSONArray("members") ?: JSONArray()
                conv.members = (0 until m.length()).map { i -> m.getJSONObject(i).let { o ->
                    val id = o.getString("id"); if (id != me && store.contacts[id] == null) runCatching { contact(id) }; id } }
                conv.keyVersion = maxOf(conv.keyVersion, p.optInt("keyVersion"))
            }
            "leave" -> { conv.members = conv.members - from; line("${store.name(from)} left", true) }
            "task" -> if (p != null && p.optBoolean("deleted").not()) line("📋 Task: ${p.optString("title")} (full details on iPhone/iPad)", true, "task." + p.optString("id") + "." + at)
            "receipt", "react", "photo", "about", "facetime", "postSeen" -> {}
            else -> {}
        }
    }
}
