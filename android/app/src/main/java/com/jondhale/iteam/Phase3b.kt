package com.jondhale.iteam

import org.json.JSONArray
import org.json.JSONObject

// CRM, Society and Gym & Training — same events and permission rules as the iPhone.

private fun k(t: String, id: String) = "$t:$id"
private fun Sync.who(from: String) = if (from == me) "You" else store.name(from)
private fun Sync.put(t: String, id: String, conv: String, from: String, at: Double, p: JSONObject, ex: Rec?): Rec {
    val r = ex ?: Rec(id, conv, from, from, SwiftDate.toMillis(at), p)
    r.p = p.put("t", t); store.misc[k(t, id)] = r
    return r
}
fun Sync.misc(t: String, id: String) = store.misc[k(t, id)]?.copyDeep()

// MARK: - Apply

internal fun Sync.applyPhase3b(case: String, v: JSONObject, p: JSONObject?, from: String, convID: String, at: Double, sys: (String) -> Unit) {
    val conv = store.convs[convID]
    when (case) {
        "crmGroup" -> {
            p ?: return
            val ex = store.misc[k("crmg", p.getString("id"))]
            if (ex != null && (p.optDouble("at") <= ex.updated || (from != ex.owner && p.optBoolean("deleted")))) return
            val r = put("crmg", p.getString("id"), convID, from, at, JSONObject(p.toString()).put("convID", convID), ex)
            r.updated = p.optDouble("at")
            if (ex == null) sys("💼 ${who(from)} made this a CRM team group: “${p.optString("name")}”")
        }
        "crmLead" -> {
            p ?: return
            val id = p.getString("id")
            val ex = store.misc[k("crml", id)]
            if (ex != null && p.optDouble("at") <= ex.updated) return
            val clientCopy = p.optBoolean("clientCopy")
            if (ex != null) {
                if (from == ex.s("clientID") && from != ex.s("ownerID")) return
                if (p.optBoolean("deleted") && !ex.deleted && from != ex.s("ownerID")) return
                if (!ex.p.optBoolean("clientCopy") && clientCopy) return
            } else if (!clientCopy && from != p.optString("ownerID") && !(p.optJSONArray("assignees")?.strings()?.contains(from) ?: false) && conv?.members?.contains(from) != true) return
            val oldStage = ex?.s("stage")
            val q = JSONObject(p.toString())
            if (clientCopy) q.put("groupConvID", convID)
            val r = put("crml", id, convID, from, at, q, ex); r.updated = p.optDouble("at")
            val name = p.optString("name"); val w = who(from)
            val line = when {
                ex == null -> if (clientCopy) "💼 $w shared “$name” with you in CRM" else "💼 $w added lead “$name”${if (p.optDouble("dealValue") > 0) " · ${money(p.optDouble("dealValue"))}" else ""}"
                p.optBoolean("deleted") -> "🗑️ $w deleted lead “$name”"
                oldStage != p.optString("stage") -> "💼 $w moved “$name” to ${p.optString("stage").replaceFirstChar { it.uppercase() }}"
                !clientCopy -> "💼 $w updated “$name”"
                else -> null
            }
            if (line != null && !(clientCopy && ex != null)) sys(line)
        }
        "crmActivity" -> {
            p ?: return
            val id = p.getString("id")
            val ex = store.misc[k("crma", id)]
            if (ex != null && (p.optDouble("at") <= ex.updated || from != ex.owner)) return
            put("crma", id, convID, from, at, JSONObject(p.toString()), ex).updated = p.optDouble("at")
            if (ex == null && !p.optBoolean("deleted")) {
                val lead = store.misc[k("crml", p.optString("leadID"))]?.s("name") ?: "a lead"; val w = who(from)
                sys(when (p.optString("kind")) {
                    "quote" -> "🧾 $w sent a quote of ${money(p.optDouble("amount"))} for “$lead”${if (p.optBoolean("needsAcceptance")) " — waiting for acceptance" else ""}"
                    "call" -> "📞 $w logged a call with “$lead”"
                    "meeting", "visit" -> "📍 $w logged a ${p.optString("kind")} with “$lead”"
                    else -> "📝 $w added a note to “$lead”"
                })
            }
        }
        "crmQuoteAnswer" -> {
            val a = store.misc[k("crma", v.optString("activityID"))] ?: return
            val lead = store.misc[k("crml", v.optString("leadID"))] ?: return
            if (a.s("kind") != "quote" || a.s("acceptance").isNotEmpty() || from != lead.s("clientID")) return
            val accept = v.optBoolean("accept")
            a.p.put("acceptance", if (accept) "accepted" else "declined").put("declineReason", v.optString("reason"))
            sys(if (accept) "✅ ${who(from)} accepted the quote of ${money(a.amount)} for “${lead.s("name")}”"
                else "✋ ${who(from)} declined the quote for “${lead.s("name")}”${if (v.optString("reason").isEmpty()) "" else " — “${v.optString("reason")}”"}")
            if (from != me && a.owner == me) Thread { runCatching { crmRelayAnswer(a.id, lead.id) } }.start()
        }
        "society" -> {
            val arr = p?.optJSONArray("items") ?: v.optJSONArray("items") ?: return
            val items = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.sortedBy { if (it.optString("kind") == "society") 0 else 1 }
            for (it in items) {
                val id = it.optString("id"); val kind = it.optString("kind")
                val ex = store.misc[k("soc", id)]
                if (ex != null && it.optDouble("at") <= ex.updated) continue
                val data = runCatching { JSONObject(String(E2E.unb64(it.optString("data")))) }.getOrNull() ?: continue
                val soc = if (kind == "society") data else store.misc[k("soc", it.optString("societyID"))]?.d ?: continue
                val committee = (if (ex?.s("kind") == "society") ex.d else soc).let { isCommittee(it, from) }
                val unitID = if (kind == "unit") id else it.optString("unitID")
                val ownerOfUnit = store.misc[k("soc", unitID)]?.d?.optString("ownerUserID") == from
                val ok = when (kind) {
                    "society" -> committee
                    "unit", "notice" -> committee
                    "bill", "complaint", "visitor" -> committee || ownerOfUnit
                    else -> false
                }
                if (!ok) continue
                val oldStatus = ex?.status
                val q = JSONObject(it.toString()).apply { remove("data"); put("d", data) }
                val r = put("soc", id, convID, from, at, q, ex); r.updated = it.optDouble("at")
                socLine(r, ex == null, oldStatus, from)?.let(sys)
            }
        }
        "gymMember" -> {
            p ?: return
            val id = p.getString("id")
            val ex = store.misc[k("gymm", id)]
            if (ex != null && (p.optDouble("at") <= ex.updated || (p.optBoolean("deleted") && !ex.deleted && from != ex.owner))) return
            val q = JSONObject(p.toString())
            q.put("convID", if (ex != null && !(from == ex.owner && !convID.startsWith("s_"))) ex.s("convID") else convID)
            val oldTrainer = ex?.s("trainerID") ?: ""
            q.put("trainerStatus", ex?.s("trainerStatus") ?: ""); q.put("trainerNote", ex?.s("trainerNote") ?: "")
            if (!p.has("trainerID") && ex != null) q.put("trainerID", oldTrainer)
            val r = put("gymm", id, convID, ex?.owner ?: from, at, q, ex); r.updated = p.optDouble("at")
            val t = p.optStringOrNull("trainerID")
            if (t != null && t != oldTrainer && from == r.owner) {
                r.p.put("trainerStatus", if (t.isEmpty()) "" else "waiting").put("trainerNote", "")
                if (t.isNotEmpty()) sys("🏋️ ${store.name(from)} asked ${if (t == me) "you" else store.name(t)} to be ${p.optString("name")}'s trainer — waiting for an answer")
            } else if (ex == null && from != me) sys("🏋️ ${store.name(from)} added ${p.optString("name")} to Gym & Training")
        }
        "gymTrainerAnswer" -> {
            val m = store.misc[k("gymm", v.optString("memberID"))] ?: return
            val accept = v.optBoolean("accept")
            if (from != m.s("trainerID") || m.s("trainerStatus") == (if (accept) "accepted" else "declined")) return
            m.p.put("trainerStatus", if (accept) "accepted" else "declined").put("trainerNote", v.optString("note"))
            if (accept) m.p.put("trainer", store.name(from))
            sys(if (accept) "✅ ${store.name(from)} accepted to train ${m.s("name")}" else "✋ ${store.name(from)} declined to train ${m.s("name")}${if (v.optString("note").isEmpty()) "" else " — “${v.optString("note")}”"}")
        }
        "gymPlan", "gymSession", "gymPayment" -> {
            p ?: return
            val t = mapOf("gymPlan" to "gymplan", "gymSession" to "gymsess", "gymPayment" to "gympay")[case]!!
            val id = p.getString("id")
            val ex = store.misc[k(t, id)]
            if (ex != null && p.optDouble("at") <= ex.updated) return
            val creator = store.misc[k("gymm", p.optString("memberID"))]?.owner
            if (ex != null && p.optBoolean("deleted") && !ex.deleted && from != ex.owner && from != creator) return
            put(t, id, convID, ex?.owner ?: from, at, JSONObject(p.toString()), ex).updated = p.optDouble("at")
            val who = store.misc[k("gymm", p.optString("memberID"))]?.s("name")
            if (ex == null && from != me && who != null) sys(when (case) {
                "gymPlan" -> "🏢 ${store.name(from)} added a ${p.optString("planName").ifEmpty { "membership" }} at ${p.optString("gymName")} for $who"
                "gymSession" -> "💪 ${store.name(from)} logged a training session for $who${if (p.optString("workout").isEmpty()) "" else ": " + p.optString("workout")}"
                else -> "🧾 ${store.name(from)} recorded ${money(p.optDouble("amount"))} for $who"
            })
        }
    }
}

