package com.jondhale.iteam

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// Attendance and Finance — same records, permissions and routing as the iPhone.

// MARK: - Attendance data (full objects: the iPhone needs every key)

object AttData {
    fun company(name: String, owner: String) = JSONObject().put("name", name).put("ownerID", owner).put("adminConvID", "").put("admins", JSONArray())
        .put("dutyStart", 570).put("dutyEnd", 1110).put("grace", 15).put("halfDayAfter", 60).put("weeklyOff", JSONArray().put(1))
        .put("selfPunch", true).put("needPhoto", false).put("needGeo", false).put("needQR", false).put("kiosk", true)
        .put("lat", 0.0).put("lon", 0.0).put("radius", 200.0).put("qrSecret", "").put("leaveTypes", JSONArray(listOf("Casual", "Sick", "Earned")))
    fun member(userID: String, first: String, last: String, mobile: String) = JSONObject().put("userID", userID).put("first", first).put("last", last)
        .put("sex", "").put("department", "").put("designation", "").put("mobile", mobile).put("email", "").put("fields", JSONArray())
        .put("pinHash", "").put("active", true)
    fun entry() = JSONObject().put("method", "manual").put("qrIn", "").put("qrOut", "").put("note", "").put("markedBy", "")
    fun leave(from: Long, to: Long, half: Boolean, type: String, paid: Boolean, reason: String) = JSONObject()
        .put("from", SwiftDate.from(from)).put("to", SwiftDate.from(to)).put("halfDay", half).put("type", type).put("paid", paid)
        .put("reason", reason).put("files", JSONArray()).put("decidedBy", "").put("note", "")
    fun holiday(name: String) = JSONObject().put("name", name).put("type", "govt")

    val statuses = listOf("present", "grace", "late", "halfday", "absent", "leave", "unpaid", "holiday", "off")
    fun label(s: String) = when (s) {
        "present" -> "Present"; "grace" -> "Present (grace)"; "late" -> "Late"; "halfday" -> "Half day"; "absent" -> "Absent"
        "leave" -> "Paid leave"; "unpaid" -> "Unpaid leave"; "holiday" -> "Holiday"; "off" -> "Weekly off"; "open" -> "Not marked yet"
        else -> s.replaceFirstChar { it.uppercase() }
    }
    fun code(s: String) = when (s) { "present" -> "P"; "grace" -> "G"; "late" -> "L"; "halfday" -> "H"; "absent" -> "A"; "leave" -> "PL"; "unpaid" -> "UL"; "holiday" -> "HO"; "off" -> "WO"; else -> "·" }
    fun color(s: String): Long = when (s) {
        "present" -> 0xFF34C759; "grace" -> 0xFF30B0C7; "late" -> 0xFFFF9500; "halfday" -> 0xFFFFCC00; "absent" -> 0xFFFF3B30
        "leave" -> 0xFF5856D6; "unpaid" -> 0xFFAF52DE; "holiday" -> 0xFF007AFF; "off" -> 0xFF8E8E93; else -> 0xFFC7C7CC
    }
    private fun fmt() = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    fun key(ms: Long): String = fmt().format(Date(ms))
    fun date(key: String): Long = runCatching { fmt().parse(key)!!.time }.getOrDefault(System.currentTimeMillis())
    fun minutes(ms: Long): Int { val c = Calendar.getInstance().apply { timeInMillis = ms }; return c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE) }
    fun clock(min: Int) = "%d:%02d %s".format(((min / 60) + 11) % 12 + 1, min % 60, if (min < 720) "AM" else "PM")
    fun auto(inAt: Long, start: Int, c: JSONObject): String {
        val m = minutes(inAt)
        return when {
            m <= start -> "present"
            m <= start + c.optInt("grace", 15) -> "grace"
            m <= start + c.optInt("halfDayAfter", 60) -> "late"
            else -> "halfday"
        }
    }
}

val Rec.ak get() = s("kind")
fun Rec.dutyStart(c: JSONObject) = if (d.has("dutyStart") && !d.isNull("dutyStart")) d.optInt("dutyStart") else c.optInt("dutyStart", 570)
fun Rec.dutyEnd(c: JSONObject) = if (d.has("dutyEnd") && !d.isNull("dutyEnd")) d.optInt("dutyEnd") else c.optInt("dutyEnd", 1110)
val Rec.memberName: String get() = listOf(d.optString("first"), d.optString("last")).filter { it.isNotEmpty() }.joinToString(" ")
fun isStaff(c: JSONObject, user: String) = user == c.optString("ownerID") || (c.optJSONArray("admins")?.strings()?.contains(user) ?: false)
private fun JSONObject.dateMs(k: String): Long? = optDoubleOrNull(k)?.let { SwiftDate.toMillis(it) }

