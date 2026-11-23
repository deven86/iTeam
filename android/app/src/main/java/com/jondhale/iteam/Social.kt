package com.jondhale.iteam

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// MARK: - Rooms

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomsTab(app: AppState, open: (Page) -> Unit) {
    var discover by remember { mutableStateOf<List<Rooms.Room>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var search by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        discover = withContext(Dispatchers.IO) { runCatching { app.rooms.discover() }.getOrElse { Rooms.countryRooms } }
        loading = false
    }
    val mine = remember(app.tick) { app.rooms.joinedRooms() }
    val threads = remember(app.tick) { app.rooms.threads() }
    Scaffold(topBar = { TopAppBar(title = { Text("Rooms", fontWeight = FontWeight.Bold) }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item { Text("Meet people under a room name. Private chats are end-to-end encrypted; real contacts are shared only when both tap Reveal.",
                Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            if (threads.isNotEmpty()) {
                item { Text("Private chats", Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.titleSmall) }
                items(threads, key = { it.first + it.second }) { (room, other) ->
                    val m = app.rooms.member(other)
                    val n = app.rooms.unread(room, other)
                    ListItem(modifier = Modifier.clickable { open(Page.RoomDM(room, other)) },
                        leadingContent = { Avatar(m?.alias ?: "?", 40) },
                        headlineContent = { Text("${m?.alias ?: "Someone"} ${Rooms.symbol(m?.gender ?: "")}") },
                        supportingContent = { Text(app.rooms.joinedRooms().firstOrNull { it.id == room }?.name ?: "") },
                        trailingContent = { if (n > 0) Badge(containerColor = Teal) { Text("$n") } })
                }
            }
            if (mine.isNotEmpty()) {
                item { Text("My rooms", Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.titleSmall) }
                items(mine, key = { "m" + it.id }) { r ->
                    ListItem(modifier = Modifier.clickable { open(Page.Room(r)) }, headlineContent = { Text(r.name, fontWeight = FontWeight.SemiBold) },
                        supportingContent = { Text("as ${app.rooms.persona(r.id)?.optString("alias") ?: ""}") })
                }
            }
            item {
                Text("Discover", Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.titleSmall)
                OutlinedTextField(search, { search = it }, placeholder = { Text("Search rooms") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
                if (loading) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
            }
            items(discover.filter { search.isBlank() || it.name.contains(search, true) }.filter { d -> mine.none { it.id == d.id } }, key = { "d" + it.id }) { r ->
                ListItem(modifier = Modifier.clickable { open(Page.Room(r)) }, headlineContent = { Text(r.name) },
                    supportingContent = { Text(r.about, maxLines = 2) })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomScreen(app: AppState, room: Rooms.Room, onBack: () -> Unit, open: (Page) -> Unit) {
    val scope = rememberCoroutineScope()
    var msgs by remember { mutableStateOf<List<Rooms.RMsg>>(emptyList()) }
    var text by remember { mutableStateOf("") }
    var alias by remember { mutableStateOf("") }
    var gender by remember { mutableStateOf(Rooms.genders[3]) }
    var menu by remember { mutableStateOf(false) }
    val persona = remember(app.tick) { app.rooms.persona(room.id) }
    val list = rememberLazyListState()
    LaunchedEffect(persona) {
        while (true) {
            msgs = withContext(Dispatchers.IO) { runCatching { app.rooms.roomChat(room) }.getOrDefault(msgs) }
            delay(6000)
        }
    }
    LaunchedEffect(msgs.size) { if (msgs.isNotEmpty()) list.animateScrollToItem(msgs.size - 1) }
    Scaffold(topBar = {
        TopAppBar(title = { Text(room.name, maxLines = 1) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }, actions = {
            if (persona != null) Box {
                IconButton({ menu = true }) { Icon(Icons.Default.MoreVert, null) }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Leave room") }, { menu = false; app.run(scope) { app.rooms.leave(room) }; onBack() })
                }
            }
        })
    }, bottomBar = {
        if (persona != null) Row(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(text, { text = it }, placeholder = { Text("Message the room as ${persona.optString("alias")}") }, modifier = Modifier.weight(1f), maxLines = 4)
            IconButton({
                val t = text.trim(); if (t.isEmpty()) return@IconButton
                text = ""
                scope.launch {
                    try { withContext(Dispatchers.IO) { app.rooms.sendRoom(room, t) }; msgs = withContext(Dispatchers.IO) { app.rooms.roomChat(room) } }
                    catch (e: Exception) { app.toast = e.message; text = t }
                }
            }) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Brand) }
        }
    }) { pad ->
        if (persona == null) {
            Column(Modifier.padding(pad).padding(24.dp)) {
                Text(room.about, style = MaterialTheme.typography.bodyMedium)
                Text("Join with a room name — your real name and number stay hidden.", Modifier.padding(top = 16.dp), fontWeight = FontWeight.Bold)
                OutlinedTextField(alias, { alias = it.take(30) }, label = { Text("Room name") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                Row(Modifier.padding(top = 8.dp)) { Rooms.genders.forEach { g -> FilterChip(gender == g, { gender = g }, label = { Text(g) }, modifier = Modifier.padding(end = 4.dp)) } }
                Button({ app.run(scope) { app.rooms.join(room, alias, gender) } }, enabled = alias.isNotBlank(), modifier = Modifier.padding(top = 12.dp)) { Text("Join room") }
                Text("Be kind. Rooms are moderated — breaking the rules gets an account banned from all rooms.", Modifier.padding(top = 16.dp),
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else LazyColumn(state = list, modifier = Modifier.padding(pad).padding(horizontal = 10.dp).fillMaxSize()) {
            items(msgs, key = { it.id }) { m ->
                val mine = m.sndr == persona.optString("id")
                val who = app.rooms.member(m.sndr)
                Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
                    if (!mine) Text("${who?.alias ?: "Guest"} ${Rooms.symbol(who?.gender ?: "")}", style = MaterialTheme.typography.labelSmall,
                        color = Teal, fontWeight = FontWeight.Bold, modifier = Modifier.clickable { open(Page.RoomDM(room.id, m.sndr)) })
                    Text(m.text, Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(16.dp))
                        .background(if (mine) Brand else MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 12.dp, vertical = 8.dp),
                        color = if (mine) Color.White else MaterialTheme.colorScheme.onSurface)
                    Text(time(m.at), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            item { Text("Tap someone's name to chat privately.", Modifier.fillMaxWidth().padding(12.dp), textAlign = TextAlign.Center, style = MaterialTheme.typography.labelSmall) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomDMScreen(app: AppState, room: String, other: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    val msgs = remember(app.tick) { app.rooms.dms(room, other) }
    val m = app.rooms.member(other)
    val persona = app.rooms.persona(room)
    val revealed = remember(app.tick) { app.rooms.iRevealed(room, other) }
    val theirs = remember(app.tick) { app.rooms.theirReveal(room, other) }
    LaunchedEffect(Unit) { app.rooms.markRead(room, other) }
    LaunchedEffect(Unit) { while (true) { if (withContext(Dispatchers.IO) { runCatching { app.rooms.pollDMs() }.getOrDefault(0) } > 0) app.changed(); delay(5000) } }
    Scaffold(topBar = {
        TopAppBar(title = { Column { Text("${m?.alias ?: "Someone"} ${Rooms.symbol(m?.gender ?: "")}"); Text("🔒 Private · end-to-end encrypted", style = MaterialTheme.typography.labelSmall) } },
            navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }, bottomBar = {
        if (persona != null) Row(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(text, { text = it }, placeholder = { Text("Message") }, modifier = Modifier.weight(1f), maxLines = 4)
            IconButton({ val t = text.trim(); if (t.isNotEmpty()) { text = ""; app.run(scope) { app.rooms.sendDM(room, other, t) } } }) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Brand) }
        }
    }) { pad ->
        LazyColumn(Modifier.padding(pad).padding(horizontal = 10.dp).fillMaxSize()) {
            item {
                Card(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                    Column(Modifier.padding(12.dp)) {
                        when {
                            revealed && theirs != null -> {
                                Text("You both revealed — add each other as real contacts.", fontWeight = FontWeight.Bold)
                                Button({ app.run(scope) { app.sync.addContact(theirs); app.toast = "Added to your contacts" } }, Modifier.padding(top = 6.dp)) { Text("Add contact") }
                            }
                            revealed -> Text("You revealed. They'll see your contact only if they reveal too.")
                            else -> {
                                Text(if (theirs != null) "They want to swap real contacts." else "Want to swap real contacts?", fontWeight = FontWeight.Bold)
                                OutlinedButton({ app.run(scope) { app.rooms.reveal(room, other, app.sync.inviteLink()) } }, Modifier.padding(top = 6.dp)) { Text("Reveal") }
                            }
                        }
                    }
                }
            }
            items(msgs, key = { it.id }) { x ->
                val mine = x.sndr == persona?.optString("id")
                Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
                    Text(x.text, Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(16.dp))
                        .background(if (mine) Brand else MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 12.dp, vertical = 8.dp),
                        color = if (mine) Color.White else MaterialTheme.colorScheme.onSurface)
                    Text(time(x.at), style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    }
}

// MARK: - Nearby

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NearbyScreen(app: AppState, onBack: () -> Unit, open: (Page) -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var radius by remember { mutableFloatStateOf(5f) }
    var results by remember { mutableStateOf<List<Nearby.Listing>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var setup by remember { mutableStateOf(false) }
    var filter by remember { mutableIntStateOf(0) }
    var pendingAction by remember { mutableStateOf<(() -> Unit)?>(null) }
    val perm = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) pendingAction?.invoke() else app.toast = "Location is needed for Nearby" }
    fun withLocation(f: () -> Unit) {
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED) f()
        else { pendingAction = f; perm.launch(Manifest.permission.ACCESS_COARSE_LOCATION) }
    }
    fun search() = withLocation {
        busy = true
        scope.launch {
            try {
                val loc = Nearby.locate(ctx) ?: throw IllegalStateException("Couldn't get your location — turn on Location")
                results = withContext(Dispatchers.IO) { app.nearby.search(loc, radius.toDouble()) }
            } catch (e: Exception) { app.toast = e.message }
            busy = false
        }
    }
    val until = remember(app.tick, setup) { app.nearby.until }
    Scaffold(topBar = { TopAppBar(title = { Text("Nearby") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }) }) { pad ->
        LazyColumn(Modifier.padding(pad).padding(horizontal = 16.dp)) {
            item {
                Card(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (until > 0) Icons.Default.Sensors else Icons.Default.VisibilityOff, null, tint = if (until > 0) Color(0xFF22C55E) else Color.Gray)
                        Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                            Text(if (until > 0) "You're findable nearby" else "You're not findable", fontWeight = FontWeight.Bold)
                            Text(if (until > 0) "Until ${time(until)} ${dateText(until)}" else "Let nearby iTeam users find you or your business.", style = MaterialTheme.typography.bodySmall)
                        }
                        TextButton({ setup = true }) { Text(if (until > 0) "Change" else "Turn on") }
                    }
                }
                Text("Within ${radius.toInt()} km", fontWeight = FontWeight.Bold)
                Slider(radius, { radius = it }, valueRange = 1f..15f, steps = 13)
                Row { listOf("All", "People", "Businesses").forEachIndexed { i, s -> FilterChip(filter == i, { filter = i }, label = { Text(s) }, modifier = Modifier.padding(end = 6.dp)) } }
                Button({ search() }, Modifier.fillMaxWidth().padding(vertical = 8.dp), enabled = !busy) {
                    Icon(Icons.Default.TravelExplore, null); Spacer(Modifier.width(8.dp)); Text(if (busy) "Searching…" else "Search nearby")
                }
                if (results.isEmpty() && !busy) Text("Only people and businesses who turned on “Be findable” appear. Distances are approximate (about 1 km).",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(results.filter { filter == 0 || (filter == 1) == (it.kind == "person") }, key = { it.id }) { l ->
                ListItem(leadingContent = { Avatar(l.name, 42) }, headlineContent = { Text(l.name, fontWeight = FontWeight.SemiBold) },
                    supportingContent = { Text(listOf(if (l.kind == "person") "" else l.category, String.format("≈ %.1f km", l.km), l.about).filter { it.isNotEmpty() }.joinToString(" · ")) },
                    trailingContent = {
                        val known = app.store.contacts.containsKey(l.id)
                        if (known) Icon(Icons.Default.CheckCircle, null, tint = Color(0xFF22C55E))
                        else TextButton({ scope.launch {
                            try { val c = withContext(Dispatchers.IO) { app.sync.addContactID(l.id) }; app.changed(); open(Page.Chat(c)) } catch (e: Exception) { app.toast = e.message }
                        } }) { Text("Add") }
                    })
                HorizontalDivider()
            }
        }
    }
    if (setup) NearbySetupDialog(app, onDone = { setup = false }, withLocation = ::withLocation)
}

@Composable
fun NearbySetupDialog(app: AppState, onDone: () -> Unit, withLocation: (() -> Unit) -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var business by remember { mutableStateOf(app.store.secret("nearby.kind") == "business") }
    var name by remember { mutableStateOf(app.store.secret("nearby.name") ?: app.store.myName) }
    var cat by remember { mutableStateOf(app.store.secret("nearby.cat") ?: "Other") }
    var about by remember { mutableStateOf(app.store.secret("nearby.about") ?: "") }
    var hours by remember { mutableIntStateOf(24) }
    var busy by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onDone, title = { Text("Be findable nearby") },
        text = {
            Column {
                Row { FilterChip(!business, { business = false }, label = { Text("Person") }); Spacer(Modifier.width(6.dp)); FilterChip(business, { business = true }, label = { Text("Business") }) }
                OutlinedTextField(name, { name = it }, label = { Text(if (business) "Business name" else "Name shown") }, singleLine = true)
                if (business) {
                    var open by remember { mutableStateOf(false) }
                    Box { TextButton({ open = true }) { Text("Category: $cat") }
                        DropdownMenu(open, { open = false }) { Nearby.categories.forEach { c -> DropdownMenuItem({ Text(c) }, { cat = c; open = false }) } } }
                }
                OutlinedTextField(about, { about = it.take(160) }, label = { Text("One line about you (optional)") })
                Row(Modifier.padding(top = 6.dp)) { listOf(1 to "1 h", 24 to "1 day", 168 to "7 days", 720 to "30 days").forEach { (h, l) ->
                    FilterChip(hours == h, { hours = h }, label = { Text(l) }, modifier = Modifier.padding(end = 4.dp)) } }
                Text("Others see this name, the line above and your distance rounded to about 1 km — never your exact location, phone or email.",
                    style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 6.dp))
                if (app.nearby.until > 0) TextButton({ app.run(scope) { app.nearby.remove() }; onDone() }) { Text("Stop being findable", color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton({
                withLocation {
                    busy = true
                    scope.launch {
                        try {
                            val loc = Nearby.locate(ctx) ?: throw IllegalStateException("Couldn't get your location — turn on Location")
                            withContext(Dispatchers.IO) {
                                app.store.setSecret("nearby.kind", if (business) "business" else "person"); app.store.setSecret("nearby.name", name)
                                app.store.setSecret("nearby.cat", cat); app.store.setSecret("nearby.about", about)
                                app.nearby.publish(loc, name.trim(), if (business) "business" else "person", if (business) cat else "", about, hours)
                            }
                            app.changed(); onDone()
                        } catch (e: Exception) { app.toast = e.message }
                        busy = false
                    }
                }
            }, enabled = name.isNotBlank() && !busy) { Text(if (busy) "…" else "Turn on") }
        },
        dismissButton = { TextButton(onDone) { Text("Cancel") } })
}

// MARK: - More

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MoreTab(app: AppState, open: (Page) -> Unit) {
    var invite by remember { mutableStateOf(false) }
    Scaffold(topBar = { TopAppBar(title = { Text("More", fontWeight = FontWeight.Bold) }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                ListItem(modifier = Modifier.clickable { open(Page.Profile) }, leadingContent = { Avatar(app.store.myName, 52) },
                    headlineContent = { Text(app.store.myName, fontWeight = FontWeight.Bold) }, supportingContent = { Text("Profile & settings") })
                HorizontalDivider()
                ListItem(modifier = Modifier.clickable { invite = true }, leadingContent = { Icon(Icons.Default.QrCode, null) }, headlineContent = { Text("My QR code") })
                ListItem(modifier = Modifier.clickable { open(Page.Nearby) }, leadingContent = { Icon(Icons.Default.NearMe, null) }, headlineContent = { Text("People & businesses nearby") })
                ListItem(modifier = Modifier.clickable { open(Page.NewGroup) }, leadingContent = { Icon(Icons.Default.GroupAdd, null) }, headlineContent = { Text("New group") })
                HorizontalDivider()
                ListItem(modifier = Modifier.clickable { open(Page.Modules) }, leadingContent = { Icon(Icons.Default.Apps, null) },
                    headlineContent = { Text("Modules", fontWeight = FontWeight.SemiBold) }, supportingContent = { Text("Builder & Infra, Khata, Tuition, Rent, Legal, Clinic, Bills, Kids, Travel, Pet Care") })
                ListItem(modifier = Modifier.clickable { open(Page.Builder) }, leadingContent = { Icon(Icons.Default.Apartment, null) }, headlineContent = { Text("Builder & Infra") })
                Text("Everything is free on Android. Attendance, Finance, CRM, Society and Gym are next.",
                    Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    if (invite) InviteDialog(app.sync) { invite = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileScreen(app: AppState, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(app.store.myName) }
    Scaffold(topBar = { TopAppBar(title = { Text("Profile") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }) }) { pad ->
        Column(Modifier.padding(pad).padding(16.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text("Your name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Button({ app.run(scope) { app.sync.rename(name); app.toast = "Saved" } }, enabled = name.isNotBlank() && name != app.store.myName, modifier = Modifier.padding(top = 8.dp)) { Text("Save") }
            Text("Your messages are end-to-end encrypted with a key that lives only on this phone. Messages travel through Apple's iCloud — no iTeam server.",
                Modifier.padding(top = 24.dp), style = MaterialTheme.typography.bodySmall)
            Text("App version ${BuildConfig.VERSION_NAME}", Modifier.padding(top = 12.dp), style = MaterialTheme.typography.labelSmall)
        }
    }
}
