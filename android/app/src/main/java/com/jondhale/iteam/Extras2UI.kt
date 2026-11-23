package com.jondhale.iteam

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

// Screens for task extras, polls, approvals, Meetings, Doctor & Patient, Care vault & health, Survey, Album,
// Wallet, Mindfulness, My Day, and the chat extras (view-once, Magic moment, disappearing timer).

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Scr(title: String, onBack: (() -> Unit)?, fab: (@Composable () -> Unit)? = null, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) =
    Scaffold(topBar = { TopAppBar(title = { Text(title) }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } }) },
        floatingActionButton = { fab?.invoke() }) { pad -> LazyColumn(Modifier.padding(pad), content = content) }

@Composable
private fun AddFab(text: String, onClick: () -> Unit) = ExtendedFloatingActionButton(onClick = onClick, icon = { Icon(Icons.Default.Add, null) }, text = { Text(text) })

@Composable
private fun Dlg(title: String, ok: String = "Save", enabled: Boolean = true, onDone: () -> Unit, onOk: () -> Unit, content: @Composable ColumnScope.() -> Unit) =
    AlertDialog(onDismissRequest = onDone, title = { Text(title) }, text = { Column(Modifier.verticalScroll(rememberScrollState()), content = content) },
        confirmButton = { TextButton({ onOk(); onDone() }, enabled = enabled) { Text(ok) } }, dismissButton = { TextButton(onDone) { Text("Cancel") } })

@Composable
private fun Fld(v: String, label: String, number: Boolean = false, lines: Int = 1, onChange: (String) -> Unit) =
    OutlinedTextField(v, onChange, label = { Text(label) }, singleLine = lines == 1, minLines = lines, modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        keyboardOptions = if (number) KeyboardOptions(keyboardType = KeyboardType.Decimal) else KeyboardOptions.Default)

// MARK: - Task extras (inside a task)

