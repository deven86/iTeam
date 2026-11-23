package com.jondhale.iteam

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

// Task extras (checklists, files, expenses), approvals, polls, Meetings, Doctor & Patient, Care vault & health,
// Survey, Album — same events as the iPhone. Plus local reminders.

fun timerName(s: Int) = when (s) { 0 -> "Off"; 86400 -> "24 hours"; 7 * 86400 -> "7 days"; 90 * 86400 -> "90 days"; else -> "${s / 3600} h" }
val timers = listOf(0, 86400, 7 * 86400, 90 * 86400)

private fun key(t: String, id: String) = "$t:$id"
fun Sync.x(t: String, id: String) = store.misc[key(t, id)]?.copyDeep()
fun Sync.xs(t: String) = store.miscList(t)

private fun Sync.save(t: String, id: String, conv: String, from: String, at: Double, p: JSONObject, ex: Rec?): Rec {
    val r = ex ?: Rec(id, conv, from, from, SwiftDate.toMillis(at), JSONObject())
    r.p = p.put("t", t); store.misc[key(t, id)] = r
    return r
}

internal fun Sync.applyExtras(case: String, v: JSONObject, p: JSONObject?, from: String, convID: String, at: Double, line: (String, String?, Boolean) -> Unit) {
    val who = if (from == me) "You" else store.name(from)
    val personal = convID.startsWith("s_")
    fun task(id: String) = store.tasks[id]?.title
    when (case) {
        "checklist" -> { p ?: return
            val ex = store.misc[key("chk", p.getString("id"))]
            if (ex != null && p.optDouble("at") < ex.updated) return
            save("chk", p.getString("id"), convID, from, at, JSONObject(p.toString()).put("by", from), ex).updated = p.optDouble("at")
            if (p.optBoolean("done") && !p.optBoolean("deleted") && ex?.p?.optBoolean("done") != true) task(p.optString("taskID"))?.let { line("☑︎ $who ticked “${p.optString("title")}” in “$it”", null, false) }
        }
        "taskFile" -> { p ?: return
            val ex = store.misc[key("tfile", p.getString("id"))]
            if (ex != null) { ex.p.put("deleted", p.optBoolean("deleted")).put("title", p.optString("title")) }
            else save("tfile", p.getString("id"), convID, from, at, JSONObject(p.toString()), null)
            task(p.optString("taskID"))?.let { line(if (p.optBoolean("deleted")) "📎 $who removed “${p.optString("title")}” from “$it”" else "📎 $who attached “${p.optString("title")}” to “$it”", null, false) }
        }
        "expense" -> { p ?: return
            val ex = store.misc[key("exp", p.getString("id"))]
            if (ex != null && p.optDouble("at") <= ex.updated) return
            save("exp", p.getString("id"), convID, from, at, JSONObject(p.toString()), ex).updated = p.optDouble("at")
            task(p.optString("taskID"))?.let { line(if (p.optBoolean("deleted")) "🧾 $who removed the expense “${p.optString("title")}”" else "🧾 $who logged ${money(p.optDouble("amount"))} — ${p.optString("title")} (“$it”)", null, false) }
        }
        "approval" -> { p ?: return
            if (store.misc[key("appr", p.getString("id"))] != null) return
            save("appr", p.getString("id"), convID, from, at, JSONObject(p.toString()).put("decisions", JSONObject()), null)
            line(p.optString("title"), "approval:" + p.getString("id"), true)
            store.msgs.lastOrNull()?.let { if (it.card == "approval:" + p.getString("id")) store.msgs[store.msgs.size - 1] = it.copy(id = p.optString("messageID").ifEmpty { it.id }) }
        }
        "decision" -> { p ?: return
            val ap = store.misc[key("appr", p.optString("approvalID"))] ?: return
            if (ap.p.optJSONArray("approvers")?.strings()?.contains(from) != true) return
            val d = ap.p.optJSONObject("decisions") ?: JSONObject().also { ap.p.put("decisions", it) }
            if ((d.optJSONObject(from)?.optDouble("at") ?: 0.0) > at) return
            d.put(from, JSONObject().put("approved", p.optBoolean("approved")).put("note", p.optString("note")).put("at", at).also { o -> p.optDoubleOrNull("amount")?.let { o.put("amount", it) } })
            line("${if (p.optBoolean("approved")) "✅" else "❌"} $who ${if (p.optBoolean("approved")) "approved" else "rejected"} “${ap.s("title")}”${if (p.optString("note").isEmpty()) "" else " — " + p.optString("note")}", null, ap.owner == me)
        }
        "poll" -> { p ?: return
            if (store.misc[key("poll", p.getString("id"))] != null) return
            save("poll", p.getString("id"), convID, from, at, JSONObject(p.toString()).put("votes", JSONObject()), null)
            line(p.optString("question"), "poll:" + p.getString("id"), true)
        }
        "vote" -> { p ?: return
            val poll = store.misc[key("poll", p.optString("pollID"))] ?: return
            val votes = poll.p.optJSONObject("votes") ?: JSONObject().also { poll.p.put("votes", it) }
            if ((votes.optJSONObject(from)?.optDouble("at") ?: 0.0) > at) return
            val valid = (poll.p.optJSONArray("options")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("id") } } ?: emptyList())
            var choice = (p.optJSONArray("optionIDs")?.strings() ?: emptyList()).filter { it in valid }
            if (!poll.p.optBoolean("multiple")) choice = choice.take(1)
            votes.put(from, JSONObject().put("options", JSONArray(choice)).put("at", at))
        }
        "meeting" -> { p ?: return
            val ex = store.misc[key("meet", p.getString("id"))]
            if (ex != null) {
                val admin = from == ex.owner || (ex.p.optJSONArray("admins")?.strings()?.contains(from) ?: false)
                if (!admin || p.optDouble("at") < ex.updated) return
                if ((p.optBoolean("deleted") || p.optString("status") == "cancelled") && from != ex.owner) return
            }
            val old = ex?.p
            val q = JSONObject(p.toString()).put("votes", old?.optJSONObject("votes") ?: JSONObject())
            val r = save("meet", p.getString("id"), ex?.conv ?: convID, ex?.owner ?: from, at, q, ex); r.updated = p.optDouble("at")
            val start = SwiftDate.toMillis(p.optDouble("start")); val title = p.optString("title")
            val text = when {
                p.optBoolean("deleted") && old?.optBoolean("deleted") != true -> "📅 $who cancelled the meeting “$title”"
                ex == null -> "📅 $who scheduled “$title” — ${dateText(start)} ${time(start)} · ${if (p.optBoolean("online")) "online" else p.optString("place").ifEmpty { "in person" }}"
                old?.optString("status") != "done" && p.optString("status") == "done" -> "📅 “$title” marked done by $who — ${p.optJSONArray("attended")?.length() ?: 0} attended"
                old?.optString("minutes").isNullOrEmpty() && p.optString("minutes").isNotEmpty() -> "📝 $who added the minutes of “$title”"
                old?.optDouble("start") != p.optDouble("start") -> "📅 $who moved “$title” to ${dateText(start)} ${time(start)}"
                else -> "📅 $who updated the meeting “$title”"
            }
            if (ex == null) line(text, "meeting:" + p.getString("id"), true) else line(text, null, true)
        }
        "meetingVote" -> { val m = store.misc[key("meet", v.optString("meetingID"))] ?: return
            val votes = m.p.optJSONObject("votes") ?: JSONObject().also { m.p.put("votes", it) }
            (votes.optJSONObject(v.optString("pollID")) ?: JSONObject().also { votes.put(v.optString("pollID"), it) }).put(from, v.optInt("option"))
            val poll = m.p.optJSONArray("polls")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } }?.firstOrNull { it.optString("id") == v.optString("pollID") }
            poll?.optJSONArray("options")?.optString(v.optInt("option"))?.let { line("🗳 $who voted “$it” — ${poll.optString("question")}", null, false) }
        }
        "meetingAttend" -> { val m = store.misc[key("meet", v.optString("meetingID"))] ?: return
            val a = m.p.optJSONArray("attended") ?: JSONArray().also { m.p.put("attended", it) }
            if (!a.strings().contains(from)) a.put(from)
            line("✋ $who joined “${m.s("title")}”", null, false)
        }
        "prescription" -> { p ?: return
            val ex = store.misc[key("rx", p.getString("id"))]
            if (ex != null) {
                if (ex.owner != from || p.optDouble("at") <= ex.updated) return
                val q = JSONObject(p.toString()).put("status", ex.s("status")).put("answerNote", ex.s("answerNote"))
                save("rx", p.getString("id"), ex.conv, ex.owner, at, q, ex).updated = p.optDouble("at")
                line(if (p.optBoolean("deleted")) "🩺 $who cancelled a prescription" else "🩺 $who updated the prescription — ${p.optString("diagnosis").ifEmpty { "${p.optJSONArray("items")?.length() ?: 0} medicine(s)" }}", null, true)
            } else {
                save("rx", p.getString("id"), convID, from, at, JSONObject(p.toString()).put("status", ""), null).updated = p.optDouble("at")
                val names = p.optJSONArray("items")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("name") } }?.joinToString() ?: ""
                line("🩺 ${if (from == me) "You" else "Dr. " + store.name(from)} prescribed $names — waiting for ${if (p.optString("patientID") == me) "your" else p.optString("patientName") + "'s"} OK", "rx:" + p.getString("id"), true)
            }
        }
        "rxAnswer" -> { val rx = store.misc[key("rx", v.optString("id"))] ?: return
            if (rx.s("patientID") != from) return
            val accept = v.optBoolean("accept")
            rx.p.put("status", if (accept) "accepted" else "declined").put("answerNote", v.optString("note"))
            line(if (accept) "✅ $who accepted the prescription — medicines added to Care" else "✋ $who declined the prescription${if (v.optString("note").isEmpty()) "" else " — " + v.optString("note")}", null, true)
        }
        "vault" -> { p ?: return
            val ex = store.misc[key("vault", p.getString("id"))]
            save("vault", p.getString("id"), convID, ex?.owner ?: from, at, JSONObject(p.toString()), ex)
            store.misc[key("care", p.optString("profileID"))]?.let { if (!p.optBoolean("deleted") && ex == null) line("📁 $who added “${p.optString("title")}” to ${it.s("name")}'s vault", null, false) }
        }
        "healthEvent" -> { p ?: return
            val ex = store.misc[key("hev", p.getString("id"))]
            if (ex != null && p.optDouble("at") <= ex.updated) return
            save("hev", p.getString("id"), convID, ex?.owner ?: from, at, JSONObject(p.toString()), ex).updated = p.optDouble("at")
            store.misc[key("care", p.optString("profileID"))]?.let { line("🩺 $who updated ${it.s("name")}: ${p.optString("title")}", null, false) }
        }
        "survey" -> {
            val arr = p?.optJSONArray("items") ?: return
            for (i in 0 until arr.length()) {
                val it = arr.getJSONObject(i); val id = it.optString("id"); val kind = it.optString("kind")
                val ex = store.misc[key("sv", id)]
                if (ex != null && ((ex.by != from && ex.s("ownerID") != from) || it.optDouble("at") < ex.updated)) continue
                val survey = store.misc[key("sv", it.optString("surveyID"))]
                if (kind == "response" && ex == null && (survey == null || (!survey.d.optBoolean("open", true) && survey.s("ownerID") != from))) continue
                val data = runCatching { JSONObject(String(E2E.unb64(it.optString("data")))) }.getOrElse { JSONObject() }
                val q = JSONObject(it.toString()).apply { remove("data"); put("d", data) }
                q.put("ownerID", ex?.s("ownerID") ?: if (kind == "survey") from else survey?.s("ownerID") ?: "")
                if (ex?.deleted == true) q.put("deleted", true)
                save("sv", id, if (personal) "" else convID, from, at, q, ex).updated = it.optDouble("at")
                if (!personal && ex == null) {
                    if (kind == "survey") line("📋 $who started a survey — “${data.optString("title")}”", null, true)
                    else line("📝 $who answered “${survey?.d?.optString("title") ?: "a survey"}”", null, survey?.s("ownerID") == me)
                }
            }
        }
        "album" -> { p ?: return
            val ex = store.misc[key("album", p.getString("id"))]
            if (ex != null) { if (ex.owner == from && p.optBoolean("deleted")) ex.p.put("deleted", true); return }
            if (p.optBoolean("deleted")) return
            save("album", p.getString("id"), convID, from, at, JSONObject(p.toString()), null)
        }
    }
}

