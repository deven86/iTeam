package com.jondhale.iteam

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateList
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

@Composable
fun Avatar(name: String, size: Int = 46, group: Boolean = false, photo: String = "") {
    val bmp = remember(photo) { if (photo.isEmpty()) null else runCatching { E2E.unb64(photo).let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() } }.getOrNull() }
    Box(Modifier.size(size.dp).clip(CircleShape).background(Brush.linearGradient(listOf(LookState.primary, LookState.secondary)), CircleShape), contentAlignment = Alignment.Center) {
        if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        else if (group) Icon(Icons.Default.Groups, null, tint = Color.White)
        else Text(name.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.Bold)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatList(app: AppState, status: StatusInfo, pastedInvite: MutableState<String?>, open: (Page) -> Unit) {
    var adding by remember { mutableStateOf(false) }
    var showInvite by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(pastedInvite.value) { if (pastedInvite.value != null) adding = true }
    val convs = remember(app.tick) { app.store.convList() }
    val lastMsgs = remember(app.tick) { app.store.lastMessages() }
    var filter by remember { mutableStateOf(0) } // 0 all, 1 direct, 2 groups
    val unread = convs.sumOf { it.unread }
    val shown = when (filter) { 1 -> convs.filter { !it.isGroup }; 2 -> convs.filter { it.isGroup }; else -> convs }
    Scaffold(containerColor = MaterialTheme.colorScheme.background, floatingActionButton = {
        FloatingActionButton({ adding = true }, containerColor = Brand, contentColor = Color.White, shape = CircleShape) { Icon(Icons.Default.Add, "Add contact") }
    }) { pad ->
        LazyColumn(Modifier.padding(pad), contentPadding = PaddingValues(bottom = 96.dp)) {
            // Header card: greeting, unread count, quick actions, recent people.
            item {
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(bottomStart = 32.dp, bottomEnd = 32.dp))
                    .background(Brush.linearGradient(listOf(LookState.primary, LookState.primary.copy(alpha = 0.82f), LookState.secondary)))
                    .statusBarsPadding().padding(start = 20.dp, end = 8.dp, top = 8.dp, bottom = 18.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Hi, " + app.store.myName.substringBefore(' ').ifBlank { "there" }, color = Color.White.copy(alpha = 0.85f))
                            Text(if (unread > 0) "You have $unread new message${if (unread == 1) "" else "s"}" else "You're all caught up",
                                color = Color.White, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleLarge)
                        }
                        IconButton({ open(Page.RoomsPage) }) { Icon(Icons.Default.Groups, "Rooms", tint = Color.White) }
                        IconButton({ showInvite = true }) { Icon(Icons.Default.QrCode, "My QR", tint = Color.White) }
                        Box {
                            IconButton({ menu = true }) { Icon(Icons.Default.Edit, "New", tint = Color.White) }
                            DropdownMenu(menu, { menu = false }) {
                                DropdownMenuItem({ Text("Add contact") }, { menu = false; adding = true }, leadingIcon = { Icon(Icons.Default.PersonAdd, null) })
                                DropdownMenuItem({ Text("New group") }, { menu = false; open(Page.NewGroup) }, leadingIcon = { Icon(Icons.Default.GroupAdd, null) })
                                DropdownMenuItem({ Text("New broadcast") }, { menu = false; open(Page.Broadcast) }, leadingIcon = { Icon(Icons.Default.Campaign, null) })
                                DropdownMenuItem({ Text("People nearby") }, { menu = false; open(Page.Nearby) }, leadingIcon = { Icon(Icons.Default.NearMe, null) })
                            }
                        }
                    }
                    val people0 = convs.filter { !it.isGroup }.take(20)
                    val peers = people0.mapNotNull { c -> app.sync.peerOf(c.id)?.let { c.id to it } }.toMap()
                    var seenMap by remember { mutableStateOf<Map<String, Long>>(emptyMap()) }
                    if (BuildConfig.RELAY) LaunchedEffect(peers.values.toList()) {
                        while (true) {
                            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { seenMap = RelayCloud(app.store).seen(peers.values.toList()) } }
                            kotlinx.coroutines.delay(60_000)
                        }
                    }
                    val nowMs = System.currentTimeMillis()
                    fun ago(id: String): Long = peers[id]?.let { seenMap[it] }?.let { nowMs - it } ?: Long.MAX_VALUE
                    val people = people0.sortedBy { ago(it.id) }.take(12)
                    if (people.isNotEmpty()) {
                        Spacer(Modifier.height(14.dp))
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            people.forEach { c ->
                                Column(Modifier.width(60.dp).clickable { open(Page.Chat(c.id)) }, horizontalAlignment = Alignment.CenterHorizontally) {
                                    val ag = ago(c.id)
                                    Box {
                                        Box(Modifier.border(2.dp, Color.White, CircleShape).padding(3.dp)) {
                                            Avatar(c.title, size = 50, photo = app.sync.peerOf(c.id)?.let { app.store.photoOf(it) } ?: "")
                                        }
                                        if (ag < 180_000) Box(Modifier.align(Alignment.BottomEnd).size(14.dp).border(2.dp, Color.White, CircleShape).background(Color(0xFFE53935), CircleShape))
                                    }
                                    Text(c.title.substringBefore(' '), color = Color.White, style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    val lbl = when { ag < 180_000 -> "online"; ag < 3_600_000 -> "${ag / 60_000}m"; ag < 86_400_000 -> "${ag / 3_600_000}h"; else -> "" }
                                    if (lbl.isNotEmpty()) Text(lbl, color = Color.White.copy(alpha = 0.8f), style = MaterialTheme.typography.labelSmall)
                                }
                            }
                        }
                    }
                }
            }
            item { StatusBar(status) }
            // Recent activity (like iPhone): newest 10 things from others; opening one dismisses it.
            item {
                val seenAct = remember(app.tick) { app.store.prefList("activity.seen", emptyList()).toSet() }
                val acts = remember(app.tick) {
                    val since = System.currentTimeMillis() - 7 * 86_400_000L
                    synchronized(app.store) { app.store.msgs.filter { it.from != app.store.me && !it.deleted && it.at > since && it.id !in seenAct && (it.showAt ?: 0) <= System.currentTimeMillis() }.takeLast(40) }
                        .sortedByDescending { it.at }.take(10)
                }
                if (acts.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    acts.forEach { m ->
                        val title = app.store.conv(m.conv)?.title ?: ""
                        Column(Modifier.width(170.dp).clip(RoundedCornerShape(18.dp)).background(LookState.primary.copy(alpha = 0.10f))
                            .clickable {
                                app.store.setPref("activity.seen", (app.store.prefList("activity.seen", emptyList()) + m.id).takeLast(300)); app.changed(); open(Page.Chat(m.conv))
                            }.padding(horizontal = 12.dp, vertical = 10.dp)) {
                            Text(if (m.system) preview(m) else "${app.store.name(m.from).substringBefore(' ')} · $title: ${preview(m)}",
                                style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(android.text.format.DateUtils.getRelativeTimeSpanString(m.at).toString(), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            // Pill filter: All / Direct / Groups
            item {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("All", "Direct", "Groups").forEachIndexed { i, t ->
                        val on = filter == i
                        Text(t, Modifier.clip(RoundedCornerShape(50)).background(if (on) Brand else MaterialTheme.colorScheme.surfaceVariant)
                            .clickable { filter = i }.padding(horizontal = 18.dp, vertical = 8.dp),
                            color = if (on) Color.White else MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            if (shown.isEmpty()) item {
                Text(if (convs.isEmpty()) "No chats yet.\n\nTap ＋ to scan an iTeam QR code or paste an invite link, or find people nearby." else "Nothing here yet.",
                    Modifier.fillMaxWidth().padding(32.dp), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(shown, key = { it.id }) { c ->
                val last = lastMsgs[c.id]
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).clip(RoundedCornerShape(22.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainer).clickable { open(Page.Chat(c.id)) }.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Avatar(c.title, size = 50, group = c.isGroup, photo = app.sync.peerOf(c.id)?.let { app.store.photoOf(it) } ?: "")
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(c.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(last?.let { (if (c.isGroup && !it.system) app.store.name(it.from) + ": " else "") + preview(it) } ?: "Say hello 👋",
                            maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text(if (c.updated > 0) time(c.updated) else "", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (c.unread > 0) {
                            Spacer(Modifier.height(4.dp))
                            Text("${c.unread}", Modifier.clip(CircleShape).background(Brand).padding(horizontal = 7.dp, vertical = 1.dp),
                                color = Color.White, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }
    if (adding) AddContactDialog(app, pastedInvite.value ?: "") { id -> adding = false; pastedInvite.value = null; app.changed(); if (id != null) open(Page.Chat(id)) }
    if (showInvite) InviteDialog(app.sync) { showInvite = false }
}

fun preview(m: Msg): String = when {
    m.deleted -> "This message was deleted"
    m.text.isNotBlank() -> m.text
    m.atts.isNotEmpty() -> when (m.atts.first().kind) { "image" -> "📷 Photo"; "video" -> "🎬 Video"; "audio" -> "🎤 Voice note"; else -> "📎 " + m.atts.first().name }
    else -> ""
}

@Composable
fun AddContactDialog(app: AppState, initial: String, onDone: (String?) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    var msg by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun add(t: String) {
        busy = true
        scope.launch {
            try { onDone(kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { app.sync.addContact(t) }) } catch (e: Exception) { msg = e.message }
            busy = false
        }
    }
    val scan = rememberLauncherForActivityResult(ScanContract()) { r -> r.contents?.let { text = it; add(it) } }
    AlertDialog(onDismissRequest = { onDone(null) }, title = { Text("Add contact") },
        text = {
            Column {
                OutlinedButton({
                    scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan an iTeam QR code").setBeepEnabled(false).setOrientationLocked(true))
                }, Modifier.fillMaxWidth()) { Icon(Icons.Default.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text("Scan QR code") }
                Text("…or paste the invite link they shared (iPhone or Android).", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 10.dp))
                OutlinedTextField(text, { text = it }, minLines = 3, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                msg?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton({ add(text) }, enabled = !busy && text.isNotBlank()) { Text(if (busy) "Checking…" else "Add") } },
        dismissButton = { TextButton({ onDone(null) }) { Text("Cancel") } })
}

@Composable
fun InviteDialog(sync: Sync, onDone: () -> Unit) {
    val ctx = LocalContext.current
    val link = remember { sync.inviteLink() }
    val qr = remember(link) { runCatching { BarcodeEncoder().encodeBitmap(link, BarcodeFormat.QR_CODE, 640, 640) }.getOrNull() }
    AlertDialog(onDismissRequest = onDone, title = { Text("My iTeam code") },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                qr?.let { Image(it.asImageBitmap(), "QR", Modifier.size(240.dp).background(Color.White)) }
                Text("Others scan this in iTeam (iPhone, iPad or Android) to add you, or share the link.", style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 10.dp))
            }
        },
        confirmButton = {
            TextButton({
                ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Add me on iTeam: $link"), "Share invite"))
                onDone()
            }) { Text("Share link") }
        },
        dismissButton = {
            TextButton({ ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("iTeam", link)); onDone() }) { Text("Copy") }
        })
}

/** Tick-list of contacts. */
@Composable
fun ContactPicker(app: AppState, picked: SnapshotStateList<String>, exclude: List<String> = emptyList()) {
    val contacts = remember(app.tick) { app.store.contactList().filter { it.userID !in exclude && it.userID != app.store.me } }
    if (contacts.isEmpty()) Text("No contacts yet — add people first.", Modifier.padding(16.dp))
    LazyColumn {
        items(contacts, key = { it.userID }) { c ->
            ListItem(modifier = Modifier.clickable { if (c.userID in picked) picked.remove(c.userID) else picked.add(c.userID) },
                leadingContent = { Avatar(c.name, 40, photo = c.photo) },
                headlineContent = { Text(c.name) },
                trailingContent = { Checkbox(c.userID in picked, { if (it) picked.add(c.userID) else picked.remove(c.userID) }) })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewGroupScreen(app: AppState, onBack: () -> Unit, created: (String) -> Unit) {
    var title by remember { mutableStateOf("") }
    val picked = remember { mutableStateListOf<String>() }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Scaffold(topBar = {
        TopAppBar(title = { Text("New group") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }, actions = {
            TextButton({
                busy = true
                scope.launch {
                    try { created(kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { app.sync.createGroup(title.trim(), picked.toList()) }) }
                    catch (e: Exception) { app.toast = e.message }
                    busy = false
                }
            }, enabled = !busy && title.isNotBlank() && picked.isNotEmpty()) { Text(if (busy) "Creating…" else "Create") }
        })
    }) { pad ->
        Column(Modifier.padding(pad)) {
            OutlinedTextField(title, { title = it }, label = { Text("Group name") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(16.dp))
            Text("Members (${picked.size})", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(horizontal = 16.dp))
            ContactPicker(app, picked)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupInfoScreen(app: AppState, id: String, onBack: () -> Unit) {
    val conv = remember(app.tick) { app.store.conv(id) } ?: return
    var adding by remember { mutableStateOf(false) }
    var confirmLeave by remember { mutableStateOf(false) }
    val picked = remember { mutableStateListOf<String>() }
    val scope = rememberCoroutineScope()
    val me = app.store.me
    Scaffold(topBar = {
        TopAppBar(title = { Text(conv.title) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item { Text("${conv.members.size} members · end-to-end encrypted", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall) }
            items(conv.members) { m ->
                ListItem(leadingContent = { Avatar(app.store.name(m), 40, photo = app.store.photoOf(m)) }, headlineContent = { Text(if (m == me) "You" else app.store.name(m)) },
                    trailingContent = { Text(if (m == conv.owner) "Owner" else if (m in conv.admins) "Admin" else "", style = MaterialTheme.typography.labelSmall) })
            }
            item {
                if (conv.canManage(me) && !conv.left) TextButton({ picked.clear(); adding = true }, Modifier.padding(8.dp)) { Icon(Icons.Default.PersonAdd, null); Spacer(Modifier.width(8.dp)); Text("Add members") }
                if (!conv.left) TextButton({ confirmLeave = true }, Modifier.padding(8.dp)) { Text("Leave group", color = MaterialTheme.colorScheme.error) }
                else Text("You're no longer in this group.", Modifier.padding(16.dp))
            }
        }
    }
    if (adding) AlertDialog(onDismissRequest = { adding = false }, title = { Text("Add members") },
        text = { Box(Modifier.heightIn(max = 420.dp)) { ContactPicker(app, picked, exclude = conv.members) } },
        confirmButton = { TextButton({ adding = false; app.run(scope) { app.sync.addMembers(id, picked.toList()) } }, enabled = picked.isNotEmpty()) { Text("Add") } },
        dismissButton = { TextButton({ adding = false }) { Text("Cancel") } })
    if (confirmLeave) AlertDialog(onDismissRequest = { confirmLeave = false }, title = { Text("Leave “${conv.title}”?") },
        confirmButton = { TextButton({ confirmLeave = false; app.run(scope) { app.sync.leave(id) }; onBack() }) { Text("Leave") } },
        dismissButton = { TextButton({ confirmLeave = false }) { Text("Cancel") } })
}


/** Broadcast: one message, delivered privately to up to 200 people in each one-to-one chat. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BroadcastScreen(app: AppState, onBack: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val picked = remember { mutableStateListOf<String>().apply { addAll(app.store.prefList("broadcast.last", emptyList()).filter { app.store.contacts[it] != null }) } }
    var busy by remember { mutableStateOf(false) }
    var progress by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val max = 200
    Scaffold(topBar = {
        TopAppBar(title = { Text("Broadcast") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }, actions = {
            TextButton({
                busy = true
                val list = picked.take(max).toList()
                app.store.setPref("broadcast.last", list)
                scope.launch {
                    var ok = 0
                    list.forEachIndexed { i, u ->
                        progress = "Sending ${i + 1} of ${list.size}…"
                        runCatching {
                            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                val me = app.store.me; val d = app.sync.directID(me, u)
                                synchronized(app.store) { app.store.convs.getOrPut(d) { Conv(d, app.store.name(u), listOf(me, u)) } }
                                app.sync.sendText(d, text.trim())
                            }
                        }.onSuccess { ok++ }
                    }
                    app.toast = "Sent to $ok of ${list.size}"; busy = false; app.changed(); onBack()
                }
            }, enabled = !busy && text.isNotBlank() && picked.isNotEmpty()) { Text(if (busy) "Sending…" else "Send") }
        })
    }) { pad ->
        Column(Modifier.padding(pad)) {
            OutlinedTextField(text, { text = it }, label = { Text("Message") }, minLines = 3, modifier = Modifier.fillMaxWidth().padding(16.dp))
            Text("Each person gets it in your private chat with them and replies only to you. They can't see who else got it.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(if (busy) progress else "Send to ${picked.size} / $max", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                TextButton({ if (picked.isNotEmpty()) picked.clear() else picked.addAll(app.store.contacts.keys.filter { it != app.store.me }.take(max)) }) {
                    Text(if (picked.isNotEmpty()) "None" else "All")
                }
            }
            if (picked.size > max) Text("Only the first $max will get it.", color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 16.dp))
            ContactPicker(app, picked)
        }
    }
}