// MARK: - CRM actions

val crmStages = listOf("new", "contacted", "proposal", "negotiation", "won", "lost")
fun crmStageColor(s: String): Long = when (s) { "new" -> 0xFF5B8DEF; "contacted" -> 0xFF30B0C7; "proposal" -> 0xFFAF52DE; "negotiation" -> 0xFFFF9500; "won" -> 0xFF34C759; else -> 0xFF8E8E93 }

/** Companies for CRM: the Attendance companies I own, admin, or work in. */
fun Sync.crmCompanies(): List<Pair<String, String>> {
    val all = store.attList().filter { !it.deleted }
    val mine = all.filter { it.ak == "member" && it.d.optString("userID") == me && it.d.optBoolean("accepted", true) }.map { it.s("companyID") }.toSet()
    return all.filter { it.ak == "company" && (isStaff(it.d, me) || it.id in mine) }.map { it.id to it.d.optString("name") }
}

private fun Sync.crmHomes(groupConvID: String, assignees: List<String>): List<String> {
    store.conv(groupConvID)?.takeIf { !it.left }?.let { return listOf(it.id) }
    return assignees.filter { it != me && store.contacts[it] != null }.map { directID(me, it).also { id -> synchronized(store) { store.convs.getOrPut(id) { Conv(id, store.name(it), listOf(me, it)) } } } }
}