/** The day's status for one member, like the iPhone's Att.status. */
fun attStatus(member: Rec, c: JSONObject, day: Long, entry: Rec?, leaves: List<Rec>, holidays: List<Rec>): String {
    if (entry != null && !entry.deleted) {
        if (entry.status.isNotEmpty()) return entry.status
        entry.d.dateMs("inAt")?.let { return AttData.auto(it, member.dutyStart(c), c) }
    }
    val k = AttData.key(day)
    val dayStart = AttData.date(k)
    leaves.firstOrNull { l -> l.s("memberID") == member.id && l.status == "approved" && !l.deleted &&
        AttData.key(l.d.dateMs("from") ?: 0) <= k && k <= AttData.key(l.d.dateMs("to") ?: 0) }?.let { return if (it.d.optBoolean("paid", true)) "leave" else "unpaid" }
    if (holidays.any { it.s("day") == k && it.status == "approved" && !it.deleted }) return "holiday"
    val wd = Calendar.getInstance().apply { timeInMillis = day }.get(Calendar.DAY_OF_WEEK)
    if (c.optJSONArray("weeklyOff")?.let { a -> (0 until a.length()).any { a.optInt(it) == wd } } == true) return "off"
    member.d.dateMs("joined")?.let { if (dayStart < AttData.date(AttData.key(it))) return "none" }
    val today = AttData.key(System.currentTimeMillis())
    if (k == today) return if (AttData.minutes(System.currentTimeMillis()) > member.dutyEnd(c)) "absent" else "open"
    return if (k < today) "absent" else "none"
}

private fun attItem(id: String, kind: String, company: String, member: String = "", day: String = "", status: String = "", deleted: Boolean = false, data: JSONObject, by: String) =
    JSONObject().put("id", id).put("kind", kind).put("companyID", company).put("memberID", member).put("day", day).put("status", status)
        .put("deleted", deleted).put("at", SwiftDate.now()).put("data", E2E.b64(data.toString().toByteArray())).put("by", by)

private fun Rec.attItem(): JSONObject = attItem(id, ak, s("companyID"), s("memberID"), s("day"), status, deleted, d, s("by").ifEmpty { owner })

private fun forEmployee(items: List<JSONObject>) = items.map { it ->
    if (it.optString("kind") != "company") it else {
        val d = JSONObject(String(E2E.unb64(it.getString("data")))).put("qrSecret", "")
        JSONObject(it.toString()).put("data", E2E.b64(d.toString().toByteArray()))
    }
}

fun Sync.attCompany(id: String): JSONObject? = store.attRec(id)?.d
fun Sync.attAll(kind: String, company: String) = store.attList().filter { it.ak == kind && it.s("companyID") == company }

private fun Sync.ensureDirect(user: String): String {
    val id = directID(me, user)
    synchronized(store) { store.convs.getOrPut(id) { Conv(id, store.name(user), listOf(me, user), updated = System.currentTimeMillis()) } }
    return id
}

private fun Sync.sendLocal(items: List<JSONObject>) = synchronized(store) {
    applyAttendance(JSONObject().put("items", JSONArray(items)), me, "", SwiftDate.now()) {}
    store.save()
}

/** Staff → the admins' group (+ the employee's direct chat); employee → direct chats with the owner and admins. */
fun Sync.attSend(items: List<JSONObject>, c: JSONObject, about: String = "", loud: Boolean = false, preview: String? = null) {
    val body = { list: List<JSONObject> -> ev("attendance", JSONObject().put("items", JSONArray(list))) }
    if (isStaff(c, me)) {
        val g = store.conv(c.optString("adminConvID"))
        if (g != null && !g.left) send(g.id, body(items), loud, preview) else sendLocal(items)
        if (about.isNotEmpty() && about != me && !isStaff(c, about) && store.contacts[about] != null)
            send(ensureDirect(about), body(forEmployee(items)), loud, preview)
    } else {
        var sent = false
        for (staff in listOf(c.optString("ownerID")) + (c.optJSONArray("admins")?.strings() ?: emptyList())) {
            if (staff == me || staff.isEmpty()) continue
            runCatching { send(ensureDirect(staff), body(items), loud, preview); sent = true }
        }
        if (!sent) sendLocal(items)
    }
}

fun Sync.attCreateCompany(name: String, dutyStart: Int, dutyEnd: Int, weeklyOff: List<Int>): String {
    val id = "attc_" + newID()
    val d = AttData.company(name, me).put("dutyStart", dutyStart).put("dutyEnd", dutyEnd).put("weeklyOff", JSONArray(weeklyOff))
        .put("qrSecret", E2E.b64(E2E.newKey()))
    attSend(listOf(attItem(id, "company", id, data = d, by = me)), d)
    return id
}

