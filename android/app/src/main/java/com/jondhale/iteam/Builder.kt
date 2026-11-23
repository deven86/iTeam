package com.jondhale.iteam

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONObject

// Builder & Infra on Android: projects, buildings → units, sales → payments / demands, stock, machines, approvals, tests,
// disputes, parties… Same records and permissions as the iPhone (owner, admins, team).

/** Project-level kinds shown as sections on a project. */
private val projectSections = listOf("building", "material", "equipment", "party", "approval", "inspection", "test", "progress", "dispute", "land", "asset", "reward", "vault")
/** Which kinds hang under which record. */
private fun childKinds(kind: String) = when (kind) {
    "building" -> listOf("unit")
    "unit" -> listOf("sale")
    "sale" -> listOf("demand", "payment")
    "party" -> listOf("payment")
    "material" -> listOf("move")
    "equipment" -> listOf("log")
    else -> emptyList()
}

fun statusColor(s: String) = when (s) {
    "Available" -> Color(0xFF2E7D32)
    "Hold" -> Color(0xFFF9A825)
    "Booked", "Agreement done" -> Color(0xFF1565C0)
    "Registered", "Possession given" -> Color(0xFF6A1B9A)
    "Rehab" -> Color(0xFF00838F)
    else -> Color.Gray
}

// MARK: - Home

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BuilderHome(app: AppState, onBack: (() -> Unit)?, open: (Page) -> Unit) {
    val me = app.store.me
    val all = remember(app.tick) { app.store.buildList().filter { !it.deleted } }
    val projects = all.filter { it.bkind == "project" && (it.ownerID == me || me in it.team || me in it.admins) }
    val units = all.filter { it.bkind == "unit" && projects.any { p -> p.id == it.projectID } }
    val sold = units.count { it.status in listOf("Booked", "Agreement done", "Registered", "Possession given") }
    val dues = all.filter { it.bkind == "demand" && it.status == "Due" && projects.any { p -> p.id == it.projectID } }.sumOf { it.fnum("amount") }
    val myHomes = all.filter { it.bkind == "sale" && it.d.optString("subjectID") == me && it.ownerID != me }
    var newProject by remember { mutableStateOf(false) }
    val scan = rememberLauncherForActivityResult(ScanContract()) { r ->
        r.contents?.removePrefix("iteam-build:")?.let { id -> if (app.store.buildRec(id) != null) open(Page.BuildRec(id)) else app.toast = "Not found on this phone" }
    }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Builder & Infra") }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } },
            actions = {
                IconButton({ scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan a stock / machine / asset QR").setBeepEnabled(false)) }) { Icon(Icons.Default.QrCodeScanner, "Scan") }
                IconButton({ open(Page.FSI) }) { Icon(Icons.Default.Calculate, "FSI calculator") }
            })
    }, floatingActionButton = { ExtendedFloatingActionButton(onClick = { newProject = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text("New project") }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item { StatTiles("${projects.size}" to "Projects", "$sold / ${units.size}" to "Units sold", money(dues) to "Instalments due") }
            item { SectionHeader("Projects") }
            if (projects.isEmpty()) item { Empty("No projects yet. Tap New project — add your team and a project chat is created for them.") }
            items(projects.sortedByDescending { it.updated }, key = { it.id }) { p ->
                ListItem(modifier = Modifier.clickable { open(Page.BuildProject(p.id)) },
                    leadingContent = { Icon(Icons.Default.Apartment, null) },
                    headlineContent = { Text(p.btitle) },
                    supportingContent = { Text(listOf(p.f("type"), p.f("city"), p.status).filter { it.isNotEmpty() }.joinToString(" · ")) },
                    trailingContent = { if (p.ownerID != me) Text("Team", style = MaterialTheme.typography.labelSmall) })
            }
            if (myHomes.isNotEmpty()) {
                item { SectionHeader("My properties") }
                items(myHomes, key = { "h" + it.id }) { s ->
                    val unit = app.store.buildRec(s.s("parentID"))
                    val proj = app.store.buildRec(s.projectID)
                    ListItem(modifier = Modifier.clickable { open(Page.BuildRec(s.id)) },
                        leadingContent = { Icon(Icons.Default.Home, null) },
                        headlineContent = { Text("Unit ${unit?.btitle ?: ""} · ${proj?.btitle ?: ""}") },
                        supportingContent = { Text("${s.status} · Managed by ${app.store.name(s.ownerID)}") })
                }
            }
            item { Spacer(Modifier.height(90.dp)) }
        }
    }
    if (newProject) ProjectEditor(app, null) { id -> newProject = false; id?.let { open(Page.BuildProject(it)) } }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProjectEditor(app: AppState, existing: Rec?, onDone: (String?) -> Unit) {
    val kind = BuildKinds.project
    val values = remember { mutableStateMapOf<String, String>().apply { kind.fields.forEach { put(it.key, existing?.f(it.key) ?: "") } } }
    val team = remember { mutableStateListOf<String>().apply { existing?.team?.let { addAll(it) } } }
    val admins = remember { mutableStateListOf<String>().apply { existing?.admins?.let { addAll(it) } } }
    var status by remember { mutableStateOf(existing?.status ?: "Planning") }
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = { onDone(null) }, title = { Text(if (existing == null) "New project" else "Edit project") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                FieldInputs(kind, values)
                if (existing != null) {
                    Text("Status", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 8.dp))
                    FlowRow { kind.statuses.forEach { s -> FilterChip(status == s, { status = s }, label = { Text(s) }, modifier = Modifier.padding(end = 4.dp)) } }
                }
                Text("Team (gets the project chat; can add site entries)", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 10.dp))
                app.store.contactList().filter { it.userID != app.store.me }.forEach { c ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(c.userID in team, { if (it) team.add(c.userID) else { team.remove(c.userID); admins.remove(c.userID) } })
                        Text(c.name, Modifier.weight(1f))
                        if (c.userID in team) FilterChip(c.userID in admins, { if (c.userID in admins) admins.remove(c.userID) else admins.add(c.userID) }, label = { Text("Admin") })
                    }
                }
            }
        },
        confirmButton = {
            TextButton({
                busy = true
                app.run(scope) {
                    val f = values.toMap()
                    val id = if (existing == null) app.sync.bCreateProject("", f, team.toList(), admins.toList())
                    else { app.sync.bSaveProject(existing, f, team.toList(), admins.toList(), status); existing.id }
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { onDone(id) }
                }
            }, enabled = !values["name"].isNullOrBlank() && !busy) { Text(if (busy) "Saving…" else "Save") }
        },
        dismissButton = { TextButton({ onDone(null) }) { Text("Cancel") } })
}