private fun Sync.sendOrLocal(convs: List<String>, body: JSONObject, loud: Boolean = false, hint: String? = null) {
    if (convs.isEmpty()) synchronized(store) {
        val case = body.keys().next(); val v = body.getJSONObject(case)
        applyPhase3b(case, v, v.optJSONObject("_0"), me, "", SwiftDate.now()) {}
        store.save()
    } else convs.forEach { runCatching { send(it, body, loud, hint) } }
}

fun Sync.crmCreateGroup(name: String, companyID: String, members: List<String>): String {
    val conv = createGroup(name, members)
    send(conv, ev("crmGroup", JSONObject().put("id", "crmg_" + newID()).put("companyID", companyID).put("name", name)
        .put("memberIDs", JSONArray(members + me)).put("deleted", false).put("at", SwiftDate.now())), loud = true, hintText = "💼 CRM team group “$name”")
    return conv
}

fun Sync.crmSaveLead(p: JSONObject) {
    p.put("at", SwiftDate.now()); if (p.optString("ownerID").isEmpty()) p.put("ownerID", me)
    val isNew = misc("crml", p.getString("id")) == null
    sendOrLocal(crmHomes(p.optString("groupConvID"), p.optJSONArray("assignees")?.strings() ?: emptyList()), ev("crmLead", p), isNew || p.optBoolean("deleted"), if (isNew) "💼 New lead: ${p.optString("name")}" else null)
    val client = p.optString("clientID")
    if (client.isNotEmpty() && client != me && store.contacts[client] != null) {
        val safe = JSONObject(p.toString()).put("notes", "").put("assignees", JSONArray()).put("probability", 0).put("groupConvID", "").put("source", "").put("clientCopy", true)
        val d = directID(me, client); synchronized(store) { store.convs.getOrPut(d) { Conv(d, store.name(client), listOf(me, client)) } }
        runCatching { send(d, ev("crmLead", safe), isNew, if (isNew) "💼 ${store.myName} shared “${p.optString("name")}” with you" else null) }
    }
}

