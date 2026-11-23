package com.jondhale.iteam

import android.content.Context
import android.content.Intent
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

// Chat bubble colours, Help & grievances, Request a module, and branded PDF reports.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun XScreen(title: String, onBack: () -> Unit, content: @Composable ColumnScope.() -> Unit) =
    Scaffold(topBar = { TopAppBar(title = { Text(title) }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }) }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), content = content)
    }

// MARK: - Chat bubble colour (same palette as the iPhone)

val bubblePalette = listOf(0x52A866, 0xDCF8C6, 0x5B4BD5, 0xE6DEFC, 0xB264D6, 0xEDD9F3, 0xD9745A, 0xF8E3D9, 0x3A8076, 0xD2EFEC, 0x3D6AE0, 0xD6E5FA,
    0x234E77, 0xD5E1EA, 0x41503D, 0xE0E7DF, 0x6A2331, 0xF4CDD5, 0x333333, 0xD9DADC, 0x4290F5, 0xD3E4FB, 0x46A0DD, 0xD5E3EE, 0x976B4E, 0xF0DFD3,
    0xBEA88A, 0xEDE7DF, 0x4AA686, 0xDDF8EC, 0xE0CC42, 0xFAF7BC, 0x7DA344, 0xEAFCC5, 0xD3426E, 0xF8DCE6, 0xD62B3B, 0xF5D9DE).map { 0xFF000000L or it.toLong() }

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun BubbleColorScreen(app: AppState, onBack: () -> Unit) {
    var which by remember { mutableStateOf("bubbleOut") }
    var tick by remember { mutableIntStateOf(0) }
    XScreen("Chat bubble colour", onBack) {
        Row { listOf("bubbleOut" to "My messages", "bubbleIn" to "Their messages").forEach { (k, t) -> FilterChip(which == k, { which = k }, { Text(t) }, Modifier.padding(end = 6.dp)) } }
        if (tick >= 0) Column(Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
            Box(Modifier.align(Alignment.Start).background(bubbleBrush(app, false), RoundedCornerShape(16.dp)).padding(12.dp)) { Text("Hi! How's the site visit?", color = bubbleText(app, false)) }
            Spacer(Modifier.height(6.dp))
            Box(Modifier.align(Alignment.End).background(bubbleBrush(app, true), RoundedCornerShape(16.dp)).padding(12.dp)) { Text("All good — sending photos 👍", color = bubbleText(app, true)) }
        }
        val current = app.store.pref(which).toLongOrNull()
        FlowRow {
            Box(Modifier.padding(6.dp).size(52.dp).border(if (current == null) 3.dp else 1.dp, MaterialTheme.colorScheme.primary, CircleShape).clickable { app.store.setPref(which, null); tick++; app.changed() },
                contentAlignment = Alignment.Center) { Text("Auto", style = MaterialTheme.typography.labelSmall) }
            bubblePalette.forEach { c ->
                Box(Modifier.padding(6.dp).size(52.dp).background(Color(c), CircleShape).border(if (current == c) 3.dp else 0.dp, MaterialTheme.colorScheme.onSurface, CircleShape)
                    .clickable { app.store.setPref(which, c.toString()); tick++; app.changed() }, contentAlignment = Alignment.Center) {
                    if (current == c) Icon(Icons.Default.Check, null, tint = if (isLightColor(c)) Color.Black else Color.White)
                }
            }
        }
        Text("Only on this phone — others see their own colours.", style = MaterialTheme.typography.bodySmall)
    }
}

// MARK: - Help & grievances (same CloudKit records as the iPhone: Complaint + ComplaintNote)