// MARK: - Actions

fun Sync.checklistSave(taskID: String, conv: String, id: String?, title: String, done: Boolean, position: Double, deleted: Boolean = false) =
    send(conv, ev("checklist", JSONObject().put("id", id ?: newID()).put("taskID", taskID).put("title", title).put("done", done).put("position", position)
        .put("deleted", deleted).put("at", SwiftDate.now())))

fun Sync.expenseSave(taskID: String, conv: String, title: String, amount: Double, category: String) =
    send(conv, ev("expense", JSONObject().put("id", newID()).put("taskID", taskID).put("title", title).put("amount", amount).put("date", SwiftDate.now())
        .put("paidBy", me).put("category", category).put("receipts", JSONArray()).put("deleted", false).put("at", SwiftDate.now())))

fun Sync.taskFileAdd(taskID: String, conv: String, att: Att, files: Map<String, ByteArray>) =
    send(conv, ev("taskFile", JSONObject().put("id", newID()).put("taskID", taskID).put("kind", "file").put("attachment", att.json()).put("title", att.name).put("deleted", false)), files = files)

fun Sync.taskLinkAdd(taskID: String, conv: String, url: String, title: String) =
    send(conv, ev("taskFile", JSONObject().put("id", newID()).put("taskID", taskID).put("kind", "link").put("url", url).put("title", title).put("deleted", false)))