fun newLead(company: String, group: String) = JSONObject().put("id", "crm_" + newID()).put("companyID", company).put("groupConvID", group).put("ownerID", "")
    .put("assignees", JSONArray()).put("clientID", "").put("name", "").put("company", "").put("phone", "").put("email", "").put("source", "")
    .put("stage", "new").put("dealValue", 0.0).put("probability", 20).put("notes", "").put("deleted", false).put("at", SwiftDate.now())

fun Sync.crmLeadPayload(l: Rec) = JSONObject(l.p.toString()).apply { remove("t"); if (!optBoolean("clientCopy")) remove("clientCopy") }

fun Sync.crmSetStage(l: Rec, stage: String) {
    val p = crmLeadPayload(l).put("stage", stage)
    if (stage == "won") p.put("probability", 100) else if (stage == "lost") p.put("probability", 0)
    crmSaveLead(p)
}

fun Sync.crmSaveActivity(lead: Rec, kind: String, title: String, detail: String, amount: Double) {
    val p = JSONObject().put("id", "crma_" + newID()).put("leadID", lead.id).put("companyID", lead.s("companyID")).put("kind", kind).put("title", title)
        .put("detail", detail).put("amount", amount).put("date", SwiftDate.now()).put("needsAcceptance", kind == "quote" && lead.s("clientID").isNotEmpty())
        .put("acceptance", "").put("declineReason", "").put("files", JSONArray()).put("deleted", false).put("at", SwiftDate.now())
    sendOrLocal(crmHomes(lead.s("groupConvID"), lead.p.optJSONArray("assignees")?.strings() ?: emptyList()), ev("crmActivity", p), kind == "quote", if (kind == "quote") "🧾 Quote for ${lead.s("name")}" else null)
    val client = lead.s("clientID")
    if (kind == "quote" && client.isNotEmpty() && client != me && store.contacts[client] != null)
        runCatching { send(directID(me, client), ev("crmActivity", p), true, "🧾 ${store.myName} sent you a quote of ${money(amount)} — tap to accept") }
}

fun Sync.crmAnswerQuote(a: Rec, lead: Rec, accept: Boolean, reason: String) =
    send(lead.s("groupConvID"), evNamed("crmQuoteAnswer", JSONObject().put("activityID", a.id).put("leadID", lead.id).put("accept", accept).put("reason", reason)),
        loud = true, hintText = if (accept) "✅ ${store.myName} accepted your quote" else "✋ ${store.myName} declined your quote")

