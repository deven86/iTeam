package com.jondhale.iteam

import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat
import java.util.Locale

// Business modules (shared record engine) and Builder & Infra — same events and rules as the iPhone.

fun money(v: Double): String = NumberFormat.getCurrencyInstance(Locale("en", "IN")).apply { maximumFractionDigits = 0 }.format(v)
fun num(s: String): Double = s.replace(",", "").trim().toDoubleOrNull() ?: 0.0

// MARK: - Biz records

val Rec.module get() = s("module")
val Rec.kind get() = s("kind")
val Rec.parentID get() = s("parentID")
val Rec.subjectID get() = s("subjectID")
val Rec.title get() = s("title")
val Rec.status get() = s("status")
val Rec.amount get() = p.optDouble("amount", 0.0).let { if (it.isNaN()) 0.0 else it }
val Rec.date: Long? get() = p.optDoubleOrNull("date")?.let { SwiftDate.toMillis(it) }
val Rec.due: Long? get() = p.optDoubleOrNull("due")?.let { SwiftDate.toMillis(it) }
fun Rec.extra(k: String) = p.optJSONObject("extra")?.optString(k) ?: ""

object Biz {
    fun new(module: String, kind: String, parent: String = ""): JSONObject = JSONObject()
        .put("id", "biz_" + newID()).put("module", module).put("kind", kind).put("parentID", parent).put("subjectID", "")
        .put("title", "").put("subtitle", "").put("phone", "").put("amount", 0.0).put("status", "").put("notes", "")
        .put("deleted", false).put("at", SwiftDate.now())

    fun logLine(p: JSONObject, who: String, isNew: Boolean): String {
        val kind = BizSpecs.spec(p.optString("module"))?.kind(p.optString("kind"))
        val what = kind?.label ?: p.optString("kind")
        val amt = p.optDouble("amount", 0.0)
        var detail = listOf(p.optString("title"), if (amt != 0.0 && !amt.isNaN()) money(amt) else "", p.optString("status")).filter { it.isNotEmpty() }.joinToString(" · ")
        (p.optDoubleOrNull("date") ?: p.optDoubleOrNull("due"))?.let { detail += (if (detail.isEmpty()) "" else " · ") + dateText(SwiftDate.toMillis(it)) }
        val verb = if (p.optBoolean("deleted")) "deleted" else if (isNew) "added" else "updated"
        return "📒 $who $verb ${what.lowercase()}${if (detail.isEmpty()) "" else " — $detail"}"
    }

    /** What the linked person owes (or has spent) on this parent. */
    fun balance(spec: BizSpec, children: List<Rec>): Double = children.filter { !it.deleted }.sumOf { r ->
        val k = spec.kind(r.kind) ?: return@sumOf 0.0
        if (k.sign == 0) 0.0 else if (k.countWhen != null && r.status != k.countWhen) 0.0 else r.amount * k.sign
    }
}

private fun Sync.isAdmin(conv: Conv?, who: String, default: Boolean) = conv?.let { it.owner == who || it.admins.contains(who) } ?: default

/** Saves a record: in the linked person's direct chat (they see their own records), or only on this phone. */
fun Sync.saveBiz(p: JSONObject, convID: String) {
    p.put("at", SwiftDate.now())
    val existing = store.bizRec(p.getString("id"))
    val isNew = existing == null
    if (convID.isNotEmpty() && store.conv(convID) != null) {
        val answer = BizSpecs.spec(p.optString("module"))?.kind(p.optString("kind"))?.clientAnswers == true
        val loud = (isNew || answer) && !p.optBoolean("deleted")
        send(convID, ev("biz", p), loud = loud, hintText = if (loud) Biz.logLine(p, store.myName, isNew) else null)
    } else synchronized(store) {
        applyBiz(p, me, "") {}
        store.save()
    }
    // Rent: a payment settles the oldest due charges.
    if (isNew && p.optString("module") == "rent" && p.optString("kind") == "payment" && !p.optBoolean("deleted")) {
        var left = p.optDouble("amount", 0.0)
        store.bizList("rent").filter { it.parentID == p.optString("parentID") && !it.deleted && it.kind == "charge" && it.status == "Due" }
            .sortedBy { it.due ?: it.created }.forEach { c ->
                if (c.amount <= left + 0.5) {
                    left -= c.amount
                    val q = JSONObject(c.p.toString()).put("status", "Paid").put("notes", (if (c.s("notes").isEmpty()) "" else c.s("notes") + " · ") + "settled by payment")
                    saveBiz(q, c.conv)
                }
            }
    }
}

