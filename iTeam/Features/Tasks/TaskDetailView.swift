import SwiftUI
import SwiftData

struct TaskDetailView: View {
    let taskID: String
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query private var found: [TaskItem]
    @Query private var checklist: [ChecklistItem]
    @Query private var comments: [TaskComment]

    @State private var newItem = ""
    @State private var newComment = ""
    @State private var editTitle = false
    @State private var titleText = ""
    @State private var notesText = ""
    @State private var reopenReason = ""
    @State private var askReopen = false
    @State private var confirmDelete = false

    init(taskID: String) {
        self.taskID = taskID
        _found = Query(filter: #Predicate<TaskItem> { $0.id == taskID })
        _checklist = Query(filter: #Predicate<ChecklistItem> { $0.taskID == taskID && !$0.deleted }, sort: \ChecklistItem.position)
        _comments = Query(filter: #Predicate<TaskComment> { $0.taskID == taskID }, sort: \TaskComment.createdAt)
    }

    var body: some View {
        if let t = found.first, !t.deleted {
            content(t)
        } else {
            EmptyStateView(icon: "checklist", title: "Task not found", message: "It may have been deleted.")
        }
    }

    private func conv(_ t: TaskItem) -> Conversation? { t.convID.flatMap { engine.conversation($0) } }

    private func canEdit(_ t: TaskItem) -> Bool {
        guard let c = conv(t) else { return true }
        return !c.left && (t.createdBy == engine.me || t.involves(engine.me) || (c.role(of: engine.me)?.canManage ?? false))
    }

    private func content(_ t: TaskItem) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text(t.title).font(.title2.bold()).strikethrough(t.isDone)
                        Spacer()
                        if canEdit(t) {
                            Button { titleText = t.title; editTitle = true } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                        }
                    }
                    FlowChips(task: t, checklistDone: checklist.filter(\.done).count, checklistTotal: checklist.count, comments: comments.count)
                    Text("Created by \(engine.name(of: t.createdBy)) · \(t.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(look.textSecondary)
                    if t.isDone, let by = t.completedBy, let at = t.completedAt {
                        Label("Completed by \(engine.name(of: by)) · \(at.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(look.success)
                    }
                }
                .padding(.vertical, 4)
            }
            .lookRows()

            Section("Status") {
                if t.policy == .all && !t.assignees.isEmpty {
                    progressBlock(t)
                } else {
                    Picker("Status", selection: Binding(get: { t.status }, set: { engine.setStatus(t, $0) })) {
                        ForEach(TaskStatus.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!canEdit(t))
                }
                if t.isDone && canEdit(t) {
                    Button("Reopen with a reason…", systemImage: "arrow.uturn.backward") { askReopen = true }
                }
            }
            .lookRows()

            Section("Details") {
                TextField("Notes", text: $notesText, axis: .vertical)
                    .lineLimit(2...10)
                    .disabled(!canEdit(t))
                    .onSubmit { saveNotes(t) }
                if notesText != t.notes {
                    Button("Save notes") { saveNotes(t) }
                }
                DueRow(task: t, editable: canEdit(t))
                Picker("Priority", selection: Binding(get: { t.priority }, set: { p in
                    engine.updateTask(t, fields: ["priority"], change: "set priority to \(p.title)") { $0.priority = p }
                })) {
                    ForEach(WorkPriority.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .disabled(!canEdit(t))
                if t.dueAt != nil {
                    Picker("My reminder", selection: Binding(get: { t.reminderOffset }, set: { v in
                        t.reminderOffset = v
                        engine.save()
                        Reminders.shared.reschedule(context: engine.context, me: engine.me)
                    })) {
                        Text("At due time").tag(0)
                        Text("15 min before").tag(15)
                        Text("1 hour before").tag(60)
                        Text("1 day before").tag(1440)
                    }
                }
                if let c = conv(t) {
                    Button { router.show(conversation: c.id) } label: {
                        Label("Open chat: \(c.title)", systemImage: c.isGroup ? "person.3" : "bubble.left")
                    }
                }
            }
            .lookRows()

            Section("Checklist") {
                ForEach(checklist) { item in
                    HStack {
                        Button {
                            Haptics.tap()
                            engine.updateChecklistItem(item, done: !item.done)
                        } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? look.success : look.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEdit(t))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).strikethrough(item.done)
                            if item.done {
                                Text(engine.name(of: item.updatedBy)).font(.caption2).foregroundStyle(look.textSecondary)
                            }
                        }
                    }
                    .swipeActions {
                        if canEdit(t) {
                            Button("Delete", role: .destructive) { engine.updateChecklistItem(item, deleted: true) }
                        }
                    }
                }
                if canEdit(t) {
                    HStack {
                        TextField("Add a step", text: $newItem).onSubmit { addItem(t) }
                        Button { addItem(t) } label: { Image(systemName: "plus.circle.fill") }.disabled(newItem.isEmpty)
                    }
                }
            }
            .lookRows()

            TaskFilesSection(task: t, editable: canEdit(t))
            TaskApprovalsSection(task: t)
            TaskExpensesSection(task: t, editable: canEdit(t))

            Section("Comments") {
                ForEach(comments) { c in
                    HStack(alignment: .top, spacing: 10) {
                        AvatarView(name: engine.name(of: c.authorID), imageData: c.authorID == engine.me ? engine.myAvatar : engine.contact(c.authorID)?.avatar, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(engine.name(of: c.authorID)).font(.caption.bold())
                                Text(Fmt.chatTime(c.createdAt)).font(.caption2).foregroundStyle(look.textSecondary)
                            }
                            Text(c.body).font(.subheadline)
                        }
                    }
                }
                if conv(t)?.left != true {
                    HStack {
                        TextField("Write a comment", text: $newComment, axis: .vertical).lineLimit(1...4)
                        Button {
                            engine.addComment(newComment, to: t)
                            newComment = ""
                        } label: { Image(systemName: "paperplane.fill") }
                        .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .lookRows()

            if t.createdBy == engine.me || conv(t)?.role(of: engine.me)?.canManage == true || conv(t) == nil {
                Section {
                    Button("Delete task", role: .destructive) { confirmDelete = true }
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { notesText = t.notes }
        .onChange(of: t.notes) { _, n in notesText = n }
        .alert("Rename task", isPresented: $editTitle) {
            TextField("Title", text: $titleText)
            Button("Save") {
                let v = titleText.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && v != t.title { engine.updateTask(t, fields: ["title"], change: "renamed") { $0.title = v } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Reopen task", isPresented: $askReopen) {
            TextField("Reason", text: $reopenReason)
            Button("Reopen") { engine.reopen(t, reason: reopenReason); reopenReason = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in the task sees the reason as a comment.")
        }
        .confirmationDialog("Delete this task for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { engine.deleteTask(t); dismiss() }
        }
    }

    private func progressBlock(_ t: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressRing(progress: t.groupProgress, color: look.accent, lineWidth: 6).frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text("\(t.doneBy.keys.filter { t.assignees.contains($0) }.count) of \(t.assignees.count) finished").font(.headline)
                    Text("Completes when everyone has finished their part").font(.caption).foregroundStyle(look.textSecondary)
                }
            }
            ForEach(t.assignees, id: \.self) { id in
                HStack {
                    AvatarView(name: engine.name(of: id), imageData: id == engine.me ? engine.myAvatar : engine.contact(id)?.avatar, size: 28)
                    Text(id == engine.me ? "Me" : engine.name(of: id))
                    Spacer()
                    if let at = t.doneBy[id] {
                        Label(Fmt.chatTime(at), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(look.success)
                    } else {
                        Text("Pending").font(.caption).foregroundStyle(look.textSecondary)
                    }
                }
            }
            if t.assignees.contains(engine.me) && !t.isDone {
                let mine = t.doneBy[engine.me] != nil
                Button {
                    Haptics.success()
                    engine.setMyPart(t, done: !mine)
                } label: {
                    Label(mine ? "Undo my part" : "Mark my part done", systemImage: mine ? "arrow.uturn.backward" : "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private func saveNotes(_ t: TaskItem) {
        guard notesText != t.notes else { return }
        let v = notesText
        engine.updateTask(t, fields: ["notes"], change: "updated the notes") { $0.notes = v }
    }

    private func addItem(_ t: TaskItem) {
        let v = newItem.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        engine.addChecklistItem(v, to: t.id, position: (checklist.map(\.position).max() ?? 0) + 1)
        newItem = ""
    }
}

struct DueRow: View {
    let task: TaskItem
    let editable: Bool
    @EnvironmentObject var engine: SyncEngine
    @State private var date = Date.now

    var body: some View {
        Toggle("Due date", isOn: Binding(get: { task.dueAt != nil }, set: { on in
            let new: Date? = on ? Date(timeIntervalSinceNow: 86400) : nil
            engine.updateTask(task, fields: ["dueAt"], change: on ? "set a due date" : "removed the due date", loud: on) { $0.dueAt = new }
        }))
        .disabled(!editable)
        if let due = task.dueAt {
            DatePicker("Due", selection: Binding(get: { due }, set: { date = $0 }), displayedComponents: [.date, .hourAndMinute])
                .disabled(!editable)
                .onChange(of: date) { _, d in
                    guard d != task.dueAt else { return }
                    engine.updateTask(task, fields: ["dueAt"], change: "changed the due date to \(Fmt.due(d))", loud: true) { $0.dueAt = d }
                }
        }
    }
}
