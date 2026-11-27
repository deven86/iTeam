package com.jondhale.iteam

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

val priorities = listOf("Low", "Normal", "High", "Urgent")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TasksTab(app: AppState, open: (Page) -> Unit) {
    val me = app.store.me
    var filter by remember { mutableIntStateOf(0) }
    val all = remember(app.tick) { app.store.taskList() }
    val shown = all.filter { t ->
        when (filter) {
            0 -> t.status != "done" && (t.assignees.contains(me) || t.assignees.isEmpty())
            1 -> t.status != "done" && t.createdBy == me
            2 -> t.needsAcceptance && t.assignees.contains(me) && t.answer(me) == null
            else -> t.status == "done"
        }
    }.sortedWith(compareBy<TaskRec> { it.due ?: Long.MAX_VALUE }.thenByDescending { it.updated })
    val now = System.currentTimeMillis()
    val open = all.filter { it.status != "done" && !it.deleted }
    val mine = open.filter { it.assignees.contains(me) || it.assignees.isEmpty() }
    val endOfToday = lastDays(1)[0].second + 86_400_000L
    val today = mine.filter { (it.due ?: Long.MAX_VALUE) < endOfToday }
    val overdue = open.filter { (it.due ?: Long.MAX_VALUE) < now }
    val toAccept = open.filter { it.needsAcceptance && it.assignees.contains(me) && it.answer(me) == null }
    val upcoming = open.sortedBy { it.due ?: Long.MAX_VALUE }.take(8)
    val days = lastDays(7)
    val doneByDay = days.map { (_, start) -> all.count { it.status == "done" && it.updated in start until start + 86_400_000L }.toFloat() }
    fun people(t: TaskRec) = t.assignees.map { app.store.name(it) }
    fun leftText(t: TaskRec) = t.due?.let { d -> val days2 = ((d - now) / 86_400_000L).toInt()
        when { d < now -> "Overdue"; days2 == 0 -> "Due today"; days2 == 1 -> "1 day remaining"; else -> "$days2 days remaining" } } ?: "No due date"
    Scaffold(containerColor = MaterialTheme.colorScheme.background) { pad ->
        LazyColumn(Modifier.padding(pad), contentPadding = PaddingValues(bottom = 100.dp)) {
            item {
                DashHeader("Hello, " + app.store.myName.substringBefore(' ').ifBlank { "there" },
                    "You have ${today.size} task${if (today.size == 1) "" else "s"} today") {
                    IconButton({ open(Page.Meetings) }) { Icon(Icons.Default.Groups, "Meetings", tint = Brand) }
                }
            }
            item { StatRow(Triple("Open", "${mine.size}", null), Triple("Overdue", "${overdue.size}", null), Triple("To accept", "${toAccept.size}", { filter = 2 })) }
            item {
                Row(Modifier.padding(horizontal = 14.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AssistChip({ open(Page.Meetings) }, { Text("Meetings") }, leadingIcon = { Icon(Icons.Default.Groups, null, Modifier.size(18.dp)) })
                    AssistChip({ open(Page.MyDay) }, { Text("My Day") }, leadingIcon = { Icon(Icons.Default.WbSunny, null, Modifier.size(18.dp)) })
                    AssistChip({ open(Page.Events) }, { Text("Events") }, leadingIcon = { Icon(Icons.Default.Celebration, null, Modifier.size(18.dp)) })
                }
            }
            if (upcoming.isNotEmpty()) {
                item { SectionTitle("Upcoming tasks", upcoming.size) }
                item {
                    HorizontalCards {
                        upcoming.forEachIndexed { i, t ->
                            val n = t.assignees.size.coerceAtLeast(1)
                            VioletCard(t.title, t.conv?.let { app.store.conv(it)?.title } ?: "Personal",
                                t.due?.let { dateText(it) } ?: "", leftText(t), people(t),
                                progress = if (t.assignees.size > 1) t.doneBy.size.toFloat() / n else null,
                                modifier = Modifier.width(250.dp), filled = i % 2 == 0) { open(Page.Task(t.id)) }
                        }
                    }
                }
            }
            item { BarChartCard("Completed this week", "${doneByDay.sum().toInt()} done", days.map { it.first }, doneByDay) }
            item {
                ScrollableTabRow(filter, edgePadding = 8.dp, containerColor = Color.Transparent) {
                    listOf("For me", "I assigned", "To accept", "Done").forEachIndexed { i, s -> Tab(filter == i, { filter = i }, text = { Text(s) }) }
                }
            }
            if (shown.isEmpty()) item { Centered("No tasks here.\n\nCreate a task from any chat with the ✓+ button, or long-press a message → Make a task.") }
            run {
                items(shown, key = { it.id }) { t ->
                    ListItem(modifier = Modifier.clickable { open(Page.Task(t.id)) },
                        leadingContent = {
                            Icon(if (t.status == "done") Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, null,
                                tint = if (t.status == "done") Color(0xFF22C55E) else priorityColor(t.p.optInt("priority", 1)))
                        },
                        headlineContent = { Text(t.title, fontWeight = FontWeight.SemiBold) },
                        supportingContent = {
                            val conv = t.conv?.let { app.store.conv(it)?.title } ?: "Personal"
                            val due = t.due?.let { (if (it < System.currentTimeMillis() && t.status != "done") "⚠️ overdue " else "due ") + dateText(it) } ?: ""
                            Text(listOf(statusTitle(t.status), due, conv).filter { it.isNotEmpty() }.joinToString(" · "))
                        })
                    HorizontalDivider()
                }
            }
        }
    }
}

fun priorityColor(p: Int) = when (p) { 3 -> Color(0xFFE5484D); 2 -> Color(0xFFF59E0B); 0 -> Color.Gray; else -> Brand }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskScreen(app: AppState, id: String, onBack: () -> Unit, open: (Page) -> Unit) {
    val t = remember(app.tick, id) { app.store.task(id) } ?: return
    val me = app.store.me
    val scope = rememberCoroutineScope()
    var comment by remember { mutableStateOf("") }
    var declining by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    var confirmDelete by remember { mutableStateOf(false) }
    val myAnswer = t.answer(me)
    val mustAnswer = t.needsAcceptance && t.assignees.contains(me) && myAnswer == null && t.createdBy != me
    Scaffold(topBar = {
        TopAppBar(title = { Text("Task") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } }, actions = {
            t.conv?.let { c -> IconButton({ open(Page.Chat(c)) }) { Icon(Icons.Default.Chat, "Chat") } }
            if (t.createdBy == me && !t.deleted) IconButton({ confirmDelete = true }) { Icon(Icons.Default.Delete, "Delete") }
        })
    }, bottomBar = {
        Row(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(comment, { comment = it }, placeholder = { Text("Comment") }, modifier = Modifier.weight(1f), maxLines = 4)
            IconButton({ val c = comment.trim(); if (c.isNotEmpty()) { comment = ""; app.run(scope) { app.sync.comment(id, c) } } }) {
                Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Brand)
            }
        }
    }) { pad ->
        Column(Modifier.padding(pad).padding(16.dp).verticalScroll(rememberScrollState())) {
            Text(t.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            if (t.deleted) Text("Deleted by the creator", color = MaterialTheme.colorScheme.error)
            Text("${priorities.getOrElse(t.p.optInt("priority", 1)) { "Normal" }} priority" + (t.due?.let { " · due ${dateText(it)}" } ?: ""),
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("Created by ${app.store.name(t.createdBy)}" + (t.conv?.let { " in ${app.store.conv(it)?.title ?: "a chat"}" } ?: ""),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (t.p.optString("notes").isNotBlank()) Text(t.p.optString("notes"), Modifier.padding(top = 12.dp))

            if (mustAnswer) Card(Modifier.fillMaxWidth().padding(top = 16.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Text("${app.store.name(t.createdBy)} assigned this to you", fontWeight = FontWeight.Bold)
                    Row(Modifier.padding(top = 8.dp)) {
                        Button({ app.run(scope) { app.sync.answerTask(id, true, "") } }) { Text("Accept") }
                        Spacer(Modifier.width(8.dp))
                        OutlinedButton({ declining = true }) { Text("Decline") }
                    }
                }
            }

            Text("Status", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
            Row {
                listOf("open" to "To do", "inProgress" to "In progress", "done" to "Done").forEach { (s, label) ->
                    FilterChip(t.status == s, { if (t.status != s && !t.deleted && !mustAnswer) app.run(scope) { app.sync.setTaskStatus(id, s) } },
                        label = { Text(label) }, modifier = Modifier.padding(end = 6.dp))
                }
            }
            if (t.p.optString("policy") == "all" && t.assignees.contains(me)) {
                val mine = t.doneBy.containsKey(me)
                OutlinedButton({ app.run(scope) { app.sync.taskPart(id, !mine) } }, Modifier.padding(top = 6.dp)) {
                    Text(if (mine) "Mark my part not done" else "Mark my part done")
                }
            }

            Text("Assigned to", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
            if (t.assignees.isEmpty()) Text("Everyone in the chat")
            t.assignees.forEach { u ->
                val a = t.acceptance[u]
                val state = when { !t.needsAcceptance -> ""; a == null -> " · waiting"; a.startsWith("accepted") -> " · accepted"
                    else -> " · declined" + (a.substringAfter("|", "").let { if (it.isEmpty()) "" else ": $it" }) }
                Text("• ${app.store.name(u)}$state${if (t.doneBy.containsKey(u)) " · part done ✅" else ""}")
            }

            var editFollow by remember { mutableStateOf(false) }
            Text("Follow-ups", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
            val fu = t.p.optJSONObject("followUp")?.takeIf { f -> f.optDoubleOrNull("until")?.let { SwiftDate.toMillis(it) > System.currentTimeMillis() } ?: true }
            Text(fu?.let { followUpText(it) } ?: "None", style = MaterialTheme.typography.bodyMedium)
            if (t.createdBy == me && t.status != "done") Row {
                TextButton({ editFollow = true }) { Text(if (fu == null) "Add follow-ups" else "Change") }
                if (fu != null) TextButton({ app.run(scope) { app.sync.updateTask(id, "stopped follow-ups") { p -> p.put("followUp", org.json.JSONObject(fu.toString()).put("until", SwiftDate.now())); listOf("followUp") } } }) { Text("Stop") }
            }
            if (editFollow) FollowUpDialog(fu, app.store.conv(t.conv ?: "")?.isGroup == true, onDone = { editFollow = false }) { f ->
                if (f != null) app.run(scope) { app.sync.updateTask(id, "set follow-ups: ${followUpText(f)}") { p -> p.put("followUp", f); listOf("followUp") } }
            }

            TaskExtras(app, t)

            Text("Comments", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 16.dp))
            if (t.comments.isEmpty()) Text("No comments yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            t.comments.sortedBy { it.optLong("at") }.forEach { c ->
                Column(Modifier.padding(vertical = 4.dp)) {
                    Text("${app.store.name(c.optString("from"))} · ${time(c.optLong("at"))}", style = MaterialTheme.typography.labelSmall, color = Brand)
                    Text(c.optString("body"))
                }
            }
            Text("Checklists, files, expenses and follow-ups are managed on iPhone/iPad.", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 16.dp))
        }
    }
    if (declining) AlertDialog(onDismissRequest = { declining = false }, title = { Text("Decline the task?") },
        text = { OutlinedTextField(note, { note = it }, label = { Text("Reason (optional)") }) },
        confirmButton = { TextButton({ declining = false; app.run(scope) { app.sync.answerTask(id, false, note.trim()) } }) { Text("Decline") } },
        dismissButton = { TextButton({ declining = false }) { Text("Cancel") } })
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete this task for everyone?") },
        confirmButton = { TextButton({ confirmDelete = false; app.run(scope) { app.sync.deleteTask(id) } }) { Text("Delete") } },
        dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel") } })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskEditorDialog(app: AppState, conv: Conv, onDone: () -> Unit) {
    val me = app.store.me
    var title by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }
    var priority by remember { mutableIntStateOf(1) }
    var due by remember { mutableStateOf<Long?>(null) }
    var pickDate by remember { mutableStateOf(false) }
    val people = remember { mutableStateListOf<String>().also { l -> if (!conv.isGroup) app.sync.peerOf(conv.id)?.let { l.add(it) } } }
    var everyone by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var followUp by remember { mutableStateOf<org.json.JSONObject?>(null) }
    var editFollow by remember { mutableStateOf(false) }
    if (editFollow) FollowUpDialog(followUp, conv.isGroup, onDone = { editFollow = false }) { followUp = it }
    AlertDialog(onDismissRequest = onDone, title = { Text("New task") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(title, { title = it }, label = { Text("Task") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(notes, { notes = it }, label = { Text("Details (optional)") }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp), maxLines = 4)
                Text("Priority", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 10.dp))
                Row { priorities.forEachIndexed { i, p -> FilterChip(priority == i, { priority = i }, label = { Text(p) }, modifier = Modifier.padding(end = 4.dp)) } }
                TextButton({ pickDate = true }) { Icon(Icons.Default.Event, null); Spacer(Modifier.width(6.dp)); Text(due?.let { "Due ${dateText(it)}" } ?: "Add a due date") }
                TextButton({ editFollow = true }) { Icon(Icons.Default.NotificationsActive, null); Spacer(Modifier.width(6.dp)); Text(followUp?.let { followUpText(it) } ?: "Add follow-up reminders") }
                Text("Assign to", style = MaterialTheme.typography.labelMedium)
                conv.members.forEach { u ->
                    Row(Modifier.fillMaxWidth().clickable { if (u in people) people.remove(u) else people.add(u) }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(u in people, { if (it) people.add(u) else people.remove(u) })
                        Text(if (u == me) "Me" else app.store.name(u))
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(everyone, { everyone = it }); Spacer(Modifier.width(8.dp))
                    Text("Starts at once (no Accept needed)", style = MaterialTheme.typography.bodySmall)
                }
            }
        },
        confirmButton = {
            TextButton({
                busy = true
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) { app.sync.createTask(conv.id, title.trim(), notes.trim(), people.toList(), due, priority, everyone, followUp) }
                        app.changed(); onDone()
                    } catch (e: Exception) { app.toast = e.message }
                    busy = false
                }
            }, enabled = title.isNotBlank() && !busy) { Text(if (busy) "Creating…" else "Create") }
        },
        dismissButton = { TextButton(onDone) { Text("Cancel") } })
    if (pickDate) {
        val state = rememberDatePickerState(initialSelectedDateMillis = due ?: System.currentTimeMillis())
        DatePickerDialog(onDismissRequest = { pickDate = false },
            confirmButton = { TextButton({ due = state.selectedDateMillis?.let { it + 18 * 3_600_000L }; pickDate = false }) { Text("OK") } },
            dismissButton = { TextButton({ due = null; pickDate = false }) { Text("No date") } }) { DatePicker(state) }
    }
}