fun Sync.deleteBiz(r: Rec) = saveBiz(JSONObject(r.p.toString()).put("deleted", true), r.conv)

internal fun Sync.applyBiz(incoming: JSONObject, from: String, convID: String, sys: (String) -> Unit) {
    var p = incoming
    val id = p.optString("id")
    if (id.isEmpty()) return
    val personal = convID.isEmpty() || convID.startsWith("s_")
    val conv = if (personal) null else store.convs[convID]
    val at = p.optDouble("at", SwiftDate.now())
    val existing = store.biz[id]
    val r: Rec
    if (existing != null) {
        if (at <= existing.updated) return
        val kind = BizSpecs.spec(existing.module)?.kind(existing.kind)
        val parentOwner = store.biz[existing.parentID]?.owner
        val isOwner = existing.owner == from || parentOwner == from
        val team = conv?.isGroup == true && conv.members.contains(from) && existing.conv == conv.id && !p.optBoolean("deleted")
        val client = existing.subjectID.isNotEmpty() && existing.subjectID == from && !isOwner && (kind?.clientAnswers == true || existing.status == "Reverting")
        if (!(isOwner || team || client)) return
        if (client) {
            val keep = JSONObject(existing.p.toString())
            keep.put("status", if (existing.status == "Reverting") (if (p.optString("status") == "Due") "Due" else "Paid") else p.optString("status"))
            if (kind?.clientAnswers == true && p.optString("notes").isNotEmpty()) keep.put("notes", p.optString("notes"))
            keep.put("at", at)
            p = keep
        }
        val st = p.optString("status")
        if (existing.status == "Paid" && st == "Due" && !client) {
            if ((existing.subjectID.isNotEmpty() && existing.subjectID != from) || (conv?.isGroup == true && !isAdmin(conv, from, true))) p.put("status", "Reverting")
        }
        if (existing.module == "bills" && conv?.isGroup == true && !client) {
            val admin = isAdmin(conv, from, false)
            if (!admin && p.optString("status") == "Paid" && existing.status != "Paid") p.put("status", "Approving")
            if (!admin && existing.status == "Approving" && p.optString("status") != "Approving") p.put("status", "Approving")
        }
        if (existing.status == "Reverting" && !client && p.optString("status") == "Due") {
            if (existing.subjectID.isNotEmpty() || (conv?.isGroup == true && !isAdmin(conv, from, true))) p.put("status", "Reverting")
        }
        r = existing
    } else {
        r = Rec(id, if (personal) "" else convID, from, from, System.currentTimeMillis(), p)
        store.biz[id] = r
    }
    if (!personal && conv != null) r.conv = conv.id
    val wasDeleted = r.deleted
    val old = r.p
    val merged = JSONObject(p.toString())
    if (!merged.has("files") && old.has("files")) merged.put("files", old.get("files"))
    if (!merged.has("extra") && old.has("extra")) merged.put("extra", old.get("extra"))
    if (wasDeleted) merged.put("deleted", true)
    r.p = merged
    r.updated = at
    if (merged.optBoolean("deleted") && !wasDeleted) r.deletedBy = from
    if (!personal && conv != null) {
        val who = if (from == me) "You" else store.name(from)
        val title = merged.optString("title"); val amt = merged.optDouble("amount", 0.0)
        sys(when {
            merged.optString("status") == "Reverting" && existing?.status != "Reverting" -> "↩️ $who wants to move “$title” back to Due — needs approval"
            merged.optString("status") == "Approving" && existing?.status != "Approving" -> "💸 $who paid “$title”${if (amt > 0) " (${money(amt)})" else ""} — waiting for a group admin to approve"
            else -> Biz.logLine(merged, who, existing == null)
        })
    }
}

