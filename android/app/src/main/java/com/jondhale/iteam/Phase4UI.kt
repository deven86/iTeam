package com.jondhale.iteam

import android.Manifest
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.PendingIntent
import android.widget.RemoteViews
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.random.Random

// Phase 4: mini (Views), Events, Family Safety + Check In, Care, Fluffy Fight practice, home-screen widget.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun P4Screen(title: String, onBack: (() -> Unit)?, fab: (@Composable () -> Unit)? = null, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Scaffold(topBar = { TopAppBar(title = { Text(title) }, navigationIcon = { onBack?.let { b -> IconButton(b) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } } }) },
        floatingActionButton = { fab?.invoke() }) { pad -> LazyColumn(Modifier.padding(pad), content = content) }
}

private fun Sync.selfConv(): String {
    val id = "s_$me"
    synchronized(store) { store.convs.getOrPut(id) { Conv(id, "Notes to self", listOf(me)) } }
    return id
}

// MARK: - mini (Views)

@Composable
fun ViewsScreen(app: AppState, onBack: (() -> Unit)?) {
    val now = System.currentTimeMillis()
    val posts = remember(app.tick) { app.store.miscList("post").filter { !it.deleted && (it.p.optDoubleOrNull("expires")?.let { e -> SwiftDate.toMillis(e) > now } ?: true) }.sortedByDescending { it.created } }
    val statuses = posts.filter { it.p.optBoolean("status") }.groupBy { it.owner }
    var composing by remember { mutableStateOf<Boolean?>(null) }
    var comment by remember { mutableStateOf<Rec?>(null) }
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    P4Screen("mini", onBack, { ExtendedFloatingActionButton(onClick = { composing = false }, icon = { Icon(Icons.Default.Edit, null) }, text = { Text("Post") }) }) {
        item {
            LazyRow(Modifier.padding(12.dp)) {
                item { Column(Modifier.padding(end = 12.dp).clickable { composing = true }, horizontalAlignment = Alignment.CenterHorizontally) {
                    Box { Avatar(app.store.myName, 60, photo = app.store.pref("photo")); Icon(Icons.Default.AddCircle, null, Modifier.align(Alignment.BottomEnd), tint = MaterialTheme.colorScheme.primary) }
                    Text("My mini", style = MaterialTheme.typography.labelSmall) } }
                items(statuses.keys.filter { it != app.store.me }.toList()) { u -> Column(Modifier.padding(end = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Avatar(app.store.name(u), 60, photo = app.store.photoOf(u)); Text(app.store.name(u).substringBefore(" "), style = MaterialTheme.typography.labelSmall) } }
            }
            HorizontalDivider()
        }
        if (posts.isEmpty()) item { Empty("Nothing yet. Share a moment or a 24-hour mini with the people you chat with.") }
        items(posts, key = { it.id }) { r ->
            Card(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Avatar(app.store.name(r.owner), 36, photo = app.store.photoOf(r.owner)); Spacer(Modifier.width(8.dp))
                        Column(Modifier.weight(1f)) { Text(app.store.name(r.owner), fontWeight = FontWeight.SemiBold); Text((if (r.p.optBoolean("status")) "mini · " else "") + time(r.created), style = MaterialTheme.typography.labelSmall) }
                        if (r.owner == app.store.me) IconButton({ app.run(scope) { app.sync.deletePost(r) } }) { Icon(Icons.Default.Delete, "Delete") }
                    }
                    if (r.s("text").isNotEmpty()) Text(r.s("text"), Modifier.padding(top = 6.dp))
                    Att.list(r.p.optJSONArray("media")).forEach { a -> AttachmentView(app, a, MaterialTheme.colorScheme.onSurface) { f -> Media.open(ctx, f, a) } }
                    val reacts = r.p.optJSONObject("reacts"); val mine = reacts?.optString(app.store.me).orEmpty()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton({ app.run(scope) { app.sync.reactPost(r, if (mine.isEmpty()) "❤️" else null) } }) { Text(if (mine.isEmpty()) "🤍 Like" else "❤️ Liked") }
                        Text("${reacts?.length() ?: 0}", style = MaterialTheme.typography.labelSmall)
                        TextButton({ comment = r }) { Text("💬 ${r.p.optJSONArray("comments")?.length() ?: 0}") }
                    }
                    r.p.optJSONArray("comments")?.let { a -> (0 until a.length()).mapNotNull { a.optJSONObject(it) }.filter { !it.optBoolean("deleted") }.takeLast(3).forEach { c ->
                        Text("${app.store.name(c.optString("from"))}: ${c.optString("text")}", style = MaterialTheme.typography.bodySmall) } }
                }
            }
        }
        item { Spacer(Modifier.height(90.dp)) }
    }
    composing?.let { status -> PostComposer(app, status) { composing = null } }
    comment?.let { r ->
        var t by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = { comment = null }, title = { Text("Comment") }, text = { OutlinedTextField(t, { t = it }, modifier = Modifier.fillMaxWidth()) },
            confirmButton = { TextButton({ app.run(scope) { app.sync.commentPost(r, t.trim()) }; comment = null }, enabled = t.isNotBlank()) { Text("Send") } })
    }
}

