package com.jondhale.iteam

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

val Brand: Color get() = LookState.primary
val Teal: Color get() = LookState.secondary

class MainActivity : androidx.fragment.app.FragmentActivity() {
    /** Fingerprint / face / PIN lock (Settings → Privacy). */
    private var locked = mutableStateOf(false)
    private var stoppedAt = 0L
    private fun lockOn() = Store.get(this).prefBool("appLock", false)
    private fun unlock() {
        val prompt = androidx.biometric.BiometricPrompt(this, androidx.core.content.ContextCompat.getMainExecutor(this),
            object : androidx.biometric.BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: androidx.biometric.BiometricPrompt.AuthenticationResult) { locked.value = false }
            })
        val info = androidx.biometric.BiometricPrompt.PromptInfo.Builder().setTitle("Unlock iTeam")
            .setAllowedAuthenticators(androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK or androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL).build()
        runCatching { prompt.authenticate(info) }.onFailure { locked.value = false }
    }
    override fun onStop() { super.onStop(); stoppedAt = System.currentTimeMillis() }
    override fun onStart() {
        super.onStart()
        if (lockOn() && (stoppedAt == 0L || System.currentTimeMillis() - stoppedAt > 30_000)) { locked.value = true; unlock() }
    }

    private var openConv = mutableStateOf<String?>(null)
    private var pastedInvite = mutableStateOf<String?>(null)
    private var signInTick = mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        PollWorker.schedule(this)
        handle(intent)
        LookState.load(Store.get(this))
        setContent {
            val dark = when (LookState.mode) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
            MaterialTheme(colorScheme = LookState.scheme(dark)) {
                Surface(Modifier.fillMaxSize()) {
                    if (locked.value) Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                        Logo(); Spacer(Modifier.height(16.dp)); Button({ unlock() }) { Text("Unlock") }
                    } else App(Store.get(this), openConv, pastedInvite, signInTick, openSignIn)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }
    private val openSignIn = mutableStateOf(false)
    private fun handle(i: Intent?) {
        i?.getStringExtra("conv")?.let { openConv.value = it }
        if (i?.getBooleanExtra("signin", false) == true) openSignIn.value = true
        i?.data?.toString()?.takeIf { it.startsWith("iteam://add") }?.let { pastedInvite.value = it }
        // Back from Apple ID sign-in in the browser.
        i?.data?.toString()?.let { u ->
            val t = android.net.Uri.parse(u).getQueryParameter("ckWebAuthToken")
                ?: Regex("ckWebAuthToken=([^&#]+)").find(u)?.groupValues?.get(1)?.let { java.net.URLDecoder.decode(it, "UTF-8") }
            if (t != null) { Store.get(this).webToken = t; signInTick.intValue++ }
        }
    }
}

/** Everything the screens share. */
class AppState(val store: Store, val sync: Sync) {
    val rooms = Rooms(store, sync.cloudKit)
    val nearby = Nearby(store, sync.cloudKit)
    var tick by mutableIntStateOf(0)
    val fastUntil = mutableLongStateOf(0L)
    val nextPoll = mutableLongStateOf(0L)
    var toast by mutableStateOf<String?>(null)
    /** Set when the Apple ID sign-in expired: a banner on every screen offers "Sign in again". */
    var reconnect by mutableStateOf<String?>(null)
    var signIn: (String?) -> Unit = {}
    fun changed() { tick++ }
    fun hurry() { fastUntil.longValue = System.currentTimeMillis() + 90_000; nextPoll.longValue = System.currentTimeMillis() + 2_000 }
}

/** Runs [block] off the main thread and shows any error. */
fun AppState.run(scope: kotlinx.coroutines.CoroutineScope, block: suspend () -> Unit) {
    scope.launch {
        try { withContext(Dispatchers.IO) { block() }; changed() }
        catch (e: AuthNeeded) { reconnect = e.redirectURL; toast = "Apple ID sign-in expired — tap “Sign in again” at the top" }
        catch (e: Exception) { toast = e.message ?: "Something went wrong" }
    }
}

