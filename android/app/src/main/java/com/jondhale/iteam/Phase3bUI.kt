package com.jondhale.iteam

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import kotlinx.coroutines.launch

// CRM, Society and Gym & Training screens.

private fun miscList(app: AppState, t: String) = app.store.miscList(t)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Screen(title: String, onBack: (() -> Unit)?, fab: (@Composable () -> Unit)? = null, pdf: (() -> List<String>)? = null,
                   charts: () -> List<Chart> = { emptyList() }, module: String = title, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Scaffold(topBar = { TopAppBar(title = { Text(title) }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } },
        actions = { pdf?.let { PdfButton(module, "$title report", charts, it) } }) },
        floatingActionButton = { fab?.invoke() }) { pad -> LazyColumn(Modifier.padding(pad), content = content) }
}

@Composable
private fun Fab(text: String, onClick: () -> Unit) = ExtendedFloatingActionButton(onClick = onClick, icon = { Icon(Icons.Default.Add, null) }, text = { Text(text) })

@Composable
private fun Field(v: String, label: String, number: Boolean = false, onChange: (String) -> Unit) =
    OutlinedTextField(v, onChange, label = { Text(label) }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        keyboardOptions = if (number) KeyboardOptions(keyboardType = KeyboardType.Decimal) else KeyboardOptions.Default)

@Composable
private fun Form(title: String, ok: String = "Save", enabled: Boolean = true, onDone: () -> Unit, onOk: () -> Unit, content: @Composable ColumnScope.() -> Unit) =
    AlertDialog(onDismissRequest = onDone, title = { Text(title) }, text = { Column(Modifier.verticalScroll(rememberScrollState()), content = content) },
        confirmButton = { TextButton({ onOk(); onDone() }, enabled = enabled) { Text(ok) } }, dismissButton = { TextButton(onDone) { Text("Cancel") } })

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Chips(options: List<String>, sel: String, label: (String) -> String = { it }, onPick: (String) -> Unit) =
    FlowRow { options.forEach { o -> FilterChip(sel == o, { onPick(o) }, label = { Text(label(o)) }, modifier = Modifier.padding(end = 4.dp)) } }

// MARK: - CRM

@Composable
fun CRMHome(app: AppState, onBack: (() -> Unit)?, open: (Page) -> Unit) {
    val me = app.store.me
    val leads = remember(app.tick) { miscList(app, "crml").filter { !it.deleted } }
    val mine = leads.filter { !it.p.optBoolean("clientCopy") }
    val shared = leads.filter { it.p.optBoolean("clientCopy") && it.s("clientID") == me }
    val groups = remember(app.tick) { miscList(app, "crmg").filter { !it.deleted } }
    var stage by remember { mutableStateOf("") }
    var adding by remember { mutableStateOf(false) }
    var newGroup by remember { mutableStateOf(false) }
    val open0 = mine.filter { it.s("stage") !in listOf("won", "lost") }
    Screen("CRM", onBack, { Fab("New lead") { adding = true } }, charts = { ModuleCharts.crm(app) }, pdf = { crmStages.flatMap { st -> listOf("## ${st.replaceFirstChar { it.uppercase() }}") + mine.filter { it.s("stage") == st }.map { "• ${it.s("name")} ${it.s("company")} · ${money(it.p.optDouble("dealValue"))} · ${it.s("phone")}" } } }) {
        item {
            StatTiles("${open0.size}" to "Open leads", money(open0.sumOf { it.p.optDouble("dealValue") }) to "Pipeline value",
                money(mine.filter { it.s("stage") == "won" }.sumOf { it.p.optDouble("dealValue") }) to "Won")
            ModuleCharts.crm(app).forEach { ChartCard(it) }
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
                FilterChip(stage == "", { stage = "" }, { Text("All") }, Modifier.padding(end = 4.dp))
                crmStages.forEach { s -> FilterChip(stage == s, { stage = s }, { Text("${s.replaceFirstChar { it.uppercase() }} ${mine.count { it.s("stage") == s }}") }, Modifier.padding(end = 4.dp)) }
            }
            val due = mine.filter { l -> l.p.optDoubleOrNull("nextFollowUp")?.let { SwiftDate.toMillis(it) < System.currentTimeMillis() + 86_400_000L } == true && l.s("stage") !in listOf("won", "lost") }
            if (due.isNotEmpty()) { SectionHeader("Follow up today"); due.forEach { l -> LeadRow(l) { open(Page.Lead(l.id)) } } }
            SectionHeader("Leads", "Team group") { newGroup = true }
        }
        val list = mine.filter { stage.isEmpty() || it.s("stage") == stage }.sortedByDescending { it.updated }
        if (list.isEmpty()) item { Empty("No leads yet. Add one — keep it to yourself, or make a CRM team group so your sales team shares the pipeline.") }
        items(list, key = { it.id }) { l -> LeadRow(l) { open(Page.Lead(l.id)) } }
        if (shared.isNotEmpty()) { item { SectionHeader("Shared with me") }; items(shared, key = { "s" + it.id }) { l -> LeadRow(l) { open(Page.Lead(l.id)) } } }
        item { Spacer(Modifier.height(90.dp)) }
    }
    if (adding) LeadEditor(app, null, groups) { adding = false }
    if (newGroup) {
        var name by remember { mutableStateOf("") }
        val picked = remember { mutableStateListOf<String>() }
        val companies = remember { app.sync.crmCompanies() }
        var company by remember { mutableStateOf(companies.firstOrNull()?.first ?: "") }
        Form("CRM team group", "Create", name.isNotBlank() && picked.isNotEmpty(), { newGroup = false }, { app.run(kotlinx.coroutines.MainScope()) { app.sync.crmCreateGroup(name.trim(), company, picked.toList()) } }) {
            Field(name, "Group name (e.g. Sales team)") { name = it }
            if (companies.isNotEmpty()) Chips(companies.map { it.first }, company, { id -> companies.first { it.first == id }.second }) { company = it }
            app.store.contactList().filter { it.userID != me }.forEach { c ->
                Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(c.userID in picked, { if (it) picked.add(c.userID) else picked.remove(c.userID) }); Text(c.name) }
            }
        }
    }
}

