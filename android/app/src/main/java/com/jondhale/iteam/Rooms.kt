package com.jondhale.iteam

import org.json.JSONArray
import org.json.JSONObject

/** Rooms — the same public rooms as the iPhone: a room name ("alias") and gender per room, public room chat,
 *  end-to-end encrypted private chats between two room members, and "Reveal" to swap real contacts when both agree. */
class Rooms(private val store: Store, private val cloud: CloudKit) {
    data class Room(val id: String, val name: String, val about: String, val owner: String)
    data class Member(val id: String, val room: String, val alias: String, val gender: String, val key: String)
    data class RMsg(val id: String, val room: String, val sndr: String, val rcpt: String, val kind: Int, val text: String, val at: Long)

    companion object {
        val genders = listOf("Male", "Female", "Other", "Prefer not to say")
        fun symbol(g: String) = when (g) { "Male" -> "♂"; "Female" -> "♀"; "Other" -> "⚧"; else -> "•" }
        val countries = listOf("IN" to "India", "US" to "United States", "GB" to "United Kingdom", "CA" to "Canada", "AU" to "Australia",
            "NZ" to "New Zealand", "AE" to "United Arab Emirates", "SA" to "Saudi Arabia", "QA" to "Qatar", "KW" to "Kuwait", "OM" to "Oman",
            "BH" to "Bahrain", "SG" to "Singapore", "MY" to "Malaysia", "TH" to "Thailand", "ID" to "Indonesia", "PH" to "Philippines",
            "VN" to "Vietnam", "JP" to "Japan", "KR" to "South Korea", "CN" to "China", "HK" to "Hong Kong", "TW" to "Taiwan", "NP" to "Nepal",
            "BD" to "Bangladesh", "LK" to "Sri Lanka", "PK" to "Pakistan", "AF" to "Afghanistan", "IR" to "Iran", "TR" to "Türkiye",
            "IL" to "Israel", "EG" to "Egypt", "ZA" to "South Africa", "NG" to "Nigeria", "KE" to "Kenya", "DE" to "Germany", "FR" to "France",
            "IT" to "Italy", "ES" to "Spain", "PT" to "Portugal", "NL" to "Netherlands", "BE" to "Belgium", "CH" to "Switzerland",
            "SE" to "Sweden", "NO" to "Norway", "IE" to "Ireland", "PL" to "Poland", "RU" to "Russia", "UA" to "Ukraine", "BR" to "Brazil",
            "MX" to "Mexico", "AR" to "Argentina")
        fun flag(cc: String) = cc.uppercase().map { String(Character.toChars(127397 + it.code)) }.joinToString("")
        val countryRooms = countries.map { (cc, n) -> Room("country-" + cc.lowercase(), "${flag(cc)} $n", "iTeam's room for $n — meet people, stay anonymous until you both reveal.", "") }
    }

    private val s: JSONObject get() = store.rooms
    private fun obj(k: String): JSONObject = s.optJSONObject(k) ?: JSONObject().also { s.put(k, it) }

    fun persona(room: String): JSONObject? = obj("joined").optJSONObject(room)
    fun joinedRooms(): List<Room> = synchronized(store) {
        val j = obj("joined"); val r = obj("rooms")
        j.keys().asSequence().mapNotNull { id -> r.optJSONObject(id)?.let { Room(id, it.optString("name"), it.optString("about"), it.optString("owner")) } }.sortedBy { it.name }.toList()
    }
    fun member(id: String): Member? = obj("members").optJSONObject(id)?.let { Member(id, it.optString("room"), it.optString("alias"), it.optString("gender"), it.optString("key")) }

    private var banned: Set<String> = emptySet()

    fun loadBans() {
        runCatching {
            val r = cloud.lookup(listOf("iteam-config"))["iteam-config"] ?: return
            val data = r.optJSONObject("fields")?.optJSONObject("data")?.optString("value") ?: return
            val c = JSONObject(String(E2E.unb64(data)))
            banned = c.optJSONArray("banned")?.strings()?.toSet() ?: emptySet()
        }
    }

    fun discover(): List<Room> {
        val list = cloud.query("Room", JSONArray(), listOf("name", "about", "owner"), limit = 150).map {
            Room(it.getString("recordName"), it.fstr("name").ifEmpty { "Room" }, it.fstr("about"), it.fstr("owner"))
        }
        val have = list.map { it.id }.toSet()
        return list + countryRooms.filter { it.id !in have }
    }

