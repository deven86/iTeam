package com.jondhale.iteam

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import java.io.File

val reactionsRow = listOf("👍", "❤️", "😂", "😮", "😢", "🙏")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(app: AppState, convID: String, onBack: () -> Unit, open: (Page) -> Unit) {
    val ctx = LocalContext.current
    val conv = remember(app.tick, convID) { app.store.conv(convID) } ?: return
    val msgs = remember(app.tick, convID) { app.store.messages(convID) }
    val me = app.store.me
    var text by remember { mutableStateOf("") }
    var replyTo by remember { mutableStateOf<Msg?>(null) }
    var editing by remember { mutableStateOf<Msg?>(null) }
    var actionsFor by remember { mutableStateOf<Msg?>(null) }
    var attachMenu by remember { mutableStateOf(false) }
    var newTask by remember { mutableStateOf(false) }
    var pickOpponent by remember { mutableStateOf(false) }
    var openGame by remember { mutableStateOf<String?>(null) }
    var viewer by remember { mutableStateOf<File?>(null) }
    var extra by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(0) }
    var recording by remember { mutableStateOf(false) }
    val recorder = remember { VoiceRecorder(ctx) }
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    Notify.foregroundConv = convID
    DisposableEffect(convID) { onDispose { Notify.foregroundConv = null } }

    LaunchedEffect(msgs.size) {
        if (msgs.isNotEmpty()) list.animateScrollToItem(msgs.size - 1)
        withContext(Dispatchers.IO) { app.store.markRead(convID); app.sync.readReceipt(convID) }
    }
    LaunchedEffect(convID) { app.hurry() }

    fun sendFiles(prep: suspend () -> List<Media.Prepared>, caption: String = "") {
        sending++
        scope.launch {
            try {
                val p = withContext(Dispatchers.IO) { prep() }
                withContext(Dispatchers.IO) { app.sync.sendText(convID, caption, replyTo?.id, p.map { it.att }, p.associate { it.blob }) }
                replyTo = null; app.hurry(); app.changed()
            } catch (e: AuthNeeded) { app.reconnect = e.redirectURL; app.toast = "Not sent — sign in again (top of the screen), then resend."
            } catch (e: Exception) { app.toast = "Not sent: ${e.message}" }
            sending--
        }
    }
    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(10)) { uris ->
        if (uris.isNotEmpty()) sendFiles({ uris.map { Media.file(ctx, it) } })
    }
    val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) sendFiles({ listOf(Media.file(ctx, uri)) })
    }
    val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) runCatching { recorder.start(); recording = true }.onFailure { app.toast = "Microphone unavailable" }
    }
    fun startVoice() {
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            runCatching { recorder.start(); recording = true }.onFailure { app.toast = "Microphone unavailable" }
        } else micPermission.launch(Manifest.permission.RECORD_AUDIO)
    }

    // Presence (iTeam Next): share mine and read theirs every 40 s while the chat is open.
    var peerSeen by remember { mutableStateOf(0L) }
    var recommend by remember { mutableStateOf(false) }
    if (recommend) {
        val people = remember(app.tick) { app.store.contacts.values.filter { it.userID != me && it.userID !in conv.members }.sortedBy { it.name.lowercase() } }
        AlertDialog({ recommend = false }, confirmButton = { TextButton({ recommend = false }) { Text("Cancel") } },
            title = { Text("Recommend a contact") },
            text = {
                if (people.isEmpty()) Text("No other contacts to recommend yet.")
                else LazyColumn(Modifier.heightIn(max = 380.dp)) {
                    items(people, key = { it.userID }) { c ->
                        ListItem(modifier = Modifier.clickable { recommend = false; app.run(scope) { app.sync.recommend(c.userID, convID) } },
                            leadingContent = { Avatar(c.name, size = 36, photo = c.photo) }, headlineContent = { Text(c.name) })
                    }
                }
            })
    }
    if (BuildConfig.RELAY && !conv.isGroup) LaunchedEffect(convID) {
        val peer = app.sync.peerOf(convID)
        while (true) {
            withContext(Dispatchers.IO) {
                val rc = RelayCloud(app.store)
                if (app.store.prefBool("shareSeen", true)) runCatching { rc.touchSeen() }
                if (peer != null) runCatching { rc.seen(listOf(peer))[peer]?.let { peerSeen = it } }
            }
            kotlinx.coroutines.delay(40_000)
        }
    }
    val online = peerSeen > 0 && System.currentTimeMillis() - peerSeen < 180_000
    Scaffold(topBar = {
        TopAppBar(title = {
            Column(Modifier.clickable(enabled = conv.isGroup) { open(Page.GroupInfo(convID)) }) {
                Text(conv.title, fontWeight = FontWeight.Bold, maxLines = 1)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (online) { Box(Modifier.size(8.dp).clip(CircleShape).background(Color.Red)); Spacer(Modifier.width(5.dp)) }
                    Text(when {
                        conv.isGroup -> "${conv.members.size} members · tap for info"
                        online -> "online"
                        peerSeen > 0 -> "last seen " + (if (dateText(peerSeen) == dateText(System.currentTimeMillis())) "today" else dateText(peerSeen)) + " at " + time(peerSeen)
                        else -> "🔒 End-to-end encrypted"
                    }, style = MaterialTheme.typography.labelSmall)
                }
            }
        }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }, actions = {
            IconButton({ extra = "timer" }) { Icon(if (conv.timer > 0) Icons.Default.TimerOff else Icons.Default.Timer, "Disappearing messages") }
            IconButton({ newTask = true }) { Icon(Icons.Default.AddTask, "New task") }
            IconButton({ recommend = true }) { Icon(Icons.Default.PersonAddAlt, "Recommend a contact") }
            IconButton({ if (conv.isGroup) pickOpponent = true else app.sync.peerOf(convID)?.let { o -> app.run(scope) { app.sync.gameInvite(convID, o) } } }) {
                Icon(Icons.Default.Grid3x3, "X and O")
            }
        })
    }, bottomBar = {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().imePadding()) {
            if (sending > 0) LinearProgressIndicator(Modifier.fillMaxWidth())
            // @mentions: typing "@" in a group suggests members.
            val lastWord = text.substringAfterLast(' ')
            if (conv.isGroup && lastWord.startsWith("@")) {
                val q = lastWord.drop(1).lowercase()
                val hits = conv.members.filter { it != me && (q.isEmpty() || app.store.name(it).lowercase().contains(q)) }.take(8)
                if (hits.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    hits.forEach { id ->
                        AssistChip({ text = text.dropLast(lastWord.length) + "@" + app.store.name(id).replace(' ', '_') + " " }, { Text(app.store.name(id)) },
                            leadingIcon = { Icon(Icons.Default.AlternateEmail, null, Modifier.size(16.dp)) })
                    }
                }
            }
            (replyTo ?: editing)?.let { r ->
                Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(if (editing != null) "Edit message" else "Reply to ${app.store.name(r.from)}", style = MaterialTheme.typography.labelSmall, color = Brand)
                        Text(preview(r), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
                    }
                    IconButton({ replyTo = null; if (editing != null) { editing = null; text = "" } }) { Icon(Icons.Default.Close, "Cancel") }
                }
            }
            if (conv.left) Text("You're no longer in this group.", Modifier.padding(16.dp).fillMaxWidth(), textAlign = TextAlign.Center)
            else if (recording) Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.FiberManualRecord, null, tint = Color.Red); Spacer(Modifier.width(8.dp))
                Text("Recording voice note…", Modifier.weight(1f))
                TextButton({ recorder.cancel(); recording = false }) { Text("Cancel") }
                Button({
                    recording = false
                    val secs = recorder.stop()
                    if (secs == null) app.toast = "Too short" else sendFiles({ listOf(Media.voice(ctx, recorder.file, secs)) })
                }) { Text("Send") }
            } else Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box {
                    IconButton({ attachMenu = true }) { Icon(Icons.Default.Add, "Attach", tint = Brand) }
                    DropdownMenu(attachMenu, { attachMenu = false }) {
                        DropdownMenuItem({ Text("Photos & videos") }, { attachMenu = false; pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) },
                            leadingIcon = { Icon(Icons.Default.Photo, null) })
                        DropdownMenuItem({ Text("Document") }, { attachMenu = false; pickFile.launch(arrayOf("*/*")) }, leadingIcon = { Icon(Icons.Default.Description, null) })
                        DropdownMenuItem({ Text("Task") }, { attachMenu = false; newTask = true }, leadingIcon = { Icon(Icons.Default.AddTask, null) })
                        DropdownMenuItem({ Text("View-once photo") }, { attachMenu = false; extra = "once" }, leadingIcon = { Icon(Icons.Default.VisibilityOff, null) })
                        DropdownMenuItem({ Text("✨ Magic moment") }, { attachMenu = false; extra = "magic" }, leadingIcon = { Icon(Icons.Default.AutoAwesome, null) })
                        DropdownMenuItem({ Text("Poll") }, { attachMenu = false; extra = "poll" }, leadingIcon = { Icon(Icons.Default.Poll, null) })
                        DropdownMenuItem({ Text("Ask for approval") }, { attachMenu = false; extra = "approval" }, leadingIcon = { Icon(Icons.Default.Approval, null) })
                        DropdownMenuItem({ Text("Meeting") }, { attachMenu = false; extra = "meeting" }, leadingIcon = { Icon(Icons.Default.Event, null) })
                    }
                }
                OutlinedTextField(text, { text = it }, placeholder = { Text("Message") }, modifier = Modifier.weight(1f), shape = RoundedCornerShape(24.dp), maxLines = 5)
                if (text.isBlank() && editing == null) IconButton({ startVoice() }) { Icon(Icons.Default.Mic, "Voice note", tint = Brand) }
                else IconButton({
                    val t = text.trim(); if (t.isEmpty()) return@IconButton
                    text = ""
                    val ed = editing; val re = replyTo
                    editing = null; replyTo = null
                    scope.launch {
                        try {
                            withContext(Dispatchers.IO) { if (ed != null) app.sync.edit(convID, ed.id, t) else app.sync.sendText(convID, t, re?.id) }
                            app.hurry(); app.changed()
                        } catch (e: AuthNeeded) { app.reconnect = e.redirectURL; app.toast = "Not sent — sign in again (top of the screen), then tap send."; text = t
                        } catch (e: Exception) { app.toast = "Not sent: ${e.message}"; text = t }
                    }
                }) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Brand) }
            }
        }
    }) { pad ->
        LazyColumn(state = list, modifier = Modifier.padding(pad).fillMaxSize().padding(horizontal = 10.dp)) {
            // First visit to a group someone else added me to: what members can see.
            val seenGroups = app.store.prefList("groupNotice.seen", emptyList())
            if (conv.isGroup && conv.owner != me && !conv.left && convID !in seenGroups) item {
                Card(Modifier.fillMaxWidth().padding(vertical = 8.dp), shape = RoundedCornerShape(18.dp)) {
                    Column(Modifier.padding(14.dp)) {
                        Text("You were added to ${conv.title}", fontWeight = FontWeight.Bold)
                        Text("All members — including people who join later — can see your name and photo and can add you as a contact. They can message you privately only after you add them back.",
                            style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 6.dp))
                        Row {
                            Button({ app.store.setPref("groupNotice.seen", seenGroups + convID); app.changed() }) { Text("Got it") }
                            Spacer(Modifier.width(8.dp))
                            OutlinedButton({ app.store.setPref("groupNotice.seen", seenGroups + convID); app.run(scope) { app.sync.leave(convID) }; onBack() }) { Text("Leave group") }
                        }
                    }
                }
            }
            items(msgs, key = { it.id }) { m ->
                when {
                    m.card?.startsWith("task:") == true -> TaskCard(app, m, m.card.removePrefix("task:")) { open(Page.Task(it)) }
                    m.card?.startsWith("game:") == true -> SystemLine(m.text) { openGame = m.card.removePrefix("game:") }
                    m.card != null && m.card.substringBefore(":") in listOf("poll", "approval", "meeting", "rx") -> ChatCard(app, m, open)
                    m.system -> SystemLine(m.text, null)
                    else -> Bubble(app, m, conv, msgs, onLong = { actionsFor = m }, onView = { viewer = it })
                }
            }
        }
    }

    actionsFor?.let { m ->
        AlertDialog(onDismissRequest = { actionsFor = null }, confirmButton = {}, text = {
            Column {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                    reactionsRow.forEach { e ->
                        Text(e, fontSize = 28.sp, modifier = Modifier.clickable {
                            actionsFor = null
                            val mine = m.reactions[me] == e
                            app.run(scope) { app.sync.react(convID, m.id, if (mine) null else e) }
                        }.padding(4.dp))
                    }
                }
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                if (!m.deleted) TextButton({ actionsFor = null; replyTo = m }) { Text("Reply") }
                if (!m.deleted && m.from != me && m.text.contains("iteam://add?")) TextButton({
                    actionsFor = null
                    app.run(scope) { val id = app.sync.addContact(m.text); app.changed(); open(Page.Chat(id)) }
                }) { Text("➕ Add this contact") }
                if (m.text.isNotBlank() && !m.deleted) TextButton({
                    actionsFor = null
                    ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("iTeam", m.text))
                }) { Text("Copy") }
                if (m.from == me && !m.deleted && m.atts.isEmpty()) TextButton({ actionsFor = null; editing = m; text = m.text }) { Text("Edit") }
                if (!m.deleted && m.text.isNotBlank()) TextButton({ actionsFor = null; app.run(scope) { app.sync.createTask(convID, m.text.take(120), "", emptyList(), null, 1, true) } }) { Text("Make a task") }
                if (m.from == me && !m.deleted) TextButton({ actionsFor = null; app.run(scope) { app.sync.unsend(convID, m.id) } }) {
                    Text("Delete for everyone", color = MaterialTheme.colorScheme.error)
                }
            }
        })
    }
    if (newTask) TaskEditorDialog(app, conv) { newTask = false }
    if (extra.isNotEmpty()) ChatExtrasMenu(app, convID, extra) { extra = ""; app.changed() }
    if (pickOpponent) AlertDialog(onDismissRequest = { pickOpponent = false }, title = { Text("Play X and O with…") }, confirmButton = {},
        text = {
            LazyColumn(Modifier.heightIn(max = 400.dp)) {
                items(conv.members.filter { it != me }) { u ->
                    ListItem(modifier = Modifier.clickable { pickOpponent = false; app.run(scope) { app.sync.gameInvite(convID, u) } },
                        leadingContent = { Avatar(app.store.name(u), 36) }, headlineContent = { Text(app.store.name(u)) })
                }
            }
        })
    openGame?.let { GameDialog(app, it) { openGame = null } }
    viewer?.let { f ->
        val images = remember(msgs) { msgs.filter { !it.deleted }.flatMap { m -> m.atts.filter { it.kind == "image" } } }
        PhotoSwiper(app, images, images.indexOfFirst { it.id == f.name }.coerceAtLeast(0)) { viewer = null }
    }
}