@Composable
fun TaskExtras(app: AppState, t: TaskRec) {
    val conv = t.conv ?: "s_${app.store.me}"
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val items = remember(app.tick) { app.sync.xs("chk").filter { it.s("taskID") == t.id && !it.deleted }.sortedBy { it.p.optDouble("position") } }
    val exps = remember(app.tick) { app.sync.xs("exp").filter { it.s("taskID") == t.id && !it.deleted } }
    val files = remember(app.tick) { app.sync.xs("tfile").filter { it.s("taskID") == t.id && !it.deleted } }
    val meetings = remember(app.tick) { app.sync.xs("meet").filter { it.s("taskID") == t.id && !it.deleted } }
    var step by remember { mutableStateOf("") }
    var dialog by remember { mutableStateOf("") }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) app.run(scope) { val f = Media.file(ctx, uri); app.sync.taskFileAdd(t.id, conv, f.att, mapOf(f.blob)) }
    }
    Text("Checklist (${items.count { it.p.optBoolean("done") }}/${items.size})", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
    items.forEach { c -> Row(verticalAlignment = Alignment.CenterVertically) {
        Checkbox(c.p.optBoolean("done"), { d -> app.run(scope) { app.sync.checklistSave(t.id, conv, c.id, c.s("title"), d, c.p.optDouble("position")) } })
        Text(c.s("title"), Modifier.weight(1f))
        IconButton({ app.run(scope) { app.sync.checklistSave(t.id, conv, c.id, c.s("title"), c.p.optBoolean("done"), c.p.optDouble("position"), true) } }) { Icon(Icons.Default.Close, "Remove", Modifier.size(16.dp)) }
    } }
    Row(verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(step, { step = it }, placeholder = { Text("Add a step") }, singleLine = true, modifier = Modifier.weight(1f))
        IconButton({ val s = step.trim(); step = ""; if (s.isNotEmpty()) app.run(scope) { app.sync.checklistSave(t.id, conv, null, s, false, (items.size + 1).toDouble()) } }) { Icon(Icons.Default.Add, "Add") }
    }
    Text("Expenses · ${money(exps.sumOf { it.amount })}", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
    exps.forEach { e -> Text("• ${e.s("title")} — ${money(e.amount)} · paid by ${app.store.name(e.s("paidBy"))}") }
    Text("Files & links", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
    files.forEach { f -> Text("📎 ${f.s("title")}${if (f.s("url").isNotEmpty()) " — " + f.s("url") else ""}") }
    if (meetings.isNotEmpty()) { Text("Meetings", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
        meetings.forEach { m -> Text("📅 ${m.s("title")} · ${dateText(SwiftDate.toMillis(m.p.optDouble("start")))} ${m.s("status")}") } }
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp)) {
        OutlinedButton({ dialog = "exp" }, Modifier.padding(end = 4.dp)) { Text("Expense") }
        OutlinedButton({ pick.launch(arrayOf("*/*")) }, Modifier.padding(end = 4.dp)) { Text("File") }
        OutlinedButton({ dialog = "link" }, Modifier.padding(end = 4.dp)) { Text("Link") }
        OutlinedButton({ dialog = "appr" }, Modifier.padding(end = 4.dp)) { Text("Approval") }
        OutlinedButton({ dialog = "meet" }) { Text("Meeting") }
    }
    when (dialog) {
        "exp" -> { var title by remember { mutableStateOf("") }; var amt by remember { mutableStateOf("") }; var cat by remember { mutableStateOf("Travel") }
            Dlg("Expense", enabled = num(amt) > 0 && title.isNotBlank(), onDone = { dialog = "" }, onOk = { app.run(scope) { app.sync.expenseSave(t.id, conv, title.trim(), num(amt), cat) } }) {
                Fld(title, "What for") { title = it }; Fld(amt, "Amount (₹)", true) { amt = it }
                Row(Modifier.horizontalScroll(rememberScrollState())) { listOf("Travel", "Food", "Materials", "Fuel", "Printing", "Other").forEach { c -> FilterChip(cat == c, { cat = c }, { Text(c) }, Modifier.padding(end = 4.dp)) } }
            } }
        "link" -> { var url by remember { mutableStateOf("") }; var title by remember { mutableStateOf("") }
            Dlg("Link", enabled = url.isNotBlank(), onDone = { dialog = "" }, onOk = { app.run(scope) { app.sync.taskLinkAdd(t.id, conv, url.trim(), title.trim().ifEmpty { url.trim() }) } }) { Fld(url, "URL") { url = it }; Fld(title, "Title") { title = it } } }
        "appr" -> ApprovalDialog(app, conv, t.id) { dialog = "" }
        "meet" -> MeetingDialog(app, conv, t.id) { dialog = "" }
    }
}

// MARK: - Chat cards

@Composable
fun ChatCard(app: AppState, m: Msg, open: (Page) -> Unit) {
    val card = m.card ?: return
    val kind = card.substringBefore(":"); val id = card.substringAfter(":")
    val scope = rememberCoroutineScope()
    val me = app.store.me
    Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) { Column(Modifier.padding(12.dp)) {
        when (kind) {
            "poll" -> { val p = remember(app.tick) { app.sync.x("poll", id) } ?: return@Column
                val opts = p.p.optJSONArray("options")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList()
                val votes = p.p.optJSONObject("votes") ?: JSONObject()
                val mine = votes.optJSONObject(me)?.optJSONArray("options")?.strings() ?: emptyList()
                val total = votes.keys().asSequence().count()
                Text("📊 ${p.s("question")}", fontWeight = FontWeight.Bold)
                Text("${app.store.name(p.owner)} · ${if (p.p.optBoolean("multiple")) "choose any" else "choose one"} · $total voted", style = MaterialTheme.typography.labelSmall)
                opts.forEach { o -> val oid = o.optString("id")
                    val n = votes.keys().asSequence().count { votes.optJSONObject(it)?.optJSONArray("options")?.strings()?.contains(oid) == true }
                    Row(Modifier.fillMaxWidth().clickable {
                        val next = if (p.p.optBoolean("multiple")) (if (oid in mine) mine - oid else mine + oid) else listOf(oid)
                        app.run(scope) { app.sync.vote(p, next) } }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (p.p.optBoolean("multiple")) Checkbox(oid in mine, null) else RadioButton(oid in mine, null)
                        Column(Modifier.weight(1f)) { Text(o.optString("text")); LinearProgressIndicator(progress = { if (total == 0) 0f else n / total.toFloat() }, Modifier.fillMaxWidth()) }
                        Text(" $n")
                    } }
            }
            "approval" -> { val a = remember(app.tick) { app.sync.x("appr", id) } ?: return@Column
                val d = a.p.optJSONObject("decisions") ?: JSONObject()
                val approvers = a.p.optJSONArray("approvers")?.strings() ?: emptyList()
                Text("🙋 ${a.s("title")}", fontWeight = FontWeight.Bold)
                a.p.optDoubleOrNull("amount")?.let { Text(money(it), fontWeight = FontWeight.SemiBold) }
                if (a.s("details").isNotEmpty()) Text(a.s("details"), style = MaterialTheme.typography.bodySmall)
                Text("Asked by ${app.store.name(a.owner)}", style = MaterialTheme.typography.labelSmall)
                approvers.forEach { u -> val x = d.optJSONObject(u)
                    Text("${app.store.name(u)}: ${when { x == null -> "⏳ waiting"; x.optBoolean("approved") -> "✅ approved"; else -> "❌ rejected" }}${x?.optString("note")?.takeIf { it.isNotEmpty() }?.let { " — $it" } ?: ""}", style = MaterialTheme.typography.bodySmall) }
                if (me in approvers && d.optJSONObject(me) == null) { var note by remember { mutableStateOf("") }
                    OutlinedTextField(note, { note = it }, placeholder = { Text("Note (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    Row { Button({ app.run(scope) { app.sync.decide(a, true, note, null) } }) { Text("Approve") }; Spacer(Modifier.width(8.dp)); OutlinedButton({ app.run(scope) { app.sync.decide(a, false, note, null) } }) { Text("Reject") } } }
            }
            "meeting" -> { val mt = remember(app.tick) { app.sync.x("meet", id) } ?: return@Column
                val start = SwiftDate.toMillis(mt.p.optDouble("start"))
                Text("📅 ${mt.s("title")}", fontWeight = FontWeight.Bold)
                Text("${dateText(start)} ${time(start)} · ${if (mt.p.optBoolean("online")) "Online" else mt.s("place").ifEmpty { "In person" }} · ${mt.s("status")}", style = MaterialTheme.typography.bodySmall)
                TextButton({ open(Page.MeetingPage(id)) }) { Text("Open meeting") }
            }
            "rx" -> { val rx = remember(app.tick) { app.sync.x("rx", id) } ?: return@Column
                Text("🩺 Prescription — Dr. ${app.store.name(rx.owner)}", fontWeight = FontWeight.Bold)
                if (rx.s("diagnosis").isNotEmpty()) Text("Diagnosis: ${rx.s("diagnosis")}")
                rx.p.optJSONArray("items")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } }?.forEach { i ->
                    Text("💊 ${i.optString("name")} ${i.optString("dose")} · ${(i.optJSONArray("times")?.let { t -> (0 until t.length()).map { AttData.clock(t.optInt(it)) } } ?: emptyList()).joinToString()} · ${i.optInt("days")} days", style = MaterialTheme.typography.bodySmall) }
                if (rx.s("advice").isNotEmpty()) Text("Advice: ${rx.s("advice")}", style = MaterialTheme.typography.bodySmall)
                Text("Not a substitute for your doctor's instructions.", style = MaterialTheme.typography.labelSmall)
                when {
                    rx.s("status").isNotEmpty() -> Text(if (rx.s("status") == "accepted") "✅ Accepted" else "✋ Declined", fontWeight = FontWeight.SemiBold)
                    rx.s("patientID") == me -> Row { Button({ app.run(scope) { app.sync.answerRx(rx, true, "") } }) { Text("Accept → Care") }; Spacer(Modifier.width(8.dp)); OutlinedButton({ app.run(scope) { app.sync.answerRx(rx, false, "") } }) { Text("Decline") } }
                    else -> Text("Waiting for the patient", style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    } }
}

@Composable
fun ApprovalDialog(app: AppState, conv: String, taskID: String? = null, onDone: () -> Unit) {
    var title by remember { mutableStateOf("") }; var details by remember { mutableStateOf("") }; var amt by remember { mutableStateOf("") }
    val c = app.store.conv(conv)
    val people = c?.members?.filter { it != app.store.me } ?: emptyList()
    val picked = remember { mutableStateListOf<String>().apply { if (people.size == 1) addAll(people) } }
    val scope = rememberCoroutineScope()
    Dlg("Ask for approval", "Send", title.isNotBlank() && picked.isNotEmpty(), onDone, { app.run(scope) { app.sync.askApproval(conv, title.trim(), details.trim(), num(amt).takeIf { it > 0 }, picked.toList(), taskID) } }) {
        Fld(title, "What needs approval") { title = it }; Fld(details, "Details", lines = 2) { details = it }; Fld(amt, "Amount (optional)", true) { amt = it }
        Text("Approvers", style = MaterialTheme.typography.labelMedium)
        people.forEach { u -> Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(u in picked, { if (it) picked.add(u) else picked.remove(u) }); Text(app.store.name(u)) } }
    }
}

@Composable
fun PollDialog(app: AppState, conv: String, onDone: () -> Unit) {
    var q by remember { mutableStateOf("") }; val opts = remember { mutableStateListOf("", "") }; var multi by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Dlg("New poll", "Send", q.isNotBlank() && opts.count { it.isNotBlank() } >= 2, onDone, { app.run(scope) { app.sync.createPoll(conv, q.trim(), opts.filter { it.isNotBlank() }.map { it.trim() }, multi) } }) {
        Fld(q, "Question") { q = it }
        opts.forEachIndexed { i, o -> Fld(o, "Option ${i + 1}") { opts[i] = it } }
        if (opts.size < 10) TextButton({ opts.add("") }) { Text("Add option") }
        Row(verticalAlignment = Alignment.CenterVertically) { Switch(multi, { multi = it }); Spacer(Modifier.width(8.dp)); Text("Allow several answers") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MeetingDialog(app: AppState, conv: String, taskID: String = "", onDone: () -> Unit) {
    var title by remember { mutableStateOf("") }; var online by remember { mutableStateOf(false) }; var link by remember { mutableStateOf("") }; var place by remember { mutableStateOf("") }
    var agenda by remember { mutableStateOf("") }; var day by remember { mutableLongStateOf(System.currentTimeMillis() + 86_400_000L) }; var hour by remember { mutableIntStateOf(11) }; var mins by remember { mutableIntStateOf(60) }
    var pick by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Dlg("Schedule a meeting", "Schedule", title.isNotBlank(), onDone, {
        val s = java.util.Calendar.getInstance().apply { timeInMillis = day; set(java.util.Calendar.HOUR_OF_DAY, hour); set(java.util.Calendar.MINUTE, 0) }.timeInMillis
        val expected = app.store.conv(conv)?.members ?: emptyList()
        app.run(scope) { app.sync.saveMeeting(conv, newMeeting(title.trim(), s, s + mins * 60_000L, online, link.trim(), place.trim(), agenda.lines().map { it.trim() }.filter { it.isNotEmpty() }, expected, taskID)) }
    }) {
        Fld(title, "Title") { title = it }
        TextButton({ pick = true }) { Text("Date: ${dateText(day)}") }
        Text("Time ${AttData.clock(hour * 60)} · $mins min"); Slider(hour.toFloat(), { hour = it.toInt() }, valueRange = 6f..22f)
        Row { listOf(30, 60, 90, 120).forEach { m -> FilterChip(mins == m, { mins = m }, { Text("$m") }, Modifier.padding(end = 4.dp)) } }
        Row(verticalAlignment = Alignment.CenterVertically) { Switch(online, { online = it }); Spacer(Modifier.width(8.dp)); Text("Online") }
        if (online) Fld(link, "Meeting link (Meet, Zoom, FaceTime)") { link = it } else Fld(place, "Place") { place = it }
        Fld(agenda, "Agenda (one item per line)", lines = 3) { agenda = it }
    }
    if (pick) { val st = rememberDatePickerState(initialSelectedDateMillis = day)
        DatePickerDialog(onDismissRequest = { pick = false }, confirmButton = { TextButton({ st.selectedDateMillis?.let { day = it }; pick = false }) { Text("OK") } }) { DatePicker(st) } }
}

@Composable
fun MeetingScreen(app: AppState, id: String, onBack: () -> Unit) {
    val m = remember(app.tick) { app.sync.x("meet", id) } ?: run { Centered("Not found"); return }
    val me = app.store.me
    val admin = m.owner == me || (m.p.optJSONArray("admins")?.strings()?.contains(me) ?: false)
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var minutes by remember { mutableStateOf(m.s("minutes")) }
    var poll by remember { mutableStateOf(false) }
    val start = SwiftDate.toMillis(m.p.optDouble("start"))
    Scr(m.s("title"), onBack) {
        item { Column(Modifier.padding(16.dp)) {
            Text("${dateText(start)} · ${time(start)}–${time(SwiftDate.toMillis(m.p.optDouble("end")))}", fontWeight = FontWeight.SemiBold)
            Text(if (m.p.optBoolean("online")) "Online" else m.s("place").ifEmpty { "In person" })
            if (m.s("link").isNotEmpty()) TextButton({ runCatching { ctx.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(m.s("link")))) } }) { Text("Join: ${m.s("link")}") }
            Text("Status: ${m.s("status")}")
            val attended = m.p.optJSONArray("attended")?.strings() ?: emptyList()
            if (me !in attended && m.s("status") == "scheduled") Button({ app.run(scope) { app.sync.attendMeeting(m) } }) { Text("✋ I've joined") }
            Text("Attended: ${attended.joinToString { app.store.name(it) }.ifEmpty { "—" }}", style = MaterialTheme.typography.bodySmall)
            Text("Agenda", Modifier.padding(top = 12.dp), fontWeight = FontWeight.Bold)
            (m.p.optJSONArray("agenda")?.strings() ?: emptyList()).forEachIndexed { i, a -> Text("${i + 1}. $a") }
            Text("Polls", Modifier.padding(top = 12.dp), fontWeight = FontWeight.Bold)
            val votes = m.p.optJSONObject("votes") ?: JSONObject()
            m.p.optJSONArray("polls")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } }?.forEach { p ->
                Text(p.optString("question"), fontWeight = FontWeight.SemiBold)
                val pv = votes.optJSONObject(p.optString("id")) ?: JSONObject()
                (p.optJSONArray("options")?.strings() ?: emptyList()).forEachIndexed { i, o ->
                    val n = pv.keys().asSequence().count { pv.optInt(it) == i }
                    Row(Modifier.clickable { app.run(scope) { app.sync.voteMeeting(m, p.optString("id"), i) } }, verticalAlignment = Alignment.CenterVertically) { RadioButton(pv.has(me) && pv.optInt(me) == i, null); Text("$o ($n)") }
                }
            }
            if (admin) TextButton({ poll = true }) { Text("Add a poll") }
            Text("Minutes", Modifier.padding(top = 12.dp), fontWeight = FontWeight.Bold)
            if (admin) {
                OutlinedTextField(minutes, { minutes = it }, minLines = 4, modifier = Modifier.fillMaxWidth())
                Row {
                    Button({ app.run(scope) { app.sync.saveMeeting(m.conv, JSONObject(m.p.toString()).put("minutes", minutes)) } }) { Text("Save minutes") }
                    Spacer(Modifier.width(8.dp))
                    if (m.s("status") == "scheduled") OutlinedButton({ app.run(scope) { app.sync.saveMeeting(m.conv, JSONObject(m.p.toString()).put("minutes", minutes).put("status", "done")) } }) { Text("Mark done") }
                }
                if (m.owner == me) TextButton({ app.run(scope) { app.sync.saveMeeting(m.conv, JSONObject(m.p.toString()).put("deleted", true).put("status", "cancelled")) }; onBack() }) { Text("Cancel meeting", color = MaterialTheme.colorScheme.error) }
            } else Text(m.s("minutes").ifEmpty { "Not added yet." })
        } }
    }
    if (poll) { var q by remember { mutableStateOf("") }; var o by remember { mutableStateOf("Yes, No") }
        Dlg("Meeting poll", enabled = q.isNotBlank(), onDone = { poll = false }, onOk = {
            val polls = m.p.optJSONArray("polls") ?: JSONArray()
            polls.put(JSONObject().put("id", newID()).put("question", q.trim()).put("options", JSONArray(o.split(",").map { it.trim() }.filter { it.isNotEmpty() })))
            app.run(scope) { app.sync.saveMeeting(m.conv, JSONObject(m.p.toString()).put("polls", polls)) }
        }) { Fld(q, "Question") { q = it }; Fld(o, "Options (comma separated)") { o = it } } }
}

@Composable
fun MeetingsScreen(app: AppState, onBack: (() -> Unit)?, open: (Page) -> Unit) {
    val list = remember(app.tick) { app.sync.xs("meet").filter { !it.deleted }.sortedByDescending { it.p.optDouble("start") } }
    var create by remember { mutableStateOf(false) }; var conv by remember { mutableStateOf("") }
    Scr("Meetings", onBack, { AddFab("Schedule") { create = true } }) {
        if (list.isEmpty()) item { Empty("Schedule a meeting in any chat — agenda, attendance, polls and minutes.") }
        items(list, key = { it.id }) { m -> val s = SwiftDate.toMillis(m.p.optDouble("start"))
            ListItem(modifier = Modifier.clickable { open(Page.MeetingPage(m.id)) }, headlineContent = { Text(m.s("title")) },
                supportingContent = { Text("${dateText(s)} ${time(s)} · ${app.store.conv(m.conv)?.title ?: ""} · ${m.s("status")}") }) }
    }
    if (create && conv.isEmpty()) ChatPicker(app, { conv = it ?: ""; if (it == null) create = false })
    if (create && conv.isNotEmpty()) MeetingDialog(app, conv) { create = false; conv = "" }
}

@Composable
fun ChatPicker(app: AppState, onPick: (String?) -> Unit) {
    val chats = remember { app.store.convList().filter { !it.left && !it.id.startsWith("s_") } }
    AlertDialog(onDismissRequest = { onPick(null) }, title = { Text("In which chat?") }, text = {
        LazyColumn(Modifier.heightIn(max = 420.dp)) { items(chats, key = { it.id }) { c -> ListItem(modifier = Modifier.clickable { onPick(c.id) }, headlineContent = { Text(c.title) }) } }
    }, confirmButton = { TextButton({ onPick(null) }) { Text("Cancel") } })
}

// MARK: - Doctor & Patient

@Composable
fun DoctorScreen(app: AppState, onBack: (() -> Unit)?) {
    val me = app.store.me
    val all = remember(app.tick) { app.sync.xs("rx").filter { !it.deleted }.sortedByDescending { it.created } }
    var create by remember { mutableStateOf(false) }
    Scr("Doctor & Patient", onBack, { AddFab("Prescribe") { create = true } }) {
        item { StatTiles("${all.count { it.owner == me }}" to "Prescribed", "${all.count { it.s("patientID") == me }}" to "For me", "${all.count { it.s("status").isEmpty() }}" to "Waiting") }
        if (all.isEmpty()) item { Empty("Doctors send prescriptions to patients on iTeam; the patient accepts and the medicines go into Care with reminders. Free for everyone.") }
        items(all, key = { it.id }) { r -> ChatCard(app, Msg(r.id, r.conv, r.owner, "", r.created, card = "rx:" + r.id)) {} }
        item { Spacer(Modifier.height(90.dp)) }
    }
    if (create) {
        var patient by remember { mutableStateOf("") }; var pick by remember { mutableStateOf(true) }
        var diag by remember { mutableStateOf("") }; var advice by remember { mutableStateOf("") }
        val meds = remember { mutableStateListOf(JSONObject().put("id", newID()).put("name", "").put("dose", "1 tablet").put("form", "Tablet").put("times", JSONArray(listOf(540, 1260))).put("days", 5).put("instructions", "")) }
        var tick by remember { mutableIntStateOf(0) }
        val scope = rememberCoroutineScope()
        if (pick) PersonPicker(app) { patient = it ?: ""; pick = false; if (it == null) create = false }
        else Dlg("Prescription for ${app.store.name(patient)}", "Send", meds.any { it.optString("name").isNotBlank() }, { create = false }, {
            app.run(scope) { app.sync.prescribe(patient, app.store.name(patient), diag.trim(), advice.trim(), meds.filter { it.optString("name").isNotBlank() }, null) } }) {
            Fld(diag, "Diagnosis") { diag = it }
            if (tick >= 0) meds.forEachIndexed { i, m -> Card(Modifier.padding(top = 6.dp)) { Column(Modifier.padding(8.dp)) {
                Fld(m.optString("name"), "Medicine ${i + 1}") { m.put("name", it); tick++ }
                Fld(m.optString("dose"), "Dose") { m.put("dose", it); tick++ }
                Row(Modifier.horizontalScroll(rememberScrollState())) { listOf(480, 540, 840, 1260).forEach { t -> val on = m.optJSONArray("times")!!.strings().contains("$t")
                    FilterChip(on, { val cur = m.optJSONArray("times")!!.strings().map { it.toInt() }.toMutableList(); if (on) cur.remove(t) else cur.add(t); m.put("times", JSONArray(cur.sorted())); tick++ }, { Text(AttData.clock(t)) }, Modifier.padding(end = 4.dp)) } }
                Row { listOf(3, 5, 7, 14, 30).forEach { d -> FilterChip(m.optInt("days") == d, { m.put("days", d); tick++ }, { Text("$d d") }, Modifier.padding(end = 4.dp)) } }
            } } }
            TextButton({ meds.add(JSONObject().put("id", newID()).put("name", "").put("dose", "1 tablet").put("form", "Tablet").put("times", JSONArray(listOf(540))).put("days", 5).put("instructions", "")) }) { Text("Add medicine") }
            Fld(advice, "Advice", lines = 2) { advice = it }
        }
    }
}

// MARK: - Care vault & health history (shown in Care)

@Composable
fun CareExtras(app: AppState, prof: Rec) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val docs = remember(app.tick) { app.sync.xs("vault").filter { it.s("profileID") == prof.id && !it.deleted } }
    val hist = remember(app.tick) { app.sync.xs("hev").filter { it.s("profileID") == prof.id && !it.deleted }.sortedByDescending { it.p.optDouble("date") } }
    var add by remember { mutableStateOf(false) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) app.run(scope) { val f = Media.file(ctx, uri); app.sync.vaultAdd(prof, f.att.name, "Report", f.att, mapOf(f.blob)) }
    }
    if (docs.isNotEmpty()) Text("📁 Vault: " + docs.joinToString { it.s("title") }, style = MaterialTheme.typography.bodySmall)
    hist.take(3).forEach { h -> Text("🩺 ${dateText(SwiftDate.toMillis(h.p.optDouble("date")))} ${h.s("title")} — ${h.s("details")}", style = MaterialTheme.typography.bodySmall) }
    Row { TextButton({ pick.launch(arrayOf("*/*")) }) { Text("Add report") }; TextButton({ add = true }) { Text("Health note") } }
    if (add) { var title by remember { mutableStateOf("") }; var det by remember { mutableStateOf("") }; var kind by remember { mutableStateOf("illness") }
        Dlg("Health note — ${prof.s("name")}", enabled = title.isNotBlank(), onDone = { add = false }, onOk = { app.run(scope) { app.sync.healthEvent(prof, kind, title.trim(), det.trim(), 1) } }) {
            Row(Modifier.horizontalScroll(rememberScrollState())) { listOf("illness", "injury", "checkup", "surgery", "allergy", "other").forEach { k -> FilterChip(kind == k, { kind = k }, { Text(k.replaceFirstChar { it.uppercase() }) }, Modifier.padding(end = 4.dp)) } }
            Fld(title, "Title (e.g. Fever)") { title = it }; Fld(det, "Details", lines = 2) { det = it }
        } }
}

// MARK: - Survey

private val qTypes = listOf("text" to "Text", "number" to "Number", "choice" to "One choice", "multi" to "Several choices", "yesno" to "Yes / No", "rating" to "Rating 1–5", "location" to "GPS location", "date" to "Date")
private fun template(type: String): List<JSONObject> {
    fun q(t: String, k: String, o: List<String> = emptyList(), r: Boolean = false) = JSONObject().put("id", newID()).put("type", k).put("text", t).put("options", JSONArray(o)).put("required", r)
    return when (type) {
        "land" -> listOf(q("Survey / Gat / CTS no.", "text", r = true), q("Owner name", "text"), q("Area", "number"), q("Land use", "choice", listOf("Agricultural", "Residential", "Commercial", "Open", "Other")), q("Encroachment seen?", "yesno"), q("GPS location", "location", r = true), q("Notes", "text"))
        "building" -> listOf(q("Building / flat", "text", r = true), q("Floors", "number"), q("Structure condition", "rating"), q("Cracks / leakage", "multi", listOf("None", "Cracks", "Leakage", "Seepage", "Rusted steel")), q("Occupancy", "choice", listOf("Owner", "Tenant", "Vacant")), q("GPS location", "location"), q("Remarks", "text"))
        "poll" -> listOf(q("Your choice", "choice", listOf("Option A", "Option B", "Option C"), true))
        else -> listOf(q("Your name", "text"), q("How satisfied are you?", "rating", r = true), q("Comments", "text"))
    }
}

@Composable
fun SurveyScreen(app: AppState, onBack: (() -> Unit)?) {
    val me = app.store.me
    val all = remember(app.tick) { app.sync.xs("sv").filter { !it.deleted } }
    val surveys = all.filter { it.s("kind") == "survey" }
    var create by remember { mutableStateOf(false) }
    var answer by remember { mutableStateOf<Rec?>(null) }
    var results by remember { mutableStateOf<Rec?>(null) }
    Scr("Survey", onBack, { AddFab("New survey") { create = true } }) {
        if (surveys.isEmpty()) item { Empty("Land, building, online or poll surveys — send to a chat or group, or use it just for yourself in the field.") }
        items(surveys, key = { it.id }) { s -> val n = all.count { it.s("kind") == "response" && it.s("surveyID") == s.id }
            val answered = all.any { it.s("kind") == "response" && it.s("surveyID") == s.id && it.by == me }
            ListItem(headlineContent = { Text(s.d.optString("title")) }, supportingContent = { Text("${s.d.optString("type")} · $n responses · by ${app.store.name(s.owner)}${if (!s.d.optBoolean("open", true)) " · closed" else ""}") },
                trailingContent = { Row {
                    if (s.d.optBoolean("open", true) && (!answered || s.s("ownerID") == me)) TextButton({ answer = s }) { Text(if (s.s("ownerID") == me) "Add entry" else "Answer") }
                    if (s.s("ownerID") == me) TextButton({ results = s }) { Text("Results") }
                } })
        }
        item { Spacer(Modifier.height(90.dp)) }
    }
    if (create) { var title by remember { mutableStateOf("") }; var type by remember { mutableStateOf("online") }; var conv by remember { mutableStateOf("") }
        val chats = remember { app.store.convList().filter { !it.left && !it.id.startsWith("s_") } }
        val scope = rememberCoroutineScope()
        Dlg("New survey", "Create", title.isNotBlank(), { create = false }, {
            val d = JSONObject().put("title", title.trim()).put("type", type).put("about", "").put("questions", JSONArray(template(type))).put("open", true)
            app.run(scope) { app.sync.surveySave(null, "survey", "", d, conv) } }) {
            Fld(title, "Title") { title = it }
            Row(Modifier.horizontalScroll(rememberScrollState())) { listOf("land" to "Land", "building" to "Building", "online" to "Online", "poll" to "Poll", "other" to "Other").forEach { (k, t) -> FilterChip(type == k, { type = k }, { Text(t) }, Modifier.padding(end = 4.dp)) } }
            Text("Ready-made questions are added for the type.", style = MaterialTheme.typography.labelSmall)
            Row(Modifier.clickable { conv = "" }, verticalAlignment = Alignment.CenterVertically) { RadioButton(conv == "", { conv = "" }); Text("Just me (field survey)") }
            chats.forEach { c -> Row(Modifier.clickable { conv = c.id }, verticalAlignment = Alignment.CenterVertically) { RadioButton(conv == c.id, { conv = c.id }); Text(c.title) } }
        } }
    answer?.let { s -> SurveyAnswerDialog(app, s) { answer = null } }
    results?.let { s -> val resp = all.filter { it.s("kind") == "response" && it.s("surveyID") == s.id }
        val qs = s.d.optJSONArray("questions")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList()
        AlertDialog(onDismissRequest = { results = null }, title = { Text(s.d.optString("title")) }, text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            Text("${resp.size} responses", fontWeight = FontWeight.Bold)
            qs.forEach { q -> Text(q.optString("text"), Modifier.padding(top = 8.dp), fontWeight = FontWeight.SemiBold)
                resp.forEach { r -> val a = r.d.optJSONObject("answers")?.optJSONObject(q.optString("id"))
                    val v = a?.let { listOfNotNull(it.optString("text").ifEmpty { null }, it.optDoubleOrNull("number")?.let { n -> fmtQty(n) }, it.optJSONArray("choices")?.strings()?.joinToString()?.ifEmpty { null },
                        it.optDoubleOrNull("lat")?.let { la -> "📍 %.5f, %.5f".format(la, it.optDouble("lon")) }).joinToString(" ") } ?: "—"
                    Text("• ${app.store.name(r.by)}: $v", style = MaterialTheme.typography.bodySmall) } }
        } }, confirmButton = {
            Row { PdfButton("Survey", s.d.optString("title")) { qs.flatMap { q -> listOf("## " + q.optString("text")) + resp.map { r -> "• ${app.store.name(r.by)}: ${r.d.optJSONObject("answers")?.optJSONObject(q.optString("id"))?.toString() ?: "—"}" } } }
                TextButton({ results = null }) { Text("Close") } } })
    }
}