// MARK: - Builder & Infra

/** BuildData: the f-map plus team, admins, project chat and the person it's about. */
val Rec.d: JSONObject get() = p.optJSONObject("d") ?: JSONObject()
fun Rec.f(k: String): String = d.optJSONObject("f")?.optString(k) ?: ""
fun Rec.fnum(k: String) = num(f(k))
val Rec.bkind get() = s("kind")
val Rec.projectID get() = s("projectID")
val Rec.companyID get() = s("companyID")
val Rec.ownerID get() = s("ownerID")
val Rec.team: List<String> get() = d.optJSONArray("team")?.strings() ?: emptyList()
val Rec.admins: List<String> get() = d.optJSONArray("admins")?.strings() ?: emptyList()
val Rec.btitle: String get() = BuildData.title(bkind, d)

object BuildData {
    fun new(f: Map<String, String> = emptyMap()): JSONObject = JSONObject().put("f", JSONObject(f.filterValues { it.isNotEmpty() }))
        .put("files", JSONArray()).put("team", JSONArray()).put("admins", JSONArray()).put("convID", "").put("subjectID", "")
    fun fill(d: JSONObject): JSONObject {
        if (!d.has("f")) d.put("f", JSONObject())
        for (k in listOf("files", "team", "admins")) if (!d.has(k)) d.put(k, JSONArray())
        for (k in listOf("convID", "subjectID")) if (!d.has(k)) d.put(k, "")
        return d
    }
    fun title(kind: String, d: JSONObject): String {
        val f = d.optJSONObject("f") ?: JSONObject()
        fun g(k: String) = f.optString(k)
        return when (kind) {
            "unit" -> listOf(g("wing"), g("number")).filter { it.isNotEmpty() }.joinToString("-")
            "sale" -> g("buyer")
            "payment", "demand", "move", "log" -> g("title").ifEmpty { g("type") }
            else -> g("name")
        }
    }
    fun date(s: String): Long? = s.toDoubleOrNull()?.let { (it * 1000).toLong() }
    fun dateString(ms: Long) = (ms / 1000).toString()
}

/** Turns a stored record back into the iPhone's BuildItem JSON. */
private fun Rec.item(at: Double = p.optDouble("at", SwiftDate.now())): JSONObject = JSONObject()
    .put("id", id).put("kind", bkind).put("companyID", companyID).put("projectID", projectID).put("parentID", s("parentID"))
    .put("status", s("status")).put("ownerID", ownerID).put("deleted", deleted)
    .put("data", E2E.b64(BuildData.fill(JSONObject(d.toString())).toString().toByteArray())).put("at", at)

private fun buildItem(id: String, kind: String, company: String, project: String, parent: String, status: String, owner: String, data: JSONObject, deleted: Boolean = false) =
    JSONObject().put("id", id).put("kind", kind).put("companyID", company).put("projectID", project).put("parentID", parent)
        .put("status", status).put("ownerID", owner).put("deleted", deleted)
        .put("data", E2E.b64(BuildData.fill(data).toString().toByteArray())).put("at", SwiftDate.now())

fun Sync.bChildren(parent: String, kind: String? = null) = store.buildList().filter { it.s("parentID") == parent && !it.deleted && (kind == null || it.bkind == kind) }
fun Sync.bIsAdmin(project: Rec?) = project == null || project.ownerID == me || project.admins.contains(me)

fun Sync.bStock(material: Rec): Double = bChildren(material.id, "move").sumOf { m ->
    val q = m.fnum("qty")
    when (m.f("type")) { "Received", "Returned", "Count correction" -> q; else -> -q }
}

