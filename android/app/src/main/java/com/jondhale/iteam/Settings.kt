package com.jondhale.iteam

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.io.ByteArrayOutputStream

// Settings: my details & photo, privacy, Module Store, appearance (the iPhone's three looks), bottom bar.

/** The three looks from the iPhone, plus light / dark / system. */
object LookState {
    data class Look(val id: String, val name: String, val primary: Color, val secondary: Color, val lightBg: Color, val darkBg: Color)
    val looks = listOf(
        Look("prism", "Prism Glass", Color(0xFF5B5BF7), Color(0xFF00B4D8), Color(0xFFF4F5FB), Color(0xFF0E0F1A)),
        Look("zen", "Zen Calm", Color(0xFF4F7A68), Color(0xFFB59A72), Color(0xFFF5F3EE), Color(0xFF151816)),
        Look("pastel", "Pastel Breeze", Color(0xFF9C7CF4), Color(0xFFF28DB2), Color(0xFFFBF6FF), Color(0xFF1A1520)),
    )
    var look by mutableStateOf(looks[0])
    var mode by mutableStateOf("system")
    val primary get() = look.primary
    val secondary get() = look.secondary

    fun load(store: Store) {
        look = looks.firstOrNull { it.id == store.pref("look", "prism") } ?: looks[0]
        mode = store.pref("mode", "system")
    }
    fun scheme(dark: Boolean) = if (dark) darkColorScheme(primary = look.primary, secondary = look.secondary, background = look.darkBg, surface = look.darkBg)
        else lightColorScheme(primary = look.primary, secondary = look.secondary, background = look.lightBg, surface = look.lightBg)
}

/** Tabs that can sit in the bottom bar between Chats and Modules. */
data class TabOption(val id: String, val title: String, val icon: ImageVector)
val tabOptions: List<TabOption> get() = listOf(
    TabOption("myday", "My Day", Icons.Default.WbSunny),
    TabOption("views", "mini", Icons.Default.PlayCircle),
    TabOption("meetings", "Meetings", Icons.Default.Groups),
    TabOption("wallet", "Wallet", Icons.Default.Wallet),
    TabOption("tasks", "Tasks", Icons.Default.Checklist),
    TabOption("events", "Events", Icons.Default.Celebration),
    TabOption("safety", "Safety", Icons.Default.Sos),
    TabOption("care", "Care", Icons.Default.MedicalServices),
    TabOption("rooms", "Rooms", Icons.Default.Forum),
    TabOption("build", "Builder", Icons.Default.Apartment),
    TabOption("attendance", "Attendance", Icons.Default.Fingerprint),
    TabOption("finance", "Finance", Icons.Default.AccountBalanceWallet),
    TabOption("crm", "CRM", Icons.Default.Handshake),
    TabOption("society", "Society", Icons.Default.Apartment),
    TabOption("gym", "Gym", Icons.Default.FitnessCenter),
    TabOption("nearby", "Nearby", Icons.Default.NearMe),
) + BizSpecs.all.map { TabOption(it.module, it.title.substringBefore(" &").substringBefore(" Planner").substringBefore(" Desk").substringBefore(" Matters"), moduleIcon(it.module)) }

