package com.jondhale.iteam

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.asImageBitmap
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

// MARK: - Attendance

private fun monthDays(): List<Long> {
    val c = Calendar.getInstance().apply { set(Calendar.DAY_OF_MONTH, 1); set(Calendar.HOUR_OF_DAY, 12); set(Calendar.MINUTE, 0) }
    val n = c.getActualMaximum(Calendar.DAY_OF_MONTH)
    return (0 until n).map { c.timeInMillis + it * 86_400_000L }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AttendanceHome(app: AppState, onBack: (() -> Unit)?, open: (Page) -> Unit) {
    val me = app.store.me
    val all = remember(app.tick) { app.store.attList() }
    val companies = all.filter { it.ak == "company" && !it.deleted }
    val staffOf = companies.filter { isStaff(it.d, me) }
    val memberships = all.filter { it.ak == "member" && !it.deleted && it.d.optString("userID") == me }
        .filter { m -> companies.any { it.id == m.s("companyID") && !isStaff(it.d, me) } }
    var newCompany by remember { mutableStateOf(false) }
    var leaveFor by remember { mutableStateOf<Rec?>(null) }
    var showQR by remember { mutableStateOf<Rec?>(null) }
    val scope = rememberCoroutineScope()
    // Punch flow: scan office QR (if required) → selfie (if required) → punch.
    var pending by remember { mutableStateOf<Pair<Rec, Rec>?>(null) }
    var scanned by remember { mutableStateOf("") }
    fun finish(photo: String) {
        val (m, comp) = pending ?: return
        app.run(scope) { val w = app.sync.attPunch(m, comp, scanned, photo); app.toast = if (w == "in") "✅ Punched in" else if (w == "out") "✅ Punched out" else "Already punched out today" }
        pending = null; scanned = ""
    }
    val selfie = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.TakePicturePreview()) { bmp ->
        if (bmp == null) { app.toast = "A selfie is needed to punch"; pending = null; return@rememberLauncherForActivityResult }
        val scale = 480f / maxOf(bmp.width, bmp.height)
        val small = if (scale < 1f) android.graphics.Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt(), (bmp.height * scale).toInt(), true) else bmp
        val out = java.io.ByteArrayOutputStream(); small.compress(android.graphics.Bitmap.CompressFormat.JPEG, 60, out)
        finish(E2E.b64(out.toByteArray()))
    }
    val scanQR = androidx.activity.compose.rememberLauncherForActivityResult(com.journeyapps.barcodescanner.ScanContract()) { r ->
        val (_, comp) = pending ?: return@rememberLauncherForActivityResult
        val code = r.contents ?: run { pending = null; return@rememberLauncherForActivityResult }
        if (AttQR.company(code) != comp.id) { app.toast = "That's not this company's attendance QR"; pending = null; return@rememberLauncherForActivityResult }
        scanned = code
        if (comp.d.optBoolean("needPhoto")) selfie.launch(null) else finish("")
    }
    fun startPunch(m: Rec, comp: Rec) {
        pending = m to comp; scanned = ""
        when {
            comp.d.optBoolean("needQR") -> scanQR.launch(com.journeyapps.barcodescanner.ScanOptions().setPrompt("Scan the office attendance QR").setBeepEnabled(false).setOrientationLocked(false))
            comp.d.optBoolean("needPhoto") -> selfie.launch(null)
            else -> finish("")
        }
    }
    Scaffold(topBar = { TopAppBar(title = { Text("Attendance") }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } }) },
        floatingActionButton = { ExtendedFloatingActionButton(onClick = { newCompany = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text("New company") }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            if (memberships.isNotEmpty()) item { SectionHeader("My attendance") }
            items(memberships, key = { it.id }) { m ->
                val comp = companies.first { it.id == m.s("companyID") }
                val c = comp.d
                val today = app.sync.attTodayEntry(m)
                val st = attStatus(m, c, System.currentTimeMillis(), today, all.filter { it.ak == "leave" }, all.filter { it.ak == "holiday" })
                Card(Modifier.fillMaxWidth().padding(12.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Text(c.optString("name"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                        Text("Duty ${AttData.clock(m.dutyStart(c))}–${AttData.clock(m.dutyEnd(c))} · Today: ${AttData.label(st)}", style = MaterialTheme.typography.bodySmall)
                        if (!m.d.has("accepted")) Row(Modifier.padding(top = 8.dp)) {
                            Button({ app.run(scope) { app.sync.attAnswerInvite(m, true) } }) { Text("Accept") }; Spacer(Modifier.width(8.dp))
                            OutlinedButton({ app.run(scope) { app.sync.attAnswerInvite(m, false) } }) { Text("Decline") }
                        } else if (m.d.optBoolean("accepted")) {
                            val inAt = today?.d?.optDoubleOrNull("inAt"); val outAt = today?.d?.optDoubleOrNull("outAt")
                            if (inAt != null) Text("In ${time(SwiftDate.toMillis(inAt))}${outAt?.let { " · Out ${time(SwiftDate.toMillis(it))}" } ?: ""}")
                            val special = listOf("needPhoto", "needQR", "needGeo").filter { c.optBoolean(it) }
                            Row(Modifier.padding(top = 8.dp)) {
                                if (!c.optBoolean("selfPunch", true)) Text("Your admin marks attendance for you.", style = MaterialTheme.typography.bodySmall)
                                else if ("needGeo" in special) Text("This company needs a location punch — use the iPhone app or your office kiosk.", style = MaterialTheme.typography.bodySmall)
                                else if (outAt == null) Button({ startPunch(m, comp) }) {
                                    Icon(if (c.optBoolean("needQR")) Icons.Default.QrCodeScanner else if (c.optBoolean("needPhoto")) Icons.Default.PhotoCamera else Icons.Default.Fingerprint, null)
                                    Spacer(Modifier.width(6.dp)); Text(if (inAt == null) "Punch in" else "Punch out")
                                }
                                Spacer(Modifier.width(8.dp))
                                OutlinedButton({ leaveFor = m }) { Text("Apply leave") }
                            }
                            MonthStrip(app, m, c, all)
                        }
                    }
                }
            }
            item { SectionTitle("Companies I manage", staffOf.size.takeIf { it > 0 }) }
            if (staffOf.isEmpty()) item { Empty("Set up a company to mark attendance for your team — staff on iTeam punch in from their phones, others you mark yourself.") }
            items(staffOf, key = { it.id }) { comp ->
                // Dashboard per company: today's numbers, 7-day trend, QR for the door.
                val members = all.filter { it.ak == "member" && it.s("companyID") == comp.id && !it.deleted && it.d.optBoolean("active", true) }
                val entries = all.filter { it.ak == "entry" && it.s("companyID") == comp.id && !it.deleted }
                val leaves = all.filter { it.ak == "leave" }; val hol = all.filter { it.ak == "holiday" }
                val now = System.currentTimeMillis(); val todayKey = AttData.key(now)
                val st = members.map { m -> attStatus(m, comp.d, now, entries.firstOrNull { it.s("memberID") == m.id && it.s("day") == todayKey }, leaves, hol) }
                val present = st.count { it == "present" || it == "grace" || it == "late" || it == "open" }
                val late = st.count { it == "late" }; val onLeave = st.count { it == "leave" || it == "unpaid" }
                val days = lastDays(7)
                val trend = days.map { (_, d) -> val k = AttData.key(d); entries.count { it.s("day") == k && it.d.has("inAt") }.toFloat() }
                Column(Modifier.padding(vertical = 4.dp)) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f).clickable { open(Page.AttCompany(comp.id)) }) {
                            Text(comp.d.optString("name"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                            Text("${members.size} people · ${if (comp.d.optString("ownerID") == me) "Owner" else "Admin"} · tap to manage", style = MaterialTheme.typography.bodySmall)
                        }
                        FilledTonalButton({ showQR = comp }) { Icon(Icons.Default.QrCode, null); Spacer(Modifier.width(6.dp)); Text("QR") }
                    }
                    StatRow(Triple("Present today", "$present/${members.size}", { open(Page.AttCompany(comp.id)) }), Triple("Late", "$late", null), Triple("On leave", "$onLeave", null))
                    LineChartCard("Check-ins, last 7 days", "${trend.last().toInt()} today", days.map { it.first }, trend)
                }
            }
            item { Spacer(Modifier.height(90.dp)) }
        }
    }
    if (newCompany) NewCompanyDialog(app) { newCompany = false }
    showQR?.let { comp -> AttQRDialog(comp) { showQR = null } }
    leaveFor?.let { m -> LeaveDialog(app, m) { leaveFor = null } }
}