@Composable
private fun PostComposer(app: AppState, status: Boolean, onDone: () -> Unit) {
    val ctx = LocalContext.current
    var text by remember { mutableStateOf("") }
    var photo by remember { mutableStateOf<Media.Prepared?>(null) }
    val chats = remember { app.store.convList().filter { !it.left && !it.id.startsWith("s_") } }
    val picked = remember { mutableStateListOf<String>().apply { addAll(chats.filter { !it.isGroup }.map { it.id }) } }
    val scope = rememberCoroutineScope()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { photo = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { Media.image(ctx, uri) }.getOrNull() } }
    }
    AlertDialog(onDismissRequest = onDone, title = { Text(if (status) "New mini (24 hours)" else "New post") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(text, { text = it }, label = { Text("What's happening?") }, minLines = 3, modifier = Modifier.fillMaxWidth())
            TextButton({ pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) { Icon(Icons.Default.Image, null); Spacer(Modifier.width(6.dp)); Text(if (photo == null) "Add photo" else "Photo added ✓") }
            Text("Who sees it", style = MaterialTheme.typography.labelMedium)
            chats.forEach { c -> Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(c.id in picked, { if (it) picked.add(c.id) else picked.remove(c.id) }); Text(c.title) } }
        }
    }, confirmButton = { TextButton({
        val p = photo
        app.run(scope) { app.sync.publishPost(text.trim(), listOfNotNull(p?.att), p?.let { mapOf(it.blob) } ?: emptyMap(), status, picked.toList()) }
        onDone()
    }, enabled = (text.isNotBlank() || photo != null) && picked.isNotEmpty()) { Text("Share") } }, dismissButton = { TextButton(onDone) { Text("Cancel") } })
}