/** Modules the user added from the Module Store (opt-in, like the iPhone). Shared data always shows its module. */
fun visibleModules(store: Store): List<String> {
    val added = store.prefList("modules", emptyList())
    val withData = (store.bizList().filter { !it.deleted }.map { it.module } + (if (store.buildList().any { !it.deleted }) listOf("build") else emptyList()) +
        (if (store.attList().any { !it.deleted }) listOf("attendance") else emptyList()) + (if (store.finList().any { !it.deleted }) listOf("finance") else emptyList()) +
        store.misc.values.filter { !it.deleted }.mapNotNull { when (it.s("t")) { "crml", "crmg" -> "crm"; "soc" -> "society"; "gymm" -> "gym"; else -> null } }).toSet()
    return (listOf("attendance", "finance", "crm", "society", "gym", "build") + BizSpecs.all.map { it.module }).filter { it in added || it in withData }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsTab(app: AppState, open: (Page) -> Unit) {
    var invite by remember { mutableStateOf(false) }
    val store = app.store
    Scaffold(topBar = { TopAppBar(title = { Text("Settings", fontWeight = FontWeight.Bold) }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            item {
                ListItem(modifier = Modifier.clickable { open(Page.Profile) }, leadingContent = { Avatar(store.myName, 56, photo = store.pref("photo")) },
                    headlineContent = { Text(store.myName, fontWeight = FontWeight.Bold) },
                    supportingContent = { Text(store.pref("about").ifEmpty { "Name, photo, age, mobile, email" }) })
                HorizontalDivider()
                Row1(Icons.Default.QrCode, "My QR code") { invite = true }
                Row1(Icons.Default.Storefront, "Module Store", "Add or remove modules — all free on Android") { open(Page.ModuleStore) }
                Row1(Icons.Default.Palette, "Appearance", "${LookState.look.name} · ${modeName(LookState.mode)}") { open(Page.Appearance) }
                Row1(Icons.Default.ViewWeek, "Bottom bar", store.prefList("pinned", listOf("tasks", "rooms")).joinToString(" · ") { id -> tabOptions.firstOrNull { it.id == id }?.title ?: id }) { open(Page.BottomBar) }
                Row1(Icons.Default.ChatBubble, "Chat bubble colour") { open(Page.BubbleColor) }
                Row1(Icons.Default.Lock, "Privacy & lock", "Fingerprint lock, photo, About, read receipts") { open(Page.Privacy) }
                Row1(Icons.Default.Lightbulb, "Request a module") { open(Page.ModuleRequest) }
                Row1(Icons.Default.Feedback, "Help & grievances") { open(Page.Help) }
                HorizontalDivider()
                Row1(Icons.Default.NearMe, "People & businesses nearby") { open(Page.Nearby) }
                Row1(Icons.Default.GroupAdd, "New group") { open(Page.NewGroup) }
                Text("Messages are end-to-end encrypted with a key that lives only on this phone. They travel through Apple's iCloud — there is no iTeam server.\n\nApp version ${BuildConfig.VERSION_NAME}",
                    Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    if (invite) InviteDialog(app.sync) { invite = false }
}

@Composable
private fun Row1(icon: ImageVector, title: String, sub: String? = null, onClick: () -> Unit) =
    ListItem(modifier = Modifier.clickable(onClick = onClick), leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) },
        headlineContent = { Text(title) }, supportingContent = sub?.let { { Text(it) } }, trailingContent = { Icon(Icons.Default.ChevronRight, null) })

private fun modeName(m: String) = when (m) { "light" -> "Light"; "dark" -> "Dark"; else -> "Automatic" }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Back(title: String, onBack: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Scaffold(topBar = { TopAppBar(title = { Text(title) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }) }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), content = content)
    }
}

// MARK: - My details

private fun shrinkPhoto(b: Bitmap): ByteArray {
    val side = minOf(b.width, b.height)
    val sq = Bitmap.createBitmap(b, (b.width - side) / 2, (b.height - side) / 2, side, side)
    val out = if (side > 512) Bitmap.createScaledBitmap(sq, 512, 512, true) else sq
    return ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MyDetailsScreen(app: AppState, onBack: () -> Unit) {
    val s = app.store
    val ctx = LocalContext.current
    val parts = s.myName.split(" ", limit = 2)
    var first by remember { mutableStateOf(s.pref("first", parts.getOrElse(0) { "" })) }
    var last by remember { mutableStateOf(s.pref("last", parts.getOrElse(1) { "" })) }
    var age by remember { mutableStateOf(s.pref("age")) }
    var sex by remember { mutableStateOf(s.pref("sex")) }
    var mobile by remember { mutableStateOf(s.pref("mobile")) }
    var email by remember { mutableStateOf(s.pref("email")) }
    var about by remember { mutableStateOf(s.pref("about")) }
    var photo by remember { mutableStateOf(s.pref("photo")) }
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        runCatching {
            val bmp = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { d, _, _ -> d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE }
            photo = E2E.b64(shrinkPhoto(bmp))
        }.onFailure { app.toast = "Couldn't read that photo" }
    }
    Back("My details", onBack) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Box(Modifier.clickable { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                Avatar(listOf(first, last).joinToString(" ").ifBlank { "?" }, 110, photo = photo)
                Icon(Icons.Default.PhotoCamera, null, Modifier.align(Alignment.BottomEnd).background(MaterialTheme.colorScheme.primary, CircleShape).padding(6.dp), tint = Color.White)
            }
        }
        if (photo.isNotEmpty()) TextButton({ photo = "" }, Modifier.align(Alignment.CenterHorizontally)) { Text("Remove photo") }
        OutlinedTextField(first, { first = it }, label = { Text("First name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(last, { last = it }, label = { Text("Last name") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
        OutlinedTextField(age, { v -> age = v.filter { it.isDigit() }.take(3) }, label = { Text("Age") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
        Text("Sex", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 10.dp))
        FlowRow { listOf("Male", "Female", "Other", "Prefer not to say").forEach { o -> FilterChip(sex == o, { sex = if (sex == o) "" else o }, label = { Text(o) }, modifier = Modifier.padding(end = 6.dp)) } }
        OutlinedTextField(mobile, { mobile = it }, label = { Text("Mobile") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone), modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
        OutlinedTextField(email, { email = it }, label = { Text("Email") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
        OutlinedTextField(about, { about = it.take(140) }, label = { Text("About (e.g. Available, At work)") }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
        Text("Your name and photo are shared with people you chat with. Age, sex, mobile and email stay on this phone — they're used to fill forms in modules and are never uploaded.",
            Modifier.padding(top = 10.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button({
            busy = true
            val photoChanged = photo != s.pref("photo")
            val aboutChanged = about != s.pref("about")
            listOf("first" to first.trim(), "last" to last.trim(), "age" to age, "sex" to sex, "mobile" to mobile.trim(), "email" to email.trim(), "about" to about.trim(), "photo" to photo)
                .forEach { (k, v) -> s.setPref(k, v) }
            app.run(scope) {
                app.sync.saveMyDetails(first, last, if (photo.isEmpty()) null else E2E.unb64(photo), photoChanged)
                if (aboutChanged) app.sync.sendAbout()
                app.toast = "Saved"
                busy = false
            }
        }, enabled = first.isNotBlank() && !busy, modifier = Modifier.fillMaxWidth().padding(top = 16.dp)) { Text(if (busy) "Saving…" else "Save") }
    }
}

// MARK: - Privacy

@Composable
fun PrivacyScreen(app: AppState, onBack: () -> Unit) {
    val s = app.store
    var contactsOnly by remember { mutableStateOf(s.prefBool("photoContactsOnly", true)) }
    var aboutContacts by remember { mutableStateOf(s.prefBool("aboutContacts", true)) }
    var receipts by remember { mutableStateOf(s.prefBool("readReceipts", true)) }
    val scope = rememberCoroutineScope()
    Back("Privacy", onBack) {
        Toggle("Profile photo: only people I chat with", "Off = anyone with your iTeam ID sees it", contactsOnly) {
            contactsOnly = it; s.setPref("photoContactsOnly", it)
            app.run(scope) { app.sync.saveMyDetails(s.pref("first"), s.pref("last"), s.pref("photo").takeIf { p -> p.isNotEmpty() }?.let { p -> E2E.unb64(p) }, true) }
        }
        Toggle("Show my About to contacts", null, aboutContacts) { aboutContacts = it; s.setPref("aboutContacts", it); app.run(scope) { app.sync.sendAbout() } }
        Toggle("Read receipts", "Off = others don't see blue ticks from you", receipts) { receipts = it; s.setPref("readReceipts", it) }
        var rem by remember { mutableStateOf(s.prefBool("reminders", true)) }
        val ctx = androidx.compose.ui.platform.LocalContext.current
        Toggle("Reminders on this phone", "Medicines, punch-in, bills, events, meetings, tasks", rem) { rem = it; s.setPref("reminders", it); Reminders.reschedule(ctx) }
        var lock by remember { mutableStateOf(s.prefBool("appLock", false)) }
        Toggle("Lock with fingerprint / face / PIN", "Asks when you open iTeam after 30 seconds away", lock) { lock = it; s.setPref("appLock", it) }
    }
}

@Composable
private fun Toggle(title: String, sub: String?, value: Boolean, onChange: (Boolean) -> Unit) =
    ListItem(headlineContent = { Text(title) }, supportingContent = sub?.let { { Text(it) } }, trailingContent = { Switch(value, onChange) })

// MARK: - Appearance

@Composable
fun AppearanceScreen(app: AppState, onBack: () -> Unit) {
    Back("Appearance", onBack) {
        Text("Look", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        LookState.looks.forEach { l ->
            val sel = LookState.look.id == l.id
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp).border(if (sel) 2.dp else 1.dp, if (sel) l.primary else MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(14.dp))
                .clickable { LookState.look = l; app.store.setPref("look", l.id) }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(44.dp).background(Brush.linearGradient(listOf(l.primary, l.secondary)), RoundedCornerShape(12.dp)))
                Spacer(Modifier.width(12.dp))
                Text(l.name, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                if (sel) Icon(Icons.Default.CheckCircle, null, tint = l.primary)
            }
        }
        Text("Light or dark", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 16.dp))
        Row { listOf("system", "light", "dark").forEach { m -> FilterChip(LookState.mode == m, { LookState.mode = m; app.store.setPref("mode", m) }, label = { Text(modeName(m)) }, modifier = Modifier.padding(end = 6.dp)) } }
    }
}

// MARK: - Bottom bar

@Composable
fun BottomBarScreen(app: AppState, onBack: () -> Unit) {
    var pinned by remember { mutableStateOf(app.store.prefList("pinned", listOf("tasks", "rooms"))) }
    Back("Bottom bar", onBack) {
        Text("Chats · two of your choice · Modules · Settings. Pick two:", style = MaterialTheme.typography.bodyMedium)
        tabOptions.forEach { t ->
            val on = t.id in pinned
            ListItem(modifier = Modifier.clickable {
                pinned = if (on) pinned - t.id else (pinned + t.id).takeLast(2)
                app.store.setPref("pinned", pinned); app.changed()
            }, leadingContent = { Icon(t.icon, null) }, headlineContent = { Text(t.title) },
                trailingContent = { if (on) Text("${pinned.indexOf(t.id) + 1}", fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary) })
        }
    }
}

// MARK: - Module Store

@Composable
fun ModuleStoreScreen(app: AppState, onBack: () -> Unit, open: (Page) -> Unit) {
    var added by remember { mutableStateOf(app.store.prefList("modules", emptyList())) }
    val shown = remember(app.tick, added) { visibleModules(app.store) }
    fun toggle(id: String) {
        added = if (id in added) added - id else added + id
        app.store.setPref("modules", added); app.changed()
    }
    Back("Module Store", onBack) {
        Text("Everything is free on Android. Remove only hides a module — your records stay. A module also appears when someone shares something with you in it.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        StoreRow("Attendance", "Punch in/out, leave, holidays, monthly register for your team", listOf(Color(0xFF11998E), Color(0xFF38EF7D)), Icons.Default.Fingerprint, "attendance" in shown, "attendance" in added, { toggle("attendance") }) { open(Page.Attendance) }
        StoreRow("Finance", "Income, expenses, dues, approvals — personal and company books", listOf(Color(0xFF2193B0), Color(0xFF6DD5ED)), Icons.Default.AccountBalanceWallet, "finance" in shown, "finance" in added, { toggle("finance") }) { open(Page.Finance) }
        StoreRow("CRM", "Leads, pipeline, follow-ups, quotes your client accepts", listOf(Color(0xFFFF512F), Color(0xFFDD2476)), Icons.Default.Handshake, "crm" in shown, "crm" in added, { toggle("crm") }) { open(Page.CRM) }
        StoreRow("Society", "Flats, maintenance bills, complaints, visitors, notices", listOf(Color(0xFF8E2DE2), Color(0xFF4A00E0)), Icons.Default.Apartment, "society" in shown, "society" in added, { toggle("society") }) { open(Page.Societies) }
        StoreRow("Gym & Training", "Sessions, memberships, payments, trainer requests", listOf(Color(0xFFF7971E), Color(0xFFFFD200)), Icons.Default.FitnessCenter, "gym" in shown, "gym" in added, { toggle("gym") }) { open(Page.Gym) }
        StoreRow("Builder & Infra", "Projects, units, sales, stock, machines, approvals, FSI", listOf(Color(0xFFF7971E), Color(0xFF8E2DE2)), moduleIcon("build"), "build" in shown, "build" in added, { toggle("build") }) { open(Page.Builder) }
        BizSpecs.all.forEach { s ->
            StoreRow(s.title, (listOfNotNull(s.parent?.plural) + s.children.map { it.plural }).joinToString(", "), specColors(s), moduleIcon(s.module),
                s.module in shown, s.module in added, { toggle(s.module) }) { open(Page.BizModule(s.module)) }
        }
        Text("Free on every phone: chat, Tasks, mini, Events, Family Safety, Care, Rooms and Fluffy Fight practice (Modules tab).", Modifier.padding(top = 12.dp), style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun StoreRow(title: String, sub: String, colors: List<Color>, icon: ImageVector, shown: Boolean, added: Boolean, toggle: () -> Unit, open: () -> Unit) {
    ListItem(modifier = Modifier.clickable(enabled = shown, onClick = open),
        leadingContent = { Box(Modifier.size(44.dp).background(Brush.linearGradient(colors), RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) { Icon(icon, null, tint = Color.White) } },
        headlineContent = { Text(title, fontWeight = FontWeight.SemiBold) },
        supportingContent = { Text(sub, maxLines = 2) },
        trailingContent = { if (added) OutlinedButton(toggle) { Text("Remove") } else Button(toggle) { Text(if (shown) "Add" else "Get — Free") } })
}