/** "10:00 AM, 6:00 PM · Mon–Fri · until done" */
fun followUpText(f: org.json.JSONObject): String {
    val times = f.optJSONArray("times")?.let { a -> (0 until a.length()).map { AttData.clock(a.optInt(it)) } } ?: emptyList()
    val wd = f.optJSONArray("weekdays")?.let { a -> (0 until a.length()).map { a.optInt(it) } }?.sorted() ?: emptyList()
    val names = listOf("", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
    val days = when (wd) { listOf(2, 3, 4, 5, 6) -> "Mon–Fri"; (1..7).toList() -> "Every day"; listOf(2, 3, 4, 5, 6, 7) -> "Mon–Sat"; else -> wd.joinToString { names.getOrElse(it) { "" } } }
    val until = f.optDoubleOrNull("until")?.let { "until ${dateText(SwiftDate.toMillis(it))}" } ?: "until done"
    return "${times.joinToString()} · $days · $until${if (f.optBoolean("wholeGroup")) " · whole group" else ""}"
}

/** Pro follow-ups: 1–4 times a day, chosen weekdays, until a date or until done, optionally for the whole group. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun FollowUpDialog(current: org.json.JSONObject?, group: Boolean, onDone: () -> Unit, onSave: (org.json.JSONObject?) -> Unit) {
    val times = remember { mutableStateListOf<Int>().apply { addAll(current?.optJSONArray("times")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: listOf(600)) } }
    val days = remember { mutableStateListOf<Int>().apply { addAll(current?.optJSONArray("weekdays")?.let { a -> (0 until a.length()).map { a.optInt(it) } } ?: listOf(2, 3, 4, 5, 6)) } }
    var until by remember { mutableStateOf(current?.optDoubleOrNull("until")?.let { SwiftDate.toMillis(it) }) }
    var whole by remember { mutableStateOf(current?.optBoolean("wholeGroup") ?: false) }
    var pick by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onDone, title = { Text("Follow-up reminders") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Text("Times a day (up to 4)", style = MaterialTheme.typography.labelMedium)
            FlowRow { listOf(480, 540, 600, 660, 720, 840, 960, 1080, 1200).forEach { t ->
                FilterChip(t in times, { if (t in times) { if (times.size > 1) times.remove(t) } else if (times.size < 4) times.add(t) }, { Text(AttData.clock(t)) }, Modifier.padding(end = 4.dp)) } }
            Text("Days", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 8.dp))
            FlowRow { listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat").forEachIndexed { i, d -> val w = i + 1
                FilterChip(w in days, { if (w in days) { if (days.size > 1) days.remove(w) } else days.add(w) }, { Text(d) }, Modifier.padding(end = 4.dp)) } }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                Switch(until == null, { until = if (it) null else System.currentTimeMillis() + 7 * 86_400_000L }); Spacer(Modifier.width(8.dp)); Text("Until the task is done")
            }
            until?.let { u -> TextButton({ pick = true }) { Text("Until ${dateText(u)}") } }
            if (group) Row(verticalAlignment = Alignment.CenterVertically) { Switch(whole, { whole = it }); Spacer(Modifier.width(8.dp)); Text("Remind the whole group") }
            Text("Reminders ring on each involved phone (after they accept) until the task is completed.", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 6.dp))
        }
    }, confirmButton = { TextButton({
        val f = org.json.JSONObject().put("times", org.json.JSONArray(times.sorted())).put("weekdays", org.json.JSONArray(days.sorted())).put("wholeGroup", whole)
        until?.let { f.put("until", SwiftDate.from(it)) }
        onSave(f); onDone()
    }) { Text("Save") } }, dismissButton = { Row {
        if (current != null) TextButton({ onSave(null); onDone() }) { Text("Remove") }
        TextButton(onDone) { Text("Cancel") }
    } })
    if (pick) { val st = rememberDatePickerState(initialSelectedDateMillis = until ?: System.currentTimeMillis())
        DatePickerDialog(onDismissRequest = { pick = false }, confirmButton = { TextButton({ until = st.selectedDateMillis?.let { it + 20 * 3_600_000L }; pick = false }) { Text("OK") } }) { DatePicker(st) } }
}