// MARK: - Events

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EventsScreen(app: AppState, onBack: (() -> Unit)?) {
    val now = System.currentTimeMillis()
    val all = remember(app.tick) { app.store.miscList("event").filter { !it.deleted }.sortedBy { it.p.optDouble("start") } }
    val upcoming = all.filter { SwiftDate.toMillis(it.p.optDouble("end", it.p.optDouble("start"))) >= now - 3_600_000 }
    var creating by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    P4Screen("Events", onBack, { ExtendedFloatingActionButton(onClick = { creating = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text("New event") }) }) {
        item { StatTiles("${upcoming.size}" to "Upcoming", "${upcoming.count { it.p.optJSONObject("rsvps")?.optString(app.store.me) == "going" || it.owner == app.store.me }}" to "Going", "${all.size - upcoming.size}" to "Past") }
        if (upcoming.isEmpty()) item { Empty("Invite a chat or group to a birthday, puja, meeting or trip — everyone answers Going / Maybe / Can't.") }
        items(upcoming, key = { it.id }) { e ->
            val start = SwiftDate.toMillis(e.p.optDouble("start"))
            val rs = e.p.optJSONObject("rsvps"); val mine = rs?.optString(app.store.me).orEmpty()
            val counts = listOf("going", "maybe", "no").associateWith { a -> rs?.let { o -> o.keys().asSequence().count { o.optString(it) == a } } ?: 0 }
            Card(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) { Column(Modifier.padding(14.dp)) {
                Text("🎉 " + e.s("title"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text("${dateText(start)} · ${time(start)}${if (e.s("place").isEmpty()) "" else " · " + e.s("place")}")
                Text("${app.store.conv(e.conv)?.title ?: ""} · by ${app.store.name(e.owner)}", style = MaterialTheme.typography.labelSmall)
                if (e.s("notes").isNotEmpty()) Text(e.s("notes"), style = MaterialTheme.typography.bodySmall)
                Text("✅ ${counts["going"]}  🤔 ${counts["maybe"]}  ✋ ${counts["no"]}", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 4.dp))
                Row {
                    listOf("going" to "Going", "maybe" to "Maybe", "no" to "Can't").forEach { (k, t) -> FilterChip(mine == k, { app.run(scope) { app.sync.rsvp(e, k) } }, { Text(t) }, Modifier.padding(end = 4.dp)) }
                    if (e.owner == app.store.me) TextButton({ app.run(scope) { app.sync.saveEvent(e.conv, e, e.s("title"), e.s("place"), start, SwiftDate.toMillis(e.p.optDouble("end")), e.s("notes"), true) } }) { Text("Cancel", color = MaterialTheme.colorScheme.error) }
                }
            } }
        }
        item { Spacer(Modifier.height(90.dp)) }
    }
    if (creating) {
        var title by remember { mutableStateOf("") }; var place by remember { mutableStateOf("") }; var notes by remember { mutableStateOf("") }
        var start by remember { mutableLongStateOf(System.currentTimeMillis() + 86_400_000L) }; var hours by remember { mutableIntStateOf(2) }
        var conv by remember { mutableStateOf("") }; var pickDate by remember { mutableStateOf(false) }; var hour by remember { mutableIntStateOf(18) }
        val chats = remember { app.store.convList().filter { !it.left && !it.id.startsWith("s_") } }
        AlertDialog(onDismissRequest = { creating = false }, title = { Text("New event") }, text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(title, { title = it }, label = { Text("What") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(place, { place = it }, label = { Text("Where") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            TextButton({ pickDate = true }) { Text("Date: ${dateText(start)}") }
            Text("Time: ${AttData.clock(hour * 60)} · ${hours} h"); Slider(hour.toFloat(), { hour = it.toInt() }, valueRange = 6f..23f)
            Row { listOf(1, 2, 3, 6).forEach { h -> FilterChip(hours == h, { hours = h }, { Text("$h h") }, Modifier.padding(end = 4.dp)) } }
            OutlinedTextField(notes, { notes = it }, label = { Text("Notes") }, modifier = Modifier.fillMaxWidth())
            Text("Invite", style = MaterialTheme.typography.labelMedium)
            chats.forEach { c -> Row(Modifier.clickable { conv = c.id }, verticalAlignment = Alignment.CenterVertically) { RadioButton(conv == c.id, { conv = c.id }); Text(c.title) } }
        } }, confirmButton = { TextButton({
            val s = java.util.Calendar.getInstance().apply { timeInMillis = start; set(java.util.Calendar.HOUR_OF_DAY, hour); set(java.util.Calendar.MINUTE, 0) }.timeInMillis
            app.run(scope) { app.sync.saveEvent(conv, null, title.trim(), place.trim(), s, s + hours * 3_600_000L, notes.trim()) }; creating = false
        }, enabled = title.isNotBlank() && conv.isNotEmpty()) { Text("Invite") } }, dismissButton = { TextButton({ creating = false }) { Text("Cancel") } })
        if (pickDate) {
            val st = rememberDatePickerState(initialSelectedDateMillis = start)
            DatePickerDialog(onDismissRequest = { pickDate = false }, confirmButton = { TextButton({ st.selectedDateMillis?.let { start = it }; pickDate = false }) { Text("OK") } }) { DatePicker(st) }
        }
    }
}

// MARK: - Family Safety

@Composable
fun SafetyScreen(app: AppState, onBack: (() -> Unit)?) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var targets by remember { mutableStateOf(app.store.prefList("sosChats", emptyList())) }
    var choose by remember { mutableStateOf(false) }
    var checkIn by remember { mutableStateOf(false) }
    var lastSent by remember { mutableStateOf("") }
    val checkins = remember(app.tick) { app.store.miscList("checkin").filter { it.status == "active" }.sortedByDescending { it.created } }
    val perm = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    fun broadcast(text: String) = app.run(scope) { targets.forEach { runCatching { app.sync.sendText(it, text) } } }
    fun sos() {
        scope.launch {
            val l = runCatching { Nearby.locate(ctx) }.getOrNull()
            var text = "🆘 SOS from ${app.store.myName} — I need help."
            text += if (l != null) "\nLocation: https://www.google.com/maps?q=${l.latitude},${l.longitude}\nApple Maps: https://maps.apple.com/?q=${l.latitude},${l.longitude}" else "\n(Location unavailable — please call me.)"
            broadcast(text); lastSent = "SOS sent at ${time(System.currentTimeMillis())}"
        }
    }
    LaunchedEffect(Unit) { perm.launch(Manifest.permission.ACCESS_COARSE_LOCATION) }
    P4Screen("Family Safety", onBack) {
        item {
            Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                var holding by remember { mutableStateOf(false) }
                Box(Modifier.size(180.dp).background(Brush.radialGradient(listOf(Color(0xFFFF416C), Color(0xFFB31217))), CircleShape)
                    .scale(if (holding) 0.94f else 1f)
                    .pointerInput(targets) { detectTapGestures(onPress = {
                        if (targets.isEmpty()) { choose = true; return@detectTapGestures }
                        holding = true
                        val held = kotlinx.coroutines.withTimeoutOrNull(2000) { tryAwaitRelease() }
                        holding = false
                        if (held == null) sos()
                    }) }, contentAlignment = Alignment.Center) {
                    Text("SOS", color = Color.White, fontSize = 44.sp, fontWeight = FontWeight.Black)
                }
                Text(if (targets.isEmpty()) "Pick your emergency chats first" else "Hold for 2 seconds — your location goes to ${targets.size} chat(s)", Modifier.padding(top = 10.dp), textAlign = TextAlign.Center)
                if (lastSent.isNotEmpty()) Text(lastSent, color = Color(0xFFB31217), fontWeight = FontWeight.Bold)
                Row(Modifier.padding(top = 12.dp)) {
                    Button({ broadcast("✅ I'm safe — ${app.store.myName}"); lastSent = "“I'm safe” sent" }, enabled = targets.isNotEmpty()) { Text("I'm safe") }
                    Spacer(Modifier.width(8.dp))
                    OutlinedButton({ ctx.startActivity(Intent(Intent.ACTION_DIAL, android.net.Uri.parse("tel:112"))) }) { Icon(Icons.Default.Phone, null); Text(" Call 112") }
                }
                TextButton({ choose = true }) { Text("Emergency chats (${targets.size})") }
                OutlinedButton({ checkIn = true }) { Icon(Icons.Default.LocationOn, null); Text(" Start a Check In") }
            }
        }
        if (checkins.isNotEmpty()) { item { SectionHeader("Active Check Ins") }
            items(checkins, key = { it.id }) { c ->
                val mine = c.owner == app.store.me
                ListItem(headlineContent = { Text("${if (mine) "You" else app.store.name(c.owner)} → ${c.s("place")}") },
                    supportingContent = { Text("Expected by ${time(SwiftDate.toMillis(c.p.optDouble("eta")))}") },
                    trailingContent = { if (mine) Row {
                        TextButton({ app.run(scope) { app.sync.checkIn(c.conv, c, c.s("place"), c.p.optDouble("lat"), c.p.optDouble("lon"), SwiftDate.toMillis(c.p.optDouble("eta")), "arrived") } }) { Text("Arrived") }
                        TextButton({ app.run(scope) { app.sync.checkIn(c.conv, c, c.s("place"), c.p.optDouble("lat"), c.p.optDouble("lon"), SwiftDate.toMillis(c.p.optDouble("eta")), "ended") } }) { Text("End") }
                    } else IconButton({ ctx.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://www.google.com/maps?q=${c.p.optDouble("lat")},${c.p.optDouble("lon")}"))) }) { Icon(Icons.Default.Map, "Map") } })
            } }
    }
    if (choose) {
        val chats = remember { app.store.convList().filter { !it.left && !it.id.startsWith("s_") } }
        val sel = remember { mutableStateListOf<String>().apply { addAll(targets) } }
        AlertDialog(onDismissRequest = { choose = false }, title = { Text("Emergency chats") }, text = { LazyColumn(Modifier.heightIn(max = 420.dp)) {
            items(chats, key = { it.id }) { c -> Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(c.id in sel, { if (it) sel.add(c.id) else sel.remove(c.id) }); Text(c.title) } } } },
            confirmButton = { TextButton({ targets = sel.toList(); app.store.setPref("sosChats", targets); choose = false }) { Text("Done") } })
    }
    if (checkIn) {
        var place by remember { mutableStateOf("") }; var mins by remember { mutableIntStateOf(30) }; var conv by remember { mutableStateOf(targets.firstOrNull() ?: "") }
        val chats = remember { app.store.convList().filter { !it.left && !it.id.startsWith("s_") } }
        AlertDialog(onDismissRequest = { checkIn = false }, title = { Text("Check In") }, text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(place, { place = it }, label = { Text("Going to (e.g. Home)") }, singleLine = true)
            Row { listOf(15, 30, 60, 120).forEach { m -> FilterChip(mins == m, { mins = m }, { Text(if (m < 60) "$m min" else "${m / 60} h") }, Modifier.padding(end = 4.dp)) } }
            chats.forEach { c -> Row(Modifier.clickable { conv = c.id }, verticalAlignment = Alignment.CenterVertically) { RadioButton(conv == c.id, { conv = c.id }); Text(c.title) } }
        } }, confirmButton = { TextButton({
            scope.launch { val l = runCatching { Nearby.locate(ctx) }.getOrNull()
                app.run(scope) { app.sync.checkIn(conv, null, place.trim(), l?.latitude ?: 0.0, l?.longitude ?: 0.0, System.currentTimeMillis() + mins * 60_000L, "active") } }
            checkIn = false
        }, enabled = place.isNotBlank() && conv.isNotEmpty()) { Text("Start") } }, dismissButton = { TextButton({ checkIn = false }) { Text("Cancel") } })
    }
}

// MARK: - Care

@Composable
fun CareScreen(app: AppState, onBack: (() -> Unit)?) {
    val profiles = remember(app.tick) { app.store.miscList("care").filter { !it.deleted } }
    val meds = remember(app.tick) { app.store.miscList("med").filter { !it.deleted && it.p.optBoolean("active", true) } }
    val doses = remember(app.tick) { app.store.miscList("dose").associateBy { it.id } }
    var addProfile by remember { mutableStateOf(false) }
    var addMed by remember { mutableStateOf<Rec?>(null) }
    val scope = rememberCoroutineScope()
    val cal = java.util.Calendar.getInstance()
    val todayStart = cal.apply { set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0) }.timeInMillis
    val today = meds.flatMap { m -> (m.p.optJSONArray("times")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: emptyList()).map { t -> m to todayStart + t * 60_000L } }
        .filter { (m, _) -> m.p.optDoubleOrNull("endDate")?.let { SwiftDate.toMillis(it) > System.currentTimeMillis() } ?: true }.sortedBy { it.second }
    P4Screen("Care", onBack, { ExtendedFloatingActionButton(onClick = { addProfile = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text("Person") }) }) {
        item { StatTiles("${profiles.size}" to "People", "${today.size}" to "Doses today", "${today.count { (m, t) -> doses["${m.id}@${t / 60000}"]?.status == "taken" }}" to "Taken") }
        if (today.isNotEmpty()) { item { SectionHeader("Today") }
            items(today, key = { "${it.first.id}@${it.second}" }) { (m, t) ->
                val prof = profiles.firstOrNull { it.id == m.s("profileID") }
                val d = doses["${m.id}@${t / 60000}"]
                ListItem(headlineContent = { Text("${time(t)} · ${m.s("name")} ${m.s("dose")}") }, supportingContent = { Text("${prof?.s("name") ?: ""}${d?.let { " · ${it.status} by ${app.store.name(it.s("by"))}" } ?: ""}") },
                    trailingContent = { if (d == null && prof != null) Row {
                        TextButton({ app.run(scope) { app.sync.logDose(m, prof, t, true) } }) { Text("Taken") }
                        TextButton({ app.run(scope) { app.sync.logDose(m, prof, t, false) } }) { Text("Skip") }
                    } })
            } }
        item { SectionHeader("People") }
        if (profiles.isEmpty()) item { Empty("Add a parent, child or yourself — medicines with Taken / Skip for the whole family, shared in your chat.") }
        items(profiles, key = { it.id }) { p ->
            Card(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) { Column(Modifier.padding(12.dp)) {
                Text("${p.s("name")}${if (p.s("relation").isEmpty()) "" else " · " + p.s("relation")}", fontWeight = FontWeight.Bold)
                listOf("Blood ${p.s("bloodGroup")}".takeIf { p.s("bloodGroup").isNotEmpty() }, p.s("allergies").takeIf { it.isNotEmpty() }?.let { "Allergies: $it" },
                    p.s("emergencyContact").takeIf { it.isNotEmpty() }?.let { "Emergency: $it" }).filterNotNull().forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
                meds.filter { it.s("profileID") == p.id }.forEach { m -> Text("💊 ${m.s("name")} ${m.s("dose")} — ${(m.p.optJSONArray("times")?.let { a -> (0 until a.length()).map { AttData.clock(a.optInt(it)) } } ?: emptyList()).joinToString()}", style = MaterialTheme.typography.bodySmall) }
                TextButton({ addMed = p }) { Text("Add medicine") }
            } }
        }
        item { Spacer(Modifier.height(90.dp)) }
    }
    if (addProfile) {
        var name by remember { mutableStateOf("") }; var rel by remember { mutableStateOf("Self") }; var blood by remember { mutableStateOf("") }; var allergies by remember { mutableStateOf("") }; var emer by remember { mutableStateOf("") }
        var conv by remember { mutableStateOf("") }
        val chats = remember { app.store.convList().filter { !it.left && !it.id.startsWith("s_") } }
        AlertDialog(onDismissRequest = { addProfile = false }, title = { Text("Add person") }, text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
            Row(Modifier.horizontalScroll(rememberScrollState())) { listOf("Self", "Mother", "Father", "Child", "Spouse", "Grandparent", "Patient", "Other").forEach { r -> FilterChip(rel == r, { rel = r }, { Text(r) }, Modifier.padding(end = 4.dp)) } }
            OutlinedTextField(blood, { blood = it }, label = { Text("Blood group") }, singleLine = true)
            OutlinedTextField(allergies, { allergies = it }, label = { Text("Allergies") }, singleLine = true)
            OutlinedTextField(emer, { emer = it }, label = { Text("Emergency contact") }, singleLine = true)
            Text("Share with (family chat) — or keep on this phone", style = MaterialTheme.typography.labelMedium)
            Row(Modifier.clickable { conv = "" }, verticalAlignment = Alignment.CenterVertically) { RadioButton(conv == "", { conv = "" }); Text("Only me") }
            chats.forEach { c -> Row(Modifier.clickable { conv = c.id }, verticalAlignment = Alignment.CenterVertically) { RadioButton(conv == c.id, { conv = c.id }); Text(c.title) } }
        } }, confirmButton = { TextButton({
            app.run(scope) { app.sync.saveCareProfile(conv.ifEmpty { app.sync.selfConv() }, null, name.trim(), rel, blood.trim(), allergies.trim(), "", emer.trim(), "") }; addProfile = false
        }, enabled = name.isNotBlank()) { Text("Save") } }, dismissButton = { TextButton({ addProfile = false }) { Text("Cancel") } })
    }
    addMed?.let { p ->
        var name by remember { mutableStateOf("") }; var dose by remember { mutableStateOf("") }; val times = remember { mutableStateListOf(540) }
        AlertDialog(onDismissRequest = { addMed = null }, title = { Text("Medicine for ${p.s("name")}") }, text = { Column {
            OutlinedTextField(name, { name = it }, label = { Text("Medicine") }, singleLine = true)
            OutlinedTextField(dose, { dose = it }, label = { Text("Dose (e.g. 1 tablet)") }, singleLine = true)
            Text("Times", style = MaterialTheme.typography.labelMedium)
            Row(Modifier.horizontalScroll(rememberScrollState())) { listOf(420, 540, 780, 1020, 1260).forEach { t -> FilterChip(t in times, { if (t in times) times.remove(t) else times.add(t) }, { Text(AttData.clock(t)) }, Modifier.padding(end = 4.dp)) } }
        } }, confirmButton = { TextButton({ app.run(scope) { app.sync.saveMedicine(p, null, name.trim(), dose.trim(), "Tablet", times.sorted(), "") }; addMed = null }, enabled = name.isNotBlank() && times.isNotEmpty()) { Text("Save") } },
            dismissButton = { TextButton({ addMed = null }) { Text("Cancel") } })
    }
}

