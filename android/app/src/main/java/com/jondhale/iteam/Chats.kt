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
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

@Composable
fun Avatar(name: String, size: Int = 46, group: Boolean = false) {
    Box(Modifier.size(size.dp).background(Brush.linearGradient(listOf(Brand, Teal)), CircleShape), contentAlignment = Alignment.Center) {
        if (group) Icon(Icons.Default.Groups, null, tint = Color.White)
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
    Scaffold(topBar = {
        TopAppBar(title = { Text("Chats", fontWeight = FontWeight.Bold) }, actions = {
            IconButton({ showInvite = true }) { Icon(Icons.Default.QrCode, "My QR") }
            Box {
                IconButton({ menu = true }) { Icon(Icons.Default.Edit, "New") }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Add contact") }, { menu = false; adding = true }, leadingIcon = { Icon(Icons.Default.PersonAdd, null) })
                    DropdownMenuItem({ Text("New group") }, { menu = false; open(Page.NewGroup) }, leadingIcon = { Icon(Icons.Default.GroupAdd, null) })
                    DropdownMenuItem({ Text("People nearby") }, { menu = false; open(Page.Nearby) }, leadingIcon = { Icon(Icons.Default.NearMe, null) })
                }
            }
        })
    }, floatingActionButton = {
        FloatingActionButton({ adding = true }, containerColor = Brand, contentColor = Color.White) { Icon(Icons.Default.PersonAdd, "Add contact") }
    }) { pad ->
        Column(Modifier.padding(pad)) {
            StatusBar(status)
            if (convs.isEmpty()) Centered("No chats yet.\n\nTap ➕ to scan an iTeam QR code or paste an invite link, or find people nearby.")
            LazyColumn {
                items(convs, key = { it.id }) { c ->
                    val last = lastMsgs[c.id]
                    ListItem(modifier = Modifier.clickable { open(Page.Chat(c.id)) },
                        leadingContent = { Avatar(c.title, group = c.isGroup) },
                        headlineContent = { Text(c.title, fontWeight = FontWeight.SemiBold, maxLines = 1) },
                        supportingContent = {
                            Text(last?.let { (if (c.isGroup && !it.system) app.store.name(it.from) + ": " else "") + preview(it) } ?: "Say hello 👋",
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        },
                        trailingContent = {
                            Column(horizontalAlignment = Alignment.End) {
                                Text(if (c.updated > 0) time(c.updated) else "", style = MaterialTheme.typography.labelSmall)
                                if (c.unread > 0) Badge(containerColor = Teal) { Text("${c.unread}") }
                            }
                        })
                    HorizontalDivider()
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
                Text("…or paste the invite link they shared (starts with iteam://add).", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 10.dp))
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
                leadingContent = { Avatar(c.name, 40) },
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
                ListItem(leadingContent = { Avatar(app.store.name(m), 40) }, headlineContent = { Text(if (m == me) "You" else app.store.name(m)) },
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
