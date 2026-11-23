package com.jondhale.iteam

import org.json.JSONArray
import org.json.JSONObject

// Views (mini), Events, Check In / Family Safety, Care — same events as the iPhone.

private fun mkey(t: String, id: String) = "$t:$id"
fun Rec.t() = s("t")
val Rec.convIDs: List<String> get() = p.optJSONArray("convs")?.strings() ?: emptyList()
val Rec.atMs: Long get() = p.optDoubleOrNull("at")?.let { SwiftDate.toMillis(it) } ?: created

internal fun Sync.applyMisc(case: String, v: JSONObject, p: JSONObject?, from: String, convID: String, at: Double, sys: (String, Boolean) -> Unit) {
    val who = if (from == me) "You" else store.name(from)
    val m = store.misc
    when (case) {
        "post" -> {
            p ?: return
            val k = mkey("post", p.getString("id"))
            val ex = m[k]
            if (ex != null) {
                if (ex.owner != from) return
                val convs = (ex.convIDs + convID).distinct()
                ex.p.put("text", p.optString("text")).put("deleted", p.optBoolean("deleted")).put("convs", JSONArray(convs))
                if ((p.optJSONArray("media")?.length() ?: 0) > 0) ex.p.put("media", p.getJSONArray("media"))
            } else m[k] = Rec(p.getString("id"), convID, from, from, SwiftDate.toMillis(at),
                JSONObject(p.toString()).put("t", "post").put("convs", JSONArray().put(convID)).put("at", at).put("reacts", JSONObject()).put("comments", JSONArray()))
        }
        "postReact" -> m[mkey("post", v.optString("postID"))]?.let { r ->
            val re = r.p.optJSONObject("reacts") ?: JSONObject().also { r.p.put("reacts", it) }
            if (v.has("emoji") && !v.isNull("emoji")) re.put(from, v.optString("emoji")) else re.remove(from)
        }
        "postComment" -> if (p != null) m[mkey("post", p.optString("postID"))]?.let { r ->
            val arr = r.p.optJSONArray("comments") ?: JSONArray().also { r.p.put("comments", it) }
            if ((0 until arr.length()).none { arr.optJSONObject(it)?.optString("id") == p.optString("id") })
                arr.put(JSONObject(p.toString()).put("from", from).put("at", at))
        }
        "invite" -> {
            p ?: return
            val k = mkey("event", p.getString("id"))
            val ex = m[k]
            if (ex != null && (ex.owner != from || p.optDouble("at") < ex.updated)) return
            val isNew = ex == null
            val wasDeleted = ex?.deleted == true
            val r = ex ?: Rec(p.getString("id"), convID, from, from, SwiftDate.toMillis(at), JSONObject()).also { m[k] = it }
            r.p = JSONObject(p.toString()).put("t", "event").put("rsvps", ex?.p?.optJSONObject("rsvps") ?: JSONObject())
            r.updated = p.optDouble("at")
            val start = SwiftDate.toMillis(p.optDouble("start"))
            if (p.optBoolean("deleted") && !wasDeleted) sys("🎉 $who cancelled “${p.optString("title")}”", true)
            else if (!p.optBoolean("deleted")) sys(if (isNew) "🎉 $who invited everyone to “${p.optString("title")}” — ${dateText(start)} ${time(start)}${if (p.optString("place").isEmpty()) "" else " at " + p.optString("place")}"
                else "🎉 $who updated “${p.optString("title")}” — ${dateText(start)} ${time(start)}", true)
        }
        "rsvp" -> m[mkey("event", v.optString("eventID"))]?.let { ev ->
            val a = v.optString("answer")
            (ev.p.optJSONObject("rsvps") ?: JSONObject().also { ev.p.put("rsvps", it) }).put(from, a)
            val word = if (from == me) (if (a == "going") "are going" else if (a == "maybe") "might come" else "can't come")
                else (if (a == "going") "is going" else if (a == "maybe") "might come" else "can't come")
            sys("🎉 $who $word — “${ev.s("title")}”", true)
        }
        "checkIn" -> {
            p ?: return
            val k = mkey("checkin", p.getString("id"))
            val ex = m[k]
            if (ex != null && (ex.owner != from || p.optDouble("at") < ex.updated)) return
            val was = ex?.status
            val r = ex ?: Rec(p.getString("id"), convID, from, from, SwiftDate.toMillis(at), JSONObject()).also { m[k] = it }
            r.p = JSONObject(p.toString()).put("t", "checkin"); r.updated = p.optDouble("at")
            val eta = time(SwiftDate.toMillis(p.optDouble("eta")))
            sys(when (p.optString("status")) {
                "arrived" -> "✅ $who arrived at ${p.optString("place")}"
                "ended" -> "📍 $who ended the Check In"
                else -> if (was == "active") "📍 $who updated the Check In — now by $eta" else "📍 $who started a Check In to ${p.optString("place")} — expected by $eta"
            }, true)
        }
        "care" -> {
            p ?: return
            val k = mkey("care", p.getString("id"))
            val ex = m[k]
            if (ex != null && p.optDouble("at") <= ex.updated) return
            val r = ex ?: Rec(p.getString("id"), convID, from, from, SwiftDate.toMillis(at), JSONObject()).also { m[k] = it }
            r.p = JSONObject(p.toString()).put("t", "care"); r.updated = p.optDouble("at")
            if (ex == null) sys("🩺 $who added ${p.optString("name")} to Care", false)
        }
        "medicine" -> {
            p ?: return
            val k = mkey("med", p.getString("id"))
            val ex = m[k]
            if (ex != null && p.optDouble("at") <= ex.updated) return
            val r = ex ?: Rec(p.getString("id"), convID, from, from, SwiftDate.toMillis(at), JSONObject()).also { m[k] = it }
            r.p = JSONObject(p.toString()).put("t", "med"); r.updated = p.optDouble("at")
            m[mkey("care", p.optString("profileID"))]?.let { prof ->
                sys("💊 $who ${if (p.optBoolean("deleted")) "removed" else "updated"} ${p.optString("name")} ${p.optString("dose")} for ${prof.s("name")}", false)
            }
        }
        "dose" -> {
            p ?: return
            val k = mkey("dose", p.getString("id"))
            val ex = m[k]
            if (ex != null && at < ex.updated) return
            val r = ex ?: Rec(p.getString("id"), convID, from, from, SwiftDate.toMillis(at), JSONObject()).also { m[k] = it }
            r.p = JSONObject(p.toString()).put("t", "dose").put("by", from); r.updated = at
            val med = m[mkey("med", p.optString("medicineID"))]; val prof = m[mkey("care", p.optString("profileID"))]
            if (med != null && prof != null) sys("💊 $who marked ${med.s("name")} ${if (p.optString("status") == "taken") "taken" else "skipped"} for ${prof.s("name")}", p.optString("status") != "taken")
        }
    }
}