@Composable
private fun LeadRow(l: Rec, onClick: () -> Unit) = ListItem(modifier = Modifier.clickable(onClick = onClick),
    leadingContent = { Box(Modifier.size(12.dp).background(Color(crmStageColor(l.s("stage"))), RoundedCornerShape(6.dp))) },
    headlineContent = { Text(l.s("name")) },
    supportingContent = { Text(listOf(l.s("company"), l.s("stage").replaceFirstChar { it.uppercase() }, l.p.optDoubleOrNull("nextFollowUp")?.let { "Follow up ${dateText(SwiftDate.toMillis(it))}" } ?: "").filter { it.isNotEmpty() }.joinToString(" · ")) },
    trailingContent = { if (l.p.optDouble("dealValue") > 0) Text(money(l.p.optDouble("dealValue")), fontWeight = FontWeight.SemiBold) })

@Composable
private fun LeadEditor(app: AppState, ex: Rec?, groups: List<Rec>, onDone: () -> Unit) {
    val p = remember { ex?.let { app.sync.crmLeadPayload(it) } ?: newLead("", "") }
    var name by remember { mutableStateOf(p.optString("name")) }
    var company by remember { mutableStateOf(p.optString("company")) }
    var phone by remember { mutableStateOf(p.optString("phone")) }
    var email by remember { mutableStateOf(p.optString("email")) }
    var value by remember { mutableStateOf(p.optDouble("dealValue").takeIf { it > 0 }?.let { fmtQty(it) } ?: "") }
    var source by remember { mutableStateOf(p.optString("source")) }
    var notes by remember { mutableStateOf(p.optString("notes")) }
    var group by remember { mutableStateOf(p.optString("groupConvID")) }
    var client by remember { mutableStateOf(p.optString("clientID")) }
    var follow by remember { mutableStateOf(p.optDoubleOrNull("nextFollowUp")?.let { SwiftDate.toMillis(it) }) }
    var pickClient by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Form(if (ex == null) "New lead" else "Edit lead", enabled = name.isNotBlank(), onDone = onDone, onOk = {
        p.put("name", name.trim()).put("company", company.trim()).put("phone", phone.trim()).put("email", email.trim()).put("dealValue", num(value))
            .put("source", source).put("notes", notes).put("groupConvID", group).put("clientID", client)
        groups.firstOrNull { it.s("convID") == group }?.let { p.put("companyID", it.s("companyID")) }
        if (follow != null) p.put("nextFollowUp", SwiftDate.from(follow!!)) else p.remove("nextFollowUp")
        app.run(scope) { app.sync.crmSaveLead(p) }
    }) {
        Field(name, "Name") { name = it }; Field(company, "Company") { company = it }; Field(phone, "Phone") { phone = it }; Field(email, "Email") { email = it }
        Field(value, "Deal value (₹)", true) { value = it }
        Text("Source", style = MaterialTheme.typography.labelMedium)
        Chips(listOf("Walk-in", "Referral", "Website", "Phone", "WhatsApp", "Social", "Builder", "Other"), source) { source = it }
        Field(notes, "Notes") { notes = it }
        TextButton({ follow = (follow ?: System.currentTimeMillis()) + 86_400_000L }) { Text("Follow up: ${follow?.let { dateText(it) } ?: "none"} (+1 day)") }
        if (groups.isNotEmpty()) { Text("Team group", style = MaterialTheme.typography.labelMedium); Chips(listOf("") + groups.map { it.s("convID") }, group, { id -> if (id.isEmpty()) "Just me" else groups.first { it.s("convID") == id }.s("name") }) { group = it } }
        TextButton({ pickClient = true }) { Text(if (client.isEmpty()) "Link client on iTeam (they see quotes)" else "Client: ${app.store.name(client)}") }
    }
    if (pickClient) PersonPicker(app) { client = it ?: ""; pickClient = false }
}