private fun Sync.crmRelayAnswer(actID: String, leadID: String) {
    val a = misc("crma", actID) ?: return; val lead = misc("crml", leadID) ?: return
    val p = JSONObject(a.p.toString()).apply { remove("t") }.put("at", SwiftDate.now())
    crmHomes(lead.s("groupConvID"), lead.p.optJSONArray("assignees")?.strings() ?: emptyList()).forEach { runCatching { send(it, ev("crmActivity", p)) } }
    if (a.s("acceptance") == "accepted" && lead.s("stage") != "won") crmSetStage(lead, "won")
}

// MARK: - Society actions

fun isCommittee(s: JSONObject, u: String) = u == s.optString("ownerID") || (s.optJSONArray("committee")?.strings()?.contains(u) ?: false)
fun socData(name: String, address: String, owner: String, committee: List<String>, maint: Double) = JSONObject().put("name", name).put("address", address)
    .put("ownerID", owner).put("committee", JSONArray(committee)).put("committeeConvID", "").put("attCompanyID", "").put("defaultMaintenance", maint).put("dueDay", 10).put("upi", "")
fun unitData(wing: String, flat: String, owner: String, ownerName: String, phone: String, maint: Double) = JSONObject().put("flat", flat).put("wing", wing).put("floor", "")
    .put("ownerUserID", owner).put("ownerName", ownerName).put("tenantName", "").put("phone", phone).put("members", 0).put("parking", "").put("maintenance", maint)
val Rec.unitLabel get() = listOf(d.optString("wing"), d.optString("flat")).filter { it.isNotEmpty() }.joinToString("-")

private fun socItem(id: String, kind: String, society: String, unit: String = "", status: String = "", deleted: Boolean = false, data: JSONObject) =
    JSONObject().put("id", id).put("kind", kind).put("societyID", society).put("unitID", unit).put("status", status).put("deleted", deleted)
        .put("data", E2E.b64(data.toString().toByteArray())).put("at", SwiftDate.now())
private fun Rec.socItem(status: String = this.status, deleted: Boolean = this.deleted) = socItem(id, s("kind"), s("societyID"), s("unitID"), status, deleted, d)

fun Sync.socSend(items: List<JSONObject>, s: JSONObject, ownerOf: String = "", loud: Boolean = false, preview: String? = null) {
    val body = ev("society", JSONObject().put("items", JSONArray(items)))
    if (isCommittee(s, me)) {
        sendOrLocal(listOfNotNull(store.conv(s.optString("committeeConvID"))?.takeIf { !it.left }?.id), body, loud, preview)
        val owner = misc("soc", ownerOf)?.d?.optString("ownerUserID") ?: ""
        if (owner.isNotEmpty() && owner != me && !isCommittee(s, owner) && store.contacts[owner] != null) {
            val bundle = items.toMutableList()
            if (items.none { it.optString("kind") == "society" }) misc("soc", items.first().optString("societyID"))?.let { bundle.add(0, it.socItem()) }
            val d = directID(me, owner); synchronized(store) { store.convs.getOrPut(d) { Conv(d, store.name(owner), listOf(me, owner)) } }
            runCatching { send(d, ev("society", JSONObject().put("items", JSONArray(bundle))), loud, preview) }
        }
    } else sendOrLocal((listOf(s.optString("ownerID")) + (s.optJSONArray("committee")?.strings() ?: emptyList()))
        .filter { it != me && it.isNotEmpty() && store.contacts[it] != null }.map { directID(me, it) }, body, loud, preview)
}

fun Sync.socCreate(name: String, address: String, committee: List<String>, maint: Double, personal: Boolean = false): String {
    val id = "soc_" + newID()
    val d = socData(name, address, me, committee, maint)
    if (committee.isNotEmpty()) d.put("committeeConvID", createGroup("$name · Committee", committee))
    if (!personal) d.put("attCompanyID", attCreateCompany("$name · Staff", 570, 1110, listOf(1)))
    socSend(listOf(socItem(id, "society", id, data = d)), d, loud = true, preview = "🏢 Society “$name”")
    return id
}