private fun Sync.bSubject(it: JSONObject, data: JSONObject): String {
    data.optString("subjectID").takeIf { it.isNotEmpty() }?.let { return it }
    val p = store.buildRec(it.optString("parentID"))
    return if (p != null && p.bkind in listOf("sale", "party")) p.d.optString("subjectID") else ""
}

/** Team chat (or only this phone for private kinds); the buyer / partner / rehab tenant gets their own copy. */
fun Sync.bSend(items: List<JSONObject>, loud: Boolean = false, preview: String? = null) {
    val first = items.firstOrNull() ?: return
    val data = JSONObject(String(E2E.unb64(first.getString("data"))))
    val kind = first.getString("kind")
    val project = if (kind == "project") data else store.buildRec(first.optString("projectID"))?.d
    val body = ev("build", JSONObject().put("items", JSONArray(items)))
    val conv = project?.optString("convID").orEmpty()
    val f = data.optJSONObject("f") ?: JSONObject()
    val private = BuildKinds.of(kind).privateKind || (kind == "party" && f.optString("role") in BuildKinds.money)
    val group = store.conv(conv)
    if (private || project == null || conv.isEmpty() || group == null || group.left) {
        synchronized(store) { applyBuild(JSONObject().put("items", JSONArray(items)), me, "") {}; store.save() }
    } else send(conv, body, loud = loud, hintText = preview)

    val subject = bSubject(first, data)
    if (subject.isEmpty() || subject == me || kind == "vault" || kind == "company" || store.contacts[subject] == null) return
    val bundle = mutableListOf<JSONObject>()
    store.buildRec(first.optString("projectID"))?.takeIf { kind != "project" }?.let { p ->
        val safe = JSONObject(p.d.toString()).put("team", JSONArray()).put("admins", JSONArray()).put("convID", "").put("files", JSONArray())
        safe.optJSONObject("f")?.remove("budget")
        bundle += buildItem(p.id, "project", p.companyID, p.id, "", p.status, p.ownerID, safe)
    }
    var chain = store.buildRec(first.optString("parentID"))
    while (chain != null && bundle.size < 4) { bundle += chain.item(); chain = store.buildRec(chain.s("parentID")) }
    bundle += items
    val direct = directID(me, subject)
    synchronized(store) { store.convs.getOrPut(direct) { Conv(direct, store.name(subject), listOf(me, subject), updated = System.currentTimeMillis()) } }
    send(direct, ev("build", JSONObject().put("items", JSONArray(bundle))), loud = loud,
        hintText = if (loud) preview ?: "🏗️ ${store.myName} updated your ${BuildKinds.of(kind).label.lowercase()}" else null)
}

fun Sync.bSave(kind: String, existing: Rec?, company: String, project: String, parent: String = "", status: String, data: JSONObject, loud: Boolean = false): String {
    val id = existing?.id ?: ("b${kind.take(3)}_" + newID())
    val owner = existing?.ownerID ?: store.buildRec(project)?.ownerID ?: me
    val it = buildItem(id, kind, company, project, parent, status, owner, data)
    val isNew = existing == null
    bSend(listOf(it), loud = loud || isNew && kind in listOf("sale", "payment", "demand", "test", "approval", "dispute", "inspection"),
        preview = if (isNew) "🏗️ ${BuildKinds.of(kind).label}: ${BuildData.title(kind, data)}" else null)
    return id
}

fun Sync.bDelete(r: Rec) {
    bSend(listOf(buildItem(r.id, r.bkind, r.companyID, r.projectID, r.s("parentID"), r.status, r.ownerID, JSONObject(r.d.toString()), deleted = true)))
    for (c in bChildren(r.id)) if (c.bkind in listOf("move", "log", "payment", "demand")) bDelete(c)
}