// MARK: - Fluffy Fight (practice against the computer)

private class FighterState(val f: Fighter, var x: Float, var hp: Float = 100f, var pose: String = "idle", var poseUntil: Long = 0, var blocking: Boolean = false, var superCharge: Float = 0f)

@Composable
fun FightPractice(onBack: () -> Unit) {
    val ctx = LocalContext.current
    var me by remember { mutableStateOf<Fighter?>(null) }
    var cpu by remember { mutableStateOf<Fighter?>(null) }
    var level by remember { mutableIntStateOf(1) }
    if (me == null || cpu == null) {
        P4Screen("Fluffy Fight · Practice", onBack) {
            item { Text("Pick your fighter, then your opponent. Practice is against the computer — online fights stay on iPhone.", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall) }
            item { Row(Modifier.padding(horizontal = 16.dp)) { listOf(1 to "Easy", 2 to "Normal", 3 to "Hard").forEach { (l, t) -> FilterChip(level == l, { level = l }, { Text(t) }, Modifier.padding(end = 4.dp)) } } }
            item { SectionHeader(if (me == null) "Choose your fighter" else "Choose your opponent") }
            items(fighters.chunked(3)) { row ->
                Row(Modifier.padding(horizontal = 8.dp)) { row.forEach { f ->
                    val id = remember(f.id) { ctx.resources.getIdentifier("fx_${f.id}_idle", "drawable", ctx.packageName) }
                    Column(Modifier.weight(1f).padding(4.dp).background(Color(f.tint).copy(alpha = 0.2f), RoundedCornerShape(14.dp)).clickable { if (me == null) me = f else cpu = f }.padding(6.dp),
                        horizontalAlignment = Alignment.CenterHorizontally) {
                        if (id != 0) Image(painterResource(id), f.name, Modifier.size(80.dp))
                        Text(f.name, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center, maxLines = 2)
                    }
                }; repeat(3 - row.size) { Spacer(Modifier.weight(1f)) } }
            }
        }
        return
    }
    FightArena(me!!, cpu!!, level, onBack = { me = null; cpu = null })
}