fun Sync.attSaveCompany(rec: Rec, d: JSONObject, deleted: Boolean = false) {
    val item = attItem(rec.id, "company", rec.id, deleted = deleted, data = d, by = me)
    attSend(listOf(item), d)
    for (m in attAll("member", rec.id)) {
        val u = m.d.optString("userID")
        if (m.deleted || u.isEmpty() || isStaff(d, u) || store.contacts[u] == null) continue
        runCatching { send(ensureDirect(u), ev("attendance", JSONObject().put("items", JSONArray(forEmployee(listOf(item)))))) }
    }
}

fun Sync.attSaveMember(company: Rec, existing: Rec?, d: JSONObject) {
    val c = company.d
    val id = existing?.id ?: ("attm_" + newID())
    val user = d.optString("userID")
    if (existing == null) {
        if (!d.has("joined")) d.put("joined", SwiftDate.now())
        if (user.isNotEmpty() && user != me) d.remove("accepted") else d.put("accepted", true)
    }
    val item = attItem(id, "member", company.id, status = existing?.status ?: "employee", data = d, by = me)
    if (existing == null && user.isNotEmpty() && user != me) {
        attSend(listOf(item), c)
        if (c.optString("ownerID") == me && store.contacts[user] != null) {
            val holidays = attAll("holiday", company.id).filter { it.status == "approved" && !it.deleted }.map { it.attItem() }
            val bundle = forEmployee(listOf(company.attItem())) + item + holidays
            send(ensureDirect(user), ev("attendance", JSONObject().put("items", JSONArray(bundle))), loud = true,
                hintText = "🏢 ${store.myName} added you to “${c.optString("name")}” attendance — tap to accept")
        }
    } else attSend(listOf(item), c, about = user)
}

/** Owner only: admins share a group chat with the owner where all attendance travels. */
fun Sync.attSetAdmin(company: Rec, m: Rec, on: Boolean) {
    val c = JSONObject(company.d.toString())
    val user = m.d.optString("userID")
    if (c.optString("ownerID") != me || user.isEmpty()) return
    val admins = (c.optJSONArray("admins")?.strings() ?: emptyList()).toMutableList()
    if (on) {
        if (user !in admins) admins += user
        val g = store.conv(c.optString("adminConvID"))
        if (g != null && !g.left) addMembers(g.id, listOf(user)) else c.put("adminConvID", createGroup("${c.optString("name")} · Attendance", listOf(user)))
    } else admins.remove(user)
    c.put("admins", JSONArray(admins))
    attSaveCompany(company, c)
    val memItem = attItem(m.id, "member", company.id, status = if (on) "admin" else "employee", data = m.d, by = me)
    attSend(listOf(memItem), c)
    if (on) {
        val all = store.attList().filter { it.s("companyID") == company.id && it.ak != "company" }
        val ordered = listOf(attItem(company.id, "company", company.id, data = c, by = me)) + all.filter { it.ak == "member" }.map { it.attItem() } + all.filter { it.ak != "member" }.map { it.attItem() }
        ordered.chunked(150).forEach { send(ensureDirect(user), ev("attendance", JSONObject().put("items", JSONArray(it)).put("bulk", true))) }
    }
}

fun Sync.attAnswerInvite(m: Rec, accept: Boolean) {
    val c = attCompany(m.s("companyID")) ?: return
    val d = JSONObject(m.d.toString()).put("accepted", accept)
    attSend(listOf(attItem(m.id, "member", m.s("companyID"), status = m.status, data = d, by = me)), c, loud = true,
        preview = if (accept) "✅ ${store.myName} joined “${c.optString("name")}” attendance" else null)
}

fun Sync.attTodayEntry(member: Rec, day: Long = System.currentTimeMillis()): Rec? {
    val k = AttData.key(day)
    return store.attList().firstOrNull { it.ak == "entry" && it.s("memberID") == member.id && it.s("day") == k && !it.deleted }
}

/** Punch in, or out if already in. */
fun Sync.attPunch(member: Rec, company: Rec): String {
    val day = AttData.key(System.currentTimeMillis())
    val existing = attTodayEntry(member)
    val d = existing?.d?.let { JSONObject(it.toString()) } ?: AttData.entry()
    val what = when {
        !d.has("inAt") -> { d.put("inAt", SwiftDate.now()).put("method", "self").put("markedBy", me); "in" }
        !d.has("outAt") -> { d.put("outAt", SwiftDate.now()); "out" }
        else -> return "done"
    }
    val id = existing?.id ?: "atte_${member.id}_${day}_${newID().take(6)}"
    attSend(listOf(attItem(id, "entry", company.id, member.id, day, existing?.status ?: "", data = d, by = me)), company.d, about = member.d.optString("userID"))
    return what
}

