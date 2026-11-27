package com.jondhale.iteam

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Same events as the iPhone app (Swift Codable JSON). Dates are seconds since 1 Jan 2001. */
object SwiftDate {
    private const val REF = 978307200.0
    fun now(): Double = System.currentTimeMillis() / 1000.0 - REF
    fun toMillis(d: Double): Long = ((d + REF) * 1000).toLong()
    fun from(ms: Long): Double = ms / 1000.0 - REF
}

/** Swift enum case with one unnamed value: {"case": {"_0": payload}}. */
fun ev(case: String, payload: JSONObject) = JSONObject().put(case, JSONObject().put("_0", payload))
/** Swift enum case with named values: {"case": {...}}. */
fun evNamed(case: String, values: JSONObject) = JSONObject().put(case, values)
fun newID() = UUID.randomUUID().toString().uppercase()

class Sync(internal val store: Store, private val cloud: CloudKit = newCloud(store)) {
    data class Notice(val conv: String, val title: String, val text: String)

    val me get() = store.me
    val cloudKit get() = cloud

    fun directID(a: String, b: String) = "d_" + listOf(a, b).sorted().joinToString("|")
    private fun peer(conv: String): String? = if (conv.startsWith("d_")) conv.drop(2).split("|").firstOrNull { it != me } else null
    fun peerOf(conv: String) = peer(conv)

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

    fun rename(name: String) {
        store.myName = name.trim()
        cloud.saveProfile(me, store.myName, store.myPublicKey, replace = false)
    }

    private fun directs() = synchronized(store) { store.convs.values.filter { it.id.startsWith("d_") && !it.left && peer(it.id) != null }.map { it.id } }

    /** Saves my details; the name goes on my public profile, the photo to people I chat with (or everyone). */
    fun saveMyDetails(first: String, last: String, photo: ByteArray?, photoChanged: Boolean) {
        val name = listOf(first.trim(), last.trim()).filter { it.isNotEmpty() }.joinToString(" ")
        if (name.isNotEmpty()) store.myName = name
        val everyone = !store.prefBool("photoContactsOnly", true)
        cloud.saveProfile(me, store.myName, store.myPublicKey, replace = false,
            pic = if (everyone && photoChanged) photo else null, clearPic = photoChanged && (photo == null || !everyone))
        if (photoChanged) sendPhotoToContacts()
    }

    fun sendPhotoToContacts() {
        val b64 = store.pref("photo")
        val body = JSONObject().put("photo", if (b64.isEmpty()) JSONObject() else JSONObject().put("_0", b64))
        for (c in directs()) runCatching { send(c, body) }
    }

    fun sendAbout() {
        val text = if (store.prefBool("aboutContacts", true)) store.pref("about") else ""
        for (c in directs()) runCatching { send(c, JSONObject().put("about", JSONObject().put("_0", text))) }
    }

    /** Shares a contact in a chat (same text as the iPhone), and tells that person they were recommended. */
    fun recommend(contactID: String, convID: String) {
        val c = store.contacts[contactID] ?: return
        fun safe(s: String) = s.replace('+', '-').replace('/', '_').trimEnd('=')
        val link = "iteam://add?u=${c.userID}&k=${safe(c.pubkey)}&n=" + java.net.URLEncoder.encode(c.name, "UTF-8").replace("+", "%20") + "&r=1"
        sendText(convID, "👤 I recommend ${c.name} — tap to add: $link")
        val direct = directID(me, contactID)
        if (store.convs.containsKey(direct)) runCatching { sendText(direct, "📣 I recommended you to ${store.conv(convID)?.title ?: "a chat"}") }
    }

    fun inviteLink(): String {
        fun safe(s: String) = s.replace('+', '-').replace('/', '_').trimEnd('=')
        return "iteam://add?u=${me}&k=${safe(store.myPublicKey)}&n=" + java.net.URLEncoder.encode(store.myName, "UTF-8").replace("+", "%20")
    }