@Composable
fun App(store: Store, openConv: MutableState<String?>, pastedInvite: MutableState<String?>, signInTick: MutableIntState, openSignIn: MutableState<Boolean>) {
    val cloud = remember { CloudKit(store) }
    val sync = remember { Sync(store, cloud) }
    val app = remember { AppState(store, sync) }
    // Once this phone has its key, chats open straight away — even before iCloud reconnects.
    var signedIn by remember { mutableStateOf(store.me.isNotEmpty() && store.identity != null) }
    var authURL by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle

    if (!cloud.configured) {
        Centered("This build has no CloudKit token yet.\n\nAdd the CK_API_TOKEN secret on GitHub and run the Android APK workflow again."); return
    }
    // Sign-in opens in the real browser (Apple blocks it inside web views); the app reopens with the token.
    LaunchedEffect(authURL) {
        authURL?.let { u -> if (u.isNotEmpty()) ctx.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(u))) }
    }
    val scope0 = rememberCoroutineScope()
    // Opens Apple's sign-in page; if we don't have a link (or it's stale), ask CloudKit for a fresh one.
    app.signIn = { url ->
        if (!url.isNullOrEmpty()) authURL = url
        else scope0.launch {
            val fresh = withContext(Dispatchers.IO) { runCatching { cloud.signInURL() }.getOrDefault("") }
            if (fresh.isNotEmpty()) authURL = fresh else app.toast = "Couldn't reach Apple. Check the internet and try again."
        }
    }
    LaunchedEffect(signInTick.intValue) {
        if (signInTick.intValue > 0) { authURL = null; app.reconnect = null; error = null; app.nextPoll.longValue = 0; app.tick++ }
    }
    LaunchedEffect(Unit) { if (openSignIn.value) { openSignIn.value = false; app.signIn(null) } }
    if (authURL != null) {
        Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Logo(); Spacer(Modifier.height(16.dp))
            Text("Sign in with your Apple ID in the browser that just opened. You'll come back here automatically.", textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            Button({ authURL?.let { ctx.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(it))) } }) { Text("Open sign-in again") }
            TextButton({ authURL = null; app.tick++ }) { Text("Cancel") }
        }
        return
    }
    if (!signedIn) {
        SignInScreen(store, sync, onAuth = { authURL = it }, onDone = { signedIn = true; app.nextPoll.longValue = 0; app.tick++ }, tick = app.tick); return
    }

    // Checks the mailbox only while the app is on screen: every 3 s just after you chat, otherwise every 8 s.
    // In the background Android's worker checks every 15 minutes.
    LaunchedEffect(signedIn) {
        var wasActive = false
        var roomsAt = 0L
        withContext(Dispatchers.IO) { app.rooms.loadBans() }
        while (true) {
            val active = lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
            val now = System.currentTimeMillis()
            if (active && (!wasActive || now >= app.nextPoll.longValue)) {
                val wait = try {
                    val n = withContext(Dispatchers.IO) { sync.poll().also { runCatching { ITeamWidget.update(ctx) }; runCatching { Reminders.reschedule(ctx) } } }
                    Notify.show(ctx, n)
                    if (sync.changed) app.tick++
                    if (now - roomsAt > 30_000) { roomsAt = now; if (withContext(Dispatchers.IO) { runCatching { app.rooms.pollDMs() }.getOrDefault(0) } > 0) app.tick++ }
                    error = null; app.reconnect = null
                    if (System.currentTimeMillis() < app.fastUntil.longValue) 3_000L else 8_000L
                } catch (e: AuthNeeded) { app.reconnect = e.redirectURL; 60_000L
                } catch (e: Exception) { error = e.message ?: "No connection"; 15_000L }
                app.nextPoll.longValue = System.currentTimeMillis() + wait
                app.tick++
            }
            wasActive = active
            delay(1000)
        }
    }

    val status = StatusInfo(null, error, store.lastSync) { url -> app.signIn(url) }
    Column(Modifier.fillMaxSize()) {
        app.reconnect?.let { r ->
            Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.statusBarsPadding().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Apple ID sign-in expired — messages are paused.", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                    Button({ app.signIn(r) }) { Text("Sign in again") }
                }
            }
        }
        Box(Modifier.weight(1f)) { Home(app, status, openConv, pastedInvite) }
    }
    app.toast?.let { msg ->
        LaunchedEffect(msg) { delay(3500); app.toast = null }
        Box(Modifier.fillMaxSize().padding(bottom = 96.dp), contentAlignment = Alignment.BottomCenter) {
            Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.inverseSurface, shadowElevation = 6.dp) {
                Text(msg, color = MaterialTheme.colorScheme.inverseOnSurface, modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
            }
        }
    }
}

/** Screens on top of the tabs. */
sealed class Page {
    data class Chat(val id: String) : Page()
    data class Task(val id: String) : Page()
    data class GroupInfo(val id: String) : Page()
    data class Room(val room: Rooms.Room) : Page()
    data class RoomDM(val room: String, val other: String) : Page()
    object NewGroup : Page()
    object Nearby : Page()
    object Profile : Page()
    object Modules : Page()
    data class BizModule(val module: String) : Page()
    data class BizParent(val module: String, val id: String) : Page()
    object Builder : Page()
    data class BuildProject(val id: String) : Page()
    data class BuildRec(val id: String) : Page()
    object FSI : Page()
    object ModuleStore : Page()
    object Attendance : Page()
    data class AttCompany(val id: String) : Page()
    object Finance : Page()
    object CRM : Page()
    object Views : Page()
    data class MeetingPage(val id: String) : Page()
    object Meetings : Page()
    object Doctor : Page()
    object Survey : Page()
    data class Album(val owner: String, val conv: String, val title: String) : Page()
    object Wallet : Page()
    object Mind : Page()
    object MyDay : Page()
    object Events : Page()
    object Safety : Page()
    object Care : Page()
    object Fight : Page()
    data class Lead(val id: String) : Page()
    object Societies : Page()
    data class Society(val id: String) : Page()
    object Gym : Page()
    data class GymMember(val id: String) : Page()
    object TasksPage : Page()
    object RoomsPage : Page()
    object Appearance : Page()
    object BottomBar : Page()
    object Privacy : Page()
    object BubbleColor : Page()
    object Help : Page()
    object ModuleRequest : Page()
}