@Composable
private fun SurveyAnswerDialog(app: AppState, s: Rec, onDone: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val qs = s.d.optJSONArray("questions")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList()
    val ans = remember { mutableStateMapOf<String, JSONObject>() }
    var tick by remember { mutableIntStateOf(0) }
    fun a(id: String) = ans.getOrPut(id) { JSONObject().put("text", "").put("choices", JSONArray()).put("files", JSONArray()) }
    val ok = qs.filter { it.optBoolean("required") }.all { q -> ans[q.optString("id")]?.let { it.optString("text").isNotEmpty() || it.has("number") || (it.optJSONArray("choices")?.length() ?: 0) > 0 || it.has("lat") || it.has("date") } == true }
    Dlg(s.d.optString("title"), "Submit", ok, onDone, {
        val d = JSONObject().put("respondent", app.store.myName).put("answers", JSONObject(ans.mapValues { it.value } as Map<*, *>))
        app.run(scope) { app.sync.surveySave(null, "response", s.id, d, s.conv) }
    }) {
        if (tick >= 0) qs.forEach { q -> val id = q.optString("id"); val opts = q.optJSONArray("options")?.strings() ?: emptyList()
            Text(q.optString("text") + if (q.optBoolean("required")) " *" else "", Modifier.padding(top = 8.dp), fontWeight = FontWeight.SemiBold)
            when (q.optString("type")) {
                "number" -> Fld(ans[id]?.optDoubleOrNull("number")?.let { fmtQty(it) } ?: "", "Number", true) { v -> num(v).let { a(id).put("number", it) }; tick++ }
                "choice", "yesno", "rating" -> { val o = when (q.optString("type")) { "yesno" -> listOf("Yes", "No"); "rating" -> listOf("1", "2", "3", "4", "5"); else -> opts }
                    Row(Modifier.horizontalScroll(rememberScrollState())) { o.forEach { c -> FilterChip(a(id).optJSONArray("choices")?.strings()?.contains(c) == true, { a(id).put("choices", JSONArray(listOf(c))); tick++ }, { Text(c) }, Modifier.padding(end = 4.dp)) } } }
                "multi" -> Row(Modifier.horizontalScroll(rememberScrollState())) { opts.forEach { c -> val cur = a(id).optJSONArray("choices")?.strings() ?: emptyList()
                    FilterChip(c in cur, { a(id).put("choices", JSONArray(if (c in cur) cur - c else cur + c)); tick++ }, { Text(c) }, Modifier.padding(end = 4.dp)) } }
                "location" -> TextButton({ scope.launch { val l = runCatching { Nearby.locate(ctx) }.getOrNull(); if (l != null) { a(id).put("lat", l.latitude).put("lon", l.longitude); tick++ } else app.toast = "Location unavailable" } }) {
                    Text(ans[id]?.optDoubleOrNull("lat")?.let { "📍 %.5f, %.5f".format(it, ans[id]!!.optDouble("lon")) } ?: "Capture my location") }
                "date" -> TextButton({ a(id).put("date", SwiftDate.now()); tick++ }) { Text(ans[id]?.optDoubleOrNull("date")?.let { dateText(SwiftDate.toMillis(it)) } ?: "Today") }
                "photo", "video" -> Text("Photos and videos: answer this one on iPhone for now.", style = MaterialTheme.typography.labelSmall)
                else -> Fld(ans[id]?.optString("text") ?: "", "Answer") { a(id).put("text", it); tick++ }
            }
        }
    }
}