/** Owner saves straight away; an admin's edit of an existing day becomes a change request for the owner. */
fun Sync.attSaveEntry(company: Rec, member: Rec, existing: Rec?, day: Long, status: String, delete: Boolean = false) {
    val c = company.d
    val key = AttData.key(day)
    val data = existing?.d?.let { JSONObject(it.toString()) } ?: AttData.entry().put("method", "edit").put("markedBy", me)
    val user = member.d.optString("userID")
    if (c.optString("ownerID") == me || existing == null && !delete) {
        val id = existing?.id ?: "atte_${member.id}_${key}_${newID().take(6)}"
        if (c.optString("ownerID") != me) data.put("method", "manual")
        attSend(listOf(attItem(id, "entry", company.id, member.id, key, status, delete, data, me)), c, about = user)
    } else {
        val ch = JSONObject().put("entryID", existing?.id ?: "").put("proposed", data).put("proposedStatus", status).put("reason", "")
            .put("deleteEntry", delete).put("decidedBy", "").put("note", "")
        attSend(listOf(attItem("attx_" + newID(), "change", company.id, member.id, key, "pending", data = ch, by = me)), c, loud = true,
            preview = "✏️ Change request for ${member.memberName} — ${dateText(day)}")
    }
}

fun Sync.attDecideChange(x: Rec, approve: Boolean) {
    val company = store.attRec(x.s("companyID")) ?: return
    val member = store.attRec(x.s("memberID")) ?: return
    val ch = JSONObject(x.d.toString()).put("decidedBy", me)
    attSend(listOf(attItem(x.id, "change", x.s("companyID"), x.s("memberID"), x.s("day"), if (approve) "approved" else "rejected", data = ch, by = me)), company.d)
    if (approve) attSaveEntry(company, member, store.attRec(ch.optString("entryID")), AttData.date(x.s("day")), ch.optString("proposedStatus"), ch.optBoolean("deleteEntry"))
}

fun Sync.attSaveLeave(company: Rec, member: Rec, existing: Rec?, d: JSONObject, status: String, deleted: Boolean = false) {
    val id = existing?.id ?: ("attl_" + newID())
    val item = attItem(id, "leave", company.id, member.id, AttData.key(d.dateMs("from") ?: System.currentTimeMillis()), status, deleted, d, me)
    val isRequest = status == "pending" && existing == null
    attSend(listOf(item), company.d, about = member.d.optString("userID"), loud = isRequest || (existing?.status == "pending" && status != "pending"),
        preview = if (isRequest) "🌴 ${member.memberName.ifEmpty { store.myName }} applied for leave" else null)
}

fun Sync.attDecideLeave(l: Rec, approve: Boolean, paid: Boolean) {
    val company = store.attRec(l.s("companyID")) ?: return
    val member = store.attRec(l.s("memberID")) ?: return
    attSaveLeave(company, member, l, JSONObject(l.d.toString()).put("decidedBy", me).put("paid", paid), if (approve) "approved" else "rejected")
}

fun Sync.attSaveHoliday(company: Rec, date: Long, name: String, existing: Rec? = null, status: String? = null, deleted: Boolean = false) {
    val c = company.d
    val st = status ?: if (c.optString("ownerID") == me) "approved" else "pending"
    val item = attItem(existing?.id ?: ("atth_" + newID()), "holiday", company.id, day = AttData.key(date), status = st, deleted = deleted, data = AttData.holiday(name), by = me)
    attSend(listOf(item), c, loud = st == "pending", preview = if (st == "pending") "🎌 Holiday “$name” needs your approval" else null)
    if (st == "approved" || deleted) for (m in attAll("member", company.id)) {
        val u = m.d.optString("userID")
        if (m.deleted || u.isEmpty() || isStaff(c, u) || store.contacts[u] == null) continue
        runCatching { send(ensureDirect(u), ev("attendance", JSONObject().put("items", JSONArray().put(item)))) }
    }
}

fun Sync.attDelete(r: Rec) {
    val c = attCompany(r.s("companyID")) ?: return
    val user = if (r.ak == "member") r.d.optString("userID") else store.attRec(r.s("memberID"))?.d?.optString("userID") ?: ""
    attSend(listOf(attItem(r.id, r.ak, r.s("companyID"), r.s("memberID"), r.s("day"), r.status, true, r.d, me)), c, about = user)
}

// MARK: - Apply (permission checks as on the iPhone)

