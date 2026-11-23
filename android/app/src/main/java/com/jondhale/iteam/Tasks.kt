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
    Scaffold(topBar = { TopAppBar(title = { Text("Business Tasks", fontWeight = FontWeight.Bold) }) }) { pad ->
        Column(Modifier.padding(pad)) {
            ScrollableTabRow(filter, edgePadding = 8.dp) {
                listOf("For me", "I assigned", "To accept", "Done").forEachIndexed { i, s -> Tab(filter == i, { filter = i }, text = { Text(s) }) }
            }
            if (shown.isEmpty()) Centered("No tasks here.\n\nCreate a task from any chat with the ✓+ button, or long-press a message → Make a task.")
            LazyColumn {
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
    AlertDialog(onDismissRequest = onDone, title = { Text("New task") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(title, { title = it }, label = { Text("Task") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(notes, { notes = it }, label = { Text("Details (optional)") }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp), maxLines = 4)
                Text("Priority", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 10.dp))
                Row { priorities.forEachIndexed { i, p -> FilterChip(priority == i, { priority = i }, label = { Text(p) }, modifier = Modifier.padding(end = 4.dp)) } }
                TextButton({ pickDate = true }) { Icon(Icons.Default.Event, null); Spacer(Modifier.width(6.dp)); Text(due?.let { "Due ${dateText(it)}" } ?: "Add a due date") }
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
                        withContext(Dispatchers.IO) { app.sync.createTask(conv.id, title.trim(), notes.trim(), people.toList(), due, priority, everyone) }
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