// MARK: - Album (an event's shared photos)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlbumScreen(app: AppState, owner: String, conv: String, title: String, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val items = remember(app.tick) { app.sync.xs("album").filter { it.s("owner") == owner && !it.deleted }.sortedByDescending { it.created } }
    var viewer by remember { mutableIntStateOf(-1) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(20)) { uris ->
        uris.forEach { u -> app.run(scope) { val f = Media.image(ctx, u); app.sync.albumAdd(owner, conv, f.att, mapOf(f.blob)) } }
    }
    Scaffold(topBar = { TopAppBar(title = { Text("Album · $title") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }) },
        floatingActionButton = { AddFab("Add photos") { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) } }) { pad ->
        if (items.isEmpty()) Box(Modifier.padding(pad).fillMaxSize(), contentAlignment = Alignment.Center) { Text("Everyone in the chat can add photos here.") }
        LazyVerticalGrid(GridCells.Adaptive(110.dp), Modifier.padding(pad)) {
            items(items.size) { i -> val a = Att.from(items[i].p.optJSONObject("ref") ?: JSONObject())
                val thumb = remember(a.id) { a.thumb?.let { runCatching { E2E.unb64(it).let { b -> BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() } }.getOrNull() } }
                Box(Modifier.padding(2.dp).aspectRatio(1f).background(Color.LightGray).clickable { viewer = i }) { thumb?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) } }
            }
        }
    }
    if (viewer >= 0) PhotoSwiper(app, items.map { Att.from(it.p.optJSONObject("ref") ?: JSONObject()) }, viewer) { viewer = -1 }
}