@Composable
fun HelpScreen(app: AppState, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var list by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var notes by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var raising by remember { mutableStateOf(false) }
    val cloud = app.sync.cloudKit
    suspend fun load() = withContext(Dispatchers.IO) {
        runCatching {
            list = cloud.query("Complaint", JSONArray().put(cloud.eq("user", app.store.me)), sortByCreated = true)
            notes = list.flatMap { c -> runCatching { cloud.query("ComplaintNote", JSONArray().put(cloud.eq("complaint", c.optString("recordName")))) }.getOrDefault(emptyList()) }
        }
    }
    LaunchedEffect(Unit) { load() }
    XScreen("Help & grievances", onBack) {
        Button({ raising = true }, Modifier.fillMaxWidth()) { Icon(Icons.Default.Feedback, null); Spacer(Modifier.width(8.dp)); Text("Raise a grievance or problem") }
        Text("Goes to the iTeam team. Grievances are stored in iCloud's public database (not end-to-end encrypted) so the team can read them. We acknowledge within 24 hours and aim to resolve within 15 days.",
            Modifier.padding(vertical = 10.dp), style = MaterialTheme.typography.bodySmall)
        Text("Grievance Officer: Devendra Jondhale · deven86@me.com", style = MaterialTheme.typography.labelMedium)
        Text("My grievances", Modifier.padding(top = 16.dp), fontWeight = FontWeight.Bold)
        if (list.isEmpty()) Text("None yet.", style = MaterialTheme.typography.bodySmall)
        list.forEach { c ->
            val ns = notes.filter { it.fstr("complaint") == c.optString("recordName") }
            Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) { Column(Modifier.padding(12.dp)) {
                Text("${c.fstr("cat")}: ${c.fstr("text")}")
                Text(ns.lastOrNull()?.fstr("status")?.ifEmpty { null } ?: "Received", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                ns.forEach { n -> if (n.fstr("note").isNotEmpty()) Text("↳ ${n.fstr("note")}", style = MaterialTheme.typography.bodySmall) }
            } }
        }
    }
    if (raising) {
        var cat by remember { mutableStateOf("Bug / not working") }; var text by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = { raising = false }, title = { Text("Raise a grievance") }, text = { Column {
            listOf("Bug / not working", "Payment / subscription", "Privacy / data", "Abuse / safety", "Account", "Other").forEach { c ->
                Row(Modifier.clickable { cat = c }, verticalAlignment = Alignment.CenterVertically) { RadioButton(cat == c, { cat = c }); Text(c) } }
            OutlinedTextField(text, { text = it }, label = { Text("Describe the problem") }, minLines = 3, modifier = Modifier.fillMaxWidth())
        } }, confirmButton = { TextButton({
            raising = false
            app.run(scope) {
                cloud.modify(listOf(cloud.create("Complaint", null, JSONObject().put("user", cloud.v(app.store.me)).put("name", cloud.v(app.store.myName))
                    .put("cat", cloud.v(cat)).put("text", cloud.v(text.trim())))))
                app.toast = "Sent — we'll reply here"; load()
            }
        }, enabled = text.isNotBlank()) { Text("Send") } }, dismissButton = { TextButton({ raising = false }) { Text("Cancel") } })
    }
}

// MARK: - Request a module