@Composable
private fun FightArena(meF: Fighter, cpuF: Fighter, level: Int, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val p1 = remember { FighterState(meF, 0.25f) }
    val p2 = remember { FighterState(cpuF, 0.75f) }
    var frame by remember { mutableIntStateOf(0) }
    var msg by remember { mutableStateOf("Fight!") }
    var moveDir by remember { mutableIntStateOf(0) }
    var over by remember { mutableStateOf(false) }
    fun now() = System.currentTimeMillis()
    fun attack(a: FighterState, d: FighterState, kind: String) {
        if (over || now() < a.poseUntil) return
        a.pose = kind; a.poseUntil = now() + if (kind == "super") 600 else 320; a.blocking = false
        val reach = if (kind == "kick") 0.22f else 0.17f
        if (abs(a.x - d.x) <= reach || kind == "super") {
            var dmg = when (kind) { "kick" -> 9f; "super" -> 22f; else -> 6f } * a.f.power
            if (d.blocking) dmg *= (0.25f / d.f.guard)
            d.hp = (d.hp - dmg).coerceAtLeast(0f)
            a.superCharge = (a.superCharge + dmg * 2).coerceAtMost(100f)
            d.x = (d.x + (if (d.x > a.x) 0.03f else -0.03f)).coerceIn(0.05f, 0.95f)
            msg = if (d.blocking) "${d.f.shield}!" else when (kind) { "kick" -> "${a.f.kick}!"; "super" -> "✨ SUPER ✨"; else -> "${a.f.punch}!" }
        }
        if (kind == "super") a.superCharge = 0f
        if (d.hp <= 0f) { over = true; msg = if (d === p2) "You win! 🌟" else "${cpuF.name} wins — try again" }
    }
    LaunchedEffect(Unit) {
        while (true) {
            delay(33)
            if (!over) {
                if (moveDir != 0 && now() >= p1.poseUntil) p1.x = (p1.x + moveDir * 0.012f * meF.speed).coerceIn(0.05f, 0.95f)
                // Computer: approach, attack in reach, sometimes block.
                val dist = abs(p2.x - p1.x)
                if (now() >= p2.poseUntil) {
                    p2.blocking = p1.pose != "idle" && Random.nextFloat() < 0.15f * level
                    when {
                        dist > 0.18f -> p2.x += (if (p1.x < p2.x) -1 else 1) * 0.008f * cpuF.speed * (0.7f + level * 0.15f)
                        Random.nextFloat() < 0.04f * level -> attack(p2, p1, if (p2.superCharge >= 100f) "super" else if (Random.nextBoolean()) "kick" else "fist")
                    }
                    p2.x = p2.x.coerceIn(0.05f, 0.95f)
                }
                listOf(p1, p2).forEach { if (now() >= it.poseUntil && it.pose != "block") it.pose = if (it.blocking) "block" else "idle" }
            }
            frame++
        }
    }
    if (frame < 0) Text("")
    Column(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF8EC5FC), Color(0xFFE0C3FC))))) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            HpBar(meF.name, p1.hp, p1.superCharge, Modifier.weight(1f)); Spacer(Modifier.width(8.dp)); HpBar(cpuF.name, p2.hp, p2.superCharge, Modifier.weight(1f))
        }
        Text(msg, Modifier.fillMaxWidth(), textAlign = TextAlign.Center, fontWeight = FontWeight.Black, fontSize = 22.sp, color = Color.White)
        BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
            val w = maxWidth
            listOf(p1, p2).forEach { s ->
                val id = remember(s.f.id, s.pose) { ctx.resources.getIdentifier("fx_${s.f.id}_${s.pose}", "drawable", ctx.packageName).takeIf { it != 0 } ?: ctx.resources.getIdentifier("fx_${s.f.id}_idle", "drawable", ctx.packageName) }
                val facesRight = (s === p1) == (p1.x < p2.x)
                val drawnLeft = if (s.pose == "kick" || s.pose == "fist") s.f.kickFacesLeft else true
                val flip = if (drawnLeft) facesRight else !facesRight
                if (id != 0) Image(painterResource(id), s.f.name, Modifier.size(150.dp).offset(x = w * s.x - 75.dp, y = 40.dp).scale(scaleX = if (flip) -1f else 1f, scaleY = 1f))
            }
        }
        if (over) Button(onBack, Modifier.align(Alignment.CenterHorizontally).padding(8.dp)) { Text("Play again") }
        Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Row {
                HoldButton("◀") { moveDir = it * -1 }
                Spacer(Modifier.width(10.dp))
                HoldButton("▶") { moveDir = it }
            }
            Row {
                FightButton("👊") { attack(p1, p2, "fist") }
                FightButton("🦶") { attack(p1, p2, "kick") }
                FightButton("🛡") { p1.blocking = !p1.blocking; p1.pose = if (p1.blocking) "block" else "idle" }
                FightButton(if (p1.superCharge >= 100f) "✨" else "·", enabled = p1.superCharge >= 100f) { attack(p1, p2, "super") }
            }
        }
    }
}