// MARK: - Project

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BuildProjectScreen(app: AppState, id: String, onBack: () -> Unit, open: (Page) -> Unit) {
    val p = remember(app.tick) { app.store.buildRec(id) } ?: run { Centered("Project not found"); return }
    val all = remember(app.tick) { app.store.buildList().filter { it.projectID == id && !it.deleted && it.id != id } }
    val admin = app.sync.bIsAdmin(p)
    val team = admin || app.store.me in p.team
    var adding by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf(false) }
    val sales = all.filter { it.bkind == "sale" }
    val units = all.filter { it.bkind == "unit" }
    val received = all.filter { it.bkind == "payment" && it.status != "Bounced" && app.store.buildRec(it.s("parentID"))?.bkind == "sale" }.sumOf { it.fnum("amount") }
    Scaffold(topBar = {
        TopAppBar(title = { Text(p.btitle, maxLines = 1, overflow = TextOverflow.Ellipsis) }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } },
            actions = {
                p.d.optString("convID").takeIf { it.isNotEmpty() && app.store.conv(it) != null }?.let { c -> IconButton({ open(Page.Chat(c)) }) { Icon(Icons.Default.Chat, "Project chat") } }
                if (admin) IconButton({ editing = true }) { Icon(Icons.Default.Edit, "Edit") }
            })
    }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                StatTiles("${units.count { it.status == "Available" }} / ${units.size}" to "Units available", "${sales.size}" to "Sales", money(received) to "Received")
                Text(listOf(p.f("type"), p.f("city"), p.f("authority"), p.status).filter { it.isNotEmpty() }.joinToString(" · "), Modifier.padding(horizontal = 16.dp),
                    style = MaterialTheme.typography.bodySmall)
            }
            if (sales.isNotEmpty()) {
                item { SectionHeader("Sales") }
                items(sales.sortedByDescending { it.updated }, key = { it.id }) { s -> RecRow(app, s) { open(Page.BuildRec(s.id)) } }
            }
            projectSections.forEach { k ->
                val kind = BuildKinds.of(k)
                val list = all.filter { it.bkind == k && it.s("parentID").isEmpty() }
                val canAdd = if (BuildKinds.adminOnly(k)) admin else team
                item(key = "h$k") { SectionHeader("${kind.plural}${if (list.isNotEmpty()) " (${list.size})" else ""}", if (canAdd) "Add" else null) { adding = k } }
                items(list.sortedByDescending { it.updated }.take(30), key = { it.id }) { r -> RecRow(app, r) { open(Page.BuildRec(r.id)) } }
            }
            item { Spacer(Modifier.height(40.dp)) }
        }
    }
    adding?.let { k -> BuildEditor(app, k, null, p.companyID, p.id, "") { adding = null } }
    if (editing) ProjectEditor(app, p) { editing = false }
}