@Composable
fun LeadScreen(app: AppState, id: String, onBack: () -> Unit) {
    val l = remember(app.tick) { app.sync.misc("crml", id) } ?: run { Centered("Not found"); return }
    val acts = remember(app.tick) { miscList(app, "crma").filter { it.s("leadID") == id && !it.deleted }.sortedByDescending { it.updated } }
    val client = l.p.optBoolean("clientCopy")
    var edit by remember { mutableStateOf(false) }
    var act by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    Screen(l.s("name"), onBack) {
        item {
            Card(Modifier.fillMaxWidth().padding(12.dp)) { Column(Modifier.padding(14.dp)) {
                Text(l.s("name"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                listOf(l.s("company"), l.s("phone"), l.s("email"), l.s("notes")).filter { it.isNotEmpty() }.forEach { Text(it) }
                if (l.p.optDouble("dealValue") > 0) Text("Deal ${money(l.p.optDouble("dealValue"))}", fontWeight = FontWeight.SemiBold)
                if (client) Text("Managed by ${app.store.name(l.s("ownerID"))}", style = MaterialTheme.typography.labelMedium)
                else if (l.s("clientID").isNotEmpty()) Text("🔗 Client: ${app.store.name(l.s("clientID"))}", style = MaterialTheme.typography.labelMedium)
            } }
            if (!client) {
                Chips(crmStages, l.s("stage"), { it.replaceFirstChar { c -> c.uppercase() } }) { s -> app.run(scope) { app.sync.crmSetStage(l, s) } }
                Row(Modifier.padding(horizontal = 12.dp)) {
                    listOf("note" to "Note", "call" to "Call", "meeting" to "Meeting", "quote" to "Quote").forEach { (k, t) -> OutlinedButton({ act = k }, Modifier.padding(end = 4.dp)) { Text(t) } }
                }
                Row(Modifier.padding(horizontal = 12.dp)) {
                    TextButton({ edit = true }) { Text("Edit") }
                    if (l.s("ownerID") == app.store.me) TextButton({ app.run(scope) { app.sync.crmSaveLead(app.sync.crmLeadPayload(l).put("deleted", true)) }; onBack() }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                }
            }
            SectionHeader("Activity")
        }
        items(acts, key = { it.id }) { a ->
            ListItem(headlineContent = { Text(a.s("title").ifEmpty { a.s("kind").replaceFirstChar { it.uppercase() } } + if (a.amount > 0) " · ${money(a.amount)}" else "") },
                supportingContent = { Text(listOf(a.s("detail"), a.s("acceptance").let { if (it.isEmpty() && a.p.optBoolean("needsAcceptance")) "Waiting for client" else it }).filter { it.isNotEmpty() }.joinToString(" · ")) },
                trailingContent = { if (client && a.s("kind") == "quote" && a.s("acceptance").isEmpty()) Row {
                    TextButton({ app.run(scope) { app.sync.crmAnswerQuote(a, l, true, "") } }) { Text("Accept") }
                    TextButton({ app.run(scope) { app.sync.crmAnswerQuote(a, l, false, "") } }) { Text("Decline") }
                } })
        }
    }
    if (edit) LeadEditor(app, l, miscList(app, "crmg")) { edit = false }
    act?.let { k ->
        var title by remember { mutableStateOf("") }; var detail by remember { mutableStateOf("") }; var amount by remember { mutableStateOf("") }
        Form(k.replaceFirstChar { it.uppercase() }, enabled = title.isNotBlank() || detail.isNotBlank(), onDone = { act = null }, onOk = { app.run(scope) { app.sync.crmSaveActivity(l, k, title.trim(), detail.trim(), num(amount)) } }) {
            Field(title, "Title") { title = it }; Field(detail, "Details") { detail = it }
            if (k == "quote") Field(amount, "Amount (₹)", true) { amount = it }
        }
    }
}

// MARK: - Society

@Composable
fun SocietyHome(app: AppState, onBack: (() -> Unit)?, open: (Page) -> Unit) {
    val me = app.store.me
    val all = remember(app.tick) { miscList(app, "soc").filter { !it.deleted } }
    val socs = all.filter { it.s("kind") == "society" }
    var adding by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Screen("Society", onBack, { Fab("New society") { adding = true } }) {
        if (socs.isEmpty()) item { Empty("Run your housing society — flats, maintenance bills, complaints, visitors and notices. Or track just your own flat.") }
        items(socs, key = { it.id }) { s ->
            val myFlats = all.filter { it.s("kind") == "unit" && it.s("societyID") == s.id && it.d.optString("ownerUserID") == me }
            ListItem(modifier = Modifier.clickable { open(Page.Society(s.id)) }, leadingContent = { Icon(Icons.Default.Apartment, null) },
                headlineContent = { Text(s.d.optString("name")) },
                supportingContent = { Text(if (isCommittee(s.d, me)) "Committee" else myFlats.joinToString { "Flat ${it.unitLabel}" }.ifEmpty { "Member" }) })
        }
        item { Spacer(Modifier.height(90.dp)) }
    }
    if (adding) {
        var name by remember { mutableStateOf("") }; var address by remember { mutableStateOf("") }; var maint by remember { mutableStateOf("") }
        var personal by remember { mutableStateOf(false) }
        val picked = remember { mutableStateListOf<String>() }
        Form("New society", "Create", name.isNotBlank(), { adding = false }, { app.run(scope) {
            val id = app.sync.socCreate(name.trim(), address.trim(), picked.toList(), num(maint), personal)
            if (personal) app.sync.misc("soc", id)?.let { app.sync.socSaveUnit(it, null, unitData("", "My flat", me, app.store.myName, "", num(maint))) }
        } }) {
            Field(name, "Society name") { name = it }; Field(address, "Address") { address = it }; Field(maint, "Monthly maintenance (₹)", true) { maint = it }
            Row(verticalAlignment = Alignment.CenterVertically) { Switch(personal, { personal = it }); Spacer(Modifier.width(8.dp)); Text("Just my own flat (personal)") }
            if (!personal) { Text("Committee members (get the committee chat)", style = MaterialTheme.typography.labelMedium)
                app.store.contactList().filter { it.userID != me }.forEach { c -> Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(c.userID in picked, { if (it) picked.add(c.userID) else picked.remove(c.userID) }); Text(c.name) } } }
        }
    }
}

@Composable
fun SocietyScreen(app: AppState, id: String, onBack: () -> Unit) {
    val me = app.store.me
    val all = remember(app.tick) { miscList(app, "soc").filter { it.s("societyID") == id && !it.deleted } }
    val soc = all.firstOrNull { it.id == id } ?: run { Centered("Not found"); return }
    val committee = isCommittee(soc.d, me)
    val units = all.filter { it.s("kind") == "unit" }.sortedBy { it.unitLabel }
    val myUnits = units.filter { it.d.optString("ownerUserID") == me }.map { it.id }
    val visible = if (committee) all else all.filter { it.s("unitID") in myUnits || it.s("kind") == "notice" || it.id in myUnits }
    val bills = visible.filter { it.s("kind") == "bill" }
    val complaints = visible.filter { it.s("kind") == "complaint" }
    val visitors = visible.filter { it.s("kind") == "visitor" && it.status == "waiting" }
    val notices = visible.filter { it.s("kind") == "notice" }
    var dialog by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    fun flat(u: String) = units.firstOrNull { it.id == u }?.unitLabel ?: ""
    val socCharts = listOf(Charts.grouped("Complaints by status", complaints, key = { it.status.ifEmpty { "open" } }),
        Charts.grouped("Bills (amount)", bills, key = { it.status.ifEmpty { "due" } }, value = { it.d.optDouble("amount", 0.0) })).filter { it.usable }
    Screen(soc.d.optString("name"), onBack, charts = { socCharts }, module = "Society", pdf = { listOf("## Bills") + bills.map { "• Flat ${flat(it.s("unitID"))} · ${it.d.optString("title")} · ${money(it.d.optDouble("amount"))} · ${it.status}" } +
        listOf("## Complaints") + complaints.map { "• Flat ${flat(it.s("unitID"))} · ${it.d.optString("title")} · ${it.status}" } }) {
        item {
            StatTiles(money(bills.filter { it.status != "paid" }.sumOf { it.d.optDouble("amount") }) to "Dues", "${complaints.count { it.status != "resolved" && it.status != "closed" }}" to "Open complaints", "${visitors.size}" to "At the gate")
            socCharts.forEach { ChartCard(it) }
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
                if (committee) {
                    OutlinedButton({ dialog = "unit" }, Modifier.padding(end = 4.dp)) { Text("Add flat") }
                    OutlinedButton({ app.run(scope) { app.sync.socGenerateBills(soc) }; app.toast = "Bills sent for this month" }, Modifier.padding(end = 4.dp)) { Text("Generate bills") }
                    OutlinedButton({ dialog = "notice" }, Modifier.padding(end = 4.dp)) { Text("Notice") }
                    OutlinedButton({ dialog = "visitor" }, Modifier.padding(end = 4.dp)) { Text("Visitor") }
                }
                if (myUnits.isNotEmpty() || committee) OutlinedButton({ dialog = "complaint" }) { Text("Complaint") }
            }
        }
        if (visitors.isNotEmpty()) { item { SectionHeader("At the gate") }
            items(visitors, key = { it.id }) { v -> ListItem(headlineContent = { Text("${v.d.optString("purpose")}: ${v.d.optString("name")}") }, supportingContent = { Text("Flat ${flat(v.s("unitID"))} ${v.d.optString("vehicle")}") },
                trailingContent = { Row { TextButton({ app.run(scope) { app.sync.socAnswerVisitor(v, "approved") } }) { Text("Allow") }; TextButton({ app.run(scope) { app.sync.socAnswerVisitor(v, "denied") } }) { Text("Deny") } } }) } }
        item { SectionHeader("Bills") }
        items(bills.sortedByDescending { it.updated }.take(60), key = { it.id }) { b ->
            ListItem(headlineContent = { Text("${b.d.optString("title")} · flat ${flat(b.s("unitID"))}") }, supportingContent = { Text("${money(b.d.optDouble("amount"))} · ${b.status}") },
                trailingContent = { when {
                    b.status == "due" -> TextButton({ app.run(scope) { app.sync.socPayBill(b, "UPI", "") } }) { Text(if (committee) "Mark paid" else "I paid") }
                    b.status == "verifying" && committee -> Row { TextButton({ app.run(scope) { app.sync.socVerifyBill(b, true) } }) { Text("Verify") }; TextButton({ app.run(scope) { app.sync.socVerifyBill(b, false) } }) { Text("No") } }
                    else -> {}
                } })
        }
        item { SectionHeader("Complaints") }
        items(complaints.sortedByDescending { it.updated }, key = { it.id }) { c ->
            ListItem(headlineContent = { Text(c.d.optString("title")) }, supportingContent = { Text("Flat ${flat(c.s("unitID"))} · ${c.d.optString("category")} · ${c.status}${if (c.d.optString("reply").isEmpty()) "" else " — " + c.d.optString("reply")}") },
                trailingContent = { if (committee && c.status != "resolved") TextButton({ app.run(scope) { app.sync.socUpdateComplaint(c, if (c.status == "open") "in progress" else "resolved", "") } }) { Text(if (c.status == "open") "Start" else "Resolve") } })
        }
        if (notices.isNotEmpty()) { item { SectionHeader("Notices") }; items(notices, key = { it.id }) { n -> ListItem(headlineContent = { Text("📢 " + n.d.optString("title")) }, supportingContent = { Text(n.d.optString("body")) }) } }
        if (committee) { item { SectionHeader("Flats (${units.size})") }
            items(units, key = { it.id }) { u -> ListItem(headlineContent = { Text("Flat ${u.unitLabel}") }, supportingContent = { Text(listOf(u.d.optString("ownerName"), u.d.optString("phone")).filter { it.isNotEmpty() }.joinToString(" · ")) },
                trailingContent = { if (u.d.optString("ownerUserID").isNotEmpty()) Icon(Icons.Default.Link, "On iTeam") }) } }
        item { Spacer(Modifier.height(60.dp)) }
    }
    when (dialog) {
        "unit" -> { var wing by remember { mutableStateOf("") }; var flatNo by remember { mutableStateOf("") }; var owner by remember { mutableStateOf("") }; var ownerName by remember { mutableStateOf("") }; var phone by remember { mutableStateOf("") }; var maint by remember { mutableStateOf("") }; var pick by remember { mutableStateOf(false) }
            Form("Add flat", enabled = flatNo.isNotBlank(), onDone = { dialog = "" }, onOk = { app.run(scope) { app.sync.socSaveUnit(soc, null, unitData(wing.trim(), flatNo.trim(), owner, ownerName.trim().ifEmpty { app.store.name(owner) }, phone.trim(), num(maint))) } }) {
                Field(wing, "Wing") { wing = it }; Field(flatNo, "Flat no.") { flatNo = it }; Field(ownerName, "Owner name") { ownerName = it }; Field(phone, "Phone") { phone = it }; Field(maint, "Maintenance (blank = society default)", true) { maint = it }
                TextButton({ pick = true }) { Text(if (owner.isEmpty()) "Link owner on iTeam (they see their bills)" else "Owner on iTeam: ${app.store.name(owner)}") }
            }
            if (pick) PersonPicker(app) { owner = it ?: ""; pick = false } }
        "notice" -> { var t by remember { mutableStateOf("") }; var b by remember { mutableStateOf("") }
            Form("Notice", "Post", t.isNotBlank(), { dialog = "" }, { app.run(scope) { app.sync.socNotice(soc, t.trim(), b.trim()) } }) { Field(t, "Title") { t = it }; Field(b, "Message") { b = it } } }
        "visitor", "complaint" -> { var unit by remember { mutableStateOf((if (committee) units.firstOrNull()?.id else myUnits.firstOrNull()) ?: "") }; var a by remember { mutableStateOf("") }; var b by remember { mutableStateOf("") }; var cat by remember { mutableStateOf(if (dialog == "visitor") "Guest" else "Maintenance") }
            val isV = dialog == "visitor"
            Form(if (isV) "Visitor at the gate" else "Raise a complaint", "Send", a.isNotBlank() && unit.isNotEmpty(), { dialog = "" }, { app.run(scope) { if (isV) app.sync.socVisitor(soc, unit, a.trim(), cat, b.trim()) else app.sync.socComplaint(soc, unit, a.trim(), cat, b.trim()) } }) {
                Chips(if (committee) units.map { it.id } else myUnits, unit, { flat(it) }) { unit = it }
                Field(a, if (isV) "Visitor name" else "Title") { a = it }; Field(b, if (isV) "Vehicle no." else "Details") { b = it }
                Chips(if (isV) listOf("Guest", "Delivery", "Cab", "Service", "Other") else listOf("Maintenance", "Plumbing", "Electrical", "Lift", "Security", "Cleaning", "Parking", "Other"), cat) { cat = it }
            } }
    }
}

// MARK: - Gym & Training

@Composable
fun GymHome(app: AppState, onBack: (() -> Unit)?, open: (Page) -> Unit) {
    val me = app.store.me
    val members = remember(app.tick) { miscList(app, "gymm").filter { !it.deleted } }
    val waiting = members.filter { it.s("trainerID") == me && it.s("trainerStatus") == "waiting" }
    var adding by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Screen("Gym & Training", onBack, { Fab("Add person") { adding = true } }, pdf = { GymReport.all(app) }, charts = { ModuleCharts.gymAll(app) }) {
        item {
            val sessions = miscList(app, "gymsess").filter { !it.deleted }
            val month = java.util.Calendar.getInstance().apply { set(java.util.Calendar.DAY_OF_MONTH, 1) }.timeInMillis
            StatTiles("${members.size}" to "People", "${sessions.count { SwiftDate.toMillis(it.p.optDouble("date")) >= month }}" to "Sessions this month",
                money(miscList(app, "gympay").filter { !it.deleted && SwiftDate.toMillis(it.p.optDouble("date")) >= month }.sumOf { it.amount }) to "Paid this month")
        }
        items(ModuleCharts.gymAll(app), key = { "ch" + it.title }) { ChartCard(it) }
        if (waiting.isNotEmpty()) { item { SectionHeader("Asked to be trainer") }
            items(waiting, key = { "w" + it.id }) { m -> ListItem(headlineContent = { Text(m.s("name")) }, supportingContent = { Text("from ${app.store.name(m.owner)}") },
                trailingContent = { Row { TextButton({ app.run(scope) { app.sync.gymAnswerTrainer(m, true, "") } }) { Text("Accept") }; TextButton({ app.run(scope) { app.sync.gymAnswerTrainer(m, false, "") } }) { Text("Decline") } } }) } }
        item { SectionHeader("People") }
        if (members.isEmpty()) item { Empty("Track your own training, a family member's, or your clients' — sessions, plans and payments, shared in your chat with them.") }
        items(members, key = { it.id }) { m -> ListItem(modifier = Modifier.clickable { open(Page.GymMember(m.id)) }, leadingContent = { Avatar(m.s("name").ifEmpty { "?" }, 40) },
            headlineContent = { Text(m.s("name")) }, supportingContent = { Text(listOf(m.s("relation"), m.s("goal"), m.s("trainer").let { if (it.isEmpty()) "" else "Trainer $it" }).filter { it.isNotEmpty() }.joinToString(" · ")) }) }
        item { Spacer(Modifier.height(90.dp)) }
    }
    if (adding) {
        var name by remember { mutableStateOf("") }; var relation by remember { mutableStateOf("Self") }; var goal by remember { mutableStateOf("") }; var fee by remember { mutableStateOf("") }
        var chat by remember { mutableStateOf("") }; var trainer by remember { mutableStateOf("") }; var pickChat by remember { mutableStateOf(false) }; var pickTrainer by remember { mutableStateOf(false) }
        Form("Add person", "Add", name.isNotBlank() && chat.isNotEmpty(), { adding = false }, { app.run(scope) { app.sync.gymSaveMember(chat, null, name.trim(), relation, "", goal.trim(), if (trainer.isEmpty()) "" else app.store.name(trainer), num(fee), trainer.ifEmpty { null }) } }) {
            Field(name, "Name") { name = it }
            Chips(listOf("Self", "Client", "Family", "Friend"), relation) { relation = it }
            Field(goal, "Goal (e.g. lose 5 kg)") { goal = it }; Field(fee, "Fee per session (₹)", true) { fee = it }
            TextButton({ pickChat = true }) { Text(if (chat.isEmpty()) "Share in chat with… (required)" else "Shared with ${app.store.name(app.sync.peerOf(chat) ?: "")}") }
            TextButton({ pickTrainer = true }) { Text(if (trainer.isEmpty()) "Ask a trainer (optional)" else "Trainer: ${app.store.name(trainer)}") }
        }
        if (pickChat) PersonPicker(app) { u -> if (u != null) chat = app.sync.directID(me, u); pickChat = false }
        if (pickTrainer) PersonPicker(app) { trainer = it ?: ""; pickTrainer = false }
    }
}

@Composable
fun GymMemberScreen(app: AppState, id: String, onBack: () -> Unit) {
    val m = remember(app.tick) { app.sync.misc("gymm", id) } ?: run { Centered("Not found"); return }
    val sessions = remember(app.tick) { miscList(app, "gymsess").filter { it.s("memberID") == id && !it.deleted }.sortedByDescending { it.p.optDouble("date") } }
    val pays = remember(app.tick) { miscList(app, "gympay").filter { it.s("memberID") == id && !it.deleted }.sortedByDescending { it.p.optDouble("date") } }
    val plans = remember(app.tick) { miscList(app, "gymplan").filter { it.s("memberID") == id && !it.deleted } }
    var dialog by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val charts = remember(app.tick) { ModuleCharts.gymMember(app, id) }
    Screen(m.s("name"), onBack, module = "Gym & Training", pdf = { GymReport.lines(app, id) }, charts = { charts }) {
        item {
            StatTiles("${sessions.size}" to "Sessions", money(pays.sumOf { it.amount }) to "Paid", money(sessions.size * m.p.optDouble("fee", 0.0) - pays.filter { it.s("kind") == "training" }.sumOf { it.amount }).let { it to "Training balance" })
            Text(listOf(m.s("goal"), m.s("trainer").let { if (it.isEmpty()) "" else "Trainer $it${if (m.s("trainerStatus") == "waiting") " (waiting)" else ""}" }, "Managed by ${app.store.name(m.owner)}").filter { it.isNotEmpty() }.joinToString(" · "),
                Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall)
            Row(Modifier.padding(horizontal = 12.dp)) {
                OutlinedButton({ dialog = "session" }, Modifier.padding(end = 4.dp)) { Text("Session") }
                OutlinedButton({ dialog = "pay" }, Modifier.padding(end = 4.dp)) { Text("Payment") }
                OutlinedButton({ dialog = "plan" }) { Text("Membership") }
            }
            Button({ scope.launch { runCatching { Reports.share(ctx, "Gym & Training", "${m.s("name")} — training report", GymReport.lines(app, id), charts = charts) } } },
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {
                Icon(Icons.Default.PictureAsPdf, null); Spacer(Modifier.width(8.dp)); Text("Share my training report (PDF)")
            }
            charts.forEach { ChartCard(it) }
        }
        if (plans.isNotEmpty()) { item { SectionHeader("Memberships") }; items(plans, key = { it.id }) { p -> ListItem(headlineContent = { Text("${p.s("gymName")} · ${p.s("planName")}") }, supportingContent = { Text("${dateText(SwiftDate.toMillis(p.p.optDouble("start")))} – ${dateText(SwiftDate.toMillis(p.p.optDouble("end")))} · ${money(p.p.optDouble("fee"))}") }) } }
        item { SectionHeader("Sessions") }
        items(sessions.take(60), key = { it.id }) { s -> ListItem(headlineContent = { Text(s.s("workout").ifEmpty { "Training session" }) }, supportingContent = { Text("${dateText(SwiftDate.toMillis(s.p.optDouble("date")))} ${s.s("notes")}") }) }
        item { SectionHeader("Payments") }
        items(pays.take(60), key = { it.id }) { p -> ListItem(headlineContent = { Text(gymPayKinds.firstOrNull { it.first == p.s("kind") }?.second ?: p.s("kind")) }, supportingContent = { Text("${dateText(SwiftDate.toMillis(p.p.optDouble("date")))} · ${p.s("method")}") }, trailingContent = { Text(money(p.amount)) }) }
    }
    when (dialog) {
        "session" -> { var w by remember { mutableStateOf("") }; var n by remember { mutableStateOf("") }
            Form("Training session (today)", onDone = { dialog = "" }, onOk = { app.run(scope) { app.sync.gymSession(m, System.currentTimeMillis(), w.trim(), n.trim()) } }) { Field(w, "Workout (e.g. Legs, cardio)") { w = it }; Field(n, "Notes") { n = it } } }
        "pay" -> { var kind by remember { mutableStateOf("training") }; var amt by remember { mutableStateOf("") }; var method by remember { mutableStateOf("UPI") }
            Form("Payment", enabled = num(amt) > 0, onDone = { dialog = "" }, onOk = { app.run(scope) { app.sync.gymPayment(m, kind, num(amt), method, 0, "") } }) {
                Chips(gymPayKinds.map { it.first }, kind, { k -> gymPayKinds.first { it.first == k }.second }) { kind = it }; Field(amt, "Amount (₹)", true) { amt = it }; Chips(Fin.modes, method) { method = it } } }
        "plan" -> { var gym by remember { mutableStateOf("") }; var plan by remember { mutableStateOf("Monthly") }; var fee by remember { mutableStateOf("") }
            val months = mapOf("Monthly" to 1, "Quarterly" to 3, "Half-yearly" to 6, "Yearly" to 12)
            Form("Gym membership", enabled = gym.isNotBlank(), onDone = { dialog = "" }, onOk = {
                val end = java.util.Calendar.getInstance().apply { add(java.util.Calendar.MONTH, months[plan] ?: 1) }.timeInMillis
                app.run(scope) { app.sync.gymPlan(m, gym.trim(), plan, System.currentTimeMillis(), end, num(fee)) } }) {
                Field(gym, "Gym name") { gym = it }; Chips(months.keys.toList(), plan) { plan = it }; Field(fee, "Fee (₹)", true) { fee = it } } }
    }
}

@Suppress("unused") private fun unusedJson() = JSONArray()
