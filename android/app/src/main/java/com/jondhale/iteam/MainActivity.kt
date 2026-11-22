package com.jondhale.iteam

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Brand = Color(0xFF5B5BF7)
private val Teal = Color(0xFF00B4D8)

class MainActivity : ComponentActivity() {
    private var openConv = mutableStateOf<String?>(null)
    private var pastedInvite = mutableStateOf<String?>(null)
    private var signInTick = mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        PollWorker.schedule(this)
        handle(intent)
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme(primary = Brand, secondary = Teal) else lightColorScheme(primary = Brand, secondary = Teal)) {
                Surface(Modifier.fillMaxSize()) { App(Store.get(this), openConv, pastedInvite, signInTick) }
            }
        }
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }
    private fun handle(i: Intent?) {
        i?.getStringExtra("conv")?.let { openConv.value = it }
        i?.data?.toString()?.takeIf { it.startsWith("iteam://add") }?.let { pastedInvite.value = it }
        // Back from Apple ID sign-in in the browser.
        i?.data?.toString()?.let { u ->
            val t = android.net.Uri.parse(u).getQueryParameter("ckWebAuthToken")
                ?: Regex("ckWebAuthToken=([^&#]+)").find(u)?.groupValues?.get(1)?.let { java.net.URLDecoder.decode(it, "UTF-8") }
            if (t != null) { Store.get(this).webToken = t; signInTick.intValue++ }
        }
    }
}

@Composable
fun App(store: Store, openConv: MutableState<String?>, pastedInvite: MutableState<String?>, signInTick: MutableIntState) {
    val cloud = remember { CloudKit(store) }
    val sync = remember { Sync(store, cloud) }
    var signedIn by remember { mutableStateOf(store.me.isNotEmpty() && store.webToken.isNotEmpty() && store.identity != null) }
    var tick by remember { mutableIntStateOf(0) }
    var authURL by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val ctx = androidx.compose.ui.platform.LocalContext.current

    if (!cloud.configured) {
        Centered("This build has no CloudKit token yet.\n\nAdd the CK_API_TOKEN secret on GitHub and run the Android APK workflow again."); return
    }
    // Sign-in opens in the real browser (Apple blocks it inside web views); the app reopens with the token.
    LaunchedEffect(authURL) {
        authURL?.let { u -> if (u.isNotEmpty()) ctx.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(u))) }
    }
    LaunchedEffect(signInTick.intValue) { if (signInTick.intValue > 0) { authURL = null; tick++ } }
    if (authURL != null) {
        Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Logo(); Spacer(Modifier.height(16.dp))
            Text("Sign in with your Apple ID in the browser that just opened. You'll come back here automatically.", textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            Button({ authURL?.let { ctx.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(it))) } }) { Text("Open sign-in again") }
            TextButton({ authURL = null; store.webToken = ""; tick++ }) { Text("Cancel") }
        }
        return
    }
    if (!signedIn) {
        SignInScreen(store, sync, onAuth = { authURL = it }, onDone = { signedIn = true; tick++ }, tick = tick); return
    }

    // Foreground: check the mailbox every 8 seconds.
    LaunchedEffect(signedIn) {
        while (true) {
            try {
                val n = withContext(Dispatchers.IO) { sync.poll() }
                Notify.show(ctx, n); tick++; error = null
            } catch (e: AuthNeeded) { authURL = e.redirectURL } catch (e: Exception) { error = e.message }
            delay(8000)
        }
    }

    val conv = openConv.value
    if (conv != null && store.convs[conv] != null) {
        BackHandler { openConv.value = null; Notify.foregroundConv = null }
        Notify.foregroundConv = conv
        ChatScreen(store, sync, conv, tick, onBack = { openConv.value = null; Notify.foregroundConv = null }) { tick++ }
    } else {
        ChatList(store, sync, tick, error, pastedInvite, open = { openConv.value = it }) { tick++ }
    }
}

@Composable
fun Centered(text: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) { Text(text, textAlign = TextAlign.Center) }
}

@Composable
fun Logo(size: Int = 72) {
    Box(Modifier.size(size.dp).background(Brush.linearGradient(listOf(Brand, Teal)), RoundedCornerShape((size / 4).dp)), contentAlignment = Alignment.Center) {
        Text("iT", color = Color.White, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.headlineMedium)
    }
}