internal fun Sync.applyAttendance(payload: JSONObject, from: String, convID: String, eventAt: Double, sys: (String) -> Unit) {
    val arr = payload.optJSONArray("items") ?: return
    val bulk = payload.optBoolean("bulk")
    val personal = convID.isEmpty() || convID.startsWith("s_")
    var count = 0
    val toGroup = mutableListOf<JSONObject>()
    val toUser = mutableMapOf<String, MutableList<JSONObject>>()
    var relay: JSONObject? = null
    for (i in 0 until arr.length()) {
        val it = arr.optJSONObject(i) ?: continue
        val id = it.optString("id")
        val kind = it.optString("kind")
        val existing = store.att[id]
        if (existing != null && (existing.ak != kind || it.optDouble("at") < existing.updated)) continue
        val oldStatus = existing?.status
        val oldEntry = if (existing?.ak == "entry") existing.d else null
        val wasDeleted = existing?.deleted ?: false
        val r = attWrite(it, existing, from, eventAt) ?: continue
        count++
        val comp = if (kind == "company") r.d else store.att[it.optString("companyID")]?.d ?: JSONObject()
        if (!bulk && !personal) attLine(r, existing == null, oldStatus, oldEntry, wasDeleted, from, comp).takeIf { it.isNotEmpty() }?.let(sys)
        if (from != me && comp.optString("ownerID") == me && !bulk) {
            relay = comp
            val user = if (r.ak == "member") r.d.optString("userID") else store.att[r.s("memberID")]?.d?.optString("userID") ?: ""
            val adminConv = comp.optString("adminConvID")
            if (!isStaff(comp, from) && adminConv.isNotEmpty() && convID != adminConv) toGroup += r.attItem()
            if (comp.optJSONArray("admins")?.strings()?.contains(from) == true && user.isNotEmpty() && !isStaff(comp, user) && r.ak in listOf("entry", "leave", "member"))
                toUser.getOrPut(user) { mutableListOf() } += r.attItem()
        }
    }
    if (bulk && count > 0 && !personal) sys("📋 Attendance records shared with ${if (from == me) "them" else "you"} ($count)")
    val c = relay
    if (c != null && (toGroup.isNotEmpty() || toUser.isNotEmpty())) {
        Thread {
            runCatching {
                store.conv(c.optString("adminConvID"))?.takeIf { !it.left && toGroup.isNotEmpty() }?.let { g -> send(g.id, ev("attendance", JSONObject().put("items", JSONArray(toGroup)))) }
                toUser.forEach { (u, items) -> if (store.contacts[u] != null) send(ensureDirect(u), ev("attendance", JSONObject().put("items", JSONArray(forEmployee(items))))) }
            }
        }.start()
    }
}

private fun Sync.attWrite(it: JSONObject, existing: Rec?, from: String, eventAt: Double): Rec? {
    val kind = it.optString("kind")
    val c = if (kind == "company") existing?.d else store.att[it.optString("companyID")]?.d
    var data = runCatching { JSONObject(String(E2E.unb64(it.optString("data")))) }.getOrNull() ?: return null
    var status = it.optString("status")
    var deleted = it.optBoolean("deleted")
    val atMs = SwiftDate.toMillis(eventAt)
    when (kind) {
        "company" -> {
            if (existing != null) { if (existing.d.optString("ownerID") != from || data.optString("ownerID") != from) return null }
            else if (data.optString("ownerID") != from) return null
            if (data.optString("qrSecret").isEmpty() && existing != null) data.put("qrSecret", existing.d.optString("qrSecret"))
            if (!isStaff(data, me)) data.put("qrSecret", "")
        }
        "member" -> {
            c ?: return null
            when {
                from == c.optString("ownerID") -> {}
                c.optJSONArray("admins")?.strings()?.contains(from) == true -> { if (status != "employee" || (existing != null && existing.status != "employee")) return null }
                existing != null && existing.d.optString("userID") == from && from.isNotEmpty() -> {
                    val d = JSONObject(existing.d.toString())
                    if (data.has("accepted")) d.put("accepted", data.get("accepted")) else d.remove("accepted")
                    data = d; status = existing.status; deleted = existing.deleted
                }
                else -> return null
            }
        }
        "entry" -> {
            c ?: return null
            val m = store.att[it.optString("memberID")] ?: return null
            if (from != c.optString("ownerID")) {
                val isSelf = m.d.optString("userID") == from && from.isNotEmpty()
                val canPunch = m.d.optBoolean("active", true) && (m.d.optString("userID").isEmpty() || m.d.optBoolean("accepted", false))
                val admin = c.optJSONArray("admins")?.strings()?.contains(from) == true
                if (!(admin || (isSelf && canPunch))) return null
                if (deleted) return null
                if (!admin) {
                    val near = listOf(-1, 0, 1).map { AttData.key(atMs + it * 86_400_000L) }
                    if (it.optString("day") !in near || status.isNotEmpty()) return null
                }
                if (existing != null) {
                    val old = existing.d
                    if (existing.deleted || old.has("outAt") || old.optDouble("inAt") != data.optDouble("inAt") || existing.status != status) return null
                }
            }
        }
        "leave" -> {
            c ?: return null
            val m = store.att[it.optString("memberID")] ?: return null
            if (!isStaff(c, from)) {
                if (m.d.optString("userID") != from || from.isEmpty()) return null
                if (existing != null) { if (existing.status != "pending" || status != "pending") return null }
                else if (status != "pending" || deleted) return null
            }
        }
        "holiday" -> {
            c ?: return null
            if (from != c.optString("ownerID")) {
                if (c.optJSONArray("admins")?.strings()?.contains(from) != true || deleted) return null
                if (existing != null && existing.status != "pending") return null
                status = "pending"
            }
        }
        "change" -> {
            c ?: return null
            if (from != c.optString("ownerID") && (c.optJSONArray("admins")?.strings()?.contains(from) != true || existing != null || status != "pending")) return null
        }
        else -> return null
    }
    val p = JSONObject().put("id", it.optString("id")).put("kind", kind).put("companyID", if (kind == "company") it.optString("id") else it.optString("companyID"))
        .put("memberID", it.optString("memberID")).put("day", it.optString("day")).put("status", status).put("deleted", existing?.deleted == true || deleted)
        .put("by", it.optString("by").ifEmpty { from }).put("d", data)
    val r = existing ?: Rec(it.optString("id"), "", from, from, System.currentTimeMillis(), p)
    r.p = p; r.updated = it.optDouble("at")
    if (deleted && existing?.deleted != true) r.deletedBy = from
    store.att[r.id] = r
    return r
}

