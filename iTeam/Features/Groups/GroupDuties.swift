import SwiftUI
import SwiftData

// MARK: - Transfer duties before someone leaves (or is removed from) a group

/// Open tasks of `userID` in this group. They must be handed to someone else before the person leaves or is removed.
@MainActor
enum GroupDuties {
    static func openTasks(_ conv: Conversation, of userID: String, context: ModelContext) -> [TaskItem] {
        let cid: String? = conv.id
        return ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.convID == cid && !$0.deleted }))) ?? [])
            .filter { !$0.isDone && $0.assignees.contains(userID) }
    }
}

struct TransferDutiesView: View {
    let conv: Conversation
    let userID: String
    let leaving: Bool                 // true = I'm leaving; false = an admin is removing someone
    var onDone: () -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var tasks: [TaskItem] = []
    @State private var to: [String: String] = [:]       // task id → new person
    @State private var all = ""

    private var others: [MemberInfo] { conv.members.filter { $0.id != userID } }
    private var ready: Bool { !tasks.isEmpty && tasks.allSatisfy { !(to[$0.id] ?? "").isEmpty } }

    var body: some View {
        Form {
            Section {
                Text(leaving ? "You still have \(tasks.count) open task\(tasks.count == 1 ? "" : "s") in “\(conv.title)”. Hand each one to someone before you leave."
                             : "\(engine.name(of: userID)) has \(tasks.count) open task\(tasks.count == 1 ? "" : "s") here. Transfer them before removing \(engine.name(of: userID)).")
                    .font(.callout)
                Picker("Hand all to", selection: $all) {
                    Text("Choose…").tag("")
                    ForEach(others, id: \.id) { m in Text(name(m.id)).tag(m.id) }
                }
                .onChange(of: all) { _, v in if !v.isEmpty { for t in tasks { to[t.id] = v } } }
            }
            Section("Tasks") {
                ForEach(tasks) { t in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.title).font(.body.weight(.medium))
                        if let d = t.dueAt { Text("Due " + d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        Picker("Hand to", selection: Binding(get: { to[t.id] ?? "" }, set: { to[t.id] = $0 })) {
                            Text("Choose…").tag("")
                            ForEach(others, id: \.id) { m in Text(name(m.id)).tag(m.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Transfer duties")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(leaving ? "Transfer & leave" : "Transfer & remove") { transfer() }.bold().disabled(!ready)
            }
        }
        .onAppear { tasks = GroupDuties.openTasks(conv, of: userID, context: context) }
    }

    private func name(_ id: String) -> String { id == engine.me ? "\(engine.myName) (you)" : engine.name(of: id) }

    private func transfer() {
        for t in tasks {
            guard let new = to[t.id], !new.isEmpty else { continue }
            engine.updateTask(t, fields: ["assignees"], change: "handed over from \(engine.name(of: userID)) to \(engine.name(of: new))", loud: true) { task in
                var a = task.assignees.filter { $0 != userID }
                if !a.contains(new) { a.append(new) }
                task.assignees = a
            }
        }
        Haptics.big()
        dismiss()
        onDone()
    }
}

// MARK: - Raise a grievance from a group (private)

struct RaiseGrievanceView: View {
    let group: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var aboutAdmin = false
    @State private var title = ""
    @State private var about = "A member"
    @State private var details = ""
    @State private var error: String?

    /// Owner if it's about an admin; otherwise an admin (not me), falling back to the owner.
    private var handlerID: String? {
        let me = engine.me
        let owner = group.members.first { $0.role == .owner }?.id ?? group.ownerID
        if aboutAdmin || about == "An admin" { return owner == me ? nil : owner }
        if let a = group.members.first(where: { $0.role == .admin && $0.id != me }) { return a.id }
        return owner == me ? nil : owner
    }

    var body: some View {
        Form {
            Section {
                TextField("Subject", text: $title)
                Picker("About", selection: $about) {
                    ForEach(BizSpecs.grievance.children[0].fields.first { $0.key == .subtitle }?.options ?? [], id: \.self) { Text($0).tag($0) }
                }
                Toggle("It's about an admin", isOn: $aboutAdmin)
                TextField("What happened, and what would fix it?", text: $details, axis: .vertical).lineLimit(4...10)
            } footer: {
                if let h = handlerID {
                    Text("Only you and \(engine.name(of: h)) (\(aboutAdmin || about == "An admin" ? "group owner" : "admin")) will see this — not the rest of “\(group.title)”.")
                } else {
                    Text("You run this group, so there's nobody above you to send it to.")
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .navigationTitle("Raise a grievance")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send privately") { send() }.bold()
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || handlerID == nil)
            }
        }
        .onChange(of: aboutAdmin) { _, v in if v { about = "An admin" } }
    }

    private func send() {
        guard let h = handlerID else { return }
        guard let c = engine.contact(h) else { error = "Couldn't reach \(engine.name(of: h)). Open a chat with them once, then try again."; return }
        let direct = engine.directConversation(with: c)
        var p = BizPayload(BizRecord(id: "g_" + UUID().uuidString))
        p.module = "grievance"; p.kind = "grievance"
        p.title = title.trimmingCharacters(in: .whitespaces); p.subtitle = about; p.notes = details
        p.date = .now; p.status = "Open"; p.subjectID = h
        p.extra = ["Group": group.title, "Handled by": engine.name(of: h)]
        p.at = .now
        engine.saveBiz(p, convID: direct.id)
        Haptics.big()
        dismiss()
    }
}