// MARK: - Actions

fun Sync.publishPost(text: String, media: List<Att>, files: Map<String, ByteArray>, status: Boolean, convs: List<String>) {
    val p = JSONObject().put("id", newID()).put("kind", "moment").put("text", text).put("media", JSONArray(media.map { it.json() }))
        .put("status", status).put("deleted", false).put("at", SwiftDate.now())
    if (status) p.put("expires", SwiftDate.now() + 86400)
    convs.forEachIndexed { i, c -> runCatching { send(c, ev("post", p), files = if (i == 0) files else emptyMap()) } }
}

fun Sync.deletePost(r: Rec) {
    val p = JSONObject(r.p.toString()).apply { remove("t"); remove("convs"); remove("reacts"); remove("comments") }.put("media", JSONArray()).put("deleted", true).put("at", SwiftDate.now())
    r.convIDs.forEach { runCatching { send(it, ev("post", p)) } }
}

private fun Sync.replyConvs(r: Rec) = (if (r.owner == me) r.convIDs else r.convIDs.take(1)).filter { store.conv(it)?.left == false }

fun Sync.reactPost(r: Rec, emoji: String?) {
    val v = JSONObject().put("postID", r.id); if (emoji != null) v.put("emoji", emoji)
    replyConvs(r).forEach { runCatching { send(it, evNamed("postReact", v)) } }
}