fun Sync.askApproval(conv: String, title: String, details: String, amount: Double?, approvers: List<String>, taskID: String? = null) {
    val p = JSONObject().put("id", newID()).put("messageID", newID()).put("title", title).put("details", details).put("approvers", JSONArray(approvers)).put("attachments", JSONArray())
    amount?.let { p.put("amount", it) }; taskID?.let { p.put("taskID", it) }
    send(conv, ev("approval", p), loud = true, hintText = "🙋 Approval needed: $title")
}

fun Sync.decide(ap: Rec, approved: Boolean, note: String, amount: Double?) {
    val d = JSONObject().put("approvalID", ap.id).put("approved", approved).put("note", note); amount?.let { d.put("amount", it) }
    send(ap.conv, ev("decision", d), loud = true, hintText = "${if (approved) "✅ Approved" else "❌ Rejected"}: ${ap.s("title")}")
}

fun Sync.createPoll(conv: String, question: String, options: List<String>, multiple: Boolean) =
    send(conv, ev("poll", JSONObject().put("id", newID()).put("messageID", newID()).put("question", question)
        .put("options", JSONArray(options.map { JSONObject().put("id", newID()).put("text", it) })).put("multiple", multiple)), loud = true, hintText = "📊 Poll: $question")

fun Sync.vote(poll: Rec, options: List<String>) = send(poll.conv, ev("vote", JSONObject().put("pollID", poll.id).put("optionIDs", JSONArray(options))))