@Composable
private fun MonthStrip(app: AppState, m: Rec, c: JSONObject, all: List<Rec>) {
    val entries = all.filter { it.ak == "entry" && it.s("memberID") == m.id && !it.deleted }.associateBy { it.s("day") }
    val leaves = all.filter { it.ak == "leave" }; val hol = all.filter { it.ak == "holiday" }
    val today = AttData.key(System.currentTimeMillis())
    val counts = mutableMapOf<String, Int>()
    Row(Modifier.padding(top = 8.dp).horizontalScroll(rememberScrollState())) {
        monthDays().forEach { d ->
            val k = AttData.key(d)
            val st = if (k > today) "none" else attStatus(m, c, d, entries[k], leaves, hol)
            counts[st] = (counts[st] ?: 0) + 1
            Box(Modifier.padding(1.dp).size(26.dp).background(Color(AttData.color(st)).copy(alpha = if (st == "none" || st == "open") 0.2f else 0.85f), RoundedCornerShape(5.dp)),
                contentAlignment = Alignment.Center) { Text(k.takeLast(2), style = MaterialTheme.typography.labelSmall, color = Color.White) }
        }
    }
    val present = (counts["present"] ?: 0) + (counts["grace"] ?: 0) + (counts["late"] ?: 0)
    Text("This month: $present present · ${counts["halfday"] ?: 0} half · ${counts["absent"] ?: 0} absent · ${(counts["leave"] ?: 0) + (counts["unpaid"] ?: 0)} leave",
        style = MaterialTheme.typography.labelSmall)
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun NewCompanyDialog(app: AppState, onDone: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var start by remember { mutableStateOf("9:30") }
    var end by remember { mutableStateOf("18:30") }
    val off = remember { mutableStateListOf(1) }
    val scope = rememberCoroutineScope()
    fun mins(s: String) = s.split(":").let { (it.getOrNull(0)?.toIntOrNull() ?: 9) * 60 + (it.getOrNull(1)?.toIntOrNull() ?: 0) }
    AlertDialog(onDismissRequest = onDone, title = { Text("New company") }, text = {
        Column {
            OutlinedTextField(name, { name = it }, label = { Text("Company / team name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row { OutlinedTextField(start, { start = it }, label = { Text("Duty from (24h)") }, singleLine = true, modifier = Modifier.weight(1f)); Spacer(Modifier.width(6.dp))
                OutlinedTextField(end, { end = it }, label = { Text("Duty to (24h)") }, singleLine = true, modifier = Modifier.weight(1f)) }
            Text("Weekly off", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
            FlowRow { listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat").forEachIndexed { i, d ->
                FilterChip(i + 1 in off, { if (i + 1 in off) off.remove(i + 1) else off.add(i + 1) }, label = { Text(d) }, modifier = Modifier.padding(end = 4.dp)) } }
        }
    }, confirmButton = { TextButton({ app.run(scope) { app.sync.attCreateCompany(name.trim(), mins(start), mins(end), off.toList()) }; onDone() }, enabled = name.isNotBlank()) { Text("Create") } },
        dismissButton = { TextButton(onDone) { Text("Cancel") } })
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun LeaveDialog(app: AppState, m: Rec, onDone: () -> Unit) {
    val comp = app.store.attRec(m.s("companyID")) ?: return
    val types = comp.d.optJSONArray("leaveTypes")?.strings() ?: listOf("Casual", "Sick", "Earned")
    var type by remember { mutableStateOf(types.first()) }
    var from by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var to by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var half by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf("") }
    var pick by remember { mutableIntStateOf(0) }
    val staff = isStaff(comp.d, app.store.me)
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onDone, title = { Text(if (staff) "Record leave — ${m.memberName}" else "Apply for leave") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            FlowRow { types.forEach { t -> FilterChip(type == t, { type = t }, label = { Text(t) }, modifier = Modifier.padding(end = 4.dp)) } }
            TextButton({ pick = 1 }) { Text("From: ${dateText(from)}") }
            if (!half) TextButton({ pick = 2 }) { Text("To: ${dateText(to)}") }
            Row(verticalAlignment = Alignment.CenterVertically) { Switch(half, { half = it }); Spacer(Modifier.width(8.dp)); Text("Half day") }
            OutlinedTextField(reason, { reason = it }, label = { Text("Reason") }, modifier = Modifier.fillMaxWidth())
        }
    }, confirmButton = { TextButton({
        app.run(scope) { app.sync.attSaveLeave(comp, m, null, AttData.leave(from, if (half) from else maxOf(from, to), half, type, true, reason.trim()), if (staff) "approved" else "pending") }
        onDone()
    }) { Text(if (staff) "Save" else "Send request") } }, dismissButton = { TextButton(onDone) { Text("Cancel") } })
    if (pick != 0) {
        val state = rememberDatePickerState(initialSelectedDateMillis = if (pick == 1) from else to)
        DatePickerDialog(onDismissRequest = { pick = 0 }, confirmButton = { TextButton({ state.selectedDateMillis?.let { v -> if (pick == 1) from = v + 43_200_000L else to = v + 43_200_000L }; pick = 0 }) { Text("OK") } }) { DatePicker(state) }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun AttCompanyScreen(app: AppState, id: String, onBack: () -> Unit) {
    val me = app.store.me
    val all = remember(app.tick) { app.store.attList().filter { it.s("companyID") == id } }
    val comp = all.firstOrNull { it.id == id } ?: run { Centered("Not found"); return }
    val c = comp.d
    val owner = c.optString("ownerID") == me
    val members = all.filter { it.ak == "member" && !it.deleted }.sortedBy { it.memberName.lowercase() }
    val leaves = all.filter { it.ak == "leave" }; val hol = all.filter { it.ak == "holiday" }
    var day by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val dk = AttData.key(day)
    val entries = all.filter { it.ak == "entry" && it.s("day") == dk && !it.deleted }.associateBy { it.s("memberID") }
    val statusOf = members.associate { it.id to attStatus(it, c, day, entries[it.id], leaves, hol) }
    val pending = all.filter { !it.deleted && it.status == "pending" && (it.ak == "leave" || (owner && it.ak in listOf("change", "holiday"))) }
    var marking by remember { mutableStateOf<Rec?>(null) }
    var adding by remember { mutableStateOf(false) }
    var holiday by remember { mutableStateOf(false) }
    var pickDay by remember { mutableStateOf(false) }
    var leaveFor by remember { mutableStateOf<Rec?>(null) }
    val scope = rememberCoroutineScope()
    Scaffold(topBar = {
        TopAppBar(title = { Text(c.optString("name")) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = {
                var rules by remember { mutableStateOf(false) }
                if (owner) IconButton({ rules = true }) { Icon(Icons.Default.Tune, "Punch rules") }
                if (rules) {
                    var needQR by remember { mutableStateOf(c.optBoolean("needQR")) }
                    var needPhoto by remember { mutableStateOf(c.optBoolean("needPhoto")) }
                    var photoDays by remember { mutableStateOf(c.optInt("photoDays", 60).takeIf { it > 0 } ?: 60) }
                    val scope2 = rememberCoroutineScope()
                    AlertDialog({ rules = false }, title = { Text("How staff punch in") },
                        text = { Column {
                            Row(verticalAlignment = Alignment.CenterVertically) { Switch(needQR, { needQR = it }); Spacer(Modifier.width(10.dp)); Text("Scan the office QR (show it from the dashboard, or print today's QR)") }
                            Spacer(Modifier.height(10.dp))
                            Row(verticalAlignment = Alignment.CenterVertically) { Switch(needPhoto, { needPhoto = it }); Spacer(Modifier.width(10.dp)); Text("Take a selfie") }
                            if (needPhoto) {
                                Text("Keep punch photos for", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 8.dp))
                                Row(Modifier.horizontalScroll(rememberScrollState())) {
                                    listOf(15, 30, 60, 90, 180, 365).forEach { n -> FilterChip(photoDays == n, { photoDays = n }, label = { Text("$n d") }, modifier = Modifier.padding(end = 4.dp)) }
                                }
                                Text("Older photos are deleted automatically from every phone.", style = MaterialTheme.typography.bodySmall)
                            }
                            Text("\nWith neither, a tap is enough. You and admins can always mark anyone.", style = MaterialTheme.typography.bodySmall)
                        } },
                        confirmButton = { TextButton({
                            val d = org.json.JSONObject(c.toString()).put("needQR", needQR).put("needPhoto", needPhoto).put("photoDays", photoDays)
                            app.run(scope2) { app.sync.attSaveCompany(comp, d) }; rules = false
                        }) { Text("Save") } },
                        dismissButton = { TextButton({ rules = false }) { Text("Cancel") } })
                }
                PdfButton("Attendance", "${c.optString("name")} — ${java.text.SimpleDateFormat("MMMM yyyy", java.util.Locale.ENGLISH).format(java.util.Date())}") {
                    val days = (1..java.util.Calendar.getInstance().get(java.util.Calendar.DAY_OF_MONTH)).map { d -> java.util.Calendar.getInstance().apply { set(java.util.Calendar.DAY_OF_MONTH, d); set(java.util.Calendar.HOUR_OF_DAY, 12) }.timeInMillis }
                    val ents = all.filter { it.ak == "entry" && !it.deleted }
                    listOf("## Monthly register (P present · L late · H half · A absent · PL/UL leave · HO holiday · WO off)") + members.map { m ->
                        val codes = days.map { d -> AttData.code(attStatus(m, c, d, ents.firstOrNull { it.s("memberID") == m.id && it.s("day") == AttData.key(d) }, leaves, hol)) }
                        "${m.memberName}: " + codes.joinToString(" ") + "  — present ${codes.count { it in listOf("P", "G", "L") }}, absent ${codes.count { it == "A" }}"
                    }
                }
                IconButton({ holiday = true }) { Icon(Icons.Default.Celebration, "Holiday") }
            })
    }, floatingActionButton = { ExtendedFloatingActionButton(onClick = { adding = true }, icon = { Icon(Icons.Default.PersonAdd, null) }, text = { Text("Add person") }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                val v = statusOf.values
                StatTiles("${v.count { it in listOf("present", "grace", "late", "halfday") }}" to "Present", "${v.count { it == "absent" }}" to "Absent", "${v.count { it == "leave" || it == "unpaid" }}" to "On leave")
                Row(Modifier.padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton({ day -= 86_400_000L }) { Icon(Icons.Default.ChevronLeft, "Previous day") }
                    TextButton({ pickDay = true }) { Text(dateText(day), fontWeight = FontWeight.Bold) }
                    IconButton({ day += 86_400_000L }, enabled = dk < AttData.key(System.currentTimeMillis())) { Icon(Icons.Default.ChevronRight, "Next day") }
                    Text("Duty ${AttData.clock(c.optInt("dutyStart", 570))}–${AttData.clock(c.optInt("dutyEnd", 1110))}", style = MaterialTheme.typography.labelSmall)
                }
            }
            if (pending.isNotEmpty()) {
                item { SectionHeader("Needs your approval") }
                items(pending, key = { "p" + it.id }) { r ->
                    val who = members.firstOrNull { it.id == r.s("memberID") }?.memberName ?: ""
                    val text = when (r.ak) {
                        "leave" -> "🌴 $who · ${r.d.optString("type")} leave ${dateText(SwiftDate.toMillis(r.d.optDouble("from")))}${if (r.d.optBoolean("halfDay")) " (half)" else " – " + dateText(SwiftDate.toMillis(r.d.optDouble("to")))}"
                        "holiday" -> "🎌 Holiday “${r.d.optString("name")}” on ${dateText(AttData.date(r.s("day")))}"
                        else -> "✏️ $who · ${dateText(AttData.date(r.s("day")))} → ${AttData.label(r.d.optString("proposedStatus").ifEmpty { "present" })}"
                    }
                    ListItem(headlineContent = { Text(text) }, supportingContent = { if (r.ak == "leave" && r.d.optString("reason").isNotEmpty()) Text(r.d.optString("reason")) },
                        trailingContent = { Row {
                            IconButton({ app.run(scope) { when (r.ak) { "leave" -> app.sync.attDecideLeave(r, true, true); "holiday" -> app.sync.attSaveHoliday(comp, AttData.date(r.s("day")), r.d.optString("name"), r, "approved"); else -> app.sync.attDecideChange(r, true) } } }) { Icon(Icons.Default.Check, "Approve", tint = Color(0xFF34C759)) }
                            IconButton({ app.run(scope) { when (r.ak) { "leave" -> app.sync.attDecideLeave(r, false, true); "holiday" -> app.sync.attSaveHoliday(comp, AttData.date(r.s("day")), r.d.optString("name"), r, "rejected"); else -> app.sync.attDecideChange(r, false) } } }) { Icon(Icons.Default.Close, "Reject", tint = Color(0xFFFF3B30)) }
                        } })
                }
            }
            item { SectionHeader("People (${members.size})") }
            if (members.isEmpty()) item { Empty("Add your team — people on iTeam get an invitation; others you mark yourself.") }
            items(members, key = { it.id }) { m ->
                val st = statusOf[m.id] ?: "none"
                val e = entries[m.id]?.d
                val waiting = m.d.optString("userID").isNotEmpty() && !m.d.has("accepted")
                ListItem(modifier = Modifier.clickable { marking = m },
                    leadingContent = { Avatar(m.memberName.ifEmpty { "?" }, 40, photo = app.store.photoOf(m.d.optString("userID"))) },
                    headlineContent = { Text(m.memberName + if (m.status == "admin") " ⭐" else "") },
                    supportingContent = { Text(when { waiting -> "Invitation sent"; m.d.has("accepted") && !m.d.optBoolean("accepted") && m.d.optString("userID").isNotEmpty() -> "Declined"
                        else -> listOfNotNull(e?.optDoubleOrNull("inAt")?.let { "In ${time(SwiftDate.toMillis(it))}" }, e?.optDoubleOrNull("outAt")?.let { "Out ${time(SwiftDate.toMillis(it))}" }).joinToString(" · ") }) },
                    trailingContent = { Box(Modifier.background(Color(AttData.color(st)), RoundedCornerShape(6.dp)).padding(horizontal = 8.dp, vertical = 4.dp)) { Text(AttData.code(st), color = Color.White, fontWeight = FontWeight.Bold) } })
            }
            item { Spacer(Modifier.height(90.dp)) }
        }
    }
    marking?.let { m ->
        AlertDialog(onDismissRequest = { marking = null }, title = { Text("${m.memberName} · ${dateText(day)}") }, text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                FlowRow { AttData.statuses.forEach { s -> FilterChip(statusOf[m.id] == s, { app.run(scope) { app.sync.attSaveEntry(comp, m, entries[m.id], day, s) }; marking = null },
                    label = { Text(AttData.label(s)) }, modifier = Modifier.padding(end = 4.dp)) } }
                if (!owner && entries[m.id] != null) Text("Changing a marked day goes to the owner for approval.", style = MaterialTheme.typography.labelSmall)
                TextButton({ leaveFor = m; marking = null }) { Text("Record leave…") }
                val u = m.d.optString("userID")
                if (owner && u.isNotEmpty() && m.d.optBoolean("accepted")) TextButton({ app.run(scope) { app.sync.attSetAdmin(comp, m, m.status != "admin") }; marking = null }) { Text(if (m.status == "admin") "Remove as admin" else "Make admin") }
                if (owner) TextButton({ app.run(scope) { app.sync.attDelete(m) }; marking = null }) { Text("Remove from company", color = MaterialTheme.colorScheme.error) }
            }
        }, confirmButton = { TextButton({ marking = null }) { Text("Close") } })
    }
    if (adding) AddMemberDialog(app, comp) { adding = false }
    leaveFor?.let { m -> LeaveDialog(app, m) { leaveFor = null } }
    if (holiday) {
        var name by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = { holiday = false }, title = { Text("Holiday on ${dateText(day)}") },
            text = { OutlinedTextField(name, { name = it }, label = { Text("Name (e.g. Diwali)") }, singleLine = true) },
            confirmButton = { TextButton({ app.run(scope) { app.sync.attSaveHoliday(comp, day, name.trim()) }; holiday = false }, enabled = name.isNotBlank()) { Text("Save") } },
            dismissButton = { TextButton({ holiday = false }) { Text("Cancel") } })
    }
    if (pickDay) {
        val state = rememberDatePickerState(initialSelectedDateMillis = day)
        DatePickerDialog(onDismissRequest = { pickDay = false }, confirmButton = { TextButton({ state.selectedDateMillis?.let { day = it + 43_200_000L }; pickDay = false }) { Text("OK") } }) { DatePicker(state) }
    }
}

