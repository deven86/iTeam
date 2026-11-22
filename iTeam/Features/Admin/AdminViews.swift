import SwiftUI
import CloudKit
import SwiftData

/// Owner admin: co-owners, family & friends with full or time-limited access, a users dashboard, and complaints.
/// Stored in the public iCloud database (not end-to-end encrypted — like module requests).
@MainActor
final class Admin: ObservableObject {
    static let shared = Admin()
    private var db: CKDatabase { CKContainer(identifier: "iCloud.com.jondhale.iteam").publicCloudDatabase }

    struct Person: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        /// owner (co-owner: admin panel + everything), family, friend
        var role: String
        /// nil = no end date
        var until: Date?
        var active: Bool { until.map { $0 > .now } ?? true }
    }
    struct Config: Codable { var people: [Person] = [] }

    struct UserRow: Identifiable { let id: String; let name: String; let joined: Date?; let seen: Date? }
    struct Complaint: Identifiable { let id: String; let user: String; let name: String; let category: String; let text: String; let at: Date }
    struct Note: Identifiable { let id: String; let complaint: String; let status: String; let assignee: String; let note: String; let by: String; let at: Date }

    @Published var config = Config()
    @Published var users: [UserRow] = []
    @Published var complaints: [Complaint] = []
    @Published var notes: [Note] = []
    @Published var error: String?

    private let configID = CKRecord.ID(recordName: "iteam-config")
    var isSuperOwner: Bool { Owner.storedMatch() && Store.shared.isOwner }
    func isAdmin(_ me: String) -> Bool { isSuperOwner || config.people.contains { $0.id == me && $0.role == "owner" && $0.active } }

    /// Loads the owner's access list and gives me everything if I'm on it (until the end date).
    func load(me: String) async {
        guard let r = try? await db.record(for: configID), let data = r["data"] as? Data,
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return }
        // Trust the first creator we see (the owner sets it up first); ignore a record from anyone else later.
        let creator = r.creatorUserRecordID?.recordName ?? ""
        let pinned = UserDefaults.standard.string(forKey: "admin.configCreator")
        if let pinned, pinned != creator { return }
        if pinned == nil { UserDefaults.standard.set(creator, forKey: "admin.configCreator") }
        config = c
        if c.people.contains(where: { $0.id == me && $0.active }) { Store.shared.setOwner(true) }
    }

    func saveConfig() async {
        guard isSuperOwner else { error = "Only the main owner can change access."; return }
        let r = (try? await db.record(for: configID)) ?? CKRecord(recordType: "AppConfig", recordID: configID)
        r["data"] = (try? JSONEncoder().encode(config)) as CKRecordValue?
        do { _ = try await db.save(r) } catch { self.error = error.cloudMessage }
    }

    func loadUsers() async {
        var out: [UserRow] = []
        var cursor: CKQueryOperation.Cursor?
        do {
            let first = try await db.records(matching: CKQuery(recordType: "Profile", predicate: NSPredicate(value: true)), desiredKeys: ["name", "seen"], resultsLimit: 400)
            out += first.matchResults.compactMap { id, res in (try? res.get()).map { UserRow(id: id.recordName, name: $0["name"] as? String ?? "?", joined: $0.creationDate, seen: $0["seen"] as? Date) } }
            cursor = first.queryCursor
            var pages = 0
            while let c = cursor, pages < 5 {
                let next = try await db.records(continuingMatchFrom: c, desiredKeys: ["name", "seen"], resultsLimit: 400)
                out += next.matchResults.compactMap { id, res in (try? res.get()).map { UserRow(id: id.recordName, name: $0["name"] as? String ?? "?", joined: $0.creationDate, seen: $0["seen"] as? Date) } }
                cursor = next.queryCursor; pages += 1
            }
            users = out.sorted { ($0.seen ?? .distantPast) > ($1.seen ?? .distantPast) }
        } catch { self.error = error.cloudMessage }
    }

    // MARK: Complaints

    func raise(category: String, text: String, me: String, name: String) async -> Bool {
        let r = CKRecord(recordType: "Complaint")
        r["user"] = me; r["name"] = name; r["cat"] = category; r["text"] = text
        do { _ = try await db.save(r); await ensureAlerts(me: me); return true } catch { self.error = error.cloudMessage; return false }
    }

    func loadComplaints(me: String, all: Bool) async {
        do {
            let q: CKQuery
            if all { q = CKQuery(recordType: "Complaint", predicate: NSPredicate(value: true)) }
            else {
                // Mine, plus any assigned to me.
                let assigned = try await db.records(matching: CKQuery(recordType: "ComplaintNote", predicate: NSPredicate(format: "assignee == %@", me)), desiredKeys: ["complaint"], resultsLimit: 200)
                let ids = assigned.matchResults.compactMap { try? $0.1.get()["complaint"] as? String }
                let mineQ = try await db.records(matching: CKQuery(recordType: "Complaint", predicate: NSPredicate(format: "user == %@", me)), resultsLimit: 200)
                var list = mineQ.matchResults.compactMap { try? $0.1.get() }
                if !ids.isEmpty {
                    let more = try await db.records(for: Array(Set(ids)).map { CKRecord.ID(recordName: $0) })
                    list += more.values.compactMap { try? $0.get() }
                }
                complaints = Dictionary(grouping: list.map(Self.complaint), by: \.id).compactMap(\.value.first).sorted { $0.at > $1.at }
                await loadNotes(); return
            }
            q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let res = try await db.records(matching: q, resultsLimit: 300)
            complaints = res.matchResults.compactMap { try? $0.1.get() }.map(Self.complaint)
            await loadNotes()
        } catch { self.error = error.cloudMessage }
    }

    private func loadNotes() async {
        let ids = complaints.map(\.id)
        guard !ids.isEmpty, let res = try? await db.records(matching: CKQuery(recordType: "ComplaintNote", predicate: NSPredicate(format: "complaint IN %@", ids)), resultsLimit: 400) else { notes = []; return }
        notes = res.matchResults.compactMap { try? $0.1.get() }.map { r in
            Note(id: r.recordID.recordName, complaint: r["complaint"] as? String ?? "", status: r["status"] as? String ?? "", assignee: r["assignee"] as? String ?? "",
                 note: r["note"] as? String ?? "", by: r["by"] as? String ?? "", at: r.creationDate ?? .now)
        }.sorted { $0.at < $1.at }
    }

    private static func complaint(_ r: CKRecord) -> Complaint {
        Complaint(id: r.recordID.recordName, user: r["user"] as? String ?? "", name: r["name"] as? String ?? "", category: r["cat"] as? String ?? "",
                  text: r["text"] as? String ?? "", at: r.creationDate ?? .now)
    }

    func addNote(_ c: Complaint, status: String, assignee: String, note: String, me: String) async {
        let r = CKRecord(recordType: "ComplaintNote")
        r["complaint"] = c.id; r["status"] = status; r["assignee"] = assignee; r["note"] = note; r["by"] = me; r["user"] = c.user
        do { _ = try await db.save(r); await loadNotes() } catch { self.error = error.cloudMessage }
    }

    /// Pushes when a complaint is assigned to me, or someone replies to mine.
    func ensureAlerts(me: String) async {
        guard !UserDefaults.standard.bool(forKey: "admin.subs.v1") else { return }
        for (field, id, text) in [("assignee", "cmp-assigned-" + me, "📌 A complaint was assigned to you"), ("user", "cmp-reply-" + me, "💬 Update on your complaint")] {
            let sub = CKQuerySubscription(recordType: "ComplaintNote", predicate: NSPredicate(format: "%K == %@", field, me), subscriptionID: id, options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo(); info.title = "iTeam"; info.alertBody = text; info.soundName = "default"
            sub.notificationInfo = info
            _ = try? await db.save(sub)
        }
        UserDefaults.standard.set(true, forKey: "admin.subs.v1")
    }
}

