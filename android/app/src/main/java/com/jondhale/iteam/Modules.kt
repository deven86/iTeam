package com.jondhale.iteam

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.json.JSONObject

// Modules hub + the shared record engine screens (Khata, Tuition, Rent, Legal, Clinic, Bills, Kids, Travel, Pet Care).

fun specColors(s: BizSpec) = s.colors.map { Color(it) }

/** Small material icon for a module (the iPhone uses SF Symbols). */
fun moduleIcon(module: String) = when (module) {
    "khata" -> Icons.Default.CurrencyRupee
    "tuition" -> Icons.Default.School
    "rent" -> Icons.Default.House
    "legal" -> Icons.Default.Gavel
    "clinic" -> Icons.Default.LocalHospital
    "bills" -> Icons.Default.Receipt
    "kids" -> Icons.Default.ChildCare
    "travel" -> Icons.Default.Flight
    "petcare" -> Icons.Default.Pets
    "build" -> Icons.Default.Apartment
    else -> Icons.Default.Apps
}

@Composable
fun ModuleTile(title: String, sub: String, colors: List<Color>, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    ListItem(modifier = Modifier.clickable(onClick = onClick),
        leadingContent = {
            Box(Modifier.size(44.dp).background(Brush.linearGradient(colors), RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
                Icon(icon, null, tint = Color.White)
            }
        },
        headlineContent = { Text(title, fontWeight = FontWeight.SemiBold) },
        supportingContent = { Text(sub, maxLines = 1, overflow = TextOverflow.Ellipsis) })
}

@Composable
fun StatTiles(vararg tiles: Pair<String, String>) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        tiles.forEach { (v, l) ->
            Card(Modifier.weight(1f)) {
                Column(Modifier.padding(10.dp)) {
                    Text(v, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(l, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                }
            }
        }
    }
}

@Composable
fun SectionHeader(text: String, action: String? = null, onAction: () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        if (action != null) TextButton(onAction) { Icon(Icons.Default.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text(action) }
    }
}

// MARK: - Hub

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModulesHub(app: AppState, onBack: () -> Unit, open: (Page) -> Unit) {
    val counts = remember(app.tick) { app.store.bizList().filter { !it.deleted }.groupingBy { it.module }.eachCount() }
    val projects = remember(app.tick) { app.store.buildList().count { it.bkind == "project" && !it.deleted } }
    Scaffold(topBar = { TopAppBar(title = { Text("Modules") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                Text("All modules are free on Android. They sync with iPhone and iPad through your chats.", Modifier.padding(16.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                ModuleTile("Builder & Infra", if (projects > 0) "$projects projects" else "Projects, units, sales, stock, approvals, FSI",
                    listOf(Color(0xFFF7971E), Color(0xFF8E2DE2)), moduleIcon("build")) { open(Page.Builder) }
            }
            items(BizSpecs.all, key = { it.module }) { s ->
                val n = counts[s.module] ?: 0
                ModuleTile(s.title, if (n > 0) "$n records" else (s.parent?.plural ?: s.children.first().plural), specColors(s), moduleIcon(s.module)) { open(Page.BizModule(s.module)) }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

// MARK: - Module home (dashboard first)

private fun Rec.whenMs(): Long? = due ?: date
private fun isDone(spec: BizSpec, r: Rec) = spec.kind(r.kind)?.doneStatuses?.contains(r.status) == true

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BizModuleScreen(app: AppState, module: String, onBack: () -> Unit, open: (Page) -> Unit) {
    val spec = BizSpecs.spec(module) ?: return
    val me = app.store.me
    val all = remember(app.tick) { app.store.bizList(module).filter { !it.deleted } }
    val mine = all.filter { it.subjectID != me || it.owner == me }
    val shared = all.filter { it.subjectID == me && it.owner != me }
    val parents = if (spec.parent != null) mine.filter { it.kind == spec.parent.id } else emptyList()
    val now = System.currentTimeMillis()
    val week = now + 7 * 86_400_000L
    val upcoming = mine.filter { r -> r.kind != spec.parent?.id && !isDone(spec, r) && (r.whenMs()?.let { it < week } ?: false) }.sortedBy { it.whenMs() }
    val balance = if (spec.parent != null) parents.sumOf { p -> Biz.balance(spec, mine.filter { it.parentID == p.id }) } else Biz.balance(spec, mine)
    var adding by remember { mutableStateOf<BizKind?>(null) }
    var editing by remember { mutableStateOf<Rec?>(null) }

    Scaffold(topBar = { TopAppBar(title = { Text(spec.title) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(onClick = { adding = spec.parent ?: spec.flat }, icon = { Icon(Icons.Default.Add, null) },
                text = { Text("New ${(spec.parent ?: spec.flat)?.label?.lowercase() ?: "entry"}") })
        }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                StatTiles(
                    (if (spec.parent != null) "${parents.size}" else "${mine.size}") to (spec.parent?.plural ?: spec.flat?.plural ?: "Entries"),
                    money(balance) to spec.balanceLabel,
                    "${upcoming.size}" to "Next 7 days",
                )
            }
            if (upcoming.isNotEmpty()) {
                item { SectionHeader("Needs attention") }
                items(upcoming.take(8), key = { "u" + it.id }) { r ->
                    val parent = mine.firstOrNull { it.id == r.parentID }
                    BizRow(spec, r, parent?.title) { if (parent != null) open(Page.BizParent(module, parent.id)) else editing = r }
                }
            }
            if (spec.parent != null) {
                item { SectionHeader(spec.parent.plural) }
                if (parents.isEmpty()) item { Empty("No ${spec.parent.plural.lowercase()} yet. Tap New to add one.") }
                items(parents.sortedBy { it.title.lowercase() }, key = { it.id }) { p ->
                    val bal = Biz.balance(spec, mine.filter { it.parentID == p.id })
                    ListItem(modifier = Modifier.clickable { open(Page.BizParent(module, p.id)) },
                        leadingContent = { Avatar(p.title.ifEmpty { "?" }, 40) },
                        headlineContent = { Text(p.title.ifEmpty { "(no name)" }) },
                        supportingContent = { Text(listOf(p.s("subtitle"), p.status, if (p.subjectID.isNotEmpty()) "🔗 ${app.store.name(p.subjectID)}" else "").filter { it.isNotEmpty() }.joinToString(" · ")) },
                        trailingContent = { if (bal != 0.0) Text(money(bal), fontWeight = FontWeight.SemiBold) })
                }
            } else {
                item { SectionHeader(spec.flat?.plural ?: "Entries") }
                if (mine.isEmpty()) item { Empty("Nothing here yet. Tap New to add one.") }
                items(mine.sortedWith(compareBy({ isDone(spec, it) }, { it.whenMs() ?: Long.MAX_VALUE })), key = { it.id }) { r -> BizRow(spec, r, null) { editing = r } }
            }
            if (shared.isNotEmpty()) {
                item { SectionHeader("Shared with me") }
                val tops = shared.filter { it.parentID.isEmpty() || shared.none { s -> s.id == it.parentID } }
                items(tops, key = { "s" + it.id }) { r ->
                    ListItem(modifier = Modifier.clickable { open(Page.BizParent(module, if (r.kind == spec.parent?.id) r.id else r.parentID.ifEmpty { r.id })) },
                        headlineContent = { Text(r.title.ifEmpty { spec.kind(r.kind)?.label ?: "" }) },
                        supportingContent = { Text("Managed by ${app.store.name(r.owner)}") })
                }
            }
            item { Spacer(Modifier.height(90.dp)) }
        }
    }
    adding?.let { k -> BizEditor(app, spec, k, null, null) { adding = null } }
    editing?.let { r -> BizEditor(app, spec, spec.kind(r.kind) ?: return@let, r, null) { editing = null } }
}

@Composable
fun Empty(text: String) = Text(text, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)

@Composable
private fun BizRow(spec: BizSpec, r: Rec, parentTitle: String?, onClick: () -> Unit) {
    val k = spec.kind(r.kind)
    val whenMs = r.due ?: r.date
    ListItem(modifier = Modifier.clickable(onClick = onClick),
        overlineContent = { Text(listOfNotNull(k?.label, parentTitle).joinToString(" · ")) },
        headlineContent = { Text(r.title.ifEmpty { r.s("notes").ifEmpty { k?.label ?: "" } }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(listOf(whenMs?.let { dateText(it) } ?: "", r.status).filter { it.isNotEmpty() }.joinToString(" · ")) },
        trailingContent = { if (r.amount != 0.0) Text(money(r.amount), fontWeight = FontWeight.SemiBold) })
}

// MARK: - Parent detail (customer, student, tenant, matter, patient, child, trip, pet)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BizParentScreen(app: AppState, module: String, id: String, onBack: () -> Unit) {
    val spec = BizSpecs.spec(module) ?: return
    val me = app.store.me
    val parent = remember(app.tick) { app.store.bizRec(id) }
    val kids = remember(app.tick) { app.store.bizList(module).filter { it.parentID == id && !it.deleted } }
    val owner = parent == null || parent.owner == me
    var adding by remember { mutableStateOf<BizKind?>(null) }
    var editing by remember { mutableStateOf<Rec?>(null) }
    var editParent by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Scaffold(topBar = {
        TopAppBar(title = { Text(parent?.title ?: spec.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = {
                if (owner && parent != null) {
                    IconButton({ editParent = true }) { Icon(Icons.Default.Edit, "Edit") }
                    IconButton({ confirmDelete = true }) { Icon(Icons.Default.Delete, "Delete") }
                }
            })
    }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            if (parent != null) item {
                Card(Modifier.fillMaxWidth().padding(12.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Text(parent.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                        listOf(parent.s("subtitle"), parent.s("phone"), parent.status).filter { it.isNotEmpty() }.forEach { Text(it) }
                        parent.whenMs()?.let { Text(dateText(it)) }
                        if (parent.s("notes").isNotEmpty()) Text(parent.s("notes"), style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 4.dp))
                        spec.parent?.extras?.forEach { x -> parent.extra(x).takeIf { it.isNotEmpty() }?.let { Text("$x: $it", style = MaterialTheme.typography.bodySmall) } }
                        if (!owner) Text("Managed by ${app.store.name(parent.owner)}", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
                        else if (parent.subjectID.isNotEmpty()) Text("🔗 Shared with ${app.store.name(parent.subjectID)} — they see only their own records", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
                        val bal = Biz.balance(spec, kids)
                        if (bal != 0.0) Text("${spec.balanceLabel}: ${money(bal)}", fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
            spec.children.forEach { k ->
                val list = kids.filter { it.kind == k.id }.sortedByDescending { it.whenMs() ?: it.created }
                val canAdd = owner || k.clientCanAdd
                item(key = "h" + k.id) { SectionHeader(k.plural, if (canAdd) "Add" else null) { adding = k } }
                if (list.isEmpty()) item(key = "e" + k.id) { Text("None", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(list, key = { it.id }) { r -> BizRow(spec, r, null) { editing = r } }
            }
            item { Spacer(Modifier.height(40.dp)) }
        }
    }
    adding?.let { k -> BizEditor(app, spec, k, null, parent) { adding = null } }
    editing?.let { r ->
        val k = spec.kind(r.kind)
        if (k != null) {
            if (r.owner == me || owner) BizEditor(app, spec, k, r, parent) { editing = null }
            else ClientAnswer(app, k, r) { editing = null }
        }
    }
    if (editParent && parent != null && spec.parent != null) BizEditor(app, spec, spec.parent, parent, null) { editParent = false }
    if (confirmDelete && parent != null) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete “${parent.title}”?") },
        text = { Text("It stays visible as deleted to anyone it was shared with.") },
        confirmButton = { TextButton({ confirmDelete = false; app.run(scope) { app.sync.deleteBiz(parent) }; onBack() }) { Text("Delete") } },
        dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel") } })
}

/** The linked client answers (approval, e-vakalatnama, homework, agreement) — or just views it. */
@Composable
private fun ClientAnswer(app: AppState, k: BizKind, r: Rec, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var note by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = onDone, title = { Text(r.title.ifEmpty { k.label }) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(k.label, style = MaterialTheme.typography.labelMedium)
                if (r.amount != 0.0) Text(money(r.amount), fontWeight = FontWeight.Bold)
                r.whenMs()?.let { Text(dateText(it)) }
                if (r.status.isNotEmpty()) Text("Status: ${r.status}")
                if (r.s("notes").isNotEmpty()) Text(r.s("notes"), Modifier.padding(top = 6.dp))
                Text("Managed by ${app.store.name(r.owner)}", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 8.dp))
                if (k.clientAnswers) {
                    OutlinedTextField(note, { note = it }, label = { Text("Note (optional)") }, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                    k.statuses.drop(1).forEach { s ->
                        Button({ app.run(scope) { app.sync.saveBiz(JSONObject(r.p.toString()).put("status", s).put("notes", note.ifBlank { r.s("notes") }), r.conv) }; onDone() },
                            Modifier.fillMaxWidth().padding(top = 6.dp), enabled = r.status != s) { Text(s) }
                    }
                }
            }
        },
        confirmButton = { TextButton(onDone) { Text("Close") } })
}

// MARK: - Editor

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BizEditor(app: AppState, spec: BizSpec, kind: BizKind, existing: Rec?, parent: Rec?, onDone: () -> Unit) {
    val p0 = remember { existing?.p?.let { JSONObject(it.toString()) } ?: Biz.new(spec.module, kind.id, parent?.id ?: "") }
    val values = remember { mutableStateMapOf<BK, String>().apply {
        BK.values().forEach { k -> put(k, if (k == BK.amount) p0.optDouble("amount", 0.0).let { if (it == 0.0 || it.isNaN()) "" else (if (it % 1.0 == 0.0) "%.0f".format(it) else "$it") } else p0.optString(k.name)) }
        if (get(BK.status).isNullOrEmpty() && kind.statuses.isNotEmpty()) put(BK.status, kind.statuses.first())
    } }
    val dates = remember { mutableStateMapOf<BK, Long?>().apply { put(BK.date, p0.optDoubleOrNull("date")?.let { SwiftDate.toMillis(it) }); put(BK.due, p0.optDoubleOrNull("due")?.let { SwiftDate.toMillis(it) }) } }
    val extras = remember { mutableStateMapOf<String, String>().apply { kind.extras.forEach { x -> put(x, p0.optJSONObject("extra")?.optString(x) ?: "") } } }
    var subject by remember { mutableStateOf(p0.optString("subjectID")) }
    var pickDate by remember { mutableStateOf<BK?>(null) }
    var pickPerson by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = onDone, title = { Text((if (existing == null) "New " else "Edit ") + kind.label.lowercase()) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                kind.fields.forEach { f ->
                    when (f.key) {
                        BK.date, BK.due -> TextButton({ pickDate = f.key }) {
                            Icon(Icons.Default.Event, null); Spacer(Modifier.width(6.dp))
                            Text("${f.label}: ${dates[f.key]?.let { dateText(it) } ?: "—"}")
                        }
                        BK.status -> if (kind.statuses.isNotEmpty()) {
                            Text(f.label, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
                            FlowRow { kind.statuses.forEach { s -> FilterChip(values[BK.status] == s, { values[BK.status] = s }, label = { Text(s) }, modifier = Modifier.padding(end = 4.dp)) } }
                        } else OutlinedTextField(values[f.key] ?: "", { values[f.key] = it }, label = { Text(f.label) }, modifier = Modifier.fillMaxWidth())
                        else -> if (f.options.isNotEmpty()) {
                            Text(f.label, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 6.dp))
                            FlowRow { f.options.forEach { o -> FilterChip(values[f.key] == o, { values[f.key] = o }, label = { Text(o) }, modifier = Modifier.padding(end = 4.dp)) } }
                        } else OutlinedTextField(values[f.key] ?: "", { values[f.key] = it }, label = { Text(f.label) },
                            modifier = Modifier.fillMaxWidth().padding(top = 4.dp), singleLine = f.key != BK.notes, maxLines = if (f.key == BK.notes) 5 else 1,
                            keyboardOptions = if (f.key == BK.amount) androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Decimal)
                                else if (f.key == BK.phone) androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Phone)
                                else androidx.compose.foundation.text.KeyboardOptions.Default)
                    }
                }
                kind.extras.forEach { x -> OutlinedTextField(extras[x] ?: "", { extras[x] = it }, label = { Text(x) }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp), singleLine = true) }
                if (kind.linkable && parent == null) {
                    TextButton({ pickPerson = true }) {
                        Icon(Icons.Default.Link, null); Spacer(Modifier.width(6.dp))
                        Text(if (subject.isEmpty()) "Link to an iTeam contact (they see their own records)" else "Linked: ${app.store.name(subject)} — change")
                    }
                }
            }
        },
        confirmButton = {
            TextButton({
                val p = p0
                BK.values().forEach { k ->
                    when (k) {
                        BK.amount -> p.put("amount", num(values[k] ?: ""))
                        BK.date, BK.due -> { val d = dates[k]; if (d != null) p.put(k.name, SwiftDate.from(d)) else p.remove(k.name) }
                        else -> p.put(k.name, (values[k] ?: "").trim())
                    }
                }
                if (kind.extras.isNotEmpty()) p.put("extra", JSONObject(extras.toMap().filterValues { it.isNotBlank() } as Map<*, *>))
                val conv: String
                if (parent != null) { p.put("subjectID", parent.subjectID); conv = parent.conv }
                else { p.put("subjectID", subject); conv = if (subject.isNotEmpty()) app.sync.directID(app.store.me, subject) else existing?.conv ?: "" }
                app.run(scope) { app.sync.saveBiz(p, conv) }
                onDone()
            }, enabled = kind.fields.none { it.key == BK.title } || !values[BK.title].isNullOrBlank() || !values[BK.amount].isNullOrBlank()) { Text("Save") }
        },
        dismissButton = {
            Row {
                if (existing != null && existing.owner == app.store.me) TextButton({ app.run(scope) { app.sync.deleteBiz(existing) }; onDone() }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                TextButton(onDone) { Text("Cancel") }
            }
        })
    pickDate?.let { k ->
        val state = rememberDatePickerState(initialSelectedDateMillis = dates[k] ?: System.currentTimeMillis())
        DatePickerDialog(onDismissRequest = { pickDate = null },
            confirmButton = { TextButton({ dates[k] = state.selectedDateMillis?.let { it + 9 * 3_600_000L }; pickDate = null }) { Text("OK") } },
            dismissButton = { TextButton({ dates[k] = null; pickDate = null }) { Text("No date") } }) { DatePicker(state) }
    }
    if (pickPerson) PersonPicker(app, onPick = { subject = it ?: ""; pickPerson = false })
}

/** Pick one contact (or none). */
@Composable
fun PersonPicker(app: AppState, onPick: (String?) -> Unit) {
    val contacts = remember(app.tick) { app.store.contactList().filter { it.userID != app.store.me } }
    AlertDialog(onDismissRequest = { onPick(null) }, title = { Text("Link to a contact") },
        text = {
            LazyColumn(Modifier.heightIn(max = 420.dp)) {
                if (contacts.isEmpty()) item { Text("No contacts yet — add people from Chats first.") }
                items(contacts, key = { it.userID }) { c -> ListItem(modifier = Modifier.clickable { onPick(c.userID) }, leadingContent = { Avatar(c.name, 36) }, headlineContent = { Text(c.name) }) }
            }
        },
        confirmButton = { TextButton({ onPick(null) }) { Text("Not linked") } })
}