@Composable
fun Home(app: AppState, status: StatusInfo, openConv: MutableState<String?>, pastedInvite: MutableState<String?>) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val stack = remember { mutableStateListOf<Page>() }
    fun push(p: Page) { stack.add(p) }
    fun pop() { if (stack.isNotEmpty()) stack.removeAt(stack.size - 1) }

    LaunchedEffect(openConv.value) { openConv.value?.let { if (app.store.conv(it) != null) { stack.clear(); stack.add(Page.Chat(it)) }; openConv.value = null } }

    val top = stack.lastOrNull()
    if (top != null) {
        BackHandler { pop() }
        when (top) {
            is Page.Chat -> ChatScreen(app, top.id, onBack = { pop() }, open = { push(it) })
            is Page.Task -> TaskScreen(app, top.id, onBack = { pop() }, open = { push(it) })
            is Page.GroupInfo -> GroupInfoScreen(app, top.id, onBack = { pop() })
            is Page.Room -> RoomScreen(app, top.room, onBack = { pop() }, open = { push(it) })
            is Page.RoomDM -> RoomDMScreen(app, top.room, top.other, onBack = { pop() })
            Page.NewGroup -> NewGroupScreen(app, onBack = { pop() }, created = { pop(); push(Page.Chat(it)) })
            Page.Nearby -> NearbyScreen(app, onBack = { pop() }, open = { push(it) })
            Page.Profile -> MyDetailsScreen(app, onBack = { pop() })
            Page.TasksPage -> Column { TopBack("Tasks") { pop() }; TasksTab(app, open = { push(it) }) }
            Page.RoomsPage -> Column { TopBack("Rooms") { pop() }; RoomsTab(app, open = { push(it) }) }
            Page.Attendance -> AttendanceHome(app, onBack = { pop() }, open = { push(it) })
            is Page.AttCompany -> AttCompanyScreen(app, top.id, onBack = { pop() })
            Page.Finance -> FinanceHome(app, onBack = { pop() })
            Page.Views -> ViewsScreen(app, onBack = { pop() })
            Page.Events -> EventsScreen(app, onBack = { pop() }, open = { push(it) })
            is Page.MeetingPage -> MeetingScreen(app, top.id, onBack = { pop() })
            Page.Meetings -> MeetingsScreen(app, onBack = { pop() }, open = { push(it) })
            Page.Doctor -> DoctorScreen(app, onBack = { pop() })
            Page.Survey -> SurveyScreen(app, onBack = { pop() })
            is Page.Album -> AlbumScreen(app, top.owner, top.conv, top.title, onBack = { pop() })
            Page.Wallet -> WalletScreen(app, onBack = { pop() })
            Page.Mind -> MindScreen(app, onBack = { pop() })
            Page.MyDay -> MyDayScreen(app, onBack = { pop() }, open = { push(it) })
            Page.Safety -> SafetyScreen(app, onBack = { pop() })
            Page.Care -> CareScreen(app, onBack = { pop() })
            Page.Fight -> FightPractice(onBack = { pop() })
            Page.CRM -> CRMHome(app, onBack = { pop() }, open = { push(it) })
            is Page.Lead -> LeadScreen(app, top.id, onBack = { pop() })
            Page.Societies -> SocietyHome(app, onBack = { pop() }, open = { push(it) })
            is Page.Society -> SocietyScreen(app, top.id, onBack = { pop() })
            Page.Gym -> GymHome(app, onBack = { pop() }, open = { push(it) })
            is Page.GymMember -> GymMemberScreen(app, top.id, onBack = { pop() })
            Page.ModuleStore -> ModuleStoreScreen(app, onBack = { pop() }, open = { push(it) })
            Page.Appearance -> AppearanceScreen(app, onBack = { pop() })
            Page.BottomBar -> BottomBarScreen(app, onBack = { pop() })
            Page.Privacy -> PrivacyScreen(app, onBack = { pop() })
            Page.BubbleColor -> BubbleColorScreen(app, onBack = { pop() })
            Page.Help -> HelpScreen(app, onBack = { pop() })
            Page.ModuleRequest -> ModuleRequestScreen(app, onBack = { pop() })
            Page.Modules -> ModulesHub(app, onBack = { pop() }, open = { push(it) })
            is Page.BizModule -> BizModuleScreen(app, top.module, onBack = { pop() }, open = { push(it) })
            is Page.BizParent -> BizParentScreen(app, top.module, top.id, onBack = { pop() })
            Page.Builder -> BuilderHome(app, onBack = { pop() }, open = { push(it) })
            is Page.BuildProject -> BuildProjectScreen(app, top.id, onBack = { pop() }, open = { push(it) })
            is Page.BuildRec -> BuildRecScreen(app, top.id, onBack = { pop() }, open = { push(it) })
            Page.FSI -> FSIScreen(onBack = { pop() })
        }
        return
    }
    LaunchedEffect(Unit) {
        // Rooms now sits next to Chats; free its bottom-bar slot once.
        if (!app.store.prefBool("roomsMoved", false)) {
            val p = app.store.prefList("pinned", listOf("tasks", "views"))
            if ("rooms" in p) app.store.setPref("pinned", p.map { if (it == "rooms") (if ("views" in p) "events" else "views") else it })
            app.store.setPref("roomsMoved", true); app.changed()
        }
    }
    val pinned = remember(app.tick) { app.store.prefList("pinned", listOf("tasks", "views")).mapNotNull { id -> tabOptions.firstOrNull { it.id == id } } }
    val tabs = listOf(TabOption("chats", "Chats", Icons.Default.Chat)) + pinned + listOf(TabOption("modules", "Modules", Icons.Default.GridView), TabOption("settings", "Settings", Icons.Default.Settings))
    if (tab >= tabs.size) tab = 0
    Scaffold(bottomBar = {
        NavigationBar {
            val unread = remember(app.tick) { app.store.unreadTotal() }
            tabs.forEachIndexed { i, t ->
                NavigationBarItem(tab == i, { tab = i }, {
                    if (t.id == "chats") BadgedBox({ if (unread > 0) Badge { Text("$unread") } }) { Icon(t.icon, null) } else Icon(t.icon, null)
                }, label = { Text(t.title, maxLines = 1) })
            }
        }
    }) { pad ->
        Box(Modifier.padding(pad)) {
            val go: (Page) -> Unit = { push(it) }
            when (val id = tabs[tab].id) {
                "chats" -> ChatList(app, status, pastedInvite, open = go)
                "tasks" -> TasksTab(app, open = go)
                "rooms" -> RoomsTab(app, open = go)
                "nearby" -> NearbyScreen(app, onBack = { tab = 0 }, open = go)
                "build" -> BuilderHome(app, onBack = null, open = go)
                "attendance" -> AttendanceHome(app, onBack = null, open = go)
                "finance" -> FinanceHome(app, onBack = null)
                "crm" -> CRMHome(app, onBack = null, open = go)
                "views" -> ViewsScreen(app, onBack = null)
                "events" -> EventsScreen(app, onBack = null, open = go)
                "myday" -> MyDayScreen(app, onBack = null, open = go)
                "meetings" -> MeetingsScreen(app, onBack = null, open = go)
                "wallet" -> WalletScreen(app, onBack = null)
                "safety" -> SafetyScreen(app, onBack = null)
                "care" -> CareScreen(app, onBack = null)
                "society" -> SocietyHome(app, onBack = null, open = go)
                "gym" -> GymHome(app, onBack = null, open = go)
                "modules" -> ModulesHub(app, onBack = null, open = go)
                "settings" -> SettingsTab(app, open = go)
                else -> BizModuleScreen(app, id, onBack = null, open = go)
            }
        }
    }
}

class StatusInfo(val reconnect: String?, val error: String?, val lastSync: Long, val signIn: (String) -> Unit)

@Composable
fun StatusBar(s: StatusInfo) {
    when {
        s.reconnect != null -> Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("iCloud sign-in expired — new messages are paused.", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                TextButton({ s.signIn(s.reconnect) }) { Text("Reconnect") }
            }
        }
        s.error != null -> Text("Offline — retrying: ${s.error}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        s.lastSync > 0 -> Text("Up to date · ${time(s.lastSync)}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp))
        else -> Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp))
            Text("Connecting…", style = MaterialTheme.typography.labelSmall)
        }
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

fun time(ms: Long): String {
    val today = SimpleDateFormat("yyyyMMdd", Locale.getDefault()).format(Date())
    val d = SimpleDateFormat("yyyyMMdd", Locale.getDefault()).format(Date(ms))
    return SimpleDateFormat(if (d == today) "HH:mm" else "d MMM", Locale.getDefault()).format(Date(ms))
}

fun dateText(ms: Long): String = SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(ms))

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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TopBack(title: String, onBack: () -> Unit) {
    TopAppBar(title = { Text(title) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
}