private fun Sync.attName(memberID: String): String {
    val m = store.att[memberID] ?: return "someone"
    return m.memberName.ifEmpty { m.d.optString("userID").takeIf { it.isNotEmpty() }?.let { store.name(it) } ?: "someone" }
}

private fun Sync.attLine(r: Rec, isNew: Boolean, oldStatus: String?, oldEntry: JSONObject?, wasDeleted: Boolean, from: String, c: JSONObject): String {
    val who = if (from == me) "You" else store.name(from)
    val name = c.optString("name")
    val dayText = if (r.s("day").isEmpty()) "" else dateText(AttData.date(r.s("day")))
    if (r.deleted && !wasDeleted) return when (r.ak) {
        "company" -> "🏢 $who closed attendance for “$name”"
        "member" -> "👤 $who removed ${attName(r.id)} from “$name” attendance"
        "entry" -> "🗑 $who deleted ${attName(r.s("memberID"))}'s attendance for $dayText"
        "leave" -> "🌴 $who cancelled ${attName(r.s("memberID"))}'s leave request"
        "holiday" -> "🎌 $who removed the holiday “${r.d.optString("name")}”"
        else -> ""
    }
    if (r.deleted) return ""
    return when (r.ak) {
        "company" -> if (isNew) "🏢 $who set up attendance for “$name”" else "🏢 $who updated the attendance settings of “$name”"
        "member" -> {
            val u = r.d.optString("userID")
            when {
                !isNew && oldStatus == r.status && u.isNotEmpty() && u == from -> if (r.d.optBoolean("accepted")) "✅ ${attName(r.id)} joined “$name” attendance" else "❌ ${attName(r.id)} declined “$name” attendance"
                !isNew && oldStatus != r.status && r.status == "admin" -> "⭐ $who made ${attName(r.id)} an attendance admin of “$name”"
                !isNew && oldStatus == "admin" && r.status == "employee" -> "👤 ${attName(r.id)} is no longer an attendance admin"
                isNew -> "👤 $who added ${attName(r.id)} to “$name” attendance${if (u.isNotEmpty()) " — waiting for them to accept" else ""}"
                else -> "👤 $who updated ${attName(r.id)}'s attendance profile"
            }
        }
        "entry" -> {
            val e = r.d; val nm = attName(r.s("memberID"))
            val inAt = e.dateMs("inAt"); val outAt = e.dateMs("outAt")
            val via = when (e.optString("method")) { "manual", "edit", "" -> ""; "qr" -> " · via QR"; else -> " · via ${e.optString("method")}" }
            if (oldEntry?.has("inAt") != true && inAt != null && (outAt == null || isNew)) {
                val m = store.att[r.s("memberID")]
                val st = r.status.ifEmpty { m?.let { AttData.auto(inAt, it.dutyStart(c), c) } ?: "present" }
                "🕘 $nm punched in ${time(inAt)} · ${AttData.label(st)}$via"
            } else if (oldEntry?.has("outAt") != true && outAt != null && inAt != null && oldEntry?.optDouble("inAt") == e.optDouble("inAt")) {
                val mins = ((outAt - inAt) / 60000).toInt()
                "🕕 $nm punched out ${time(outAt)} · ${mins / 60} h ${mins % 60} m"
            } else "✏️ $who changed $nm's attendance for $dayText${if (r.status.isEmpty()) "" else " — " + AttData.label(r.status)}"
        }
        "leave" -> {
            val l = r.d; val half = l.optBoolean("halfDay"); val paid = l.optBoolean("paid", true)
            val from0 = l.dateMs("from") ?: 0; val to0 = l.dateMs("to") ?: from0
            val days = if (half) 0.5 else ((AttData.date(AttData.key(to0)) - AttData.date(AttData.key(from0))) / 86_400_000L + 1).coerceAtLeast(1).toDouble()
            val span = if (half) "half day" else "${fmtQty(days)} day${if (days == 1.0) "" else "s"}"
            val dates = dateText(from0) + if (days > 1) "–" + dateText(to0) else ""
            when (r.status) {
                "approved" -> if (isNew || oldStatus == "approved") "🌴 $who recorded $span ${if (paid) "paid" else "unpaid"} leave for ${attName(r.s("memberID"))} ($dates)"
                    else "✅ $who approved ${attName(r.s("memberID"))}'s leave ($dates, ${if (paid) "paid" else "unpaid"})"
                "rejected" -> "❌ $who rejected ${attName(r.s("memberID"))}'s leave ($dates)"
                else -> "🌴 ${attName(r.s("memberID"))} applied for $span ${l.optString("type")} leave ($dates)"
            }
        }
        "holiday" -> {
            val h = r.d.optString("name")
            when { r.status == "pending" -> "🎌 $who proposed the holiday “$h” on $dayText — waiting for the owner"
                r.status == "rejected" -> "🎌 $who rejected the holiday “$h”"
                oldStatus == "pending" -> "🎌 $who approved the holiday “$h” on $dayText"
                else -> "🎌 $who set $dayText as a holiday — “$h”" }
        }
        "change" -> {
            val nm = attName(r.s("memberID"))
            when (r.status) { "approved" -> "✅ $who approved the change to $nm's attendance for $dayText"
                "rejected" -> "❌ $who rejected the change to $nm's attendance for $dayText"
                else -> "✏️ $who asked to change $nm's attendance for $dayText — waiting for the owner" }
        }
        else -> ""
    }
}