fun Sync.socSaveUnit(soc: Rec, existing: Rec?, d: JSONObject) {
    val item = socItem(existing?.id ?: ("socu_" + newID()), "unit", soc.id, data = d)
    val s = soc.d
    sendOrLocal(listOfNotNull(store.conv(s.optString("committeeConvID"))?.takeIf { !it.left }?.id), ev("society", JSONObject().put("items", JSONArray().put(item))))
    val o = d.optString("ownerUserID")
    if (o.isNotEmpty() && o != me && !isCommittee(s, o) && store.contacts[o] != null) {
        val dc = directID(me, o); synchronized(store) { store.convs.getOrPut(dc) { Conv(dc, store.name(o), listOf(me, o)) } }
        runCatching { send(dc, ev("society", JSONObject().put("items", JSONArray().put(soc.socItem()).put(item))), existing == null,
            if (existing == null) "🏠 ${store.myName} added you as owner of flat ${listOf(d.optString("wing"), d.optString("flat")).filter { it.isNotEmpty() }.joinToString("-")} in ${s.optString("name")}" else null) }
    }
}

fun Sync.socGenerateBills(soc: Rec) {
    val s = soc.d
    val cal = java.util.Calendar.getInstance()
    val monthKey = java.text.SimpleDateFormat("MMMM yyyy", java.util.Locale.ENGLISH).format(cal.time)
    cal.set(java.util.Calendar.DAY_OF_MONTH, maxOf(1, s.optInt("dueDay", 10))); cal.set(java.util.Calendar.HOUR_OF_DAY, 12)
    val all = store.misc.values.filter { it.s("t") == "soc" && it.s("societyID") == soc.id && !it.deleted }.map { it.copyDeep() }
    val have = all.filter { it.s("kind") == "bill" && it.d.optString("month") == monthKey }.map { it.s("unitID") }.toSet()
    for (u in all.filter { it.s("kind") == "unit" && it.id !in have }) {
        val amt = u.d.optDouble("maintenance", 0.0).takeIf { it > 0 } ?: s.optDouble("defaultMaintenance", 0.0)
        if (amt <= 0) continue
        val b = JSONObject().put("title", "Maintenance $monthKey").put("month", monthKey).put("amount", amt).put("due", SwiftDate.from(cal.timeInMillis))
            .put("method", "").put("reference", "").put("receipts", JSONArray()).put("verifiedBy", "")
        socSend(listOf(socItem("socb_" + newID(), "bill", soc.id, u.id, "due", data = b)), s, u.id, true, "🧾 ${s.optString("name")}: maintenance ${money(amt)} due ${dateText(cal.timeInMillis)}")
    }
}

fun Sync.socPayBill(r: Rec, method: String, reference: String) {
    val s = misc("soc", r.s("societyID"))?.d ?: return
    val b = JSONObject(r.d.toString()).put("paidOn", SwiftDate.now()).put("method", method).put("reference", reference)
    val committee = isCommittee(s, me); if (committee) b.put("verifiedBy", me)
    socSend(listOf(socItem(r.id, "bill", r.s("societyID"), r.s("unitID"), if (committee) "paid" else "verifying", data = b)), s, r.s("unitID"), true,
        if (committee) "✅ Payment received" else "💸 ${store.myName} paid ${money(b.optDouble("amount"))} — please verify")
}

fun Sync.socVerifyBill(r: Rec, ok: Boolean) {
    val s = misc("soc", r.s("societyID"))?.d ?: return
    val b = JSONObject(r.d.toString()); if (ok) b.put("verifiedBy", me) else b.remove("paidOn")
    socSend(listOf(socItem(r.id, "bill", r.s("societyID"), r.s("unitID"), if (ok) "paid" else "due", data = b)), s, r.s("unitID"), true,
        if (ok) "✅ ${s.optString("name")} confirmed your payment" else "⚠️ ${s.optString("name")} couldn't match your payment")
}

fun Sync.socComplaint(soc: Rec, unitID: String, title: String, category: String, detail: String) {
    val c = JSONObject().put("title", title).put("category", category).put("detail", detail).put("photos", JSONArray()).put("reply", "").put("assignedTo", "")
    socSend(listOf(socItem("socc_" + newID(), "complaint", soc.id, unitID, "open", data = c)), soc.d, unitID, true, "🛠️ Complaint: $title")
}