fun Sync.bSetStatus(r: Rec, status: String) = bSave(r.bkind, r, r.companyID, r.projectID, r.s("parentID"), status, JSONObject(r.d.toString()))

fun Sync.bCreateCompany(f: Map<String, String>): String {
    val id = "bcom_" + newID()
    synchronized(store) {
        applyBuild(JSONObject().put("items", JSONArray().put(buildItem(id, "company", id, "", "", "", me, BuildData.new(f)))), me, "") {}
        store.save()
    }
    return id
}

fun Sync.bCreateProject(company: String, f: Map<String, String>, team: List<String>, admins: List<String>): String {
    val d = BuildData.new(f).put("team", JSONArray(team)).put("admins", JSONArray(admins))
    if (team.isNotEmpty()) d.put("convID", createGroup("${f["name"]} · Project", team))
    return bSave("project", null, company, "", "", "Planning", d, loud = true)
}

fun Sync.bSaveProject(r: Rec, f: Map<String, String>, team: List<String>, admins: List<String>, status: String) {
    val d = JSONObject(r.d.toString()).put("f", JSONObject(f.filterValues { it.isNotEmpty() })).put("team", JSONArray(team)).put("admins", JSONArray(admins))
    val g = store.conv(d.optString("convID"))
    if (g != null) { val add = team.filter { it !in g.members }; if (add.isNotEmpty()) addMembers(g.id, add) }
    else if (team.isNotEmpty()) d.put("convID", createGroup("${f["name"]} · Project", team))
    bSave("project", r, r.companyID, "", "", status, d)
}

/** Units for every wing × floor of a building. */
fun Sync.bGenerateUnits(b: Rec, perFloor: Int, type: String, carpet: String, price: String, fromFloor: Int, toFloor: Int) {
    val wings = b.f("wings").split(",").map { it.trim() }.filter { it.isNotEmpty() }.ifEmpty { listOf("") }
    val existing = bChildren(b.id, "unit").map { it.btitle }.toSet()
    val items = mutableListOf<JSONObject>()
    for (w in wings) for (fl in fromFloor..maxOf(fromFloor, toFloor)) for (n in 1..maxOf(1, perFloor)) {
        val number = if (fl == 0) "G0$n" else "$fl${"%02d".format(n)}"
        val d = BuildData.new(mapOf("wing" to w, "floor" to "$fl", "number" to number, "type" to type, "carpet" to carpet, "price" to price))
        if (BuildData.title("unit", d) in existing) continue
        items += buildItem("bun_" + newID(), "unit", b.companyID, b.projectID, b.id, "Available", b.ownerID, d)
    }
    items.chunked(40).forEach { bSend(it) }
}

/** Instalments for a sale from the payment-plan stages. */
fun Sync.bAddPlan(sale: Rec, stages: List<Pair<String, Double>>) {
    val value = sale.fnum("value")
    if (value <= 0) return
    val items = stages.map { (t, pct) ->
        buildItem("bdem_" + newID(), "demand", sale.companyID, sale.projectID, sale.id, "Due", sale.ownerID,
            BuildData.new(mapOf("title" to t, "percent" to "$pct", "amount" to "%.0f".format(value * pct / 100))))
    }
    bSend(items, loud = true, preview = "🧾 Payment schedule for unit ${store.buildRec(sale.s("parentID"))?.btitle ?: ""}")
}

