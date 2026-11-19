import SwiftUI
import SwiftData

/// New task — from a message (pre-filled), inside a chat, or from the dashboard.
struct TaskEditorView: View {
    let conv: Conversation?
    let source: Message?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(sort: \Conversation.lastActivity, order: .reverse) private var conversations: [Conversation]

    @State private var draft = SyncEngine.TaskDraft()
    @State private var chatID: String = ""
    @State private var hasDue = false
    @State private var due = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now.addingTimeInterval(86400)) ?? .now
    @State private var newItem = ""
    @State private var everyone = true
    @ObservedObject private var store = Store.shared
    @ObservedObject private var templates = TemplateStore.shared

    private var chat: Conversation? { conversations.first { $0.id == chatID } }

    var body: some View {
        Form {
            Section {
                TextField("What needs to be done?", text: $draft.title, axis: .vertical).font(.title3).lineLimit(1...4)
                TextField("Details (optional)", text: $draft.notes, axis: .vertical).lineLimit(2...8)
                if let source, !source.isSystem {
                    Label("From \(engine.name(of: source.senderID))’s message", systemImage: "text.bubble")
                        .font(.caption).foregroundStyle(look.textSecondary)
                }
            }
            .lookRows()

            Section("Where") {
                if conv == nil {
                    Picker("Chat", selection: $chatID) {
                        Text("Personal (only me)").tag("")
                        ForEach(conversations.filter { !$0.left }) { c in
                            Text(c.title).tag(c.id)
                        }
                    }
                } else {
                    LabeledContent("Chat", value: conv?.title ?? "")
                }
            }
            .lookRows()

            if let chat {
                Section {
                    Toggle("Whole group / everyone in the chat", isOn: $everyone)
                    if !everyone {
                        ForEach(chat.members) { m in
                            Button {
                                if draft.assignees.contains(m.id) { draft.assignees.removeAll { $0 == m.id } } else { draft.assignees.append(m.id) }
                            } label: {
                                HStack {
                                    AvatarView(name: memberName(m), imageData: m.id == engine.me ? engine.myAvatar : engine.contact(m.id)?.avatar, size: 30)
                                    Text(memberName(m)).foregroundStyle(Color.primary)
                                    Spacer()
                                    Image(systemName: draft.assignees.contains(m.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(draft.assignees.contains(m.id) ? look.accent : look.textSecondary)
                                }
                            }
                        }
                    }
                    Picker("Completion", selection: $draft.policy) {
                        ForEach(CompletionPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Assign to")
                } footer: {
                    Text(draft.policy == .all
                         ? "Each person ticks off their own part. The task completes when everyone has."
                         : "One shared task: anyone in it can mark the whole task done.")
                }
                .lookRows()
            }

            Section("When") {
                Toggle("Due date", isOn: $hasDue.animation())
                if hasDue {
                    DatePicker("Due", selection: $due, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Picker("Remind me", selection: $draft.reminderOffset) {
                        Text("At due time").tag(0)
                        Text("15 minutes before").tag(15)
                        Text("1 hour before").tag(60)
                        Text("1 day before").tag(1440)
                    }
                }
                Picker("Priority", selection: $draft.priority) {
                    ForEach(WorkPriority.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
            }
            .lookRows()

            Section {
                if store.proUnlocked {
                    Picker("Repeat", selection: $draft.repeatRule) {
                        ForEach(RepeatRule.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    if !templates.templates.isEmpty {
                        Menu {
                            ForEach(templates.templates) { t in
                                Button(t.name) { apply(t) }
                            }
                        } label: { Label("Start from a template", systemImage: "doc.on.doc") }
                    }
                } else {
                    ProLockRow(text: "Repeat & templates")
                }
            } header: { Text("Business Tasks Pro") }
            .lookRows()

            Section("Checklist") {
                ForEach(Array(draft.checklist.enumerated()), id: \.offset) { i, item in
                    HStack {
                        Image(systemName: "circle").foregroundStyle(look.textSecondary)
                        Text(item)
                        Spacer()
                        Button { draft.checklist.remove(at: i) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Add a step", text: $newItem).onSubmit(addItem)
                    Button(action: addItem) { Image(systemName: "plus.circle.fill") }.disabled(newItem.isEmpty)
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("New task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }.disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if let conv { chatID = conv.id }
            if let source, draft.title.isEmpty {
                draft.title = String(source.text.prefix(120))
                if source.text.count > 120 { draft.notes = source.text }
                draft.sourceMessageID = source.id
            }
        }
    }

    private func apply(_ t: TaskTemplate) {
        draft.title = t.title
        draft.notes = t.notes
        draft.checklist = t.checklist
        draft.priority = WorkPriority(rawValue: t.priority) ?? .normal
        draft.policy = CompletionPolicy(rawValue: t.policy) ?? .any
        draft.repeatRule = t.repeatRule
        draft.reminderOffset = t.reminderOffset
    }

    private func memberName(_ m: MemberInfo) -> String {
        m.id == engine.me ? "Me" : (engine.contact(m.id)?.name ?? m.name)
    }

    private func addItem() {
        let t = newItem.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        draft.checklist.append(t)
        newItem = ""
    }

    private func create() {
        var d = draft
        d.title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        d.dueAt = hasDue ? due : nil
        if chat == nil || everyone { d.assignees = chat == nil ? [] : (d.policy == .all ? chat!.members.map(\.id) : []) }
        if chat == nil { d.policy = .any }
        engine.createTask(d, in: chat)
        Haptics.success()
        dismiss()
    }
}
