import SwiftUI
import SwiftData

// MARK: - Actions

extension SyncEngine {
    /// Saves a name to my People list (my devices only).
    @discardableResult
    func savePerson(id: String? = nil, name: String, phone: String = "", note: String = "", linkedUserID: String = "",
                    state: String = "", deleted: Bool = false) -> String {
        let pid = id ?? "pp_" + UUID().uuidString
        sendPersonal(.person(PersonPayload(id: pid, name: name, phone: phone, note: note, linkedUserID: linkedUserID,
                                           state: state, deleted: deleted, at: .now)))
        return pid
    }

    func person(_ id: String) -> Person? {
        try? context.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })).first
    }

    /// Asks an iTeam user to claim a name: when they accept, everything under it is shared with them.
    func invitePerson(_ p: Person, contact: Contact) {
        let conv = directConversation(with: contact)
        savePerson(id: p.id, name: p.name, phone: p.phone, note: p.note, linkedUserID: contact.userID, state: "invited")
        send(.personClaim(PersonClaimPayload(id: p.id, name: p.name, note: p.note)), in: conv, loud: true,
             preview: "🪪 \(myName) added you as “\(p.name)” — accept to see it")
    }

    /// My answer to someone who added me under a name.
    func answerClaim(_ p: Person, accept: Bool) {
        guard let owner = contact(p.ownerID) else { return }
        let conv = directConversation(with: owner)
        send(.personClaimAnswer(personID: p.id, accept: accept), in: conv, loud: true,
             preview: accept ? "🪪 Accepted “\(p.name)”" : "🪪 Declined “\(p.name)”")
        p.state = accept ? "accepted" : "declined"
        save()
    }

    /// They accepted: hand over everything I filed under that name.
    func completeClaim(_ p: Person) {
        guard p.ownerID == me, !p.linkedUserID.isEmpty, let c = contact(p.linkedUserID) else { return }
        savePerson(id: p.id, name: p.name, phone: p.phone, note: p.note, linkedUserID: p.linkedUserID, state: "accepted")
        // Business records (clients, patients, students, tenants, matters…): shared in our chat, "Managed by me".
        let recs = ((try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.parentID == "" && !$0.deleted }))) ?? [])
            .filter { $0.extra["personID"] == p.id && $0.subjectID.isEmpty }
        for r in recs { linkBiz(r, to: c) }
        // Tasks: become theirs where they're in the task's chat.
        let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted }))) ?? [])
            .filter { $0.peopleRaw.contains(p.id + "|") }
        for t in tasks {
            guard let convID = t.convID, let conv = conversation(convID), conv.members.contains(where: { $0.id == c.userID }) else { continue }
            updateTask(t, fields: ["assignees", "people"], change: "assigned \(c.name) (claimed “\(p.name)”)", loud: true) {
                if !$0.assignees.contains(c.userID) { $0.assignees.append(c.userID) }
                $0.peopleRaw = $0.people.filter { $0.id != p.id }.map { "\($0.id)|\($0.name)" }.joined(separator: "\n")
            }
        }
        // Care profiles kept for this name.
        let profiles = ((try? context.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { !$0.deleted }))) ?? [])
            .filter { $0.createdBy == me && $0.linkedUserID.isEmpty && $0.name.caseInsensitiveCompare(p.name) == .orderedSame }
        for prof in profiles where prof.convID == selfConversationID {
            moveCareProfile(prof, to: directConversation(with: c))
            if let conv = conversation(prof.convID) {
                saveCareProfile(in: conv, id: prof.id, name: prof.name, relation: prof.relation, bloodGroup: prof.bloodGroup,
                                allergies: prof.allergies, conditions: prof.conditions, emergencyContact: prof.emergencyContact,
                                notes: prof.notes, avatar: prof.avatar, linkedUserID: c.userID)
            }
        }
        save()
    }

    /// Everything filed under a name (for the person's page).
    func personRecords(_ p: Person) -> (biz: [BizRecord], tasks: [TaskItem]) {
        let recs = ((try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.parentID == "" && !$0.deleted }))) ?? [])
            .filter { $0.extra["personID"] == p.id }
        let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted }))) ?? [])
            .filter { $0.peopleRaw.contains(p.id + "|") }
        return (recs, tasks)
    }
}

// MARK: - People list