// MARK: - Wallet (only on this phone, encrypted)

@Composable
fun WalletScreen(app: AppState, onBack: (() -> Unit)?) {
    val ctx = LocalContext.current
    val store = app.store
    val docs = remember(app.tick) { store.prefs.optJSONArray("wallet")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList() }
    var add by remember { mutableStateOf(false) }
    var showing by remember { mutableStateOf<JSONObject?>(null) }
    fun key(): ByteArray = store.secret("wallet.key")?.let { E2E.unb64(it) } ?: E2E.newKey().also { store.setSecret("wallet.key", E2E.b64(it)) }
    fun saveDocs(list: List<JSONObject>) { store.setPref("wallet", JSONArray(list)); app.changed() }
    Scr("Wallet", onBack, { AddFab("Add document") { add = true } }) {
        item { Text("Aadhaar, PAN, passport, licence… kept only on this phone, encrypted. Turn on Settings → Privacy & lock to protect the app with your fingerprint.", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall) }
        val soon = docs.filter { it.optLong("expires") in 1..(System.currentTimeMillis() + 60 * 86_400_000L) }
        if (soon.isNotEmpty()) item { SectionHeader("Expiring soon") }
        items(soon, key = { "s" + it.optString("id") }) { d -> ListItem(headlineContent = { Text(d.optString("title")) }, supportingContent = { Text("Expires ${dateText(d.optLong("expires"))}") }) }
        item { SectionHeader("Documents") }
        items(docs, key = { it.optString("id") }) { d -> ListItem(modifier = Modifier.clickable { showing = d }, leadingContent = { Icon(Icons.Default.Badge, null) },
            headlineContent = { Text(d.optString("title")) }, supportingContent = { Text(listOf(d.optString("kind"), d.optString("number").takeLast(4).let { if (it.isEmpty()) "" else "••$it" }).filter { it.isNotEmpty() }.joinToString(" · ")) }) }
    }
    if (add) { var title by remember { mutableStateOf("") }; var kind by remember { mutableStateOf("Aadhaar") }; var number by remember { mutableStateOf("") }; var holder by remember { mutableStateOf("") }
        var expires by remember { mutableStateOf("") }; var photo by remember { mutableStateOf<ByteArray?>(null) }
        val scope = rememberCoroutineScope()
        val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u -> if (u != null) scope.launch { photo = withContext(Dispatchers.IO) { runCatching { val f = Media.image(ctx, u); E2E.open(f.blob.second, E2E.unb64(f.att.key)) }.getOrNull() } } }
        Dlg("Add document", enabled = title.isNotBlank(), onDone = { add = false }, onOk = {
            val id = newID()
            photo?.let { p -> File(ctx.filesDir, "wallet").mkdirs(); File(File(ctx.filesDir, "wallet"), id).writeBytes(E2E.seal(p, key())) }
            val exp = expires.split("/").takeIf { it.size == 3 }?.let { (d, m, y) -> runCatching { java.util.Calendar.getInstance().apply { set(y.toInt(), m.toInt() - 1, d.toInt(), 12, 0) }.timeInMillis }.getOrNull() } ?: 0L
            saveDocs(docs + JSONObject().put("id", id).put("title", title.trim()).put("kind", kind).put("number", number.trim()).put("holder", holder.trim()).put("expires", exp).put("photo", photo != null))
        }) {
            Row(Modifier.horizontalScroll(rememberScrollState())) { listOf("Aadhaar", "PAN", "Passport", "Licence", "Voter ID", "Vehicle", "Insurance", "Health", "Bank", "Education", "Property", "Other").forEach { k -> FilterChip(kind == k, { kind = k; if (title.isEmpty()) title = k }, { Text(k) }, Modifier.padding(end = 4.dp)) } }
            Fld(title, "Title") { title = it }; Fld(number, "Number") { number = it }; Fld(holder, "Holder") { holder = it }; Fld(expires, "Expiry (dd/mm/yyyy, optional)") { expires = it }
            TextButton({ pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) { Text(if (photo == null) "Add photo of the document" else "Photo added ✓") }
        } }
    showing?.let { d ->
        val bmp = remember(d.optString("id")) { runCatching { File(File(ctx.filesDir, "wallet"), d.optString("id")).readBytes().let { E2E.open(it, key()) }.let { BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() } }.getOrNull() }
        AlertDialog(onDismissRequest = { showing = null }, title = { Text(d.optString("title")) }, text = { Column {
            Text("${d.optString("kind")} · ${d.optString("number")}"); if (d.optString("holder").isNotEmpty()) Text(d.optString("holder"))
            if (d.optLong("expires") > 0) Text("Expires ${dateText(d.optLong("expires"))}")
            bmp?.let { Image(it, null, Modifier.fillMaxWidth().padding(top = 8.dp)) }
        } }, confirmButton = { TextButton({ showing = null }) { Text("Close") } },
            dismissButton = { TextButton({ File(File(ctx.filesDir, "wallet"), d.optString("id")).delete(); saveDocs(docs.filter { it.optString("id") != d.optString("id") }); showing = null }) { Text("Delete", color = MaterialTheme.colorScheme.error) } })
    }
}