@Composable
private fun HpBar(name: String, hp: Float, sp: Float, modifier: Modifier) = Column(modifier) {
    Text(name, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
    LinearProgressIndicator(progress = { hp / 100f }, Modifier.fillMaxWidth().height(10.dp), color = Color(0xFF34C759))
    LinearProgressIndicator(progress = { sp / 100f }, Modifier.fillMaxWidth().height(4.dp).padding(top = 2.dp), color = Color(0xFFFFCC00))
}

@Composable
private fun FightButton(t: String, enabled: Boolean = true, onClick: () -> Unit) =
    Box(Modifier.padding(4.dp).size(58.dp).background(Color.White.copy(alpha = if (enabled) 0.85f else 0.4f), CircleShape).clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) { Text(t, fontSize = 24.sp) }

@Composable
private fun HoldButton(t: String, onHold: (Int) -> Unit) =
    Box(Modifier.size(62.dp).background(Color.White.copy(alpha = 0.85f), CircleShape).pointerInput(Unit) { detectTapGestures(onPress = { onHold(1); tryAwaitRelease(); onHold(0) }) },
        contentAlignment = Alignment.Center) { Text(t, fontSize = 26.sp) }

// MARK: - Home-screen widget (unread chats + next task)

class ITeamWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) = update(ctx)

    companion object {
        fun update(ctx: Context) {
            val mgr = AppWidgetManager.getInstance(ctx)
            val ids = mgr.getAppWidgetIds(ComponentName(ctx, ITeamWidget::class.java))
            if (ids.isEmpty()) return
            val store = Store.get(ctx)
            val unread = store.unreadTotal()
            val me = store.me
            val next = store.taskList().filter { it.status != "done" && it.assignees.contains(me) && it.answer(me) != "declined" }
                .sortedBy { it.due ?: Long.MAX_VALUE }.firstOrNull()
            val v = RemoteViews(ctx.packageName, R.layout.widget)
            v.setTextViewText(R.id.w_unread, if (unread > 0) "$unread unread" else "No new messages")
            v.setTextViewText(R.id.w_task, next?.let { "☑ ${it.title}${it.due?.let { d -> " · " + dateText(d) } ?: ""}" } ?: "No open tasks")
            val pi = PendingIntent.getActivity(ctx, 0, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            v.setOnClickPendingIntent(R.id.w_root, pi)
            mgr.updateAppWidget(ids, v)
        }
    }
}