@Composable
fun SystemLine(text: String, onTap: (() -> Unit)?) {
    Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.labelMedium, textAlign = TextAlign.Center,
            modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                .then(if (onTap != null) Modifier.clickable { onTap() } else Modifier).padding(horizontal = 10.dp, vertical = 5.dp))
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Bubble(app: AppState, m: Msg, conv: Conv, all: List<Msg>, onLong: () -> Unit, onView: (File) -> Unit) {
    val me = app.store.me
    val mine = m.from == me
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        Column(Modifier.widthIn(max = 300.dp)
            .clip(if (mine) RoundedCornerShape(20.dp, 20.dp, 6.dp, 20.dp) else RoundedCornerShape(20.dp, 20.dp, 20.dp, 6.dp))
            .background(bubbleBrush(app, mine))
            .combinedClickable(onClick = {}, onLongClick = onLong)
            .padding(horizontal = 12.dp, vertical = 8.dp)) {
            val fg = bubbleText(app, mine)
            if (conv.isGroup && !mine) Text(app.store.name(m.from), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = Teal)
            m.replyTo?.let { rid ->
                all.firstOrNull { it.id == rid }?.let { r ->
                    Column(Modifier.padding(bottom = 4.dp).clip(RoundedCornerShape(8.dp)).background(Color.Black.copy(alpha = 0.12f)).padding(6.dp)) {
                        Text(app.store.name(r.from), style = MaterialTheme.typography.labelSmall, color = fg, fontWeight = FontWeight.Bold)
                        Text(preview(r), style = MaterialTheme.typography.bodySmall, color = fg, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (!m.deleted && m.once) ViewOnceBubble(app, m, mine, fg)
            else if (!m.deleted) m.atts.forEach { a -> AttachmentView(app, a, fg, onView) }
            m.expires?.let { Text("⏱", style = MaterialTheme.typography.labelSmall, color = fg.copy(alpha = 0.6f)) }
            m.showAt?.takeIf { mine && it > System.currentTimeMillis() }?.let { Text("✨ shows ${dateText(it)} ${time(it)}", style = MaterialTheme.typography.labelSmall, color = fg.copy(alpha = 0.8f)) }
            if (m.text.isNotBlank() || m.deleted) Text(m.text, color = if (m.deleted) fg.copy(alpha = 0.6f) else fg)
            Row(Modifier.align(Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                if (m.edited) Text("edited · ", style = MaterialTheme.typography.labelSmall, color = fg.copy(alpha = 0.75f))
                Text(time(m.at), style = MaterialTheme.typography.labelSmall, color = fg.copy(alpha = 0.8f))
                if (mine) {
                    val t = SwiftDate.from(m.at) - 1
                    val others = conv.members.filter { it != me }
                    val read = others.isNotEmpty() && others.all { (conv.receipts[it]?.get(1) ?: 0.0) >= t }
                    val delivered = others.isNotEmpty() && others.all { (conv.receipts[it]?.get(0) ?: 0.0) >= t }
                    Text(if (read || delivered) " ✓✓" else " ✓", style = MaterialTheme.typography.labelSmall,
                        color = if (read) Color(0xFF7DF9FF) else fg.copy(alpha = 0.8f), fontWeight = FontWeight.Bold)
                }
            }
        }
        if (m.reactions.isNotEmpty()) {
            Text(m.reactions.values.groupingBy { it }.eachCount().entries.joinToString(" ") { (e, n) -> if (n > 1) "$e$n" else e },
                Modifier.padding(top = 2.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 6.dp, vertical = 2.dp))
        }
    }
}

@Composable
fun AttachmentView(app: AppState, a: Att, fg: Color, onView: (File) -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var playing by remember { mutableStateOf(false) }
    fun withFile(then: (File) -> Unit) {
        busy = true
        scope.launch {
            try { val f = withContext(Dispatchers.IO) { Media.load(ctx, app.sync.cloudKit, a) }; then(f) }
            catch (e: Exception) { app.toast = e.message ?: "Couldn't open the file" }
            busy = false
        }
    }
    when (a.kind) {
        "image", "video" -> {
            val thumb = remember(a.id) { Media.thumb(a) }
            Box(Modifier.padding(bottom = 4.dp).size(220.dp, ((a.height ?: 3.0) / (a.width ?: 4.0) * 220).coerceIn(90.0, 300.0).dp)
                .clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.2f))
                .clickable { withFile { f -> if (a.kind == "image") onView(f) else Media.open(ctx, f, a) } }, contentAlignment = Alignment.Center) {
                if (thumb != null) Image(thumb.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                if (a.kind == "video") Icon(Icons.Default.PlayCircle, null, tint = Color.White, modifier = Modifier.size(48.dp))
                if (busy) CircularProgressIndicator(color = Color.White)
            }
        }
        "audio" -> Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 4.dp)) {
            IconButton({ withFile { f -> playing = true; Player.toggle(f, a.id) { playing = false } } }) {
                if (busy) CircularProgressIndicator(Modifier.size(22.dp), color = fg)
                else Icon(if (playing) Icons.Default.StopCircle else Icons.Default.PlayCircle, "Play", tint = fg, modifier = Modifier.size(34.dp))
            }
            Text("🎤 Voice note · ${(a.duration ?: 0.0).toInt()} s", color = fg)
        }
        else -> Row(Modifier.padding(bottom = 4.dp).clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.12f))
            .clickable { withFile { f -> Media.open(ctx, f, a) } }.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (busy) CircularProgressIndicator(Modifier.size(22.dp), color = fg) else Icon(Icons.Default.Description, null, tint = fg)
            Spacer(Modifier.width(8.dp))
            Column {
                Text(a.name, color = fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(Media.size(a.size), color = fg.copy(alpha = 0.7f), style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

@Composable
fun TaskCard(app: AppState, m: Msg, taskID: String, open: (String) -> Unit) {
    val t = remember(app.tick, taskID) { app.store.task(taskID) }
    Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
        Card(Modifier.widthIn(max = 320.dp).clickable { open(taskID) }) {
            Column(Modifier.padding(12.dp)) {
                Text(m.text, style = MaterialTheme.typography.labelMedium)
                if (t != null) {
                    Text(t.title, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 4.dp))
                    Text(statusTitle(t.status) + (t.due?.let { " · due ${dateText(it)}" } ?: "") + if (t.deleted) " · deleted" else "",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

fun statusTitle(s: String) = when (s) { "inProgress" -> "In progress"; "done" -> "Done ✅"; else -> "To do" }

@Composable
fun GameDialog(app: AppState, id: String, onClose: () -> Unit) {
    // While the board is open, check for the other player's move every 2 seconds (same as iPhone).
    LaunchedEffect(id) {
        while (true) {
            delay(2000)
            val st = app.store.game(id)?.status
            if (st == "won" || st == "draw" || st == "resigned" || st == "declined") break
            runCatching { withContext(Dispatchers.IO) { app.sync.poll() } }
            app.changed()
        }
    }
    val g = remember(app.tick, id) { app.store.game(id) } ?: return
    val me = app.store.me
    val scope = rememberCoroutineScope()
    val other = if (g.x == me) g.o else g.x
    val win = Sync.winner(g.board)
    AlertDialog(onDismissRequest = onClose, title = { Text("X and O vs ${app.store.name(other)}") }, confirmButton = { TextButton(onClose) { Text("Close") } },
        dismissButton = { if (g.status == "playing") TextButton({ app.run(scope) { app.sync.gameAct(id, "resign") } }) { Text("Resign") } },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                Text(when (g.status) {
                    "invite" -> if (g.createdBy == me) "Waiting for ${app.store.name(other)} to accept…" else "${app.store.name(other)} challenged you!"
                    "playing" -> if (g.turn == me) "Your move (${g.mark(me)})" else "${app.store.name(g.turn)}'s move"
                    "won" -> if (g.winner == me) "🏆 You won!" else "${app.store.name(g.winner)} won"
                    "draw" -> "🤝 Draw"
                    else -> "Declined"
                }, fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 12.dp))
                for (r in 0..2) Row {
                    for (c in 0..2) {
                        val i = r * 3 + c
                        val ch = g.board[i]
                        val canMove = g.status == "playing" && g.turn == me && ch == '-'
                        Box(Modifier.size(74.dp).padding(3.dp).clip(RoundedCornerShape(12.dp))
                            .background(if (win != null && ch == win) Teal.copy(alpha = 0.35f) else MaterialTheme.colorScheme.surfaceVariant)
                            .clickable(enabled = canMove) { app.run(scope) { app.sync.gameAct(id, "move", i) } }, contentAlignment = Alignment.Center) {
                            Text(if (ch == '-') "" else ch.toString(), fontSize = 34.sp, fontWeight = FontWeight.Black, color = if (ch == 'X') Brand else Color(0xFFE5484D))
                        }
                    }
                }
                if (g.status == "invite" && g.createdBy != me) Row(Modifier.padding(top = 12.dp)) {
                    Button({ app.run(scope) { app.sync.gameAct(id, "accept") } }) { Text("Accept") }
                    Spacer(Modifier.width(8.dp))
                    OutlinedButton({ app.run(scope) { app.sync.gameAct(id, "decline") } }) { Text("Decline") }
                }
            }
        })
}


/** Full-screen photos: swipe left/right through every photo in the chat, like the iPhone. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun PhotoSwiper(app: AppState, images: List<Att>, start: Int, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val pager = androidx.compose.foundation.pager.rememberPagerState(initialPage = start) { images.size.coerceAtLeast(1) }
    Dialog(onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            androidx.compose.foundation.pager.HorizontalPager(pager, Modifier.fillMaxSize()) { i ->
                val a = images.getOrNull(i)
                var bmp by remember(a?.id) { mutableStateOf<android.graphics.Bitmap?>(null) }
                LaunchedEffect(a?.id) { if (a != null) bmp = withContext(Dispatchers.IO) { runCatching { BitmapFactory.decodeFile(Media.load(ctx, app.sync.cloudKit, a).absolutePath) }.getOrNull() } }
                Box(Modifier.fillMaxSize().clickable { onClose() }, contentAlignment = Alignment.Center) {
                    bmp?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxWidth(), contentScale = ContentScale.Fit) } ?: CircularProgressIndicator(color = Color.White)
                }
            }
            if (images.size > 1) Text("${pager.currentPage + 1} / ${images.size}", Modifier.align(Alignment.TopCenter).padding(24.dp), color = Color.White)
        }
    }
}

/** Chat bubble colours from Settings (the iPhone's palette); default = the look's gradient. */
@Composable
fun bubbleBrush(app: AppState, mine: Boolean): Brush {
    val c = app.store.pref(if (mine) "bubbleOut" else "bubbleIn").toLongOrNull()
    return when {
        c != null -> Brush.linearGradient(listOf(Color(c), Color(c)))
        mine -> Brush.linearGradient(listOf(Brand, Teal))
        else -> Brush.linearGradient(listOf(MaterialTheme.colorScheme.surfaceVariant, MaterialTheme.colorScheme.surfaceVariant))
    }
}

@Composable
fun bubbleText(app: AppState, mine: Boolean): Color {
    val c = app.store.pref(if (mine) "bubbleOut" else "bubbleIn").toLongOrNull()
    return when {
        c != null -> if (isLightColor(c)) Color.Black else Color.White
        mine -> Color.White
        else -> MaterialTheme.colorScheme.onSurface
    }
}

fun isLightColor(c: Long): Boolean { val r = (c shr 16) and 0xFF; val g = (c shr 8) and 0xFF; val b = c and 0xFF; return (0.299 * r + 0.587 * g + 0.114 * b) > 160 }