fun Sync.socUpdateComplaint(r: Rec, status: String, reply: String) {
    val s = misc("soc", r.s("societyID"))?.d ?: return
    socSend(listOf(socItem(r.id, "complaint", r.s("societyID"), r.s("unitID"), status, data = JSONObject(r.d.toString()).put("reply", reply))), s, r.s("unitID"), true, "🛠️ “${r.d.optString("title")}”: $status")
}

fun Sync.socVisitor(soc: Rec, unitID: String, name: String, purpose: String, vehicle: String) {
    val v = JSONObject().put("name", name).put("purpose", purpose).put("vehicle", vehicle).put("phone", "").put("at", SwiftDate.now())
        .put("answeredBy", "").put("note", "").put("gateBy", me)
    socSend(listOf(socItem("socv_" + newID(), "visitor", soc.id, unitID, "waiting", data = v)), soc.d, unitID, true,
        "🚪 $purpose: $name is at the gate for flat ${misc("soc", unitID)?.unitLabel ?: ""} — approve?")
}

fun Sync.socAnswerVisitor(r: Rec, status: String) {
    val s = misc("soc", r.s("societyID"))?.d ?: return
    val v = JSONObject(r.d.toString()).put("answeredBy", me).put("answeredAt", SwiftDate.now())
    socSend(listOf(socItem(r.id, "visitor", r.s("societyID"), r.s("unitID"), status, data = v)), s, r.s("unitID"), status != "left",
        when (status) { "approved" -> "✅ ${v.optString("name")} approved"; "denied" -> "⛔️ ${v.optString("name")} denied"; else -> null })
}

fun Sync.socNotice(soc: Rec, title: String, body: String) {
    val s = soc.d
    val item = socItem("socn_" + newID(), "notice", soc.id, data = JSONObject().put("title", title).put("body", body).put("pinned", false).put("files", JSONArray()))
    sendOrLocal(listOfNotNull(store.conv(s.optString("committeeConvID"))?.takeIf { !it.left }?.id), ev("society", JSONObject().put("items", JSONArray().put(item))), true, "📢 $title")
    store.misc.values.filter { it.s("t") == "soc" && it.s("societyID") == soc.id && it.s("kind") == "unit" && !it.deleted }.map { it.d.optString("ownerUserID") }.toSet()
        .filter { it.isNotEmpty() && it != me && !isCommittee(s, it) && store.contacts[it] != null }
        .forEach { o -> runCatching { send(directID(me, o), ev("society", JSONObject().put("items", JSONArray().put(soc.socItem()).put(item))), true, "📢 ${s.optString("name")}: $title") } }
}

fun Sync.socDelete(r: Rec) { val s = misc("soc", r.s("societyID"))?.d ?: return; socSend(listOf(r.socItem(deleted = true)), s, r.s("unitID")) }

private fun Sync.socLine(r: Rec, isNew: Boolean, old: String?, from: String): String? {
    val w = who(from); val flat = misc("soc", r.s("unitID"))?.unitLabel ?: ""
    if (r.deleted) return if (isNew) null else "🗑️ $w removed a ${r.s("kind")}"
    val d = r.d
    return when (r.s("kind")) {
        "society" -> if (isNew) "🏢 $w set up society “${d.optString("name")}”" else null
        "unit" -> if (isNew) "🏠 $w added flat ${r.unitLabel} — owner ${d.optString("ownerName")}" else null
        "bill" -> if (isNew) "🧾 ${d.optString("title")} for flat $flat: ${money(d.optDouble("amount"))}, due ${dateText(SwiftDate.toMillis(d.optDouble("due")))}"
            else if (old != r.status) when (r.status) { "verifying" -> "💸 $w paid ${money(d.optDouble("amount"))} for flat $flat — please verify"
                "paid" -> "✅ $w confirmed ${money(d.optDouble("amount"))} received from flat $flat"; else -> "🧾 $w marked the bill for flat $flat as ${r.status}" } else null
        "complaint" -> if (isNew) "🛠️ $w raised a complaint for flat $flat: ${d.optString("title")}" else if (old != r.status) "🛠️ $w marked “${d.optString("title")}” ${r.status}" else null
        "visitor" -> if (isNew) "🚪 ${d.optString("purpose")}: ${d.optString("name")} at the gate for flat $flat — approve or deny"
            else if (old != r.status) when (r.status) { "approved" -> "✅ $w let ${d.optString("name")} in (flat $flat)"; "denied" -> "⛔️ $w denied entry to ${d.optString("name")} (flat $flat)"
                "left" -> "👋 ${d.optString("name")} left (flat $flat)"; else -> null } else null
        "notice" -> if (isNew) "📢 Notice: ${d.optString("title")}" else null
        else -> null
    }
}