@Composable
fun ModuleRequestScreen(app: AppState, onBack: () -> Unit) {
    var title by remember { mutableStateOf("") }; var problem by remember { mutableStateOf("") }; var details by remember { mutableStateOf("") }
    var users by remember { mutableStateOf("") }; var pay by remember { mutableIntStateOf(1) }; var contact by remember { mutableStateOf(app.store.pref("email")) }
    val scope = rememberCoroutineScope()
    XScreen("Request a module", onBack) {
        Text("Tell us what to build next. Requests go to the iTeam team (not end-to-end encrypted).", style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(title, { title = it }, label = { Text("Module name (e.g. School management)") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(problem, { problem = it }, label = { Text("What problem does it solve?") }, minLines = 2, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(details, { details = it }, label = { Text("Features you need") }, minLines = 3, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(users, { users = it }, label = { Text("Who would use it?") }, modifier = Modifier.fillMaxWidth())
        Text("Would you pay for it?", Modifier.padding(top = 8.dp), style = MaterialTheme.typography.labelMedium)
        Row { listOf("Free only", "Maybe", "Yes, I'd pay").forEachIndexed { i, t -> FilterChip(pay == i, { pay = i }, { Text(t) }, Modifier.padding(end = 4.dp)) } }
        OutlinedTextField(contact, { contact = it }, label = { Text("Contact (optional)") }, modifier = Modifier.fillMaxWidth())
        Button({
            val cloud = app.sync.cloudKit
            app.run(scope) {
                cloud.modify(listOf(cloud.create("ModuleRequest", "R" + newID(), JSONObject().put("title", cloud.v(title.trim())).put("problem", cloud.v(problem.trim()))
                    .put("details", cloud.v(details.trim())).put("users", cloud.v(users.trim())).put("pay", cloud.v(pay)).put("name", cloud.v(app.store.myName))
                    .put("contact", cloud.v(contact.trim())).put("ver", cloud.v("Android " + BuildConfig.VERSION_NAME)))))
                app.toast = "Thanks — request sent"
            }
            onBack()
        }, enabled = title.isNotBlank() && problem.isNotBlank(), modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) { Text("Send request") }
    }
}

// MARK: - Branded PDF reports: iTeam logo + module name on every page

object Reports {
    /** Builds an A4 PDF (logo, module name, title, date, then the lines) and opens the share sheet. */
    fun share(ctx: Context, module: String, title: String, lines: List<String>, colors: List<Long> = listOf(0xFF5B5BF7, 0xFF00B4D8), charts: List<Chart> = emptyList()) {
        val doc = PdfDocument()
        val w = 595; val h = 842; val left = 40f
        val body = Paint().apply { textSize = 11f; isAntiAlias = true }
        val bold = Paint(body).apply { typeface = Typeface.DEFAULT_BOLD }
        var pageNo = 0
        var page: PdfDocument.Page? = null
        var y = 0f
        fun header() {
            page?.let { doc.finishPage(it) }
            pageNo++
            page = doc.startPage(PdfDocument.PageInfo.Builder(w, h, pageNo).create())
            val c = page!!.canvas
            // iT glass logo
            val logo = Paint().apply { isAntiAlias = true; shader = LinearGradient(left, 24f, left + 30, 54f, 0xFF5B5BF7.toInt(), 0xFF00B4D8.toInt(), Shader.TileMode.CLAMP) }
            c.drawRoundRect(RectF(left, 24f, left + 30, 54f), 8f, 8f, logo)
            c.drawText("iT", left + 7, 45f, Paint().apply { color = android.graphics.Color.WHITE; textSize = 14f; typeface = Typeface.DEFAULT_BOLD; isAntiAlias = true })
            c.drawText("iTeam", left + 38, 44f, Paint(bold).apply { textSize = 14f })
            // Module name on the right, in the module's colour
            val mp = Paint(bold).apply { textSize = 12f; color = colors.first().toInt() }
            c.drawText(module, w - left - mp.measureText(module), 44f, mp)
            c.drawLine(left, 62f, w - left, 62f, Paint().apply { color = 0xFFDDDDDD.toInt() })
            c.drawText("Page $pageNo", w - left - 40, h - 24f, Paint(body).apply { textSize = 9f; color = 0xFF888888.toInt() })
            y = 82f
            if (pageNo == 1) {
                c.drawText(title, left, y + 8, Paint(bold).apply { textSize = 18f }); y += 24
                c.drawText("Generated ${dateText(System.currentTimeMillis())} ${time(System.currentTimeMillis())}", left, y + 6, Paint(body).apply { textSize = 9f; color = 0xFF888888.toInt() }); y += 22
            }
        }
        header()
        // Charts first, two per row (like the iPhone reports).
        val usable = charts.filter { it.usable }
        if (usable.isNotEmpty()) {
            val cw = (w - 2 * left - 12) / 2; val chh = 150f
            usable.chunked(2).forEach { row ->
                if (y + chh > h - 50) header()
                row.forEachIndexed { i, ch -> Charts.draw(page!!.canvas, ch, RectF(left + i * (cw + 12), y, left + i * (cw + 12) + cw, y + chh)) }
                y += chh + 12
            }
            y += 6
        }
        for (raw in lines) {
            val isHead = raw.startsWith("## ")
            val p = if (isHead) Paint(bold).apply { textSize = 13f } else body
            val text = raw.removePrefix("## ")
            val words = text.split(" "); var line = ""
            val out = mutableListOf<String>()
            for (wd in words) { val t = if (line.isEmpty()) wd else "$line $wd"; if (p.measureText(t) > w - 2 * left) { out += line; line = wd } else line = t }
            out += line
            if (isHead) y += 8
            for (l in out) { if (y > h - 50) header(); page!!.canvas.drawText(l, left, y, p); y += p.textSize + 5 }
        }
        page?.let { doc.finishPage(it) }
        val dir = File(ctx.cacheDir, "open").apply { mkdirs() }
        val f = File(dir, "${module} – ${title}.pdf".replace("/", "-"))
        f.outputStream().use { doc.writeTo(it) }
        doc.close()
        val uri = FileProvider.getUriForFile(ctx, "com.jondhale.iteam.files", f)
        ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("application/pdf").putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share $module report"))
    }
}

/** Toolbar button: "Export report (PDF)". */
@Composable
fun PdfButton(module: String, title: String, charts: () -> List<Chart> = { emptyList() }, lines: () -> List<String>) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    IconButton({ scope.launch { runCatching { Reports.share(ctx, module, title, lines(), charts = charts()) } } }) { Icon(Icons.Default.PictureAsPdf, "Export report (PDF)") }
}

/** Report text for each module. */
object ReportText {
    fun biz(app: AppState, spec: BizSpec): List<String> {
        val all = app.store.bizList(spec.module).filter { !it.deleted }
        val out = mutableListOf<String>()
        val parents = if (spec.parent != null) all.filter { it.kind == spec.parent.id } else listOf<Rec?>(null).filterNotNull()
        if (spec.parent == null) { out += "## ${spec.flat?.plural ?: "Entries"}"; all.forEach { out += row(spec, it) } }
        parents.forEach { p ->
            val kids = all.filter { it.parentID == p.id }
            out += "## ${p.title}${if (p.s("subtitle").isEmpty()) "" else " — " + p.s("subtitle")}   ${spec.balanceLabel}: ${money(Biz.balance(spec, kids))}"
            kids.sortedBy { it.due ?: it.date ?: it.created }.forEach { out += row(spec, it) }
        }
        return out
    }
    private fun row(spec: BizSpec, r: Rec) = "• ${spec.kind(r.kind)?.label ?: r.kind}: ${r.title.ifEmpty { r.s("notes") }}" +
        (if (r.amount != 0.0) " · ${money(r.amount)}" else "") + ((r.due ?: r.date)?.let { " · " + dateText(it) } ?: "") + (if (r.status.isEmpty()) "" else " · " + r.status)

    fun build(app: AppState, projectID: String): List<String> {
        val all = app.store.buildList().filter { !it.deleted && (it.projectID == projectID || it.id == projectID) }
        val out = mutableListOf<String>()
        all.groupBy { it.bkind }.forEach { (k, list) ->
            out += "## ${BuildKinds.of(k).plural} (${list.size})"
            list.forEach { r -> out += "• ${r.btitle} ${if (r.status.isEmpty()) "" else "· " + r.status} ${listOf("amount", "value", "price").firstNotNullOfOrNull { f -> r.f(f).takeIf { it.isNotEmpty() }?.let { money(num(it)) } } ?: ""}" }
        }
        return out
    }

    fun finance(app: AppState, book: String): List<String> = app.store.finList().filter { it.s("book") == book && !it.deleted }.sortedBy { it.finDate }.map { r ->
        "${dateText(r.finDate)} · ${if (r.isIn) "+" else "−"}${money(r.amount)} · ${r.s("category")} · ${r.d.optString("title")} ${r.d.optString("party")} · ${r.status}"
    }.let { listOf("## Entries") + it }

    fun misc(app: AppState, t: String, line: (Rec) -> String): List<String> = app.store.miscList(t).filter { !it.deleted }.map(line)
}