struct PeopleView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Person> { !$0.deleted }, sort: \Person.name) private var people: [Person]
    @State private var edit: Person?
    @State private var addNew = false
    @State private var search = ""

    private var mine: [Person] {
        people.filter { $0.ownerID == engine.me }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.phone.contains(search) }
    }
    private var requests: [Person] { people.filter { $0.ownerID != engine.me && $0.linkedUserID == engine.me && $0.state == "invited" } }

    var body: some View {
        List {
            if !requests.isEmpty {
                Section("Requests for you") {
                    ForEach(requests) { p in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(engine.name(of: p.ownerID)) added you as “\(p.name)”").font(.subheadline.weight(.semibold))
                            Text("Accept to see everything they filed under this name (cases, tasks, records), managed by them.")
                                .font(.caption).foregroundStyle(look.textSecondary)
                            HStack {
                                Button("Accept") { engine.answerClaim(p, accept: true); Haptics.success() }.buttonStyle(.glassProminent)
                                Button("Decline", role: .destructive) { engine.answerClaim(p, accept: false) }.buttonStyle(.glass)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .lookRows()
            }
            Section {
                ForEach(mine) { p in
                    Button { edit = p } label: { row(p) }.buttonStyle(.plain)
                }
                .onDelete { idx in
                    for i in idx { let p = mine[i]; engine.savePerson(id: p.id, name: p.name, phone: p.phone, note: p.note, linkedUserID: p.linkedUserID, state: p.state, deleted: true) }
                }
                Button { addNew = true } label: { Label("Add a person", systemImage: "person.badge.plus") }
            } header: { Text("My people") } footer: {
                Text("Clients, helpers, vendors or family who aren't on iTeam yet. Add them once, then pick them in Legal, CRM, Clinic, Tuition, Tasks and more. When they join iTeam, invite them to claim their name — once they accept, everything under it is shared with them.")
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .searchable(text: $search, prompt: "Search people")
        .navigationTitle("People")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { addNew = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $addNew) { NavigationStack { PersonEditor(person: nil) } }
        .sheet(item: $edit) { p in NavigationStack { PersonEditor(person: p) } }
    }

    private func row(_ p: Person) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: p.name, imageData: p.linkedUserID.isEmpty ? nil : engine.contact(p.linkedUserID)?.avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.headline)
                Text([p.phone, p.note].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(look.textSecondary).lineLimit(1)
            }
            Spacer()
            switch p.state {
            case "accepted": Chip(text: "On iTeam", icon: "checkmark.seal.fill", color: look.success)
            case "invited": Chip(text: "Invited", icon: "hourglass", color: look.warning)
            case "declined": Chip(text: "Declined", color: look.danger)
            default: EmptyView()
            }
        }
    }
}

struct PersonEditor: View {
    let person: Person?
    var onSaved: (String, String) -> Void = { _, _ in }
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var name = ""
    @State private var phone = ""
    @State private var note = ""
    @State private var claimBy = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).font(.title3)
                TextField("Phone (optional)", text: $phone).keyboardType(.phonePad)
                TextField("Note (e.g. Client – Patil matter, Driver)", text: $note)
            }
            .lookRows()
            if let p = person {
                let recs = engine.personRecords(p)
                if !recs.biz.isEmpty || !recs.tasks.isEmpty {
                    Section("Filed under \(p.name)") {
                        ForEach(recs.biz) { r in
                            Label("\(r.title) · \(BizSpecs.spec(r.module)?.title ?? r.module)", systemImage: BizSpecs.spec(r.module)?.icon ?? "folder")
                        }
                        ForEach(recs.tasks) { t in Label(t.title, systemImage: "checklist") }
                    }
                    .lookRows()
                }
                Section {
                    if p.state == "accepted" {
                        Label("\(engine.name(of: p.linkedUserID)) claimed this name — their records are shared with them.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(look.success)
                    } else {
                        Picker("They joined iTeam as", selection: $claimBy) {
                            Text("Choose a contact").tag("")
                            ForEach(contacts.filter { !$0.userID.hasPrefix("demo_") && $0.userID != engine.me }, id: \.userID) { c in Text(c.name).tag(c.userID) }
                        }
                        Button {
                            guard let c = contacts.first(where: { $0.userID == claimBy }) else { return }
                            engine.invitePerson(p, contact: c)
                            Haptics.big()
                            dismiss()
                        } label: { Label(p.state == "invited" ? "Send the request again" : "Invite to claim", systemImage: "paperplane.fill") }
                        .disabled(claimBy.isEmpty)
                        if p.state == "invited" { Text("Waiting for \(engine.name(of: p.linkedUserID)) to accept.").font(.caption).foregroundStyle(look.warning) }
                        if p.state == "declined" { Text("\(engine.name(of: p.linkedUserID)) declined.").font(.caption).foregroundStyle(look.danger) }
                    }
                } header: { Text("On iTeam") } footer: {
                    Text("They get a request in your chat. When they accept, the clients/cases/records and tasks under this name are shared with them — still managed by you.")
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle(person == nil ? "New person" : "Person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    let id = engine.savePerson(id: person?.id, name: n, phone: phone, note: note,
                                               linkedUserID: person?.linkedUserID ?? "", state: person?.state ?? "")
                    Haptics.success()
                    onSaved(id, n)
                    dismiss()
                }
                .bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let p = person else { return }
            name = p.name; phone = p.phone; note = p.note; claimBy = p.linkedUserID
        }
    }
}

/// "Pick from People" menu: choose a saved name or add a new one.
struct PersonPickerMenu: View {
    var title: String = "Pick from People"
    var onPick: (Person?, String, String) -> Void   // (person, id, name)
    @EnvironmentObject var engine: SyncEngine
    @Query(filter: #Predicate<Person> { !$0.deleted }, sort: \Person.name) private var people: [Person]
    @State private var addNew = false

    var body: some View {
        Menu {
            Button { addNew = true } label: { Label("New person…", systemImage: "person.badge.plus") }
            let mine = people.filter { $0.ownerID == engine.me }
            if !mine.isEmpty {
                Section("My people") {
                    ForEach(mine) { p in Button(p.name) { onPick(p, p.id, p.name) } }
                }
            }
        } label: { Label(title, systemImage: "person.crop.circle.badge.plus") }
        .sheet(isPresented: $addNew) {
            NavigationStack { PersonEditor(person: nil) { id, name in onPick(nil, id, name) } }
        }
    }
}