// MARK: - Mindfulness (breathing timer + log)

@Composable
fun MindScreen(app: AppState, onBack: (() -> Unit)?) {
    val log = remember(app.tick) { app.store.prefs.optJSONArray("mind")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList() }
    var running by remember { mutableStateOf(false) }
    var minutes by remember { mutableIntStateOf(5) }
    var left by remember { mutableIntStateOf(0) }
    var kind by remember { mutableStateOf("Box breathing") }
    val pulse by rememberInfiniteTransition(label = "b").animateFloat(0.7f, 1.15f, infiniteRepeatable(tween(4000, easing = LinearEasing), RepeatMode.Reverse), label = "s")
    LaunchedEffect(running) {
        if (running) { left = minutes * 60
            while (left > 0 && running) { delay(1000); left-- }
            if (running) { running = false
                app.store.setPref("mind", JSONArray(log + JSONObject().put("t", kind).put("m", minutes).put("at", System.currentTimeMillis()))); app.changed(); app.toast = "Well done — $minutes mindful minutes" } }
    }
    Scr("Mindfulness", onBack) {
        item { Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            StatTiles("${log.sumOf { it.optInt("m") }}" to "Total minutes", "${log.size}" to "Sessions", "${log.count { System.currentTimeMillis() - it.optLong("at") < 7 * 86_400_000L }}" to "This week")
            Box(Modifier.size(200.dp).scale(if (running) pulse else 1f).background(Brush.radialGradient(listOf(Color(0xFF9C7CF4), Color(0xFF4F7A68))), CircleShape), contentAlignment = Alignment.Center) {
                Text(if (running) "%d:%02d".format(left / 60, left % 60) else "$minutes min", color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Bold)
            }
            if (running) Text(if ((System.currentTimeMillis() / 4000) % 2 == 0L) "Breathe in…" else "Breathe out…", Modifier.padding(8.dp))
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 8.dp)) { listOf("Box breathing", "Calm focus", "Sleep wind-down", "Gratitude", "Body scan").forEach { k -> FilterChip(kind == k, { kind = k }, { Text(k) }, Modifier.padding(end = 4.dp)) } }
            Row { listOf(3, 5, 10, 15, 20).forEach { m -> FilterChip(minutes == m, { if (!running) minutes = m }, { Text("$m") }, Modifier.padding(end = 4.dp)) } }
            Button({ running = !running }, Modifier.padding(top = 8.dp)) { Text(if (running) "Stop" else "Start") }
            Text("Guided voice and music sessions are on iPhone. Not medical advice.", Modifier.padding(top = 8.dp), style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center)
        } }
        items(log.reversed().take(30)) { l -> ListItem(headlineContent = { Text(l.optString("t")) }, supportingContent = { Text("${dateText(l.optLong("at"))} · ${l.optInt("m")} min") }) }
    }
}