fun Sync.commentPost(r: Rec, text: String) {
    val c = JSONObject().put("id", newID()).put("postID", r.id).put("text", text).put("deleted", false)
    replyConvs(r).forEach { runCatching { send(it, ev("postComment", c), loud = r.owner != me, hintText = "💬 Comment on a post") } }
}

fun Sync.saveEvent(convID: String, existing: Rec?, title: String, place: String, start: Long, end: Long, notes: String, deleted: Boolean = false) {
    val p = JSONObject().put("id", existing?.id ?: newID()).put("title", title).put("place", place).put("start", SwiftDate.from(start))
        .put("end", SwiftDate.from(end)).put("notes", notes).put("deleted", deleted).put("at", SwiftDate.now())
    send(existing?.conv ?: convID, ev("invite", p), loud = existing == null, hintText = "🎉 ${store.myName} invited you: $title")
}

fun Sync.rsvp(ev: Rec, answer: String) = send(ev.conv, evNamed("rsvp", JSONObject().put("eventID", ev.id).put("answer", answer)))

fun Sync.checkIn(convID: String, existing: Rec?, place: String, lat: Double, lon: Double, eta: Long, status: String) {
    val p = JSONObject().put("id", existing?.id ?: newID()).put("place", place).put("lat", lat).put("lon", lon)
        .put("eta", SwiftDate.from(eta)).put("status", status).put("at", SwiftDate.now())
    send(existing?.conv ?: convID, ev("checkIn", p), loud = true,
        hintText = when (status) { "arrived" -> "✅ ${store.myName} arrived at $place"; "ended" -> "📍 ${store.myName} ended the Check In"; else -> "📍 ${store.myName} started a Check In to $place" })
}

fun Sync.saveCareProfile(convID: String, existing: Rec?, name: String, relation: String, blood: String, allergies: String, conditions: String, emergency: String, notes: String, deleted: Boolean = false) {
    val p = JSONObject().put("id", existing?.id ?: newID()).put("name", name).put("relation", relation).put("bloodGroup", blood).put("allergies", allergies)
        .put("conditions", conditions).put("emergencyContact", emergency).put("notes", notes).put("deleted", deleted).put("at", SwiftDate.now())
    send(existing?.conv ?: convID, ev("care", p))
}

fun Sync.saveMedicine(prof: Rec, existing: Rec?, name: String, dose: String, form: String, times: List<Int>, instructions: String, deleted: Boolean = false) {
    val p = JSONObject().put("id", existing?.id ?: newID()).put("profileID", prof.id).put("name", name).put("dose", dose).put("form", form)
        .put("times", JSONArray(times)).put("instructions", instructions).put("startDate", existing?.p?.optDouble("startDate") ?: SwiftDate.now())
        .put("active", !deleted).put("deleted", deleted).put("at", SwiftDate.now())
    existing?.p?.optDoubleOrNull("endDate")?.let { p.put("endDate", it) }
    existing?.p?.optInt("stock", -1)?.takeIf { it >= 0 }?.let { p.put("stock", it) }
    send(prof.conv, ev("medicine", p))
}

/** Same id as the iPhone (medicine@minutes since 1970), so a dose is logged once whoever taps it. */
fun Sync.logDose(med: Rec, prof: Rec, scheduledMs: Long, taken: Boolean, note: String = "") {
    val id = "${med.id}@${scheduledMs / 60000}"
    val d = JSONObject().put("id", id).put("medicineID", med.id).put("profileID", prof.id).put("scheduled", SwiftDate.from(scheduledMs))
        .put("status", if (taken) "taken" else "skipped").put("note", note)
    send(prof.conv, ev("dose", d), loud = !taken, hintText = if (taken) null else "⚠️ ${prof.s("name")}'s ${time(scheduledMs)} ${med.s("name")} was skipped")
}