// MARK: - Finance

object Fin {
    val incomeCategories = listOf("Sales", "Fees", "Salary", "Rent received", "Interest", "Refund", "Other income")
    val expenseCategories = listOf("Salary & wages", "Rent", "Electricity", "Phone & internet", "Fuel & travel", "Food", "Office supplies",
        "Professional fees", "Taxes & GST", "Bank charges", "Repairs", "Purchase", "Medical", "Education", "Savings", "Other")
    val modes = listOf("Cash", "UPI", "Bank", "Cheque", "Card", "RTGS", "NEFT")
    val repeats = listOf("none", "weekly", "monthly", "quarterly", "yearly")
    fun data(title: String = "", party: String = "", note: String = "", mode: String = "Cash", repeat: String = "none") = JSONObject()
        .put("title", title).put("party", party).put("note", note).put("mode", mode).put("reference", "").put("chequeNo", "").put("chequeBank", "")
        .put("chequeStatus", "").put("repeatRule", repeat).put("files", JSONArray()).put("approver", "").put("decidedBy", "").put("decisionNote", "")
        .put("bankMatched", false).put("target", 0.0).put("goalID", "")
    fun next(ms: Long, rule: String): Long {
        val c = Calendar.getInstance().apply { timeInMillis = ms }
        when (rule) { "weekly" -> c.add(Calendar.DAY_OF_MONTH, 7); "monthly" -> c.add(Calendar.MONTH, 1); "quarterly" -> c.add(Calendar.MONTH, 3); "yearly" -> c.add(Calendar.YEAR, 1) }
        return c.timeInMillis
    }
}

val Rec.isIn get() = s("direction") == "in" || s("direction") == "refundIn"
val Rec.finDate: Long get() = p.optDoubleOrNull("date")?.let { SwiftDate.toMillis(it) } ?: created

/** Companies (from Attendance) where I'm owner or admin — they become Finance books. */
fun Sync.finBooks(): List<Pair<String, String>> = listOf("personal" to "Personal") +
    store.attList().filter { it.ak == "company" && !it.deleted && isStaff(it.d, me) }.map { it.id to it.d.optString("name") }