@Composable
private fun AddMemberDialog(app: AppState, comp: Rec, onDone: () -> Unit) {
    var user by remember { mutableStateOf("") }
    var first by remember { mutableStateOf("") }
    var last by remember { mutableStateOf("") }
    var mobile by remember { mutableStateOf("") }
    var pick by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onDone, title = { Text("Add person") }, text = {
        Column {
            OutlinedButton({ pick = true }, Modifier.fillMaxWidth()) { Text(if (user.isEmpty()) "Pick an iTeam contact (they punch in themselves)" else "iTeam: ${app.store.name(user)}") }
            Text("…or someone without iTeam:", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 8.dp))
            OutlinedTextField(first, { first = it }, label = { Text("First name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(last, { last = it }, label = { Text("Last name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(mobile, { mobile = it }, label = { Text("Mobile") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone), modifier = Modifier.fillMaxWidth())
        }
    }, confirmButton = { TextButton({
        val f = first.trim().ifEmpty { app.store.name(user).substringBefore(" ") }
        val l = last.trim().ifEmpty { if (user.isNotEmpty()) app.store.name(user).substringAfter(" ", "") else "" }
        app.run(scope) { app.sync.attSaveMember(comp, null, AttData.member(user, f, l, mobile.trim())) }
        onDone()
    }, enabled = user.isNotEmpty() || first.isNotBlank()) { Text("Add") } }, dismissButton = { TextButton(onDone) { Text("Cancel") } })
    if (pick) PersonPicker(app) { user = it ?: ""; pick = false }
}

// MARK: - Finance

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FinanceHome(app: AppState, onBack: (() -> Unit)?) {
    val books = remember(app.tick) { app.sync.finBooks() }
    var book by remember { mutableStateOf("personal") }
    val all = remember(app.tick, book) { app.store.finList().filter { it.s("book") == book && !it.deleted && it.s("kind") != "goal" } }
    val month = Calendar.getInstance().apply { set(Calendar.DAY_OF_MONTH, 1); set(Calendar.HOUR_OF_DAY, 0) }.timeInMillis
    val paidMonth = all.filter { it.status == "paid" && it.finDate >= month }
    val income = paidMonth.filter { it.isIn }.sumOf { it.amount }
    val expense = paidMonth.filter { !it.isIn }.sumOf { it.amount }
    val attention = all.filter { it.status == "due" || it.status == "pending" }.sortedBy { it.finDate }
    var editing by remember { mutableStateOf<Rec?>(null) }
    var adding by remember { mutableStateOf<Boolean?>(null) }
    val scope = rememberCoroutineScope()
    val comp = if (book == "personal") null else app.sync.attCompany(book)
    val isOwner = comp == null || comp.optString("ownerID") == app.store.me
    val moduleLines = remember(app.tick) { moduleMoney(app) }
    Scaffold(topBar = { TopAppBar(title = { Text("Finance") }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } },
        actions = { PdfButton("Finance", books.firstOrNull { it.first == book }?.second ?: "Finance", charts = { ModuleCharts.finance(app, book) }) { ReportText.finance(app, book) } }) },
        floatingActionButton = { Row {
            ExtendedFloatingActionButton(onClick = { adding = true }, icon = { Icon(Icons.Default.ArrowDownward, null) }, text = { Text("Income") }, containerColor = Color(0xFFD7F5DD))
            Spacer(Modifier.width(8.dp))
            ExtendedFloatingActionButton(onClick = { adding = false }, icon = { Icon(Icons.Default.ArrowUpward, null) }, text = { Text("Expense") }, containerColor = Color(0xFFFFDDD9))
        } }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
                    books.forEach { (id, name) -> FilterChip(book == id, { book = id }, label = { Text(name) }, modifier = Modifier.padding(end = 6.dp)) }
                }
                StatRow(Triple("Net this month", money(income - expense), null), Triple("Income", money(income), null), Triple("Spent", money(expense), null))
            }
            item {
                val days = lastDays(7)
                val spent = days.map { (_, start) -> all.filter { !it.isIn && it.status == "paid" && it.finDate >= start && it.finDate < start + 86_400_000 }.sumOf { it.amount }.toFloat() }
                BarChartCard("Spending · last 7 days", money(spent.sum().toDouble()), days.map { it.first }, spent)
            }
            items(ModuleCharts.finance(app, book), key = { "ch" + it.title }) { ChartCard(it) }
            if (attention.isNotEmpty()) {
                item { SectionHeader("Due & waiting approval") }
                items(attention, key = { "a" + it.id }) { r ->
                    FinRow(r) { editing = r }
                    Row(Modifier.padding(start = 16.dp)) {
                        if (r.status == "due") TextButton({ app.run(scope) { app.sync.finMarkPaid(r) } }) { Text("Mark paid") }
                        if (r.status == "pending" && isOwner) {
                            TextButton({ app.run(scope) { app.sync.finDecide(r, true, "") } }) { Text("Approve") }
                            TextButton({ app.run(scope) { app.sync.finDecide(r, false, "") } }) { Text("Reject") }
                        }
                    }
                }
            }
            item { SectionHeader("Entries") }
            val list = all.filter { it.status == "paid" || it.status == "rejected" }.sortedByDescending { it.finDate }
            if (list.isEmpty()) item { Empty("No entries yet. Add income or an expense.") }
            items(list.take(200), key = { it.id }) { r -> FinRow(r) { editing = r } }
            if (book == "personal") {
                val lines = moduleLines
                if (lines.isNotEmpty()) {
                    item { SectionHeader("From your modules") }
                    items(lines.take(60), key = { "m" + it.first.id }) { (r, isIn) ->
                        ListItem(headlineContent = { Text(r.title.ifEmpty { BizSpecs.spec(r.module)?.kind(r.kind)?.label ?: "" }) },
                            supportingContent = { Text("${BizSpecs.spec(r.module)?.title ?: ""} · ${r.status}") },
                            trailingContent = { Text((if (isIn) "+" else "−") + money(kotlin.math.abs(r.amount)), color = if (isIn) Color(0xFF2E7D32) else Color(0xFFC62828)) })
                    }
                }
            }
            item { Spacer(Modifier.height(90.dp)) }
        }
    }
    adding?.let { isIn -> FinEditor(app, null, book, isIn, isOwner) { adding = null } }
    editing?.let { r -> FinEditor(app, r, book, r.isIn, isOwner) { editing = null } }
}