fun newMeeting(title: String, start: Long, end: Long, online: Boolean, link: String, place: String, agenda: List<String>, expected: List<String>, taskID: String = "") =
    JSONObject().put("id", newID()).put("taskID", taskID).put("title", title).put("online", online).put("link", link).put("place", place)
        .put("start", SwiftDate.from(start)).put("end", SwiftDate.from(end)).put("notes", "").put("minutes", "").put("status", "scheduled")
        .put("agenda", JSONArray(agenda)).put("expected", JSONArray(expected)).put("attended", JSONArray()).put("admins", JSONArray())
        .put("polls", JSONArray()).put("files", JSONArray()).put("deleted", false).put("at", SwiftDate.now())

fun Sync.saveMeeting(conv: String, p: JSONObject) {
    val q = JSONObject(p.toString()).apply { remove("t"); remove("votes") }.put("at", SwiftDate.now())
    send(conv, ev("meeting", q), loud = true, hintText = "📅 ${q.optString("title")} — ${dateText(SwiftDate.toMillis(q.optDouble("start")))}")
}
fun Sync.attendMeeting(m: Rec) = send(m.conv, evNamed("meetingAttend", JSONObject().put("meetingID", m.id)))
fun Sync.voteMeeting(m: Rec, pollID: String, option: Int) = send(m.conv, evNamed("meetingVote", JSONObject().put("meetingID", m.id).put("pollID", pollID).put("option", option)))