@Composable
fun SignInScreen(store: Store, sync: Sync, onAuth: (String) -> Unit, onDone: () -> Unit, tick: Int) {
    var name by remember { mutableStateOf(store.myName) }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    var conflict by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun go(replace: Boolean) {
        busy = true; msg = null
        scope.launch {
            try {
                val r = withContext(Dispatchers.IO) { sync.connect(name, replace) }
                if (r == "conflict") conflict = true else onDone()
            } catch (e: AuthNeeded) { onAuth(e.redirectURL) } catch (e: Exception) { msg = e.message }
            busy = false
        }
    }
    LaunchedEffect(tick) { if (store.webToken.isNotEmpty() && !busy) go(false) }
    Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Logo(); Spacer(Modifier.height(16.dp))
        Text("iTeam Chat", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text("Private, end-to-end encrypted. Talks to iPhone and iPad users.", textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(24.dp))
        OutlinedTextField(name, { name = it }, label = { Text("Your name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(12.dp))
        Button({ go(false) }, enabled = !busy && name.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text(if (busy) "Connecting…" else "Continue with Apple ID") }
        Text("An Apple ID is needed because messages travel through Apple's iCloud. Any Apple ID works — create one free at appleid.apple.com.",
            style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 10.dp))
        msg?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
    }
    if (conflict) AlertDialog(onDismissRequest = { conflict = false },
        title = { Text("Apple ID already used on an iPhone") },
        text = { Text("This Apple ID already has iTeam on an iPhone or iPad. Using it here gives it a new security key, and that iPhone would stop reading new messages. Best: sign in here with a different Apple ID.") },
        confirmButton = { TextButton({ conflict = false; go(true) }) { Text("Use here anyway") } },
        dismissButton = { TextButton({ conflict = false; store.signOut() }) { Text("Use another Apple ID") } })
}

/** Apple ID sign-in in a web view; the CloudKit token's "URL redirect" callback carries ckWebAuthToken, which we catch. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun AppleSignIn(url: String, onToken: (String) -> Unit) {
    AndroidView(factory = { c ->
        WebView(c).apply {
            settings.javaScriptEnabled = true; settings.domStorageEnabled = true
            webViewClient = object : WebViewClient() {
                fun check(u: String): Boolean {
                    val t = android.net.Uri.parse(u).getQueryParameter("ckWebAuthToken") ?: Regex("ckWebAuthToken=([^&#]+)").find(u)?.groupValues?.get(1)?.let { java.net.URLDecoder.decode(it, "UTF-8") }
                    if (t != null) { onToken(t); return true }
                    return false
                }
                override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest) = check(r.url.toString())
                override fun onPageStarted(v: WebView, u: String, f: android.graphics.Bitmap?) { if (check(u)) v.stopLoading() }
            }
            loadUrl(url)
        }
    }, modifier = Modifier.fillMaxSize().systemBarsPadding())
}

private fun time(ms: Long): String {
    val today = SimpleDateFormat("yyyyMMdd", Locale.getDefault()).format(Date())
    val d = SimpleDateFormat("yyyyMMdd", Locale.getDefault()).format(Date(ms))
    return SimpleDateFormat(if (d == today) "HH:mm" else "d MMM", Locale.getDefault()).format(Date(ms))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatList(store: Store, sync: Sync, tick: Int, error: String?, pastedInvite: MutableState<String?>, open: (String) -> Unit, changed: () -> Unit) {
    var adding by remember { mutableStateOf(false) }
    var showInvite by remember { mutableStateOf(false) }
    LaunchedEffect(pastedInvite.value) { if (pastedInvite.value != null) adding = true }
    val convs = remember(tick) { store.convs.values.sortedByDescending { it.updated } }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Chats", fontWeight = FontWeight.Bold) }, actions = {
            IconButton({ showInvite = true }) { Icon(Icons.Default.QrCode, "My invite") }
        })
    }, floatingActionButton = {
        FloatingActionButton({ adding = true }, containerColor = Brand, contentColor = Color.White) { Icon(Icons.Default.PersonAdd, "Add contact") }
    }) { pad ->
        Column(Modifier.padding(pad)) {
            error?.let { Text("Offline: $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 16.dp)) }
            if (convs.isEmpty()) Centered("No chats yet.\n\nTap ➕ and paste an iTeam invite link from an iPhone user (Settings → My QR → Share), or share your own link with the QR button.")
            LazyColumn {
                items(convs, key = { it.id }) { c ->
                    val last = store.msgs.lastOrNull { it.conv == c.id }
                    ListItem(modifier = Modifier.clickable { c.unread = 0; store.save(); open(c.id) },
                        leadingContent = {
                            Box(Modifier.size(46.dp).background(Brush.linearGradient(listOf(Brand, Teal)), CircleShape), contentAlignment = Alignment.Center) {
                                Text(c.title.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.Bold)
                            }
                        },
                        headlineContent = { Text(c.title, fontWeight = FontWeight.SemiBold, maxLines = 1) },
                        supportingContent = { Text(last?.let { (if (c.isGroup && !it.system) store.name(it.from) + ": " else "") + it.text } ?: "Say hello 👋", maxLines = 1, overflow = TextOverflow.Ellipsis) },
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
    if (adding) AddContactDialog(sync, pastedInvite.value ?: "", onDone = { id -> adding = false; pastedInvite.value = null; changed(); if (id != null) open(id) })
    if (showInvite) InviteDialog(sync) { showInvite = false }
}

@Composable
fun AddContactDialog(sync: Sync, initial: String, onDone: (String?) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    var msg by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = { onDone(null) }, title = { Text("Add contact") },
        text = {
            Column {
                Text("Paste the iTeam invite link they shared (it starts with iteam://add).", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(text, { text = it }, minLines = 3, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                msg?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton({
                busy = true
                scope.launch {
                    try { onDone(withContext(Dispatchers.IO) { sync.addContact(text) }) } catch (e: Exception) { msg = e.message }
                    busy = false
                }
            }, enabled = !busy && text.isNotBlank()) { Text(if (busy) "Checking…" else "Add") }
        },
        dismissButton = { TextButton({ onDone(null) }) { Text("Cancel") } })
}

@Composable
fun InviteDialog(sync: Sync, onDone: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val link = remember { sync.inviteLink() }
    AlertDialog(onDismissRequest = onDone, title = { Text("My invite link") },
        text = { Text("Send this to iPhone, iPad or Android users. They tap it (or paste it in Add contact) to add you.\n\n$link", style = MaterialTheme.typography.bodySmall) },
        confirmButton = {
            TextButton({
                ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Add me on iTeam: $link"), "Share invite"))
                onDone()
            }) { Text("Share") }
        },
        dismissButton = {
            TextButton({
                (ctx.getSystemService(ClipboardManager::class.java)).setPrimaryClip(ClipData.newPlainText("iTeam", link)); onDone()
            }) { Text("Copy") }
        })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(store: Store, sync: Sync, convID: String, tick: Int, onBack: () -> Unit, changed: () -> Unit) {
    val conv = store.convs[convID] ?: return
    val msgs = remember(tick, convID) { store.msgs.filter { it.conv == convID }.sortedBy { it.at } }
    var text by remember { mutableStateOf("") }
    var err by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    LaunchedEffect(msgs.size) { if (msgs.isNotEmpty()) list.scrollToItem(msgs.size - 1) }
    LaunchedEffect(tick) { if (conv.unread > 0) { conv.unread = 0; store.save() } }
    Scaffold(topBar = {
        TopAppBar(title = {
            Column {
                Text(conv.title, fontWeight = FontWeight.Bold, maxLines = 1)
                Text(if (conv.isGroup) "${conv.members.size} members" else "🔒 End-to-end encrypted", style = MaterialTheme.typography.labelSmall)
            }
        }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }, bottomBar = {
        Row(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(text, { text = it }, placeholder = { Text("Message") }, modifier = Modifier.weight(1f), shape = RoundedCornerShape(24.dp), maxLines = 5)
            IconButton({
                val t = text.trim(); if (t.isEmpty()) return@IconButton
                text = ""
                scope.launch {
                    try { withContext(Dispatchers.IO) { sync.sendText(convID, t) }; err = null; changed() } catch (e: Exception) { err = e.message; text = t }
                }
            }) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Brand) }
        }
    }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            err?.let { Text("Not sent: $it", color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(8.dp)) }
            LazyColumn(state = list, modifier = Modifier.weight(1f).padding(horizontal = 10.dp)) {
                items(msgs, key = { it.id }) { m -> Bubble(m, mine = m.from == store.me, showName = conv.isGroup, name = store.name(m.from)) }
            }
        }
    }
}

@Composable
fun Bubble(m: Msg, mine: Boolean, showName: Boolean, name: String) {
    if (m.system) {
        Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
            Text(m.text, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center,
                modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 4.dp))
        }
        return
    }
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Column(Modifier.widthIn(max = 300.dp)
            .background(if (mine) Brush.linearGradient(listOf(Brand, Teal)) else Brush.linearGradient(listOf(MaterialTheme.colorScheme.surfaceVariant, MaterialTheme.colorScheme.surfaceVariant)), RoundedCornerShape(18.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp)) {
            if (showName && !mine) Text(name, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = Teal)
            Text(m.text, color = if (mine) Color.White else MaterialTheme.colorScheme.onSurface)
            Text(time(m.at), style = MaterialTheme.typography.labelSmall, color = if (mine) Color.White.copy(alpha = 0.8f) else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.align(Alignment.End))
        }
    }
}