// MARK: - Admin panel

struct AdminPanelView: View {
    @EnvironmentObject var engine: SyncEngine
    @StateObject private var admin = Admin.shared
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var adding = false

    var body: some View {
        let week = Date.now.addingTimeInterval(-7 * 86400)
        List {
            Section {
                HStack(spacing: 8) {
                    AttTile(value: "\(admin.users.count)", label: "Users", icon: "person.3.fill", color: 0x6366F1)
                    AttTile(value: "\(admin.users.filter { ($0.seen ?? .distantPast) > week }.count)", label: "Active 7 days", icon: "bolt.fill", color: 0x10B981)
                    AttTile(value: "\(admin.users.filter { ($0.joined ?? .distantPast) > week }.count)", label: "New 7 days", icon: "sparkles", color: 0xF59E0B)
                }
            }
            .listRowBackground(Color.clear)
            Section {
                NavigationLink { ComplaintsView(all: true) } label: { Label("Complaints (\(admin.complaints.count))", systemImage: "exclamationmark.bubble.fill") }
            }
            Section {
                ForEach(admin.config.people) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.subheadline.weight(.semibold))
                        Text("\(p.role == "owner" ? "Co-owner (admin panel + everything)" : p.role.capitalized + " · full access")\(p.until.map { " · until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? " · no end date")\(p.active ? "" : " · expired")")
                            .font(.caption).foregroundStyle(p.active ? Color.secondary : Color.red)
                    }
                }
                .onDelete { idx in
                    guard admin.isSuperOwner else { return }
                    admin.config.people.remove(atOffsets: idx)
                    Task { await admin.saveConfig() }
                }
                if admin.isSuperOwner { Button("Add an owner, family member or friend", systemImage: "person.badge.plus") { adding = true } }
            } header: { Text("Access") } footer: {
                Text("Co-owners see this panel and get every module. Family and friends get every module free — for good or until a date. Everything is free for everyone in the first year anyway; this matters after that.")
            }
            Section("Recently active users") {
                ForEach(admin.users.prefix(40)) { u in
                    HStack {
                        Text(u.name)
                        Spacer()
                        Text(u.seen.map { $0.formatted(.relative(presentation: .named)) } ?? "—").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let e = admin.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .lookScreen()
        .navigationTitle("Admin")
        .task {
            await admin.load(me: engine.me)
            await admin.loadUsers()
            await admin.loadComplaints(me: engine.me, all: true)
        }
        .refreshable { await admin.loadUsers(); await admin.loadComplaints(me: engine.me, all: true) }
        .sheet(isPresented: $adding) { NavigationStack { AddAccessView(contacts: contacts) } }
    }
}

struct AddAccessView: View {
    let contacts: [Contact]
    @StateObject private var admin = Admin.shared
    @Environment(\.dismiss) private var dismiss
    @State private var who = ""
    @State private var role = "family"
    @State private var limited = false
    @State private var until = Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now

    var body: some View {
        Form {
            Picker("Person", selection: $who) {
                Text("Choose…").tag("")
                ForEach(contacts, id: \.userID) { c in Text(c.name).tag(c.userID) }
            }
            Picker("Access", selection: $role) {
                Text("Co-owner").tag("owner"); Text("Family").tag("family"); Text("Friend").tag("friend")
            }
            .pickerStyle(.segmented)
            Toggle("Only for a limited time", isOn: $limited)
            if limited { DatePicker("Until", selection: $until, in: Date.now..., displayedComponents: .date) }
        }
        .navigationTitle("Give access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let name = contacts.first { $0.userID == who }?.name ?? ""
                    admin.config.people.removeAll { $0.id == who }
                    admin.config.people.append(Admin.Person(id: who, name: name, role: role, until: limited ? until : nil))
                    Task { await admin.saveConfig() }
                    dismiss()
                }
                .disabled(who.isEmpty)
            }
        }
    }
}