fun Sync.prescribe(patient: String, patientName: String, diagnosis: String, advice: String, items: List<JSONObject>, nextVisit: Long?) {
    val conv = directID(me, patient)
    synchronized(store) { store.convs.getOrPut(conv) { Conv(conv, store.name(patient), listOf(me, patient)) } }
    val p = JSONObject().put("id", newID()).put("patientID", patient).put("patientName", patientName).put("diagnosis", diagnosis).put("advice", advice)
        .put("items", JSONArray(items)).put("deleted", false).put("at", SwiftDate.now())
    nextVisit?.let { p.put("nextVisit", SwiftDate.from(it)) }
    send(conv, ev("prescription", p), loud = true, hintText = "🩺 Dr. ${store.myName} sent you a prescription")
}

/** Patient: accepting adds the medicines to my own Care profile (like the iPhone). */
fun Sync.answerRx(rx: Rec, accept: Boolean, note: String) {
    if (accept) {
        val self = "s_$me"
        synchronized(store) { store.convs.getOrPut(self) { Conv(self, "Notes to self", listOf(me)) } }
        val prof = xs("care").firstOrNull { !it.deleted && it.s("relation") == "Self" } ?: run {
            saveCareProfile(self, null, store.myName, "Self", "", "", "", "", ""); xs("care").firstOrNull { it.s("relation") == "Self" }
        }
        if (prof != null) rx.p.optJSONArray("items")?.let { a -> for (i in 0 until a.length()) { val it = a.getJSONObject(i)
            saveMedicine(prof, null, it.optString("name"), it.optString("dose"), it.optString("form", "Tablet"), it.optJSONArray("times")?.let { t -> (0 until t.length()).map { t.optInt(it) } } ?: listOf(540),
                listOf(it.optString("instructions"), "Prescribed by Dr. ${store.name(rx.owner)}").filter { s -> s.isNotEmpty() }.joinToString(" · "))
        } }
    }
    send(rx.conv, evNamed("rxAnswer", JSONObject().put("id", rx.id).put("accept", accept).put("note", note)), loud = true,
        hintText = if (accept) "✅ Prescription accepted" else "✋ Prescription declined")
}

fun Sync.vaultAdd(prof: Rec, title: String, category: String, att: Att, files: Map<String, ByteArray>) =
    send(prof.conv, ev("vault", JSONObject().put("id", newID()).put("profileID", prof.id).put("title", title).put("category", category)
        .put("date", SwiftDate.now()).put("attachment", att.json()).put("deleted", false)), files = files)

fun Sync.healthEvent(prof: Rec, kind: String, title: String, details: String, severity: Int) =
    send(prof.conv, ev("healthEvent", JSONObject().put("id", newID()).put("profileID", prof.id).put("kind", kind).put("title", title).put("details", details)
        .put("date", SwiftDate.now()).put("severity", severity).put("status", "active").put("recovery", 0).put("attachments", JSONArray()).put("deleted", false).put("at", SwiftDate.now())))

fun Sync.surveySave(existing: Rec?, kind: String, surveyID: String, data: JSONObject, conv: String, deleted: Boolean = false) {
    val id = existing?.id ?: ("sv_" + newID())
    val item = JSONObject().put("id", id).put("kind", kind).put("surveyID", if (kind == "survey") id else surveyID).put("deleted", deleted)
        .put("at", SwiftDate.now()).put("data", E2E.b64(data.toString().toByteArray()))
    val target = conv.ifEmpty { "s_$me".also { s -> synchronized(store) { store.convs.getOrPut(s) { Conv(s, "Notes to self", listOf(me)) } } } }
    send(target, ev("survey", JSONObject().put("items", JSONArray().put(item))), loud = existing == null,
        hintText = if (existing == null) (if (kind == "survey") "📋 New survey — please answer" else "📝 New survey response") else null)
}

