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
    @State private var askTemplate = false
    @State private var templateName = ""
    @State private var showFollowUp = false
    @State private var shareToViews = false
    @State private var askDecline = false
    @State private var declineReason = ""
    @ObservedObject private var store = Store.shared

    init(taskID: String) {
        self.taskID = taskID
        _found = Query(filter: #Predicate<TaskItem> { $0.id == taskID })
        _checklist = Query(filter: #Predicate<ChecklistItem> { $0.taskID == taskID && !$0.deleted }, sort: \ChecklistItem.position)
        _comments = Query(filter: #Predicate<TaskComment> { $0.taskID == taskID }, sort: \TaskComment.createdAt)
    }

    var body: some View {
        if let t = found.first, t.deleted {
            deletedView(t)
        } else if let t = found.first {
            content(t)
        } else {
            EmptyStateView(icon: "checklist", title: "Task not found", message: "It may have been deleted.")
        }
    }

    /// Deleted tasks stay readable, clearly marked, so nobody wonders where they went.
    private func deletedView(_ t: TaskItem) -> some View {
        List {
            Section {
                Label {
                    Text("Deleted by \(engine.name(of: t.deletedBy ?? t.createdBy))\(t.deletedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                } icon: { Image(systemName: "trash.fill") }
                .foregroundStyle(look.danger)
                Text(t.title).font(.title2.bold()).strikethrough()
                if !t.notes.isEmpty { Text(t.notes).foregroundStyle(look.textSecondary) }
                Text("Created by \(engine.name(of: t.createdBy)) · \(t.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(look.textSecondary)
            }
            .lookRows()
            if !checklist.isEmpty {
                Section("Checklist") {
                    ForEach(checklist) { c in Label(c.title, systemImage: c.done ? "checkmark.circle.fill" : "circle") }
                }
                .lookRows()
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Deleted task")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func conv(_ t: TaskItem) -> Conversation? { t.convID.flatMap { engine.conversation($0) } }

    private func canEdit(_ t: TaskItem) -> Bool {
        guard let c = conv(t) else { return true }
        return !c.left && (t.createdBy == engine.me || t.involves(engine.me) || (c.role(of: engine.me)?.canManage ?? false))
    }

    @ViewBuilder
    private func acceptanceSection(_ t: TaskItem) -> some View {
        if t.awaitsMe(engine.me) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(engine.name(of: t.createdBy)) assigned this to you", systemImage: "hand.raised.fill").font(.headline)
                    Text("Accept to start it, or decline with a reason.").font(.caption).foregroundStyle(look.textSecondary)
                    HStack {
                        Button { engine.respondToTask(t, accept: true); Haptics.success() } label: {
                            Label("Accept", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        Button { askDecline = true } label: { Label("Decline", systemImage: "xmark").frame(maxWidth: .infinity) }
                            .buttonStyle(.glass)
                    }
                }
                .padding(.vertical, 4)
            }
            .lookRows()
        } else if t.needsAcceptance && (!t.pendingAcceptance.isEmpty || !t.acceptance.isEmpty) {
            Section("Acceptance") {
                ForEach(t.assignees.filter { $0 != t.createdBy }, id: \.self) { a in
                    let answer = t.acceptance[a]
                    LabeledContent(engine.name(of: a)) {
                        if let answer {
                            Text(answer.hasPrefix("accepted") ? "Accepted" : "Declined" + (answer.split(separator: "|").dropFirst().first.map { ": \($0)" } ?? ""))
                                .foregroundStyle(answer.hasPrefix("accepted") ? look.success : look.danger)
                        } else {
                            Text("Waiting").foregroundStyle(look.warning)
                        }
                    }
                }
            }
            .lookRows()
        }
    }

    @ViewBuilder
    private func headerSection(_ t: TaskItem) -> some View {
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
                    TaskMeetingsRow(task: t)
                    if t.isDone, let by = t.completedBy, let at = t.completedAt {
                        Label("Completed by \(engine.name(of: by)) · \(at.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(look.success)
                        Button("Share to Views", systemImage: "play.rectangle.on.rectangle") { shareToViews = true }
                            .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
            .lookRows()

    }

    @ViewBuilder
    private func statusSection(_ t: TaskItem) -> some View {
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

    }

    @ViewBuilder
    private func detailsSection(_ t: TaskItem) -> some View {
            Section("Details") {
                TextField("Notes", text: $notesText, axis: .vertical)
                    .lineLimit(2...10)
                    .disabled(!canEdit(t))
                    .onSubmit { saveNotes(t) }
                if notesText != t.notes {
                    Button("Save notes") { saveNotes(t) }
                }
                if !t.people.isEmpty {
                    LabeledContent("Also for") {
                        Text(t.people.map(\.name).joined(separator: ", ") + " (not on iTeam)").multilineTextAlignment(.trailing)
                    }
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
                if t.dueAt != nil {
                    Menu {
                        ForEach(ExtraReminder.options, id: \.0) { o in
                            let on = t.remindersRaw.split(separator: ",").map(String.init).contains(o.0)
                            Button { toggleReminder(t, o.0) } label: { Label(o.1, systemImage: on ? "checkmark.circle.fill" : "circle") }
                        }
                    } label: {
                        let n = t.remindersRaw.split(separator: ",").count
                        LabeledContent("More reminders", value: n == 0 ? "None" : "\(n) set")
                    }
                }
                if store.proUnlocked {
                    Picker("Repeat", selection: Binding(get: { t.repeatRule }, set: { r in
                        engine.updateTask(t, fields: ["repeat"], change: "set it to repeat \(RepeatRule(rawValue: r)?.title.lowercased() ?? r)") { $0.repeatRule = r }
                    })) {
                        ForEach(RepeatRule.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .disabled(!canEdit(t))
                    if t.createdBy == engine.me && !t.isDone {
                        Button { showFollowUp = true } label: {
                            LabeledContent {
                                Text(t.followUp.map { FollowUpEditor.summary($0) } ?? "Off")
                            } label: { Label("Follow-up", systemImage: "bell.and.waves.left.and.right") }
                        }
                    } else if let fu = t.followUp {
                        LabeledContent("Follow-up", value: FollowUpEditor.summary(fu))
                    }
                    Button { templateName = t.title; askTemplate = true } label: { Label("Save as template", systemImage: "doc.on.doc") }
                } else {
                    if t.repeatRule != "none" { LabeledContent("Repeats", value: RepeatRule(rawValue: t.repeatRule)?.title ?? t.repeatRule) }
                    if let fu = t.followUp { LabeledContent("Follow-up", value: FollowUpEditor.summary(fu)) }
                    ProLockRow(text: "Repeat, templates & follow-ups")
                }
                if let c = conv(t) {
                    Button { router.show(conversation: c.id) } label: {
                        Label("Open chat: \(c.title)", systemImage: c.isGroup ? "person.3" : "bubble.left")
                    }
                }
            }
            .lookRows()

    }

    private func content(_ t: TaskItem) -> some View {
        List {
            acceptanceSection(t)
            headerSection(t)
            statusSection(t)
            detailsSection(t)
            TaskIdeasSection(task: t)
            DocumentsSection(module: "task", recordID: t.id, recordOwner: t.createdBy, convID: t.convID ?? "", title: t.title, canAdd: canEdit(t)).lookRows()

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

            if t.createdBy == engine.me || t.createdBy.hasPrefix("demo_") {
                Section {
                    Button("Delete task", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Only the person who created a task can delete it. It stays listed under Deleted for everyone.")
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareMenu(title: t.title,
                          text: { ShareText.task(t, checklist: checklist, comments: comments, engine: engine) },
                          html: { ShareText.taskHTML(t, checklist: checklist, comments: comments, engine: engine) },
                          module: "Business Tasks", icon: "checklist", colors: [0x28BEE6, 0x3A5BD9],
                          charts: { PDFCharts.task(checklist: checklist) })
                    .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $showFollowUp) { NavigationStack { FollowUpEditor(task: t) } }
        .alert("Decline this task?", isPresented: $askDecline) {
            TextField("Reason (optional)", text: $declineReason)
            Button("Decline", role: .destructive) { engine.respondToTask(t, accept: false, note: declineReason); declineReason = "" }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $shareToViews) { NavigationStack { NewPostView(status: false, kind: .taskDone, prefill: "✅ Completed: \(t.title)") } }
        .onAppear { notesText = t.notes }
        .onChange(of: t.notes) { _, n in notesText = n }
        .alert("Save as template", isPresented: $askTemplate) {
            TextField("Template name", text: $templateName)
            Button("Save") {
                let n = templateName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { TemplateStore.shared.save(from: t, name: n, context: engine.context); Haptics.success() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Title, notes, checklist, priority and repeat are saved. Start new tasks from it in “New task”.") }
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


// MARK: - ✨ How to do this task, who can help, who did similar work before

struct TaskIdeasSection: View {
    let task: TaskItem
    @EnvironmentObject var engine: SyncEngine
    @ObservedObject private var ai = AISettings.shared
    @Query(filter: #Predicate<TaskItem> { !$0.deleted && $0.completedAt != nil }, sort: \TaskItem.completedAt, order: .reverse) private var done: [TaskItem]

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 })
    }

    private var similar: [TaskItem] {
        let w = Self.words(task.title + " " + task.notes)
        guard !w.isEmpty else { return [] }
        return done.filter { $0.id != task.id }.map { ($0, Self.words($0.title + " " + $0.notes).intersection(w).count) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(8).map { $0.0 }
    }

    var body: some View {
        if ai.allows(.advisor) && !task.isDone {
            Section {
                AISuggest(title: "How to do this & who can help",
                          instructions: "Help the person assigned to this task: give clear steps to complete it, what to prepare, and risks. Then, from the similar finished tasks, say who has done similar work before (names given), how they did it (from their notes) and who could help. Only use names in the data.",
                          context: context)
            } footer: { Text("Uses this task and up to 8 similar finished tasks from your chats.") }
        }
    }

    private func context() -> String {
        var s = "This task: \(task.title)\nNotes: \(task.notes)\nDue: \(task.dueAt?.formatted(date: .abbreviated, time: .shortened) ?? "none")\nAssigned to: \(task.assignees.map { engine.name(of: $0) }.joined(separator: ", "))\n\nSimilar finished tasks:\n"
        for t in similar {
            let who = (t.assignees.isEmpty ? [t.createdBy] : t.assignees).map { engine.name(of: $0) }.joined(separator: ", ")
            s += "- \(t.title) — done by \(who) on \(t.completedAt?.formatted(date: .abbreviated, time: .omitted) ?? "") — notes: \(String(t.notes.prefix(300)))\n"
        }
        return s
    }
}


extension TaskDetailView {
    /// Turns one extra reminder on/off (personal, this phone only) and reschedules notifications.
    func toggleReminder(_ t: TaskItem, _ code: String) {
        var set = t.remindersRaw.split(separator: ",").map(String.init)
        if let i = set.firstIndex(of: code) { set.remove(at: i) } else { set.append(code) }
        t.remindersRaw = set.joined(separator: ",")
        Reminders.shared.reschedule(context: engine.context, me: engine.me)
        Haptics.tap()
    }
}