@Composable
private fun RecRow(app: AppState, r: Rec, onClick: () -> Unit) {
    val sub = when (r.bkind) {
        "material" -> "${fmtQty(app.sync.bStock(r))} ${r.f("unit")} in stock"
        "sale" -> listOf("Unit ${app.store.buildRec(r.s("parentID"))?.btitle ?: ""}", money(r.fnum("value"))).joinToString(" · ")
        "payment", "demand" -> money(r.fnum("amount"))
        "party" -> r.f("role")
        "approval", "inspection" -> r.f("authority")
        else -> r.f("type")
    }
    ListItem(modifier = Modifier.clickable(onClick = onClick),
        headlineContent = { Text(r.btitle.ifEmpty { BuildKinds.of(r.bkind).label }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(listOf(sub, r.status).filter { it.isNotEmpty() }.joinToString(" · ")) },
        trailingContent = { if (r.bkind == "material" && r.fnum("reorder") > 0 && app.sync.bStock(r) <= r.fnum("reorder")) Text("Reorder", color = MaterialTheme.colorScheme.error) })
}

fun fmtQty(v: Double) = if (v % 1.0 == 0.0) "%.0f".format(v) else "%.2f".format(v)

// MARK: - Any record

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BuildRecScreen(app: AppState, id: String, onBack: () -> Unit, open: (Page) -> Unit) {
    val r = remember(app.tick) { app.store.buildRec(id) } ?: run { Centered("Not found"); return }
    val project = remember(app.tick) { app.store.buildRec(r.projectID) }
    val kind = BuildKinds.of(r.bkind)
    val admin = app.sync.bIsAdmin(project) || r.ownerID == app.store.me
    val canEdit = if (BuildKinds.adminOnly(r.bkind)) admin else admin || app.store.me in (project?.team ?: emptyList())
    val children = remember(app.tick) { app.sync.bChildren(id) }
    var editing by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf<String?>(null) }
    var showQR by remember { mutableStateOf(false) }
    var generate by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Scaffold(topBar = {
        TopAppBar(title = { Text(r.btitle.ifEmpty { kind.label }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } },
            actions = {
                if (kind.qr) IconButton({ showQR = true }) { Icon(Icons.Default.QrCode, "QR sticker") }
                if (canEdit) {
                    IconButton({ editing = true }) { Icon(Icons.Default.Edit, "Edit") }
                    IconButton({ confirmDelete = true }) { Icon(Icons.Default.Delete, "Delete") }
                }
            })
    }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                Card(Modifier.fillMaxWidth().padding(12.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Text(kind.label + (project?.let { " · ${it.btitle}" } ?: ""), style = MaterialTheme.typography.labelMedium)
                        Text(r.btitle, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                        if (r.bkind == "material") Text("In stock: ${fmtQty(app.sync.bStock(r))} ${r.f("unit")}", fontWeight = FontWeight.SemiBold)
                        if (r.bkind == "sale") {
                            val paid = children.filter { it.bkind == "payment" && it.status != "Bounced" }.sumOf { it.fnum("amount") }
                            Text("Received ${money(paid)} of ${money(r.fnum("value"))}", fontWeight = FontWeight.SemiBold)
                        }
                        kind.fields.forEach { f ->
                            val v = r.f(f.key)
                            if (v.isNotEmpty()) Text("${f.label}: ${showValue(f, v)}", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 2.dp))
                        }
                        if (r.ownerID != app.store.me && r.d.optString("subjectID") == app.store.me) Text("Managed by ${app.store.name(r.ownerID)}", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
            if (kind.statuses.isNotEmpty()) item {
                Text("Status", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelMedium)
                FlowRow(Modifier.padding(horizontal = 12.dp)) {
                    kind.statuses.forEach { s -> FilterChip(r.status == s, { if (canEdit && r.status != s) app.run(scope) { app.sync.bSetStatus(r, s) } }, label = { Text(s) }, enabled = canEdit || r.status == s, modifier = Modifier.padding(end = 4.dp)) }
                }
            }
            if (r.bkind == "building") item {
                val units = children.filter { it.bkind == "unit" }
                SectionHeader("Units (${units.size})", if (admin) "Generate" else null) { generate = true }
                UnitsGrid(units) { open(Page.BuildRec(it.id)) }
            }
            childKinds(r.bkind).filter { r.bkind != "building" }.forEach { ck ->
                val list = children.filter { it.bkind == ck }
                val canAdd = if (BuildKinds.adminOnly(ck)) admin else canEdit || app.store.me in (project?.team ?: emptyList())
                item(key = "h$ck") {
                    SectionHeader(BuildKinds.of(ck).plural, if (canAdd && !(ck == "sale" && list.isNotEmpty())) "Add" else null) { adding = ck }
                    if (ck == "demand" && list.isEmpty() && admin && r.fnum("value") > 0)
                        OutlinedButton({ app.run(scope) { app.sync.bAddPlan(r, BuildCatalog.clpStages) } }, Modifier.padding(horizontal = 16.dp)) { Text("Add construction-linked payment plan") }
                }
                items(list.sortedByDescending { it.updated }, key = { it.id }) { c -> RecRow(app, c) { open(Page.BuildRec(c.id)) } }
            }
            item { Spacer(Modifier.height(40.dp)) }
        }
    }
    if (editing) BuildEditor(app, r.bkind, r, r.companyID, r.projectID, r.s("parentID")) { editing = false }
    adding?.let { k -> BuildEditor(app, k, null, r.companyID, r.projectID.ifEmpty { r.id }, r.id) { adding = null } }
    if (generate) GenerateUnits(app, r) { generate = false }
    if (showQR) {
        val qr = remember { runCatching { BarcodeEncoder().encodeBitmap("iteam-build:${r.id}", BarcodeFormat.QR_CODE, 640, 640) }.getOrNull() }
        AlertDialog(onDismissRequest = { showQR = false }, title = { Text(r.btitle) },
            text = { Column(horizontalAlignment = Alignment.CenterHorizontally) {
                qr?.let { Image(it.asImageBitmap(), "QR", Modifier.size(240.dp).background(Color.White)) }
                Text("Print and stick it on the ${kind.label.lowercase()}. Scan it in Builder & Infra to open this record.", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 8.dp))
            } },
            confirmButton = { TextButton({ showQR = false }) { Text("Done") } })
    }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete “${r.btitle}”?") },
        confirmButton = { TextButton({ confirmDelete = false; app.run(scope) { app.sync.bDelete(r) }; onBack() }) { Text("Delete") } },
        dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel") } })
}

private fun showValue(f: F, v: String) = when (f.type) {
    BT.date -> BuildData.date(v)?.let { dateText(it) } ?: v
    BT.money -> money(num(v))
    BT.percent -> "$v%"
    else -> v
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun UnitsGrid(units: List<Rec>, onClick: (Rec) -> Unit) {
    if (units.isEmpty()) { Empty("No units yet — tap Generate to create them for every wing and floor."); return }
    val sorted = units.sortedWith(compareBy({ it.f("wing") }, { -(it.f("floor").toIntOrNull() ?: 0) }, { it.f("number") }))
    FlowRow(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        sorted.forEach { u ->
            Box(Modifier.size(width = 64.dp, height = 44.dp).border(2.dp, statusColor(u.status), RoundedCornerShape(8.dp))
                .background(statusColor(u.status).copy(alpha = 0.12f), RoundedCornerShape(8.dp)).clickable { onClick(u) }, contentAlignment = Alignment.Center) {
                Text(u.btitle, style = MaterialTheme.typography.labelSmall, maxLines = 1)
            }
        }
    }
    Text("Green available · yellow hold · blue booked · purple registered", Modifier.padding(16.dp), style = MaterialTheme.typography.labelSmall)
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun GenerateUnits(app: AppState, b: Rec, onDone: () -> Unit) {
    var perFloor by remember { mutableStateOf("4") }
    var from by remember { mutableStateOf("1") }
    var to by remember { mutableStateOf(b.f("floors").ifEmpty { "7" }) }
    var type by remember { mutableStateOf("2 BHK") }
    var carpet by remember { mutableStateOf("") }
    var price by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onDone, title = { Text("Generate units") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text("Wings: ${b.f("wings").ifEmpty { "(one wing)" }}", style = MaterialTheme.typography.bodySmall)
                val nk = KeyboardOptions(keyboardType = KeyboardType.Number)
                Row { OutlinedTextField(from, { from = it }, label = { Text("From floor") }, keyboardOptions = nk, modifier = Modifier.weight(1f)); Spacer(Modifier.width(6.dp))
                    OutlinedTextField(to, { to = it }, label = { Text("To floor") }, keyboardOptions = nk, modifier = Modifier.weight(1f)) }
                OutlinedTextField(perFloor, { perFloor = it }, label = { Text("Units per floor") }, keyboardOptions = nk, modifier = Modifier.fillMaxWidth())
                Text("Type", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
                FlowRow { BuildKinds.unitTypes.take(10).forEach { t -> FilterChip(type == t, { type = t }, label = { Text(t) }, modifier = Modifier.padding(end = 4.dp)) } }
                OutlinedTextField(carpet, { carpet = it }, label = { Text("Carpet area (sq ft)") }, keyboardOptions = nk, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(price, { price = it }, label = { Text("Price") }, keyboardOptions = nk, modifier = Modifier.fillMaxWidth())
            }
        },
        confirmButton = { TextButton({
            app.run(scope) { app.sync.bGenerateUnits(b, perFloor.toIntOrNull() ?: 4, type, carpet, price, from.toIntOrNull() ?: 1, to.toIntOrNull() ?: 1) }
            onDone()
        }) { Text("Generate") } },
        dismissButton = { TextButton(onDone) { Text("Cancel") } })
}

// MARK: - Editor (fields come from the shared spec)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BuildEditor(app: AppState, kindID: String, existing: Rec?, company: String, project: String, parent: String, onDone: () -> Unit) {
    val kind = BuildKinds.of(kindID)
    val values = remember { mutableStateMapOf<String, String>().apply { kind.fields.forEach { put(it.key, existing?.f(it.key) ?: "") } } }
    var status by remember { mutableStateOf(existing?.status ?: kind.statuses.firstOrNull() ?: "") }
    var subject by remember { mutableStateOf(existing?.d?.optString("subjectID") ?: "") }
    var pickPerson by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onDone, title = { Text((if (existing == null) "New " else "Edit ") + kind.label.lowercase()) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                FieldInputs(kind, values)
                if (kind.statuses.isNotEmpty()) {
                    Text("Status", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 8.dp))
                    FlowRow { kind.statuses.forEach { s -> FilterChip(status == s, { status = s }, label = { Text(s) }, modifier = Modifier.padding(end = 4.dp)) } }
                }
                if (kindID in listOf("sale", "party")) TextButton({ pickPerson = true }) {
                    Icon(Icons.Default.Link, null); Spacer(Modifier.width(6.dp))
                    Text(if (subject.isEmpty()) "Link to their iTeam (they get their own copy)" else "Linked: ${app.store.name(subject)}")
                }
            }
        },
        confirmButton = { TextButton({
            val d = existing?.d?.let { JSONObject(it.toString()) } ?: BuildData.new()
            d.put("f", JSONObject(values.toMap().filterValues { it.isNotBlank() }.mapValues { it.value.trim() } as Map<*, *>))
            d.put("subjectID", subject)
            app.run(scope) {
                app.sync.bSave(kindID, existing, company, project, parent, status, d)
                // Booking a unit marks the unit as booked.
                if (existing == null && kindID == "sale") app.store.buildRec(parent)?.let { u -> if (u.status == "Available" || u.status == "Hold") app.sync.bSetStatus(u, "Booked") }
            }
            onDone()
        }, enabled = values.values.any { it.isNotBlank() }) { Text("Save") } },
        dismissButton = { TextButton(onDone) { Text("Cancel") } })
    if (pickPerson) PersonPicker(app) { subject = it ?: ""; pickPerson = false }
}