fun Sync.albumAdd(owner: String, conv: String, att: Att, files: Map<String, ByteArray>) =
    send(conv, ev("album", JSONObject().put("id", "al_" + newID()).put("owner", owner).put("ref", att.json()).put("deleted", false).put("at", SwiftDate.now())), files = files,
        loud = true, hintText = "📸 ${store.myName} added a photo to the album")

fun Sync.albumRemove(r: Rec) = send(r.conv, ev("album", JSONObject(r.p.toString()).apply { remove("t") }.put("deleted", true).put("at", SwiftDate.now())))

// MARK: - Local reminders (medicines, punch-in, bills, events, tasks, meetings, Magic moments)

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, i: Intent) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("reminders", "Reminders", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(ctx, 7, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(ctx, "reminders").setSmallIcon(R.drawable.ic_launcher).setContentTitle(i.getStringExtra("title"))
            .setContentText(i.getStringExtra("body")).setAutoCancel(true).setContentIntent(open).build()
        runCatching { NotificationManagerCompat.from(ctx).notify(i.getIntExtra("id", 0), n) }
    }
}

object Reminders {
    private const val MAX = 60
    fun reschedule(ctx: Context) {
        val store = Store.get(ctx)
        if (!store.prefBool("reminders", true)) { cancelAll(ctx, store); return }
        val now = System.currentTimeMillis()
        val horizon = now + 3 * 86_400_000L
        val out = mutableListOf<Triple<Long, String, String>>()
        val me = store.me
        val day0 = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis
        // Medicines: today and the next two days.
        val profiles = store.miscList("care").filter { !it.deleted }.associateBy { it.id }
        for (m in store.miscList("med").filter { !it.deleted && it.p.optBoolean("active", true) }) {
            val prof = profiles[m.s("profileID")] ?: continue
            val end = m.p.optDoubleOrNull("endDate")?.let { SwiftDate.toMillis(it) } ?: Long.MAX_VALUE
            val times = m.p.optJSONArray("times")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: emptyList()
            for (d in 0..2) for (t in times) { val at = day0 + d * 86_400_000L + t * 60_000L; if (at in (now + 1)..minOf(end, horizon)) out += Triple(at, "💊 ${prof.s("name")}: ${m.s("name")}", "${m.s("dose")} — tap Taken / Skip in Care") }
        }
        // Punch in / out on working days.
        store.attList().filter { it.ak == "member" && !it.deleted && it.d.optString("userID") == me && it.d.optBoolean("accepted") }.forEach { m ->
            val c = store.att[m.s("companyID")]?.d ?: return@forEach
            if (!c.optBoolean("selfPunch", true)) return@forEach
            val off = c.optJSONArray("weeklyOff")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: emptyList()
            for (d in 0..2) {
                val base = day0 + d * 86_400_000L
                val wd = Calendar.getInstance().apply { timeInMillis = base }.get(Calendar.DAY_OF_WEEK)
                if (wd in off) continue
                val s = base + (m.dutyStart(c) - 5) * 60_000L; val e = base + m.dutyEnd(c) * 60_000L
                if (s > now) out += Triple(s, "Time to punch in", c.optString("name"))
                if (e > now) out += Triple(e, "Punch out before you leave", c.optString("name"))
            }
        }
        // Bills, fees, rent, instalments due (9 am on the day).
        store.bizList().filter { !it.deleted && it.owner == me && it.status in listOf("Due", "Upcoming", "Booked") }.forEach { r ->
            (r.due ?: r.date)?.let { d -> val at = AttData.date(AttData.key(d)) + 9 * 3_600_000L; if (at in now..horizon) out += Triple(at, "📒 ${BizSpecs.spec(r.module)?.title}: ${r.title.ifEmpty { r.status }}", if (r.amount != 0.0) money(r.amount) else "") }
        }
        store.finList().filter { !it.deleted && it.status == "due" }.forEach { r -> val at = AttData.date(AttData.key(r.finDate)) + 9 * 3_600_000L + 1_800_000L
            if (at in now..horizon) out += Triple(at, if (r.isIn) "Money to receive today" else "Payment due today", "${money(r.amount)} — ${r.d.optString("title").ifEmpty { r.s("category") }}") }
        store.miscList("soc").filter { !it.deleted && it.s("kind") == "bill" && it.status == "due" }.forEach { b -> val at = AttData.date(AttData.key(SwiftDate.toMillis(b.d.optDouble("due")))) + 9 * 3_600_000L
            if (at in now..horizon) out += Triple(at, "🧾 ${b.d.optString("title")}", money(b.d.optDouble("amount"))) }
        // Events and meetings: one hour before.
        store.miscList("event").filter { !it.deleted }.forEach { e -> val at = SwiftDate.toMillis(e.p.optDouble("start")) - 3_600_000L; if (at in now..horizon) out += Triple(at, "🎉 In 1 hour: ${e.s("title")}", e.s("place")) }
        store.miscList("meet").filter { !it.deleted && it.s("status") == "scheduled" }.forEach { e -> val at = SwiftDate.toMillis(e.p.optDouble("start")) - 900_000L; if (at in now..horizon) out += Triple(at, "📅 In 15 min: ${e.s("title")}", if (e.p.optBoolean("online")) e.s("link") else e.s("place")) }
        // Tasks due.
        store.taskList().filter { it.status != "done" && (it.assignees.contains(me) || it.createdBy == me) && it.answer(me) != "declined" }.forEach { t -> t.due?.let { if (it in now..horizon) out += Triple(it, "☑ Task due: ${t.title}", "") } }
        // Task follow-ups (1–4 times a day on chosen weekdays, until done or a date).
        store.taskList().filter { it.status != "done" && !it.deleted }.forEach { t ->
            val f = t.p.optJSONObject("followUp") ?: return@forEach
            val accepted = t.assignees.contains(me) && (!t.needsAcceptance || t.answer(me)?.startsWith("accepted") == true)
            val group = f.optBoolean("wholeGroup") && store.conv(t.conv ?: "")?.members?.contains(me) == true
            if (!(t.createdBy == me || accepted || group)) return@forEach
            val until = f.optDoubleOrNull("until")?.let { SwiftDate.toMillis(it) } ?: Long.MAX_VALUE
            val times = f.optJSONArray("times")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: listOf(600)
            val days = f.optJSONArray("weekdays")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: listOf(2, 3, 4, 5, 6)
            for (d in 0..2) { val base = day0 + d * 86_400_000L
                if (Calendar.getInstance().apply { timeInMillis = base }.get(Calendar.DAY_OF_WEEK) !in days) continue
                for (m in times) { val at = base + m * 60_000L; if (at in (now + 1)..minOf(until, horizon)) out += Triple(at, "🔔 Follow up: ${t.title}", if (t.createdBy == me) "Check progress with ${t.assignees.filter { it != me }.joinToString { store.name(it) }.ifEmpty { "the group" }}" else "From ${store.name(t.createdBy)}") }
            }
        }
        // Magic moments arriving.
        store.msgs.filter { it.showAt != null && it.showAt > now && it.from != me }.forEach { out += Triple(it.showAt!!, "✨ ${store.name(it.from)}", it.text.ifEmpty { "Sent you a Magic moment" }) }

        cancelAll(ctx, store)
        val am = ctx.getSystemService(AlarmManager::class.java)
        val list = out.sortedBy { it.first }.take(MAX)
        list.forEachIndexed { i, (at, title, body) ->
            val pi = PendingIntent.getBroadcast(ctx, 9000 + i, Intent(ctx, ReminderReceiver::class.java).putExtra("title", title).putExtra("body", body).putExtra("id", 9000 + i),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            runCatching { am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi) }
        }
        store.setPref("remCount", list.size)
    }

    private fun cancelAll(ctx: Context, store: Store) {
        val am = ctx.getSystemService(AlarmManager::class.java)
        for (i in 0 until store.pref("remCount", "0").toIntOrNull().let { it ?: MAX }.coerceAtLeast(MAX)) {
            PendingIntent.getBroadcast(ctx, 9000 + i, Intent(ctx, ReminderReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE)?.let { am.cancel(it) }
        }
    }
}