    fun join(room: Room, alias: String, gender: String) {
        if (room.id.startsWith("country-")) runCatching {
            cloud.modify(listOf(cloud.create("Room", room.id, JSONObject().put("name", cloud.v(room.name)).put("about", cloud.v(room.about)).put("owner", cloud.v("")))))
        }
        val pid = "p" + newID().replace("-", "").take(20).lowercase()
        val priv = E2E.newIdentity()
        val pub = E2E.publicKey(priv)
        cloud.modify(listOf(cloud.create("RoomMember", "rm-$pid", JSONObject().put("room", cloud.v(room.id)).put("alias", cloud.v(alias.trim()))
            .put("gender", cloud.v(gender)).put("key", cloud.v(pub)))))
        synchronized(store) {
            store.setSecret("room.persona.$pid", E2E.b64(priv))
            obj("joined").put(room.id, JSONObject().put("id", pid).put("alias", alias.trim()).put("gender", gender))
            obj("rooms").put(room.id, JSONObject().put("name", room.name).put("about", room.about).put("owner", room.owner))
            obj("members").put(pid, JSONObject().put("room", room.id).put("alias", alias.trim()).put("gender", gender).put("key", pub))
            store.save()
        }
    }

    /** Changes my room name in this room; my threads and messages stay. */
    fun rename(room: String, alias: String) {
        val p = persona(room) ?: return
        val a = alias.trim().take(30)
        if (a.isEmpty() || a == p.optString("alias")) return
        cloud.modify(listOf(cloud.create("RoomMember", "rm-${p.getString("id")}", JSONObject().put("alias", cloud.v(a)), "forceUpdate")))
        synchronized(store) {
            p.put("alias", a)
            obj("members").optJSONObject(p.getString("id"))?.put("alias", a)
            store.save()
        }
    }

    fun leave(room: Room) {
        val p = persona(room.id) ?: return
        runCatching { cloud.modify(listOf(cloud.delete("rm-" + p.getString("id")))) }
        synchronized(store) { obj("joined").remove(room.id); obj("rooms").remove(room.id); store.save() }
    }

    private fun loadMembers(ids: Collection<String>) {
        val missing = ids.filter { obj("members").optJSONObject(it) == null }.distinct()
        if (missing.isEmpty()) return
        cloud.lookup(missing.map { "rm-$it" }).values.forEach { r ->
            val id = r.getString("recordName").removePrefix("rm-")
            synchronized(store) {
                obj("members").put(id, JSONObject().put("room", r.fstr("room")).put("alias", r.fstr("alias").ifEmpty { "Guest" })
                    .put("gender", r.fstr("gender")).put("key", r.fstr("key")))
            }
        }
    }

    private fun text(r: JSONObject): String = (r.field("body") as? String)?.let { runCatching { String(E2E.unb64(it)) }.getOrNull() } ?: ""

    /** Public room chat (last 3 days). */
    fun roomChat(room: Room): List<RMsg> {
        val since = System.currentTimeMillis() - 3L * 86_400_000
        val recs = cloud.query("RoomMsg", JSONArray().put(cloud.eq("room", room.id)).put(cloud.eq("rcpt", "all")).put(cloud.createdAfter(since)),
            listOf("sndr", "kind", "body"), sortByCreated = true, limit = 300)
        var list = recs.filter { (it.optJSONObject("created")?.optString("userRecordName") ?: "") !in banned }.map {
            RMsg(it.getString("recordName"), room.id, it.fstr("sndr"), "all", ((it.field("kind") as? Number)?.toInt() ?: 0), text(it),
                it.optJSONObject("created")?.optLong("timestamp") ?: 0)
        }
        val hidden = list.filter { it.kind == 2 && it.sndr == room.owner }.map { it.text }.toSet()
        list = list.filter { it.id !in hidden && it.kind != 2 }
        loadMembers(list.map { it.sndr })
        return list
    }

    fun sendRoom(room: Room, text: String) {
        val p = persona(room.id) ?: return
        cloud.modify(listOf(cloud.create("RoomMsg", null, JSONObject().put("room", cloud.v(room.id)).put("rcpt", cloud.v("all"))
            .put("sndr", cloud.v(p.getString("id"))).put("kind", cloud.v(0)).put("body", cloud.bytes(text.trim().toByteArray())))))
    }

    // MARK: Private chats

    fun threadID(room: String, other: String) = "$room|$other"

    private fun threadKey(room: String, mine: String, theirs: String): ByteArray {
        val priv = store.secret("room.persona.$mine")?.let { E2E.unb64(it) } ?: throw CloudError("Room key missing")
        val m = member(theirs) ?: throw CloudError("Unknown member")
        return E2E.pairwiseKey(priv, m.key, room, "iteam-room-v1")
    }