/** Inputs for a spec's fields: text, numbers, dates and choices; section titles; role-specific fields. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun FieldInputs(kind: BKind, values: MutableMap<String, String>) {
    var pickDate by remember { mutableStateOf<String?>(null) }
    var lastSection = ""
    val selector = values["role"].orEmpty().ifEmpty { values["type"].orEmpty() }
    kind.fields.filter { it.roles == null || selector in it.roles }.forEach { f ->
        if (f.section.isNotEmpty() && f.section != lastSection) {
            lastSection = f.section
            Text(f.section, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 12.dp))
        }
        when (f.type) {
            BT.date -> TextButton({ pickDate = f.key }) {
                Icon(Icons.Default.Event, null); Spacer(Modifier.width(6.dp))
                Text("${f.label}: ${values[f.key]?.let { BuildData.date(it) }?.let { dateText(it) } ?: "—"}")
            }
            BT.choice -> ChoiceField(f, values[f.key] ?: "") { values[f.key] = it }
            else -> OutlinedTextField(values[f.key] ?: "", { values[f.key] = it }, label = { Text(f.label + if (f.type == BT.percent) " (%)" else "") },
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp), singleLine = f.type != BT.long, maxLines = if (f.type == BT.long) 5 else 1,
                keyboardOptions = when (f.type) {
                    BT.number, BT.money, BT.area, BT.percent -> KeyboardOptions(keyboardType = KeyboardType.Decimal)
                    BT.phone -> KeyboardOptions(keyboardType = KeyboardType.Phone)
                    BT.email -> KeyboardOptions(keyboardType = KeyboardType.Email)
                    else -> KeyboardOptions.Default
                })
        }
    }
    pickDate?.let { k ->
        val state = rememberDatePickerState(initialSelectedDateMillis = values[k]?.let { BuildData.date(it) } ?: System.currentTimeMillis())
        DatePickerDialog(onDismissRequest = { pickDate = null },
            confirmButton = { TextButton({ values[k] = state.selectedDateMillis?.let { BuildData.dateString(it + 9 * 3_600_000L) } ?: ""; pickDate = null }) { Text("OK") } },
            dismissButton = { TextButton({ values[k] = ""; pickDate = null }) { Text("No date") } }) { DatePicker(state) }
    }
}

@Composable
private fun ChoiceField(f: F, value: String, onChange: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box(Modifier.padding(top = 4.dp)) {
        OutlinedButton({ open = true }, Modifier.fillMaxWidth()) {
            Text(if (value.isEmpty()) f.label else "${f.label}: $value", Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(Icons.Default.ArrowDropDown, null)
        }
        DropdownMenu(open, { open = false }, Modifier.heightIn(max = 360.dp)) {
            DropdownMenuItem({ Text("—") }, { onChange(""); open = false })
            f.options.forEach { o -> DropdownMenuItem({ Text(o) }, { onChange(o); open = false }) }
        }
    }
}

// MARK: - FSI calculator (Maharashtra UDCPR-2020 or any country's ratio)

private data class FsiRow(val upTo: Double, val label: String, val basic: Double, val premium: Double, val tdr: Double)
private val mcNon = listOf(FsiRow(9.0, "Below 9 m", 1.10, 0.0, 0.0), FsiRow(12.0, "9 m to below 12 m", 1.10, 0.50, 0.40), FsiRow(15.0, "12 m to below 15 m", 1.10, 0.50, 0.65),
    FsiRow(24.0, "15 m to below 24 m", 1.10, 0.50, 0.90), FsiRow(30.0, "24 m to below 30 m", 1.10, 0.50, 1.15), FsiRow(Double.MAX_VALUE, "30 m and above", 1.10, 0.50, 1.40))
private val otherNon = listOf(FsiRow(9.0, "Below 9 m", 1.10, 0.0, 0.0), FsiRow(12.0, "9 m to below 12 m", 1.10, 0.30, 0.30), FsiRow(15.0, "12 m to below 15 m", 1.10, 0.30, 0.60),
    FsiRow(24.0, "15 m to below 24 m", 1.10, 0.30, 0.70), FsiRow(30.0, "24 m to below 30 m", 1.10, 0.30, 0.90), FsiRow(Double.MAX_VALUE, "30 m and above", 1.10, 0.30, 1.10))
private val mcCong = listOf(FsiRow(9.0, "Below 9 m", 1.50, 0.0, 0.0), FsiRow(18.0, "9 m to below 18 m", 2.00, 0.30, 0.30), FsiRow(30.0, "18 m to below 30 m", 2.00, 0.30, 0.50), FsiRow(Double.MAX_VALUE, "30 m and above", 2.00, 0.30, 0.70))
private val otherCong = listOf(FsiRow(9.0, "Below 9 m", 1.50, 0.0, 0.0), FsiRow(18.0, "9 m to below 18 m", 2.00, 0.30, 0.10), FsiRow(30.0, "18 m to below 30 m", 2.00, 0.30, 0.20), FsiRow(Double.MAX_VALUE, "30 m and above", 2.00, 0.30, 0.20))

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun FSIScreen(onBack: () -> Unit) {
    var world by remember { mutableStateOf(false) }
    var sqft by remember { mutableStateOf(false) }
    var corp by remember { mutableStateOf(true) }
    var congested by remember { mutableStateOf(false) }
    var residential by remember { mutableStateOf(true) }
    var plot by remember { mutableStateOf("") }
    var ded by remember { mutableStateOf("") }
    var road by remember { mutableFloatStateOf(12f) }
    var asr by remember { mutableStateOf("") }
    var ratio by remember { mutableStateOf("") }
    var bonus by remember { mutableStateOf("") }
    var coverage by remember { mutableStateOf("") }
    val toSqm = if (sqft) 1 / 10.7639 else 1.0
    val unit = if (sqft) "sq ft" else "m²"
    val back = 1 / toSqm
    Scaffold(topBar = { TopAppBar(title = { Text("FSI calculator") }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } }) }) { pad ->
        Column(Modifier.padding(pad).padding(16.dp).verticalScroll(rememberScrollState())) {
            Row { FilterChip(!world, { world = false }, { Text("Maharashtra UDCPR") }); Spacer(Modifier.width(6.dp)); FilterChip(world, { world = true }, { Text("Any country") }) }
            Row { FilterChip(!sqft, { sqft = false }, { Text("Square metres") }); Spacer(Modifier.width(6.dp)); FilterChip(sqft, { sqft = true }, { Text("Square feet") }) }
            val dk = KeyboardOptions(keyboardType = KeyboardType.Decimal)
            OutlinedTextField(plot, { plot = it }, label = { Text("Plot area ($unit)") }, keyboardOptions = dk, modifier = Modifier.fillMaxWidth())
            if (!world) {
                OutlinedTextField(ded, { ded = it }, label = { Text("Less road widening / reservation / amenity ($unit)") }, keyboardOptions = dk, modifier = Modifier.fillMaxWidth())
                Text("Road in front: ${fmtQty(road.toDouble())} m", Modifier.padding(top = 10.dp), fontWeight = FontWeight.SemiBold)
                Slider(road, { road = (it * 2).toInt() / 2f }, valueRange = 3f..45f)
                FlowRow { listOf(corp to "Municipal Corp. / CIDCO", !corp to "Council / other").forEachIndexed { i, (sel, l) -> FilterChip(sel, { corp = i == 0 }, { Text(l) }, Modifier.padding(end = 4.dp)) } }
                FlowRow { listOf(!congested to "Non-congested", congested to "Congested (gaothan)").forEachIndexed { i, (sel, l) -> FilterChip(sel, { congested = i == 1 }, { Text(l) }, Modifier.padding(end = 4.dp)) } }
                FlowRow { listOf(residential to "Residential", !residential to "Non-residential").forEachIndexed { i, (sel, l) -> FilterChip(sel, { residential = i == 0 }, { Text(l) }, Modifier.padding(end = 4.dp)) } }
                OutlinedTextField(asr, { asr = it }, label = { Text("ASR land rate per m² (optional, for premium cost)") }, keyboardOptions = dk, modifier = Modifier.fillMaxWidth())
                val table = if (corp) (if (congested) mcCong else mcNon) else (if (congested) otherCong else otherNon)
                val row = table.firstOrNull { road < it.upTo } ?: table.last()
                val gross = maxOf(0.0, num(plot) * toSqm); val net = maxOf(0.0, gross - num(ded) * toSqm)
                val basic = net * row.basic; val premium = gross * row.premium; val tdr = gross * row.tdr
                val potential = basic + premium + tdr; val anc = potential * if (residential) 0.60 else 0.80
                val total = potential + anc
                Card(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Text("Road ${row.label}: basic ${row.basic} · premium ${row.premium} · TDR ${row.tdr}", style = MaterialTheme.typography.labelMedium)
                        listOf("Basic FSI (on net plot)" to basic, "Premium FSI" to premium, "TDR" to tdr, "Ancillary (${if (residential) 60 else 80}%)" to anc).forEach { (l, v) ->
                            Row { Text(l, Modifier.weight(1f)); Text("${fmtQty(v * back)} $unit") }
                        }
                        HorizontalDivider(Modifier.padding(vertical = 6.dp))
                        Row { Text("Total built-up allowed", Modifier.weight(1f), fontWeight = FontWeight.Bold); Text("${fmtQty(total * back)} $unit", fontWeight = FontWeight.Bold) }
                        if (gross > 0) Text("Effective FSI ${"%.2f".format(total / gross)}", style = MaterialTheme.typography.bodySmall)
                        if (num(asr) > 0) Text("Premium FSI cost ≈ ${money(premium * num(asr) * 0.35)} (35% of ASR)", style = MaterialTheme.typography.bodySmall)
                    }
                }
                Text("UDCPR-2020 Table 6-G / 6-A, residential zone. Not for Greater Mumbai (DCPR-2034). Confirm with your architect and the planning authority.",
                    Modifier.padding(top = 8.dp), style = MaterialTheme.typography.labelSmall)
            } else {
                OutlinedTextField(ratio, { ratio = it }, label = { Text("FAR / plot ratio from your zoning") }, keyboardOptions = dk, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(bonus, { bonus = it }, label = { Text("Bonus % (optional)") }, keyboardOptions = dk, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(coverage, { coverage = it }, label = { Text("Site coverage % (optional)") }, keyboardOptions = dk, modifier = Modifier.fillMaxWidth())
                val p = maxOf(0.0, num(plot)); val gfa = p * maxOf(0.0, num(ratio)) * (1 + maxOf(0.0, num(bonus)) / 100)
                val foot = if (num(coverage) > 0) p * num(coverage) / 100 else 0.0
                Card(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Row { Text("Gross floor area", Modifier.weight(1f), fontWeight = FontWeight.Bold); Text("${fmtQty(gfa)} $unit", fontWeight = FontWeight.Bold) }
                        if (foot > 0) { Row { Text("Footprint", Modifier.weight(1f)); Text("${fmtQty(foot)} $unit") }; Row { Text("Floors (approx.)", Modifier.weight(1f)); Text("${kotlin.math.ceil(gfa / foot).toInt()}") } }
                    }
                }
                Text("The ratio comes from your local zoning plan (US FAR, UK plot ratio, Dubai affection plan, Singapore GPR, Japan 容積率…).",
                    Modifier.padding(top = 8.dp), style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}