internal fun Sync.applyBuild(payload: JSONObject, from: String, convID: String, sys: (String) -> Unit) {
    val arr = payload.optJSONArray("items") ?: return
    val items = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.sortedBy { if (it.optString("kind") == "project") 0 else 1 }
    val local = convID.isEmpty() || convID.startsWith("s_")
    for (it in items) {
        val id = it.optString("id")
        if (id.isEmpty()) continue
        val at = it.optDouble("at", 0.0)
        val existing = store.build[id]
        if (existing != null && at <= existing.updated) continue
        if (existing != null && existing.ownerID.isNotEmpty() && existing.ownerID != it.optString("ownerID")) continue
        val incoming = runCatching { JSONObject(String(E2E.unb64(it.optString("data")))) }.getOrElse { JSONObject() }
        val kind = it.optString("kind")
        val project = if (kind == "project") (existing?.d ?: incoming) else store.build[it.optString("projectID")]?.d
        val isOwner = from == it.optString("ownerID")
        val isAdmin = isOwner || (project?.optJSONArray("admins")?.strings()?.contains(from) ?: false)
        val isTeam = isAdmin || (project?.optJSONArray("team")?.strings()?.contains(from) ?: false)
        val allowed = when {
            kind == "project" -> if (existing == null) isOwner else isAdmin
            it.optString("projectID").isEmpty() -> isOwner
            else -> if (BuildKinds.adminOnly(kind)) isAdmin else isTeam
        }
        if (!allowed) continue
        val oldStatus = existing?.status
        val wasDeleted = existing?.deleted ?: false
        val p = JSONObject(it.toString()).apply { remove("data"); put("d", BuildData.fill(incoming)) }
        val r = existing ?: Rec(id, if (local) "" else convID, it.optString("ownerID"), from, System.currentTimeMillis(), p)
        store.build[id] = r
        r.p = p; r.owner = it.optString("ownerID"); r.updated = at
        if (!local) buildLine(r, existing == null, oldStatus, wasDeleted, from)?.let(sys)
    }
}

private fun Sync.buildLine(r: Rec, isNew: Boolean, oldStatus: String?, wasDeleted: Boolean, from: String): String? {
    val who = if (from == me) "You" else store.name(from)
    val k = BuildKinds.of(r.bkind)
    val t = r.btitle
    if (r.deleted) return if (wasDeleted) null else "🗑️ $who deleted ${k.label.lowercase()} “$t”"
    val parent = store.build[r.s("parentID")]
    val pt = parent?.btitle ?: ""
    val changed = oldStatus != r.status
    return when (r.bkind) {
        "company" -> null
        "project" -> if (isNew) "🏗️ $who set up project “$t”" else if (changed) "🏗️ “$t” is now ${r.status}" else null
        "unit" -> if (!isNew && changed) "🏠 Unit $t: ${r.status}" else null
        "sale" -> if (isNew) "🤝 $who booked unit $pt for $t" else if (changed) "🤝 $t · unit $pt: ${r.status}" else null
        "payment" -> { val amt = money(r.fnum("amount")); if (isNew) "💰 $who recorded $amt from $pt — ${r.f("title")}" else if (changed) "💰 Payment $amt ${r.status.lowercase()}" else null }
        "demand" -> if (isNew) "🧾 Demand: ${r.f("title")} ${money(r.fnum("amount"))} for $pt" else if (changed) "🧾 ${r.f("title")} marked ${r.status}" else null
        "move" -> if (isNew) "📦 $who: ${r.f("type")} ${r.f("qty")} ${parent?.f("unit") ?: ""} $pt${if (r.f("where").isEmpty()) "" else " → ${r.f("where")}"}" else null
        "log" -> if (isNew) "🚜 $who logged $pt: ${r.f("title")}" else null
        "test" -> if (isNew) "🧪 $who added test “$t” (${r.f("where")})" else if (changed) (if (r.status == "Fail") "❌ Test failed: $t — ${r.f("where")}" else "🧪 $t: ${r.status}") else null
        "approval" -> if (isNew) "📜 $who added approval “$t” — ${r.status}" else if (changed) (if (r.status == "Approved") "✅ Approved: $t" else "📜 $t: ${r.status}") else null
        "progress" -> if (isNew) "📸 Site report by $who: $t" else null
        else -> if (isNew) "${if (r.bkind == "dispute") "⚠️" else "➕"} $who added ${k.label.lowercase()} “$t”" else if (changed && r.status.isNotEmpty()) "✏️ “$t”: ${r.status}" else null
    }
}