    fun threads(): List<Pair<String, String>> = synchronized(store) {
        val d = obj("dms")
        d.keys().asSequence().map { it.split("|") }.filter { it.size == 2 }.map { it[0] to it[1] }
            .sortedByDescending { (r, o) -> d.optJSONArray("$r|$o")?.let { a -> a.optJSONObject(a.length() - 1)?.optLong("at") } ?: 0 }.toList()
    }

    fun dms(room: String, other: String): List<RMsg> = synchronized(store) {
        val a = obj("dms").optJSONArray(threadID(room, other)) ?: JSONArray()
        (0 until a.length()).map { a.getJSONObject(it) }.map { RMsg(it.getString("id"), room, it.getString("s"), it.getString("r"), it.optInt("k"), it.getString("t"), it.getLong("at")) }
    }

    fun unread(room: String, other: String): Int = obj("unread").optInt(threadID(room, other))
    fun markRead(room: String, other: String) = synchronized(store) { obj("unread").remove(threadID(room, other)); store.save() }
    fun iRevealed(room: String, other: String) = obj("revealed").optBoolean(threadID(room, other))
    fun theirReveal(room: String, other: String): String? = obj("theirReveal").optString(threadID(room, other)).ifEmpty { null }

    private fun keep(m: RMsg, other: String) {
        val d = obj("dms"); val k = threadID(m.room, other)
        val a = d.optJSONArray(k) ?: JSONArray().also { d.put(k, it) }
        for (i in 0 until a.length()) if (a.getJSONObject(i).getString("id") == m.id) return
        a.put(JSONObject().put("id", m.id).put("s", m.sndr).put("r", m.rcpt).put("k", m.kind).put("t", m.text).put("at", m.at))
    }

    fun sendDM(room: String, other: String, text: String, kind: Int = 0) {
        val p = persona(room) ?: return
        val mine = p.getString("id")
        loadMembers(listOf(other))
        val body = E2E.seal(text.toByteArray(), threadKey(room, mine, other))
        val id = "rmsg-" + newID()
        cloud.modify(listOf(cloud.create("RoomMsg", id, JSONObject().put("room", cloud.v(room)).put("rcpt", cloud.v(other))
            .put("sndr", cloud.v(mine)).put("kind", cloud.v(kind)).put("body", cloud.bytes(body)))))
        synchronized(store) {
            if (kind == 0) keep(RMsg(id, room, mine, other, 0, text, System.currentTimeMillis()), other)
            if (kind == 1) obj("revealed").put(threadID(room, other), true)
            if (obj("dms").optJSONArray(threadID(room, other)) == null) obj("dms").put(threadID(room, other), JSONArray())
            store.save()
        }
    }

    fun reveal(room: String, other: String, invite: String) = sendDM(room, other, invite, 1)

    /** New private messages to any of my room identities. Returns how many arrived. */
    fun pollDMs(): Int {
        val personas = synchronized(store) { val j = obj("joined"); j.keys().asSequence().map { it to j.getJSONObject(it).getString("id") }.toList() }
        if (personas.isEmpty()) return 0
        val since = obj("meta").optLong("lastDM", System.currentTimeMillis() - 7L * 86_400_000)
        var newest = since; var n = 0
        for ((room, pid) in personas) {
            val recs = cloud.query("RoomMsg", JSONArray().put(cloud.eq("rcpt", pid)).put(cloud.createdAfter(since - 2000)),
                listOf("room", "sndr", "kind", "body"), sortByCreated = true)
            loadMembers(recs.map { it.fstr("sndr") })
            for (r in recs) {
                val at = r.optJSONObject("created")?.optLong("timestamp") ?: 0
                newest = maxOf(newest, at)
                val other = r.fstr("sndr")
                val body = (r.field("body") as? String)?.let { E2E.unb64(it) } ?: continue
                val plain = runCatching { String(E2E.open(body, threadKey(room, pid, other))) }.getOrNull() ?: continue
                val kind = (r.field("kind") as? Number)?.toInt() ?: 0
                synchronized(store) {
                    if (kind == 1) obj("theirReveal").put(threadID(room, other), plain)
                    else {
                        val before = obj("dms").optJSONArray(threadID(room, other))?.length() ?: 0
                        keep(RMsg(r.getString("recordName"), room, other, pid, kind, plain, at), other)
                        if ((obj("dms").optJSONArray(threadID(room, other))?.length() ?: 0) > before) {
                            obj("unread").put(threadID(room, other), obj("unread").optInt(threadID(room, other)) + 1); n++
                        }
                    }
                }
            }
        }
        synchronized(store) { obj("meta").put("lastDM", newest); store.save() }
        return n
    }
}