fun Sync.finSave(existing: Rec?, book: String, date: Long, amount: Double, direction: String, status: String, category: String, data: JSONObject,
                 deleted: Boolean = false, kind: String = "entry") {
    val item = JSONObject().put("id", existing?.id ?: ("fin_" + newID())).put("kind", kind).put("book", book).put("date", SwiftDate.from(date))
        .put("amount", amount).put("direction", direction).put("status", status).put("category", category).put("deleted", deleted)
        .put("at", SwiftDate.now()).put("data", E2E.b64(data.toString().toByteArray()))
    val ask = status == "pending" && existing?.status != "pending"
    val body = ev("finance", JSONObject().put("items", JSONArray().put(item)))
    val g = if (book != "personal") attCompany(book)?.optString("adminConvID")?.let { store.conv(it) } else null
    if (g != null && !g.left) send(g.id, body, loud = ask, hintText = if (ask) "💸 Approval needed: ${money(amount)} — ${data.optString("title").ifEmpty { category }}" else null)
    else synchronized(store) { applyFinance(JSONObject().put("items", JSONArray().put(item)), me, "") {}; store.save() }
}

fun Sync.finDelete(r: Rec) = finSave(r, r.s("book"), r.finDate, r.amount, r.s("direction"), r.status, r.s("category"), JSONObject(r.d.toString()), deleted = true, kind = r.s("kind"))
fun Sync.finDecide(r: Rec, approve: Boolean, note: String) =
    finSave(r, r.s("book"), r.finDate, r.amount, r.s("direction"), if (approve) (if (r.finDate > System.currentTimeMillis()) "due" else "paid") else "rejected",
        r.s("category"), JSONObject(r.d.toString()).put("decidedBy", me).put("decisionNote", note))
fun Sync.finMarkPaid(r: Rec) {
    val d = r.d
    val rule = d.optString("repeatRule", "none")
    if (rule != "none") {
        finSave(null, r.s("book"), System.currentTimeMillis(), r.amount, r.s("direction"), "paid", r.s("category"), JSONObject(d.toString()).put("repeatRule", "none"))
        finSave(r, r.s("book"), Fin.next(r.finDate, rule), r.amount, r.s("direction"), "due", r.s("category"), JSONObject(d.toString()))
    } else finSave(r, r.s("book"), System.currentTimeMillis(), r.amount, r.s("direction"), "paid", r.s("category"), JSONObject(d.toString()))
}

internal fun Sync.applyFinance(payload: JSONObject, from: String, convID: String, sys: (String) -> Unit) {
    val arr = payload.optJSONArray("items") ?: return
    val personal = convID.isEmpty() || convID.startsWith("s_")
    for (i in 0 until arr.length()) {
        val it = arr.optJSONObject(i) ?: continue
        val id = it.optString("id")
        val ex = store.fin[id]
        if (ex != null && it.optDouble("at") < ex.updated) continue
        val book = it.optString("book")
        if (book == "personal") { if (from != me) continue } else {
            val comp = store.att[book]?.d ?: continue
            if (!isStaff(comp, from)) continue
            if (ex != null && ex.status == "pending" && it.optString("status") != "pending" && from != comp.optString("ownerID")) continue
            if (it.optBoolean("deleted") && from != comp.optString("ownerID") && ex?.by != from) continue
        }
        val data = runCatching { JSONObject(String(E2E.unb64(it.optString("data")))) }.getOrElse { Fin.data() }
        val wasPending = ex?.status == "pending"
        val p = JSONObject(it.toString()).apply { remove("data"); put("d", data); if (ex?.deleted == true) put("deleted", true) }
        val r = ex ?: Rec(id, "", from, from, System.currentTimeMillis(), p)
        r.p = p; r.updated = it.optDouble("at")
        if (it.optBoolean("deleted") && ex?.deleted != true) r.deletedBy = from
        store.fin[id] = r
        if (!personal && book != "personal") {
            val who = if (from == me) "You" else store.name(from)
            val what = "${money(r.amount)} ${if (r.isIn) "income" else "expense"} — ${data.optString("title").ifEmpty { r.s("category") }}"
            val st = it.optString("status")
            sys(when {
                r.deleted -> "🗑 $who deleted $what"
                st == "pending" -> "💸 $who asked approval for $what"
                wasPending && (st == "paid" || st == "due") -> "✅ $who approved $what"
                st == "rejected" -> "❌ $who rejected $what"
                ex == null -> "💰 $who added $what"
                else -> "💰 $who updated $what"
            })
        }
    }
}