// MARK: - Gym actions (all in the member's chat)

val gymPayKinds = listOf("membership" to "Gym membership", "training" to "Personal training", "supplements" to "Supplements & diet", "protein" to "Protein & creatine",
    "gear" to "Gear & clothing", "shoes" to "Shoes", "equipment" to "Home equipment", "medical" to "Physio & medical", "other" to "Other")

fun Sync.gymSaveMember(convID: String, existing: Rec?, name: String, relation: String, phone: String, goal: String, trainer: String, fee: Double, trainerID: String?, deleted: Boolean = false) {
    val p = JSONObject().put("id", existing?.id ?: ("g_" + newID())).put("name", name).put("relation", relation).put("phone", phone).put("goal", goal)
        .put("trainer", trainer).put("fee", fee).put("deleted", deleted).put("at", SwiftDate.now())
    if (trainerID != null) p.put("trainerID", trainerID)
    send(existing?.s("convID")?.ifEmpty { null } ?: convID, ev("gymMember", p), loud = existing == null, hintText = "🏋️ Gym & Training: $name")
}

fun Sync.gymAnswerTrainer(m: Rec, accept: Boolean, note: String) = send(m.s("convID"), evNamed("gymTrainerAnswer", JSONObject().put("memberID", m.id).put("accept", accept).put("note", note)),
    loud = true, hintText = if (accept) "✅ ${store.myName} will train ${m.s("name")}" else "✋ ${store.myName} declined to train ${m.s("name")}")

fun Sync.gymSession(m: Rec, date: Long, workout: String, notes: String) = send(m.s("convID"), ev("gymSession", JSONObject().put("id", newID()).put("memberID", m.id)
    .put("date", SwiftDate.from(date)).put("trainer", m.s("trainer")).put("workout", workout).put("notes", notes).put("deleted", false).put("at", SwiftDate.now())))

fun Sync.gymPayment(m: Rec, kind: String, amount: Double, method: String, sessions: Int, notes: String) = send(m.s("convID"), ev("gymPayment", JSONObject().put("id", newID())
    .put("memberID", m.id).put("kind", kind).put("amount", amount).put("date", SwiftDate.now()).put("method", method).put("sessions", sessions).put("notes", notes)
    .put("receipts", JSONArray()).put("deleted", false).put("at", SwiftDate.now())))

fun Sync.gymPlan(m: Rec, gym: String, plan: String, start: Long, end: Long, fee: Double) = send(m.s("convID"), ev("gymPlan", JSONObject().put("id", newID()).put("memberID", m.id)
    .put("gymName", gym).put("branch", "").put("planName", plan).put("start", SwiftDate.from(start)).put("end", SwiftDate.from(end)).put("fee", fee).put("notes", "")
    .put("deleted", false).put("at", SwiftDate.now())))

fun Sync.gymDelete(t: String, r: Rec) {
    val case = mapOf("gymplan" to "gymPlan", "gymsess" to "gymSession", "gympay" to "gymPayment")[t] ?: return
    val m = misc("gymm", r.s("memberID")) ?: return
    send(m.s("convID"), ev(case, JSONObject(r.p.toString()).apply { remove("t") }.put("deleted", true).put("at", SwiftDate.now())))
}