    /** Adds a contact from an "iteam://add?…" link; the key is checked against their iCloud profile. */
    fun addContact(text: String): String {
        // Accepts iteam://add?u=… and the web/iPhone share links (…?u=… or …&u=…).
        val u = Regex("[?&]u=([^&\\s]+)").find(text)?.groupValues?.get(1)?.let { java.net.URLDecoder.decode(it, "UTF-8") }
            ?: throw IllegalArgumentException("Paste or scan an iTeam invite link")
        return addContactID(u)
    }

    /** Adds someone by iTeam ID (Nearby, Rooms reveal, group members). */
    fun addContactID(u: String): String {
        val p = cloud.profile(u) ?: throw IllegalArgumentException(
            if (BuildConfig.RELAY && !u.startsWith("u_")) "This iPhone user hasn't turned on Android chat yet. Ask them: iTeam Settings → Talk to Android users → Turn on."
            else "That person isn't on iTeam yet")
        return synchronized(store) {
            store.contacts[u] = Contact(u, p.name, p.pubkey, p.pic, store.contacts[u]?.about ?: "")
            val conv = directID(me, u)
            store.convs.getOrPut(conv) { Conv(conv, p.name, listOf(me, u), updated = System.currentTimeMillis()) }
            store.save()
            conv
        }.also { conv ->
            if (store.pref("photo").isNotEmpty()) runCatching { send(conv, JSONObject().put("photo", JSONObject().put("_0", store.pref("photo")))) }
            if (store.prefBool("aboutContacts", true) && store.pref("about").isNotEmpty()) runCatching { send(conv, JSONObject().put("about", JSONObject().put("_0", store.pref("about")))) }
        }
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

    /** Encrypts and sends one event to everyone in the chat, uploading [files] (blob name → encrypted bytes) first,
     *  then applies it here too. */
    fun send(convID: String, body: JSONObject, loud: Boolean = false, hintText: String? = null, files: Map<String, ByteArray> = emptyMap()) {
        val event = JSONObject().put("id", newID()).put("conv", convID).put("from", me).put("at", SwiftDate.now()).put("body", body)
        val (sealed, hint, to) = synchronized(store) {
            val conv = store.convs[convID] ?: throw CloudError("Unknown chat")
            val version = if (conv.isGroup) conv.keyVersion else 0
            val k = key(convID, version) ?: throw CloudError("No key for this chat yet — wait a moment and try again")
            val sealedBody = E2E.sealVersioned(event.toString().toByteArray(), k, version)
            val h = if (loud && hintText != null) {
                val j = JSONObject().put("n", store.myName).put("b", hintText.take(140)).put("k", body.keys().next())
                if (conv.isGroup) j.put("t", conv.title)
                E2E.b64(E2E.sealVersioned(j.toString().toByteArray(), k, version))
            } else null
            Triple(sealedBody, h, conv.members.filter { it != me })
        }
        files.forEach { (name, bytes) -> cloud.uploadBlob(name, bytes) }
        if (to.isNotEmpty()) cloud.modify(to.map { cloud.envelope(it, me, convID, 0, loud, sealed, hint) })
        synchronized(store) {
            apply(event, me, convID, mutableListOf())
            store.save()
        }
    }

    /** Sends a group key to members (kind 1, sealed with each person's pairwise key). */
    private fun shareKey(conv: String, version: Int, key: ByteArray, to: List<String>) {
        val plain = JSONObject().put("conv", conv).put("version", version).put("key", E2E.b64(key)).toString().toByteArray()
        val ops = to.filter { it != me }.map { u ->
            val pk = E2E.pairwiseKey(store.identity!!, contact(u).pubkey, "key:$conv")
            cloud.envelope(u, me, conv, 1, false, E2E.sealVersioned(plain, pk, 0), null)
        }
        if (ops.isNotEmpty()) cloud.modify(ops)
    }

    private fun groupPayload(c: Conv, members: List<String>, version: Int): JSONObject {
        val arr = JSONArray(members.map { id ->
            JSONObject().put("id", id).put("name", if (id == me) store.myName else store.name(id))
                .put("role", if (id == c.owner) "owner" else if (c.admins.contains(id)) "admin" else "member")
        })
        return JSONObject().put("title", c.title).put("members", arr).put("keyVersion", version)
    }

    fun createGroup(title: String, people: List<String>): String {
        val id = "g_" + newID()
        val key = E2E.newKey()
        val members = listOf(me) + people.distinct().filter { it != me }.take(255)
        synchronized(store) {
            store.setConvKey(id, 1, key)
            store.convs[id] = Conv(id, title, members, keyVersion = 1, updated = System.currentTimeMillis(), owner = me)
            store.save()
        }
        shareKey(id, 1, key, members)
        val c = store.conv(id)!!
        send(id, ev("group", groupPayload(c, members, 1)), loud = true, hintText = "${store.myName} added you to “$title”")
        return id
    }

    fun addMembers(convID: String, people: List<String>) {
        val c = store.conv(convID) ?: return
        val new = people.filter { !c.members.contains(it) }.take((256 - c.members.size).coerceAtLeast(0))
        if (new.isEmpty()) return
        val key = store.convKey(convID, c.keyVersion) ?: throw CloudError("No group key yet")
        shareKey(convID, c.keyVersion, key, new)
        val all = c.members + new
        synchronized(store) { store.convs[convID]?.members = all }
        send(convID, ev("group", groupPayload(c, all, c.keyVersion)), loud = true,
            hintText = "${store.myName} added ${new.joinToString { store.name(it) }}")
    }

    fun leave(convID: String) {
        send(convID, JSONObject().put("leave", JSONObject()))
        synchronized(store) { store.convs[convID]?.left = true; store.save() }
    }

    fun sendText(convID: String, text: String, replyTo: String? = null, atts: List<Att> = emptyList(), files: Map<String, ByteArray> = emptyMap(),
                 once: Boolean = false, showAt: Long? = null) {
        val p = JSONObject().put("id", newID()).put("text", text).put("attachments", JSONArray(atts.map { it.json() }))
        if (replyTo != null) p.put("replyTo", replyTo)
        if (once) p.put("once", true)
        if (showAt != null) p.put("at", SwiftDate.from(showAt))
        store.conv(convID)?.timer?.takeIf { it > 0 }?.let { p.put("ttl", it) }
        val preview = text.ifBlank {
            when (atts.firstOrNull()?.kind) { "image" -> "📷 Photo"; "video" -> "🎬 Video"; "audio" -> "🎤 Voice note"; null -> ""; else -> "📎 File" }
        }
        send(convID, ev("message", p), loud = showAt == null, hintText = if (once) "👁 View-once photo" else preview, files = files)
    }

    fun setTimer(convID: String, seconds: Int) = send(convID, evNamed("chatTimer", JSONObject().put("seconds", seconds)))
    fun markOpened(msgID: String) = synchronized(store) { store.msgs.firstOrNull { it.id == msgID }?.opened = true; store.save() }

    fun react(convID: String, msgID: String, emoji: String?) {
        val v = JSONObject().put("id", msgID); if (emoji != null) v.put("emoji", emoji)
        send(convID, evNamed("react", v))
    }
    fun unsend(convID: String, msgID: String) = send(convID, evNamed("unsend", JSONObject().put("id", msgID)))
    fun edit(convID: String, msgID: String, text: String) = send(convID, evNamed("edit", JSONObject().put("id", msgID).put("text", text)))

    /** Read receipt up to the newest message from others (iPhone shows blue ticks). */
    fun readReceipt(convID: String) {
        val newest = synchronized(store) { store.msgs.lastOrNull { it.conv == convID && it.from != me && !it.system }?.at } ?: return
        val t = SwiftDate.from(newest)
        val key = "rr.$convID"
        if ((store.secret(key)?.toDoubleOrNull() ?: 0.0) >= t) return
        store.setSecret(key, t.toString())
        val read = store.prefBool("readReceipts", true)
        runCatching { send(convID, evNamed("receipt", JSONObject().put("delivered", t).put("read", if (read) t else 0.0))) }
    }

    // MARK: Tasks

    private val taskFields = listOf("title", "notes", "status", "priority", "dueAt", "policy", "assignees", "repeat", "followUp")

    fun createTask(convID: String, title: String, notes: String, assignees: List<String>, due: Long?, priority: Int, everyone: Boolean, followUp: JSONObject? = null) {
        val now = SwiftDate.now()
        val stamps = JSONObject(); taskFields.forEach { stamps.put(it, now) }
        val p = JSONObject().put("id", newID()).put("title", title).put("notes", notes).put("status", "open").put("priority", priority)
            .put("policy", "any").put("assignees", JSONArray(assignees)).put("createdBy", me).put("createdAt", now)
            .put("stamps", stamps).put("repeatRule", "none")
        if (due != null) p.put("dueAt", SwiftDate.from(due))
        if (followUp != null) p.put("followUp", followUp)
        if (assignees.any { it != me } && !everyone) p.put("needsAcceptance", true)
        val who = if (assignees.isEmpty()) "the group" else assignees.joinToString { store.name(it) }
        send(convID, ev("task", p), loud = true, hintText = "📋 New task for $who: $title")
    }

    /** Changes fields of a task (last change wins per field, like the iPhone). */
    fun updateTask(id: String, change: String, loud: Boolean = false, mutate: (JSONObject) -> List<String>) {
        val (convID, p) = synchronized(store) {
            val t = store.tasks[id] ?: return
            val p = JSONObject(t.p.toString())
            val fields = mutate(p)
            val st = p.optJSONObject("stamps") ?: JSONObject()
            val now = SwiftDate.now()
            fields.forEach { st.put(it, now) }
            p.put("stamps", st).put("change", change)
            Pair(t.conv, p)
        }
        if (convID == null) return
        send(convID, ev("task", p), loud = loud, hintText = "📋 ${p.optString("title")}: $change")
    }

    fun setTaskStatus(id: String, status: String) = updateTask(id, if (status == "done") "completed it" else "set it to ${if (status == "inProgress") "In progress" else "To do"}", loud = status == "done") { p ->
        p.put("status", status)
        if (status == "done") p.put("completedAt", SwiftDate.now()).put("completedBy", me) else { p.remove("completedAt"); p.remove("completedBy") }
        listOf("status")
    }

    fun answerTask(id: String, accept: Boolean, note: String) {
        val conv = store.task(id)?.conv ?: return
        send(conv, evNamed("taskAccept", JSONObject().put("taskID", id).put("accept", accept).put("note", note)), loud = true,
            hintText = "${if (accept) "accepted" else "declined"} a task")
    }

    fun taskPart(id: String, done: Boolean) {
        val conv = store.task(id)?.conv ?: return
        send(conv, evNamed("taskPart", JSONObject().put("taskID", id).put("done", done)))
    }

    fun comment(id: String, text: String) {
        val conv = store.task(id)?.conv ?: return
        send(conv, ev("comment", JSONObject().put("id", newID()).put("taskID", id).put("body", text)), loud = true, hintText = "💬 $text")
    }

    fun deleteTask(id: String) {
        val conv = store.task(id)?.conv ?: return
        send(conv, evNamed("taskDelete", JSONObject().put("id", id)))
    }

    // MARK: X and O

    fun gameInvite(convID: String, opponent: String) {
        val p = JSONObject().put("id", "xo_" + newID()).put("kind", "xo").put("xPlayer", me).put("oPlayer", opponent)
            .put("board", "---------").put("action", "invite").put("at", SwiftDate.now())
        send(convID, ev("game", p), loud = true, hintText = "🎮 ${store.myName} challenged you to X and O")
    }

    fun gameAct(id: String, action: String, cell: Int? = null) {
        val g = store.game(id) ?: return
        val p = JSONObject().put("id", g.id).put("kind", "xo").put("xPlayer", g.x).put("oPlayer", g.o).put("board", g.board)
            .put("action", action).put("at", SwiftDate.now())
        if (cell != null) p.put("cell", cell)
        send(g.conv, ev("game", p), loud = true, hintText = "🎮 X and O: your move")
    }

    // MARK: Receive

    var changed = false
        private set

    fun poll(): List<Notice> {
        // Network first, outside the lock, so the screen never waits on it.
        val fresh = cloud.inbox(me, store.since)
        return synchronized(store) { pollLocked(fresh) }
    }

    private fun pollLocked(fresh: List<CloudKit.Incoming>): List<Notice> {
        val notices = mutableListOf<Notice>()
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
        changed = true
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
        val atSwift = e.optDouble("at", SwiftDate.now())
        val at = SwiftDate.toMillis(atSwift)
        val conv = ensureConv(convID, from)
        val who = if (from == me) "You" else store.name(from)
        fun line(text: String, system: Boolean, id: String = newID(), atts: List<Att> = emptyList(), replyTo: String? = null, card: String? = null, notify: Boolean = true) {
            if (store.msgs.any { it.id == id }) return
            store.msgs += Msg(id, convID, from, text, at, system, atts = atts, replyTo = replyTo, card = card)
            conv.updated = maxOf(conv.updated, at)
            if (from != me && notify) {
                conv.unread += 1
                notices += Notice(convID, if (conv.isGroup) "${store.name(from)} · ${conv.title}" else store.name(from), text)
            }
        }
        when (case) {
            "message" -> if (p != null) {
                val atts = Att.list(p.optJSONArray("attachments"))
                val showAt = p.optDoubleOrNull("at")?.let { SwiftDate.toMillis(it) }?.takeIf { it > System.currentTimeMillis() }
                val ttl = p.optInt("ttl", 0)
                line(p.optString("text"), false, p.getString("id"), atts, p.optStringOrNull("replyTo"), notify = showAt == null || from == me)
                val i = store.msgs.indexOfLast { it.id == p.getString("id") }
                if (i >= 0) store.msgs[i] = store.msgs[i].copy(once = p.optBoolean("once"), expires = if (ttl > 0) at + ttl * 1000L else null, showAt = showAt)
            }
            "edit" -> store.msgs.firstOrNull { it.id == v.optString("id") && it.from == from }?.let { it.text = v.optString("text"); it.edited = true }
            "unsend" -> store.msgs.firstOrNull { it.id == v.optString("id") && it.from == from }?.let { it.text = "This message was deleted"; it.deleted = true }
            "react" -> store.msgs.firstOrNull { it.id == v.optString("id") }?.let { m ->
                val emoji = v.optStringOrNull("emoji")
                if (emoji == null) m.reactions.remove(from) else m.reactions[from] = emoji
            }
            "receipt" -> conv.receipts[from] = doubleArrayOf(v.optDouble("delivered", 0.0).let { if (it.isNaN()) 0.0 else it },
                v.optDouble("read", 0.0).let { if (it.isNaN()) 0.0 else it })
            "group" -> if (p != null) {
                conv.title = p.optString("title", conv.title)
                val m = p.optJSONArray("members") ?: JSONArray()
                val ids = mutableListOf<String>(); val admins = mutableListOf<String>()
                m.forEachObj { o ->
                    val id = o.getString("id"); ids += id
                    if (id != me && store.contacts[id] == null) runCatching { contact(id) }
                    if (store.contacts[id] != null && o.optString("name").isNotEmpty() && id != me) store.contacts[id]!!.name = store.contacts[id]!!.name.ifEmpty { o.optString("name") }
                    when (o.optString("role")) { "owner" -> conv.owner = id; "admin" -> admins += id }
                }
                val added = ids.filter { !conv.members.contains(it) }
                conv.members = ids; conv.admins = admins
                conv.keyVersion = maxOf(conv.keyVersion, p.optInt("keyVersion"))
                if (!ids.contains(me)) { conv.left = true; line("You were removed from this group", true, notify = false) }
                else if (added.isNotEmpty() && added.size < ids.size) line("$who added ${added.joinToString { store.name(it) }}", true, notify = false)
                else if (added.size == ids.size) line("$who created the group “${conv.title}”", true, notify = from != me)
            }
            "leave" -> { conv.members = conv.members - from; line("${store.name(from)} left", true, notify = false) }
            "task" -> if (p != null) applyTask(p, from, convID, ::line)
            "taskDelete" -> store.tasks[v.optString("id")]?.let { t ->
                if (t.createdBy == from) { t.deleted = true; t.updated = System.currentTimeMillis(); line("🗑 $who deleted the task “${t.title}”", true, notify = false) }
            }
            "taskAccept" -> store.tasks[v.optString("taskID")]?.let { t ->
                if (!t.assignees.contains(from)) return@let
                val accept = v.optBoolean("accept"); val note = v.optString("note")
                t.acceptance[from] = (if (accept) "accepted" else "declined") + if (note.isEmpty()) "" else "|$note"
                t.updated = System.currentTimeMillis()
                line("${if (accept) "🤝" else "✋"} $who ${if (accept) "accepted" else "declined"} the task “${t.title}”${if (note.isEmpty()) "" else " — $note"}", true)
            }
            "taskPart" -> store.tasks[v.optString("taskID")]?.let { t ->
                val done = v.optBoolean("done")
                if (done) t.doneBy[from] = atSwift else t.doneBy.remove(from)
                t.updated = System.currentTimeMillis()
                line("${if (done) "✅" else "↩︎"} $who marked their part ${if (done) "done" else "not done"} — “${t.title}”", true)
            }
            "comment" -> if (p != null) store.tasks[p.optString("taskID")]?.let { t ->
                if (t.comments.none { it.optString("id") == p.optString("id") }) {
                    t.comments += JSONObject(p.toString()).put("from", from).put("at", at)
                    t.updated = System.currentTimeMillis()
                    line("💬 $who on “${t.title}”: ${p.optString("body").take(140)}", true)
                }
            }
            "game" -> if (p != null && p.optString("kind", "xo") == "xo") applyGame(p, from, convID, atSwift, ::line)
            "biz" -> if (p != null) applyBiz(p, from, convID) { t -> line(t, true, notify = from != me) }
            "build" -> if (p != null) applyBuild(p, from, convID) { t -> line(t, true, notify = from != me) }
            "attendance" -> if (p != null) applyAttendance(p, from, convID, atSwift) { t -> line(t, true, notify = from != me) }
            "finance" -> if (p != null) applyFinance(p, from, convID) { t -> line(t, true, notify = from != me) }
            "photo" -> if (from != me) store.contacts[from]?.photo = v.optString("_0")
            "about" -> if (from != me) store.contacts[from]?.about = v.optString("_0")
            "post", "postReact", "postComment", "invite", "rsvp", "checkIn", "care", "medicine", "dose" -> applyMisc(case, v, p, from, convID, atSwift) { t, n -> line(t, true, notify = n && from != me) }
            "crmGroup", "crmLead", "crmActivity", "crmQuoteAnswer", "society", "gymMember", "gymTrainerAnswer", "gymPlan", "gymSession", "gymPayment" ->
                applyPhase3b(case, v, p, from, convID, atSwift) { t -> line(t, true, notify = from != me) }
            "chatTimer" -> { conv.timer = v.optInt("seconds"); val s = conv.timer
                line(if (s == 0) "⏱ $who turned off disappearing messages" else "⏱ $who turned on disappearing messages — new messages disappear after ${timerName(s)}", true, notify = false) }
            "checklist", "taskFile", "expense", "approval", "decision", "poll", "vote", "meeting", "meetingVote", "meetingAttend", "prescription", "rxAnswer", "vault", "healthEvent", "survey", "album" ->
                applyExtras(case, v, p, from, convID, atSwift) { t, card, n -> line(t, card == null, card = card, notify = n && from != me) }
            "postSeen", "facetime", "nowPlaying" -> {}
            else -> {}
        }
    }

    private fun applyTask(p: JSONObject, from: String, convID: String, line: (String, Boolean, String, List<Att>, String?, String?, Boolean) -> Unit) {
        val id = p.getString("id")
        val who = if (from == me) "You" else store.name(from)
        val existing = store.tasks[id]
        if (existing == null) {
            store.tasks[id] = TaskRec(id, if (convID.startsWith("s_")) null else convID, p, updated = System.currentTimeMillis())
            val assignees = p.optJSONArray("assignees")?.strings() ?: emptyList()
            val text = if (assignees.contains(me) && from != me) "📋 $who assigned you “${p.optString("title")}”${if (p.optBoolean("needsAcceptance")) " — accept or decline" else ""}"
                else "📋 $who created the task “${p.optString("title")}”"
            line(text, true, "task.$id", emptyList(), null, "task:$id", true)
            return
        }
        // Last writer wins per field.
        val mine = existing.p.optJSONObject("stamps") ?: JSONObject()
        val theirs = p.optJSONObject("stamps") ?: JSONObject()
        val created = p.optDouble("createdAt", 0.0)
        var changed = false
        for (f in taskFields) {
            val t = theirs.optDouble(f, created); val o = mine.optDouble(f, -1e12)
            if (t <= o) continue
            mine.put(f, t)
            val key = if (f == "repeat") "repeatRule" else f
            if (f == "status") { listOf("completedAt", "completedBy").forEach { k -> if (p.has(k)) existing.p.put(k, p.get(k)) else existing.p.remove(k) } }
            if (f == "followUp" && !p.has("followUp")) continue
            if (p.has(key)) existing.p.put(key, p.get(key)) else existing.p.remove(key)
            changed = true
        }
        existing.p.put("stamps", mine)
        if (changed) {
            existing.updated = System.currentTimeMillis()
            line("📋 $who ${p.optString("change").ifEmpty { "updated" }} — “${existing.title}”", true, newID(), emptyList(), null, null, from != me)
        }
    }

    private fun applyGame(p: JSONObject, from: String, convID: String, at: Double, line: (String, Boolean, String, List<Att>, String?, String?, Boolean) -> Unit) {
        val id = p.getString("id")
        var g = store.games[id]
        val who = if (from == me) "You" else store.name(from)
        if (g == null) {
            if (p.optString("action") != "invite" || (from != p.optString("xPlayer") && from != p.optString("oPlayer"))) return
            g = Game(id, convID, p.optString("xPlayer"), p.optString("oPlayer"), createdBy = from)
            store.games[id] = g
        }
        if (from != g.x && from != g.o || at < g.updated) return
        val other = if (from == g.x) g.o else g.x
        val otherName = if (other == me) "you" else store.name(other)
        var text = ""
        when (p.optString("action")) {
            "invite" -> text = "🎮 $who challenged $otherName to X and O"
            "accept" -> { if (g.status != "invite" || from == g.createdBy) return; g.status = "playing"; text = "🎮 $who accepted — ${if (g.turn == me) "your" else store.name(g.turn) + "'s"} move" }
            "decline" -> { if (g.status != "invite") return; g.status = "declined"; text = "🎮 $who declined the X and O game" }
            "move" -> {
                val c = p.optInt("cell", -1)
                if (g.status != "playing" || c !in 0..8 || g.turn != from || g.board[c] != '-') return
                val b = g.board.toCharArray(); b[c] = g.mark(from); g.board = String(b)
                val w = winner(g.board)
                if (w != null) { g.status = "won"; g.winner = if (w == 'X') g.x else g.o; text = "🏆 $who won X and O against $otherName!" }
                else if (!g.board.contains('-')) { g.status = "draw"; text = "🤝 X and O ended in a draw" }
            }
            "resign" -> { if (g.status != "playing") return; g.status = "won"; g.winner = other; text = "🏳️ $who resigned — ${if (other == me) "you win" else store.name(other) + " wins"}" }
            else -> return
        }
        g.updated = at
        if (text.isNotEmpty()) line(text, true, newID(), emptyList(), null, "game:$id", true)
    }

    companion object {
        private val lines = listOf(listOf(0, 1, 2), listOf(3, 4, 5), listOf(6, 7, 8), listOf(0, 3, 6), listOf(1, 4, 7), listOf(2, 5, 8), listOf(0, 4, 8), listOf(2, 4, 6))
        fun winner(b: String): Char? = lines.firstOrNull { l -> b[l[0]] != '-' && b[l[0]] == b[l[1]] && b[l[1]] == b[l[2]] }?.let { b[it[0]] }
    }
}