/** Money recorded in record modules (read-through, like the iPhone). */
private fun moduleMoney(app: AppState): List<Pair<Rec, Boolean>> = app.store.bizList().filter { !it.deleted && it.amount != 0.0 && it.owner == app.store.me && (it.parentID.isNotEmpty() || it.module == "bills") }.mapNotNull { r ->
    val isIn = when (r.module to r.kind) {
        "khata" to "got", "rent" to "payment", "khata" to "gave", "tuition" to "fee", "legal" to "fee", "clinic" to "bill" -> true
        "rent" to "charge" -> if (r.status != "Paid") true else null
        "bills" to "bill", "kids" to "fee", "travel" to "booking", "travel" to "expense", "petcare" to "vet", "petcare" to "grooming" -> false
        else -> null
    } ?: return@mapNotNull null
    r to isIn
}.sortedByDescending { it.first.due ?: it.first.date ?: it.first.created }

@Composable
private fun FinRow(r: Rec, onClick: () -> Unit) {
    ListItem(modifier = Modifier.clickable(onClick = onClick),
        headlineContent = { Text(r.d.optString("title").ifEmpty { r.s("category") }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(listOf(dateText(r.finDate), r.s("category"), r.d.optString("party"), if (r.status != "paid") r.status else "").filter { it.isNotEmpty() }.joinToString(" · ")) },
        trailingContent = { Text((if (r.isIn) "+" else "−") + money(r.amount), fontWeight = FontWeight.SemiBold, color = if (r.isIn) Color(0xFF2E7D32) else Color(0xFFC62828)) })
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun FinEditor(app: AppState, existing: Rec?, book: String, isIn: Boolean, isOwner: Boolean, onDone: () -> Unit) {
    val d0 = existing?.d
    var amount by remember { mutableStateOf(existing?.amount?.let { fmtQty(it) } ?: "") }
    var title by remember { mutableStateOf(d0?.optString("title") ?: "") }
    var party by remember { mutableStateOf(d0?.optString("party") ?: "") }
    var category by remember { mutableStateOf(existing?.s("category") ?: (if (isIn) Fin.incomeCategories else Fin.expenseCategories).first()) }
    var mode by remember { mutableStateOf(d0?.optString("mode") ?: "Cash") }
    var repeat by remember { mutableStateOf(d0?.optString("repeatRule") ?: "none") }
    var date by remember { mutableLongStateOf(existing?.finDate ?: System.currentTimeMillis()) }
    var due by remember { mutableStateOf(existing?.status == "due") }
    var pick by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onDone, title = { Text((if (existing == null) "New " else "Edit ") + if (isIn) "income" else "expense") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(amount, { amount = it }, label = { Text("Amount (₹)") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(title, { title = it }, label = { Text("What for") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(party, { party = it }, label = { Text(if (isIn) "From" else "Paid to") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Text("Category", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
            FlowRow { (if (isIn) Fin.incomeCategories else Fin.expenseCategories).forEach { c -> FilterChip(category == c, { category = c }, label = { Text(c) }, modifier = Modifier.padding(end = 4.dp)) } }
            Text("Mode", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
            FlowRow { Fin.modes.forEach { c -> FilterChip(mode == c, { mode = c }, label = { Text(c) }, modifier = Modifier.padding(end = 4.dp)) } }
            TextButton({ pick = true }) { Icon(Icons.Default.Event, null); Spacer(Modifier.width(6.dp)); Text(dateText(date)) }
            Row(verticalAlignment = Alignment.CenterVertically) { Switch(due, { due = it }); Spacer(Modifier.width(8.dp)); Text("Not paid yet (due)") }
            Text("Repeats", style = MaterialTheme.typography.labelMedium)
            FlowRow { Fin.repeats.forEach { c -> FilterChip(repeat == c, { repeat = c }, label = { Text(if (c == "none") "Once" else c.replaceFirstChar { it.uppercase() }) }, modifier = Modifier.padding(end = 4.dp)) } }
            if (!isOwner) Text("Company money you add goes to the owner for approval.", style = MaterialTheme.typography.labelSmall)
        }
    }, confirmButton = { TextButton({
        val data = (d0?.let { JSONObject(it.toString()) } ?: Fin.data()).put("title", title.trim()).put("party", party.trim()).put("mode", mode).put("repeatRule", repeat)
        val status = if (!isOwner && existing == null) "pending" else if (due) "due" else "paid"
        app.run(scope) { app.sync.finSave(existing, book, date, num(amount), if (isIn) "in" else "out", status, category, data) }
        onDone()
    }, enabled = num(amount) > 0) { Text("Save") } }, dismissButton = { Row {
        if (existing != null) TextButton({ app.run(scope) { app.sync.finDelete(existing) }; onDone() }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
        TextButton(onDone) { Text("Cancel") }
    } })
    if (pick) {
        val state = rememberDatePickerState(initialSelectedDateMillis = date)
        DatePickerDialog(onDismissRequest = { pick = false }, confirmButton = { TextButton({ state.selectedDateMillis?.let { date = it + 43_200_000L }; pick = false }) { Text("OK") } }) { DatePicker(state) }
    }
}


/** Office QR for managers: live code (changes every 30 s) or today's code to print/share for the door. */
@Composable
fun AttQRDialog(comp: Rec, onDone: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val secret = comp.d.optString("qrSecret")
    var daily by remember { mutableStateOf(false) }
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(1000); now = System.currentTimeMillis() } }
    val token = if (secret.isEmpty()) "" else if (daily) AttQR.daily(comp.id, secret, now) else AttQR.live(comp.id, secret, now)
    val bmp = remember(token) { if (token.isEmpty()) null else runCatching { com.journeyapps.barcodescanner.BarcodeEncoder().encodeBitmap(token, com.google.zxing.BarcodeFormat.QR_CODE, 700, 700) }.getOrNull() }
    AlertDialog(onDone, confirmButton = { TextButton(onDone) { Text("Done") } },
        dismissButton = if (daily && bmp != null) { {
            TextButton({
                val f = java.io.File(ctx.cacheDir, "attendance-qr.png"); f.outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                val uri = androidx.core.content.FileProvider.getUriForFile(ctx, ctx.packageName + ".files", f)
                ctx.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("image/png")
                    .putExtra(android.content.Intent.EXTRA_STREAM, uri).addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share or print today's QR"))
            }) { Text("Share / print") }
        } } else null,
        title = { Text(comp.d.optString("name")) },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Row { FilterChip(!daily, { daily = false }, { Text("Live (30 s)") }); Spacer(Modifier.width(8.dp)); FilterChip(daily, { daily = true }, { Text("Today's QR") }) }
                Spacer(Modifier.height(10.dp))
                if (bmp == null) Text("This phone hasn't received the company's QR key yet. Pull to refresh, or ask the owner.")
                else androidx.compose.foundation.Image(bmp.asImageBitmap(), "Attendance QR", Modifier.size(260.dp).background(Color.White, RoundedCornerShape(16.dp)).padding(10.dp))
                Spacer(Modifier.height(8.dp))
                Text(if (daily) "Valid all day today — print it for the door. A new code is made every day." else "New code in ${AttQR.secondsLeft(now)} s — a photo of it can't be reused later.",
                    style = MaterialTheme.typography.bodySmall, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        })
}