// MARK: - My Day

@Composable
fun MyDayScreen(app: AppState, onBack: (() -> Unit)?, open: (Page) -> Unit) {
    val me = app.store.me
    val now = System.currentTimeMillis()
    val dayEnd = AttData.date(AttData.key(now)) + 86_400_000L
    val rows = remember(app.tick) {
        val out = mutableListOf<Triple<Long, String, Page?>>()
        app.store.taskList().filter { it.status != "done" && (it.assignees.contains(me) || it.createdBy == me) && (it.due ?: Long.MAX_VALUE) < dayEnd }.forEach { out += Triple(it.due ?: now, "☑ ${it.title}${if ((it.due ?: now) < now) " (overdue)" else ""}", Page.Task(it.id)) }
        app.store.miscList("event").filter { !it.deleted && SwiftDate.toMillis(it.p.optDouble("start")) in now..dayEnd }.forEach { out += Triple(SwiftDate.toMillis(it.p.optDouble("start")), "🎉 ${it.s("title")}", Page.Events) }
        app.store.miscList("meet").filter { !it.deleted && SwiftDate.toMillis(it.p.optDouble("start")) in (now - 3_600_000)..dayEnd }.forEach { out += Triple(SwiftDate.toMillis(it.p.optDouble("start")), "📅 ${it.s("title")}", Page.MeetingPage(it.id)) }
        val day0 = AttData.date(AttData.key(now))
        app.store.miscList("med").filter { !it.deleted && it.p.optBoolean("active", true) }.forEach { m -> (m.p.optJSONArray("times")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: emptyList()).forEach { t -> out += Triple(day0 + t * 60_000L, "💊 ${m.s("name")} ${m.s("dose")}", Page.Care) } }
        app.store.bizList().filter { !it.deleted && it.owner == me && it.status in listOf("Due", "Upcoming", "Booked") && (it.due ?: it.date ?: Long.MAX_VALUE) < dayEnd }.forEach { out += Triple(it.due ?: it.date ?: now, "📒 ${BizSpecs.spec(it.module)?.title}: ${it.title} ${if (it.amount != 0.0) money(it.amount) else ""}", Page.BizModule(it.module)) }
        app.store.miscList("crml").filter { !it.deleted && it.s("stage") !in listOf("won", "lost") && (it.p.optDoubleOrNull("nextFollowUp")?.let { f -> SwiftDate.toMillis(f) } ?: Long.MAX_VALUE) < dayEnd }.forEach { out += Triple(now, "💼 Follow up: ${it.s("name")}", Page.Lead(it.id)) }
        app.store.finList().filter { !it.deleted && it.status == "due" && it.finDate < dayEnd }.forEach { out += Triple(it.finDate, "💸 ${if (it.isIn) "Receive" else "Pay"} ${money(it.amount)} — ${it.d.optString("title")}", Page.Finance) }
        out.sortedBy { it.first }
    }
    val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    Scr("My Day", onBack) {
        item { Text("${if (hour < 12) "Good morning" else if (hour < 17) "Good afternoon" else "Good evening"}, ${app.store.myName.substringBefore(" ")}", Modifier.padding(16.dp), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            StatTiles("${rows.count { it.second.startsWith("☑") }}" to "Tasks", "${rows.count { it.second.startsWith("📅") || it.second.startsWith("🎉") }}" to "Meetings & events", "${rows.count { it.second.startsWith("💊") }}" to "Medicines") }
        if (rows.isEmpty()) item { Empty("Nothing due today. 🎉") }
        items(rows) { (t, text, page) -> ListItem(modifier = Modifier.clickable(enabled = page != null) { page?.let(open) }, leadingContent = { Text(time(t), style = MaterialTheme.typography.labelMedium) }, headlineContent = { Text(text) }) }
    }
}

// MARK: - Chat extras: view-once bubble and the extra menu

@Composable
fun ViewOnceBubble(app: AppState, m: Msg, mine: Boolean, fg: Color) {
    var open by remember { mutableStateOf(false) }
    val a = m.atts.firstOrNull()
    if (mine || m.opened || a == null) { Text("👁 ${if (mine) "View-once photo" else "Opened"}", color = fg.copy(alpha = 0.7f)); return }
    Text("👁 Photo — tap to view once", color = fg, fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable { open = true })
    if (open) PhotoSwiper(app, listOf(a), 0) { open = false; app.sync.markOpened(m.id); app.changed() }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatExtrasMenu(app: AppState, convID: String, show: String, onDone: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    when (show) {
        "poll" -> PollDialog(app, convID, onDone)
        "approval" -> ApprovalDialog(app, convID, null, onDone)
        "meeting" -> MeetingDialog(app, convID, "", onDone)
        "timer" -> { val cur = app.store.conv(convID)?.timer ?: 0
            AlertDialog(onDismissRequest = onDone, title = { Text("Disappearing messages") }, text = { Column {
                timers.forEach { s -> Row(Modifier.fillMaxWidth().clickable { app.run(scope) { app.sync.setTimer(convID, s) }; onDone() }, verticalAlignment = Alignment.CenterVertically) { RadioButton(cur == s, null); Text(timerName(s)) } }
                Text("Applies to new messages for everyone in this chat.", style = MaterialTheme.typography.labelSmall)
            } }, confirmButton = { TextButton(onDone) { Text("Close") } }) }
        "once" -> { val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u ->
                if (u != null) app.run(scope) { val f = Media.image(ctx, u); app.sync.sendText(convID, "", atts = listOf(f.att), files = mapOf(f.blob), once = true) }; onDone() }
            LaunchedEffect(Unit) { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) } }
        "magic" -> { var text by remember { mutableStateOf("") }; var day by remember { mutableLongStateOf(System.currentTimeMillis()) }; var hour by remember { mutableIntStateOf((java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY) + 1) % 24) }
            var pick by remember { mutableStateOf(false) }
            val at = java.util.Calendar.getInstance().apply { timeInMillis = day; set(java.util.Calendar.HOUR_OF_DAY, hour); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0) }.timeInMillis
            Dlg("✨ Magic moment", "Schedule", text.isNotBlank() && at > System.currentTimeMillis(), onDone, { app.run(scope) { app.sync.sendText(convID, text.trim(), showAt = at) }; app.toast = "Arrives ${dateText(at)} ${time(at)}" }) {
                Fld(text, "Message (birthday wish, reminder…)", lines = 3) { text = it }
                TextButton({ pick = true }) { Text("Day: ${dateText(day)}") }
                Text("Time: ${AttData.clock(hour * 60)}"); Slider(hour.toFloat(), { hour = it.toInt() }, valueRange = 0f..23f)
                Text("Delivered now but stays hidden on their phone until then — works even if your phone is off.", style = MaterialTheme.typography.labelSmall)
            }
            if (pick) { val st = rememberDatePickerState(initialSelectedDateMillis = day)
                DatePickerDialog(onDismissRequest = { pick = false }, confirmButton = { TextButton({ st.selectedDateMillis?.let { day = it }; pick = false }) { Text("OK") } }) { DatePicker(st) } } }
    }
}