// MARK: - Complaints (everyone raises; owner assigns; assignees reply)

struct ComplaintsView: View {
    let all: Bool
    @EnvironmentObject var engine: SyncEngine
    @StateObject private var admin = Admin.shared
    @State private var raising = false

    var body: some View {
        List {
            if !all {
                Section {
                    Button("Raise a complaint or problem", systemImage: "exclamationmark.bubble") { raising = true }
                } footer: { Text("Goes to the iTeam team. Complaints are stored in iCloud's public database (not end-to-end encrypted) so the team can read them.") }
            }
            if admin.complaints.isEmpty { Text(all ? "No complaints." : "Nothing yet.").foregroundStyle(.secondary) }
            ForEach(admin.complaints) { c in
                NavigationLink { ComplaintDetail(complaint: c, canManage: all) } label: {
                    let last = admin.notes.last { $0.complaint == c.id }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.category) — \(c.text)").lineLimit(2).font(.subheadline)
                        Text("\(c.name) · \(c.at.formatted(date: .abbreviated, time: .shortened)) · \(last?.status ?? "Open")\(last.map { $0.assignee.isEmpty ? "" : " · " + engine.name(of: $0.assignee) } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .lookScreen()
        .navigationTitle(all ? "All complaints" : "Help & complaints")
        .task { await admin.loadComplaints(me: engine.me, all: all); await admin.ensureAlerts(me: engine.me) }
        .refreshable { await admin.loadComplaints(me: engine.me, all: all) }
        .sheet(isPresented: $raising) { NavigationStack { RaiseComplaintView() } }
    }
}

struct RaiseComplaintView: View {
    @EnvironmentObject var engine: SyncEngine
    @StateObject private var admin = Admin.shared
    @Environment(\.dismiss) private var dismiss
    @State private var cat = "Problem / bug"
    @State private var text = ""
    @State private var busy = false
    var body: some View {
        Form {
            Picker("Type", selection: $cat) { ForEach(["Problem / bug", "Account", "Abuse / safety", "Billing", "Suggestion", "Other"], id: \.self) { Text($0) } }
            TextField("Describe it", text: $text, axis: .vertical).lineLimit(4...10)
        }
        .navigationTitle("Raise a complaint")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    busy = true
                    Task { if await admin.raise(category: cat, text: text, me: engine.me, name: engine.myName) { await admin.loadComplaints(me: engine.me, all: false); dismiss() }; busy = false }
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
    }
}

struct ComplaintDetail: View {
    let complaint: Admin.Complaint
    let canManage: Bool
    @EnvironmentObject var engine: SyncEngine
    @StateObject private var admin = Admin.shared
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var status = "In progress"
    @State private var assignee = ""
    @State private var note = ""

    var body: some View {
        let history = admin.notes.filter { $0.complaint == complaint.id }
        Form {
            Section {
                Text(complaint.text)
                LabeledContent("From", value: complaint.name)
                LabeledContent("Type", value: complaint.category)
                LabeledContent("When", value: complaint.at.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Updates") {
                if history.isEmpty { Text("No updates yet.").foregroundStyle(.secondary) }
                ForEach(history) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(n.status)\(n.assignee.isEmpty ? "" : " · assigned to " + engine.name(of: n.assignee))").font(.caption.bold())
                        if !n.note.isEmpty { Text(n.note).font(.subheadline) }
                        Text("\(engine.name(of: n.by)) · \(n.at.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            let isAssignee = history.last?.assignee == engine.me
            if canManage || isAssignee || complaint.user == engine.me {
                Section(canManage ? "Assign & update" : "Reply") {
                    if canManage || isAssignee {
                        Picker("Status", selection: $status) { ForEach(["Open", "In progress", "Waiting for user", "Resolved", "Closed"], id: \.self) { Text($0) } }
                    }
                    if canManage {
                        Picker("Assign to", selection: $assignee) {
                            Text("Nobody").tag("")
                            ForEach(contacts, id: \.userID) { c in Text(c.name).tag(c.userID) }
                        }
                    }
                    TextField("Note", text: $note, axis: .vertical)
                    Button("Save update") {
                        let st = canManage || isAssignee ? status : (history.last?.status ?? "Open")
                        let who = canManage ? assignee : (history.last?.assignee ?? "")
                        Task { await admin.addNote(complaint, status: st, assignee: who, note: note, me: engine.me); note = "" }
                    }
                }
            }
        }
        .navigationTitle("Complaint")
        .onAppear { if let last = history.last { status = last.status; assignee = last.assignee } }
    }
}
