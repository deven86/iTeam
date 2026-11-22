import SwiftUI
import PhotosUI
import SwiftData
import UserNotifications

// MARK: - Actions

extension SyncEngine {
    /// Saves a business record: in the linked person's direct chat (they see their own records), or only on my devices.
    func saveBiz(_ p: BizPayload, convID: String, uploads: [String: String] = [:]) {
        let isNew = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == p.id })).first) == nil
        if !convID.isEmpty, let conv = conversation(convID) {
            let answer = BizSpecs.spec(p.module)?.kind(p.kind)?.clientAnswers == true
            send(.biz(p), in: conv, loud: (isNew || answer) && !p.deleted, preview: isNew || answer ? BizSpecs.logLine(p, who: myName, isNew: isNew) : nil, uploads: uploads)
        } else {
            send(.biz(p), convID: selfConversationID, recipients: [], keyVersion: 0, loud: false, hint: nil, uploads: uploads)
        }
        save()
        // Rent: a payment settles the oldest due charges (so "rent due" always matches what's been paid).
        if isNew && p.module == "rent" && p.kind == "payment" && !p.deleted { settleRent(tenantID: p.parentID, paid: p.amount) }
        BizReminders.reschedule(self)
    }

    private func settleRent(tenantID: String, paid: Double) {
        let due = ((try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.parentID == tenantID && !$0.deleted && $0.kind == "charge" && $0.status == "Due" }))) ?? [])
            .sorted { ($0.due ?? $0.createdAt) < ($1.due ?? $1.createdAt) }
        var left = paid
        for c in due where c.amount <= left + 0.5 {
            left -= c.amount
            var q = BizPayload(c); q.status = "Paid"; q.notes = (c.notes.isEmpty ? "" : c.notes + " · ") + "settled by payment"
            saveBiz(q, convID: c.convID)
        }
    }

    /// Pet Care → core iLife Care: every pet is a Care profile; medicines and feeding become Care reminders (Taken/Skip for the family).
    func petBridge(_ p: BizPayload) {
        let pid = p.parentID.isEmpty ? p.id : p.parentID
        guard let pet = try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == pid })).first else { return }
        let careID = "c_" + pet.id
        let conv = conversation(pet.convID) ?? DemoChats.notesToSelf(self)
        if p.kind == "pet" || careProfile(careID) == nil {
            saveCareProfile(in: conv, id: careID, name: "\(pet.title) (\(pet.subtitle.isEmpty ? "Pet" : pet.subtitle))", relation: "Pet", bloodGroup: "",
                            allergies: "", conditions: "", emergencyContact: pet.phone, notes: pet.notes, avatar: nil, deleted: pet.deleted)
        }
        if p.kind == "medication" || p.kind == "feeding", let prof = careProfile(careID) {
            saveMedicine(prof, id: "m_" + p.id, name: p.title, dose: p.subtitle, form: p.kind == "feeding" ? "Meal" : "Medicine",
                         times: [p.date.map { Att.minutes($0) } ?? 540], instructions: p.notes, startDate: .now, endDate: nil, stock: nil, deleted: p.deleted)
        }
    }

    /// Rent: creates each month's charge when the due date arrives (with the yearly raise), so pending rent matches the agreement.
    func autoRentCharges() {
        let me = self.me
        let tenants = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.module == "rent" && $0.kind == "tenant" && !$0.deleted && $0.ownerID == me }))) ?? []
        for t in tenants where t.amount > 0 {
            guard var due = t.due else { continue }
            var made = 0
            while due <= .now && made < 12 {
                var rent = t.amount
                if let pct = Double(t.extra["Yearly raise %"] ?? ""), pct > 0, let start = t.date {
                    let years = Calendar.current.dateComponents([.year], from: start, to: due).year ?? 0
                    rent = (t.amount * pow(1 + pct / 100, Double(max(years, 0)))).rounded()
                }
                var c = BizPayload(BizRecord(id: "r_" + UUID().uuidString))
                c.module = "rent"; c.kind = "charge"; c.parentID = t.id; c.subjectID = t.subjectID
                c.title = "Rent " + due.formatted(.dateTime.month(.abbreviated).year()); c.amount = rent; c.due = due; c.status = "Due"
                saveBiz(c, convID: t.convID)
                due = Calendar.current.date(byAdding: .month, value: 1, to: due) ?? due.addingTimeInterval(30 * 86400)
                made += 1
            }
            if made > 0 { var p = BizPayload(t); p.due = due; saveBiz(p, convID: t.convID) }
        }
    }

    /// Shares a record and its entries into a chat or group — everyone there sees it (e.g. a trip with the travel group).
    func linkBiz(_ parent: BizRecord, toChat conv: Conversation) {
        let pid = parent.id
        let children = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.parentID == pid && !$0.deleted }))) ?? []
        for r in [parent] + children {
            r.convID = conv.id
            send(.biz(BizPayload(r)), in: conv, loud: r === parent, preview: r === parent ? "📒 \(myName) shared \(parent.title)" : nil)
        }
        save()
    }

    /// Links a person record (and its existing entries) to an iTeam contact's chat.
    func linkBiz(_ parent: BizRecord, to contact: Contact) {
        let conv = directConversation(with: contact)
        let pid = parent.id
        let children = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.parentID == pid && !$0.deleted }))) ?? []
        for r in [parent] + children {
            var p = BizPayload(r)
            p.subjectID = contact.userID
            r.subjectID = contact.userID
            r.convID = conv.id
            send(.biz(p), in: conv, loud: r === parent, preview: r === parent ? "📒 \(myName) added you to \(BizSpecs.spec(r.module)?.title ?? "a module")" : nil)
        }
        save()
    }
}

// MARK: - Reminders

@MainActor
enum BizReminders {
    static func reschedule(_ engine: SyncEngine) {
        guard let ctx = engine.context else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("biz.") }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            let me = engine.me
            let all = (try? ctx.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { !$0.deleted }))) ?? []
            var items: [(Date, String, String)] = []
            for r in all where r.ownerID == me || r.subjectID == me {
                guard let spec = BizSpecs.spec(r.module), let kind = spec.kind(r.kind), !kind.doneStatuses.contains(r.status) else { continue }
                let parent = all.first { $0.id == r.parentID }?.title ?? ""
                if let due = r.due, kind.fields.contains(where: { $0.key == .due }) {
                    let fire = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
                    if fire > .now { items.append((fire, "\(kind.label) due: \(r.title.isEmpty ? parent : r.title)", [parent, r.amount > 0 ? BizSpecs.money(r.amount) : ""].filter { !$0.isEmpty }.joined(separator: " · "))) }
                }
                if let d = r.date, !kind.statuses.isEmpty, d > .now.addingTimeInterval(3600) {
                    items.append((d.addingTimeInterval(-3600), "\(kind.label) in 1 hour", [parent, r.title].filter { !$0.isEmpty }.joined(separator: " — ")))
                }
            }
            for (i, item) in items.sorted(by: { $0.0 < $1.0 }).prefix(20).enumerated() {
                let c = UNMutableNotificationContent()
                c.title = item.1; c.body = item.2; c.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.0)
                try? await center.add(UNNotificationRequest(identifier: "biz.\(i)", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }
}

// MARK: - Home

struct BizHomeView: View {
    let spec: BizSpec
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var modules: ModuleRegistry
    @Environment(\.look) private var look
    @Query(filter: #Predicate<BizRecord> { !$0.deleted }, sort: \BizRecord.updatedAt, order: .reverse) private var all: [BizRecord]
    @State private var search = ""
    @State private var adding = false
    @State private var editing: BizRecord?
    @State private var shareItems: ShareItems?
    @State private var showArchive = false

    /// Whole-module report: every person / item with its balance and entries.
    private var reportHTML: String {
        func e(_ s: String) -> String { PDFMaker.esc(s) }
        var h = "<h2>\(e(spec.title))</h2><p>\(e(spec.balanceLabel)): <b>\(BizSpecs.money(max(balance, 0)))</b> · \(Date.now.formatted(date: .long, time: .shortened))</p>"
        h += "<table border='1' cellpadding='5' style='border-collapse:collapse;width:100%'><tr><th>\(e(spec.parent?.label ?? "Item"))</th><th>Details</th><th>Entries</th><th>\(e(spec.balanceLabel))</th></tr>"
        for r in mine.filter({ $0.parentID.isEmpty }).sorted(by: { $0.title < $1.title }) {
            let kids = mine.filter { $0.parentID == r.id }
            let bal = spec.parent == nil ? BizMath.contribution(r, spec) : BizMath.balance(of: r.id, in: mine, spec: spec)
            let details = [r.subtitle, r.status, r.due.map { "due " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            h += "<tr><td>\(e(r.title))</td><td>\(e(details))</td><td>\(kids.count)</td><td>\(bal != 0 ? BizSpecs.money(bal) : "")</td></tr>"
        }
        return h + "</table>"
    }

    private var mine: [BizRecord] { all.filter { $0.module == spec.module && $0.ownerID == engine.me } }
    private func autoRun() { if spec.module == "rent" { engine.autoRentCharges() } }
    private var shared: [BizRecord] {
        all.filter { $0.module == spec.module && $0.ownerID != engine.me && $0.parentID.isEmpty && ($0.subjectID == engine.me || ($0.subjectID.isEmpty && !$0.convID.isEmpty)) }
    }
    private var tops: [BizRecord] {
        let q = search.lowercased()
        return mine.filter { $0.parentID.isEmpty && (q.isEmpty || $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)) }
    }
    private var balance: Double { mine.reduce(0) { $0 + BizMath.contribution($1, spec) } }
    private var upcoming: [BizRecord] {
        let week = Date.now.addingTimeInterval(7 * 86400)
        return mine.filter { r in
            guard let k = spec.kind(r.kind), !k.doneStatuses.contains(r.status) else { return false }
            let d = r.date.flatMap { k.statuses.isEmpty ? nil : $0 } ?? r.due
            return d.map { $0 > Date.now.addingTimeInterval(-86400) && $0 < week } ?? false
        }.sorted { ($0.date ?? $0.due ?? .now) < ($1.date ?? $1.due ?? .now) }
    }

    var body: some View {
        NavigationStack {
            List {
                stats.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                if !upcoming.isEmpty {
                    Section("Next 7 days") { ForEach(upcoming.prefix(8)) { r in BizRow(record: r, spec: spec, showParent: true) } }.lookRows()
                }
                if tops.isEmpty && shared.isEmpty { empty.listRowBackground(Color.clear) }
                if !tops.isEmpty {
                    Section(spec.parent?.plural ?? spec.children.first?.plural ?? "") {
                        ForEach(tops) { r in row(r) }
                    }
                    .lookRows()
                }
                if !shared.isEmpty {
                    Section("Shared with me") {
                        ForEach(shared) { r in
                            NavigationLink { BizParentView(spec: spec, recordID: r.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(r.title).font(.headline)
                                    Text("Managed by \(engine.name(of: r.ownerID))").font(.caption).foregroundStyle(look.textSecondary)
                                }
                            }
                        }
                    }
                    .lookRows()
                }
            }
            .lookScreen()
            .searchable(text: $search)
            .navigationTitle(spec.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") } }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Archive (deleted)", systemImage: "archivebox") { showArchive = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export report (PDF)", systemImage: "doc.richtext") {
                        if let url = PDFMaker.make(title: spec.title, bodyHTML: reportHTML, fileName: spec.title + " report", module: spec.title, icon: spec.icon, colors: spec.colors, charts: PDFCharts.biz(spec, records: mine)) { shareItems = ShareItems(items: [url]) }
                    }
                }
            }
            .shareSheet($shareItems)
            .sheet(isPresented: $showArchive) { NavigationStack { BizArchiveView(spec: spec) } }
            .refreshable { await engine.sync(); autoRun() }
            .onAppear { autoRun() }
            .sheet(isPresented: $adding) {
                NavigationStack { BizEditor(spec: spec, kind: spec.parent ?? spec.children[0], parent: nil, existing: nil) }
            }
            .sheet(item: $editing) { r in
                NavigationStack { BizEditor(spec: spec, kind: spec.kind(r.kind) ?? spec.children[0], parent: nil, existing: r) }
            }
        }
    }

    @ViewBuilder
    private func row(_ r: BizRecord) -> some View {
        if spec.parent != nil {
            NavigationLink { BizParentView(spec: spec, recordID: r.id) } label: { BizParentRow(record: r, spec: spec, all: all) }
        } else {
            Button { editing = r } label: { BizRow(record: r, spec: spec, showParent: false) }.buttonStyle(.plain)
                .swipeActions {
                    if let k = spec.kind(r.kind), let done = k.doneStatuses.first, r.status != done {
                        Button(done) { markDone(r, done) }.tint(.green)
                    }
                }
        }
    }

    private func markDone(_ r: BizRecord, _ done: String) {
        var p = BizPayload(r); p.status = done
        engine.saveBiz(p, convID: r.convID)
        // Repeating bills roll over to the next due date.
        if spec.module == "bills", let due = r.due {
            let next: Date? = switch r.subtitle {
            case "Monthly": Calendar.current.date(byAdding: .month, value: 1, to: due)
            case "Every 3 months": Calendar.current.date(byAdding: .month, value: 3, to: due)
            case "Yearly": Calendar.current.date(byAdding: .year, value: 1, to: due)
            default: nil
            }
            if let next {
                var n = BizPayload(r); n.id = "b_" + UUID().uuidString; n.status = "Due"; n.due = next
                engine.saveBiz(n, convID: "")
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            tile("\(tops.count)", spec.parent?.plural ?? spec.children.first?.plural ?? "", "person.2.fill")
            tile(BizSpecs.money(max(balance, 0)), spec.balanceLabel, "indianrupeesign")
            tile("\(upcoming.count)", "Next 7 days", "calendar")
        }
    }

    private func tile(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(Color(hex: spec.colors[0]))
            Text(v).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(.caption2).foregroundStyle(look.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).lookCard(padding: 6)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            EmptyStateView(icon: spec.icon, title: spec.title, message: "Add your first \(spec.parent?.label.lowercased() ?? "bill"). Link an iTeam contact and they see only their own records, live.")
            Button("Try a demo", systemImage: "sparkles") { BizDemo.create(spec, engine: engine) }.buttonStyle(.glass)
        }
    }
}

enum BizMath {
    static func contribution(_ r: BizRecord, _ spec: BizSpec) -> Double {
        guard let k = spec.kind(r.kind), k.sign != 0, !r.deleted else { return 0 }
        if let w = k.countWhen, r.status != w { return 0 }
        if r.module == "rent" && r.kind == "payment" { return 0 }
        return k.sign * r.amount
    }

    static func balance(of parentID: String, in all: [BizRecord], spec: BizSpec) -> Double {
        all.filter { $0.parentID == parentID }.reduce(0) { $0 + contribution($1, spec) }
    }
}

struct BizParentRow: View {
    let record: BizRecord
    let spec: BizSpec
    let all: [BizRecord]
    var body: some View {
        let bal = BizMath.balance(of: record.id, in: all, spec: spec)
        HStack {
            AvatarView(name: record.title, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(record.title).font(.headline)
                    if !record.subjectID.isEmpty { Image(systemName: "link").font(.caption2).foregroundStyle(.secondary) }
                }
                Text([record.subtitle, record.status].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if bal != 0 { Text(BizSpecs.money(bal)).font(.subheadline.bold()).foregroundStyle(bal > 0 ? .orange : .green) }
        }
    }
}

struct BizRow: View {
    let record: BizRecord
    let spec: BizSpec
    var showParent: Bool
    @Query private var parents: [BizRecord]

    init(record: BizRecord, spec: BizSpec, showParent: Bool) {
        self.record = record; self.spec = spec; self.showParent = showParent
        let pid = record.parentID
        _parents = Query(filter: #Predicate<BizRecord> { $0.id == pid })
    }

    var body: some View {
        let k = spec.kind(record.kind)
        HStack(spacing: 10) {
            Image(systemName: k?.icon ?? "doc").foregroundStyle(Color(hex: spec.colors[0])).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title.isEmpty ? (k?.label ?? "") : record.title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if record.amount != 0 { Text(BizSpecs.money(record.amount)).font(.subheadline.bold()).foregroundStyle((k?.sign ?? 0) < 0 || record.kind == "payment" ? .green : .primary) }
            if !record.status.isEmpty { Text(record.status).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.thinMaterial, in: Capsule()) }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if showParent, let p = parents.first { parts.append(p.title) }
        if let d = record.date { parts.append(d.formatted(date: .abbreviated, time: (spec.kind(record.kind)?.statuses.isEmpty ?? true) ? .omitted : .shortened)) }
        if let d = record.due { parts.append("due " + d.formatted(date: .abbreviated, time: .omitted)) }
        if !record.subtitle.isEmpty && record.kind != spec.parent?.id { parts.append(record.subtitle) }
        if !record.notes.isEmpty { parts.append(record.notes) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Person / matter detail

struct BizParentView: View {
    let spec: BizSpec
    let recordID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [BizRecord]
    @Query private var children: [BizRecord]
    @AppStorage("biz.upi") private var upi = ""
    @State private var adding: BizKind?
    @State private var editing: BizRecord?
    @State private var editParent = false
    @State private var linking = false
    @State private var sharingChat = false
    @State private var shareItems: ShareItems?
    @State private var confirmDelete = false
    @State private var viewing: BizRecord?

    init(spec: BizSpec, recordID: String) {
        self.spec = spec; self.recordID = recordID
        _found = Query(filter: #Predicate<BizRecord> { $0.id == recordID })
        _children = Query(filter: #Predicate<BizRecord> { $0.parentID == recordID && !$0.deleted }, sort: \BizRecord.updatedAt, order: .reverse)
    }

    var body: some View {
        if let r = found.first { content(r) } else { Text("Not found") }
    }

    private func content(_ r: BizRecord) -> some View {
        // The creator, or the whole group when the record is shared into a group (a legal team).
        let team = engine.conversation(r.convID).map { $0.isGroup && $0.isMember(engine.me) } ?? false
        let mine = r.ownerID == engine.me || team
        let isClient = r.subjectID == engine.me && r.ownerID != engine.me
        let bal = children.reduce(0) { $0 + BizMath.contribution($1, spec) }
        return List {
            header(r, mine: mine, balance: bal)
            ForEach(spec.children, id: \.id) { k in
                let list = children.filter { $0.kind == k.id }.sorted { ($0.date ?? $0.due ?? $0.createdAt) > ($1.date ?? $1.due ?? $1.createdAt) }
                if !list.isEmpty || mine || (isClient && k.clientCanAdd) {
                    Section {
                        if list.count > 5 {
                            // Long lists (e.g. case updates) scroll inside a fixed area so they don't take over the screen.
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(list) { c in childRow(c, k: k, mine: mine, isClient: isClient); Divider() }
                                }
                            }
                            .frame(height: 320)
                        } else {
                            ForEach(list) { c in childRow(c, k: k, mine: mine, isClient: isClient) }
                        }
                        if mine { Button("Add \(k.label.lowercased())", systemImage: "plus") { adding = k } }
                        else if isClient && k.clientCanAdd { Button(k.id == "question" ? "Ask a question" : "Report \(k.label.lowercased())", systemImage: "plus.bubble") { adding = k } }
                    } header: { Text(k.plural) }
                    .lookRows()
                }
            }
            if spec.module == "travel" || spec.module == "kids" {
                Section {
                    NavigationLink { AlbumView(owner: r.id, convID: r.convID, title: "\(r.title) album") } label: {
                        Label(spec.module == "travel" ? "Trip album" : "Photo album", systemImage: "photo.on.rectangle.angled")
                    }
                }
                .lookRows()
            }
            if mine { actions(r, balance: bal) }
            else if !r.files.isEmpty { Section("Attachments") { BizFilesList(files: r.files) }.lookRows() }
        }
        .lookScreen()
        .navigationTitle(r.title)
        .sheet(item: Binding(get: { adding.map { KindBox(kind: $0) } }, set: { adding = $0?.kind })) { box in
            NavigationStack { BizEditor(spec: spec, kind: box.kind, parent: r, existing: nil) }
        }
        .sheet(item: $editing) { c in NavigationStack { BizEditor(spec: spec, kind: spec.kind(c.kind) ?? spec.children[0], parent: r, existing: c) } }
        .sheet(isPresented: $editParent) { NavigationStack { BizEditor(spec: spec, kind: spec.parent ?? spec.children[0], parent: nil, existing: r) } }
        .sheet(isPresented: $linking) { NavigationStack { BizLinkContact(record: r) } }
        .sheet(item: $viewing) { c in NavigationStack { BizRecordViewer(record: c, spec: spec) } }
        .sheet(isPresented: $sharingChat) { NavigationStack { BizLinkChat(record: r) } }
        .shareSheet($shareItems)
        .confirmationDialog("Delete \(r.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { var p = BizPayload(r); p.deleted = true; engine.saveBiz(p, convID: r.convID); dismiss() }
        }
    }

    @ViewBuilder
    private func childRow(_ c: BizRecord, k: BizKind, mine: Bool, isClient: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if mine || c.ownerID == engine.me { editing = c } else { viewing = c } } label: { BizRow(record: c, spec: spec, showParent: false) }
                .buttonStyle(.plain)
            if !c.files.isEmpty { Label("\(c.files.count) attachment\(c.files.count == 1 ? "" : "s")", systemImage: "paperclip").font(.caption2).foregroundStyle(.secondary) }
            if isClient && k.clientAnswers && !k.doneStatuses.contains(c.status) {
                HStack {
                    let yes = k.statuses.count > 1 ? k.statuses[1] : "Done"
                    Button(yes) { answer(c, yes) }.buttonStyle(.glassProminent).controlSize(.small)
                    if k.statuses.count > 2 { Button(k.statuses[2], role: .destructive) { answer(c, k.statuses[2]) }.buttonStyle(.glass).controlSize(.small) }
                }
            }
            if c.status == "Reverting" && (isClient || (!c.convID.isEmpty && engine.conversation(c.convID)?.members.first { $0.id == engine.me }?.role != .member && c.subjectID.isEmpty)) {
                HStack {
                    Text("Move back to Due?").font(.caption)
                    Button("Approve") { answer(c, "Due") }.buttonStyle(.glassProminent).controlSize(.small)
                    Button("Keep Paid") { answer(c, "Paid") }.buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .swipeActions {
            if mine, let done = k.doneStatuses.first, c.status != done {
                Button(done) { var p = BizPayload(c); p.status = done; engine.saveBiz(p, convID: c.convID) }.tint(.green)
            }
        }
    }

    private func answer(_ c: BizRecord, _ status: String) {
        var p = BizPayload(c); p.status = status; p.at = .now
        engine.saveBiz(p, convID: c.convID)
        Haptics.success()
    }

    private func header(_ r: BizRecord, mine: Bool, balance: Double) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    AvatarView(name: r.title, size: 48)
                    VStack(alignment: .leading) {
                        Text(r.title).font(.title3.bold())
                        if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(look.textSecondary) }
                        if !r.status.isEmpty { Text(r.status).font(.caption.bold()) }
                    }
                    Spacer()
                    if !r.phone.isEmpty, let url = URL(string: "tel:" + r.phone.filter { $0.isNumber || $0 == "+" }) {
                        Link(destination: url) { Image(systemName: "phone.fill").font(.title3) }
                    }
                }
                if r.amount != 0 && spec.module == "rent" { Text("Monthly rent \(BizSpecs.money(r.amount))").font(.caption) }
                if let d = r.due { Text("Next due \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
                if !r.notes.isEmpty { Text(r.notes).font(.caption).foregroundStyle(look.textSecondary) }
                if balance != 0 {
                    Text("\(spec.balanceLabel): \(BizSpecs.money(balance))").font(.headline).foregroundStyle(balance > 0 ? .orange : .green)
                }
                if !mine { Text("Managed by \(engine.name(of: r.ownerID))").font(.caption).foregroundStyle(look.textSecondary) }
                else if !r.subjectID.isEmpty { Label("Shared with \(engine.name(of: r.subjectID)) — they see these records", systemImage: "link").font(.caption) }
            }
        }
        .lookRows()
    }

    @ViewBuilder
    private func actions(_ r: BizRecord, balance: Double) -> some View {
        Section {
            if balance > 0 && ["khata", "tuition", "rent", "legal", "clinic"].contains(spec.module) {
                Button("Ask for payment", systemImage: "indianrupeesign.circle") { askPayment(r, balance) }
                TextField("Your UPI ID (for payment links)", text: $upi).textInputAutocapitalization(.never).font(.caption)
            }
            Button("Share statement (PDF)", systemImage: "doc.richtext") {
                if let url = PDFMaker.make(title: "\(spec.title) — \(r.title)", bodyHTML: statementHTML(r, balance), fileName: "\(r.title) statement", module: spec.title, icon: spec.icon, colors: spec.colors, charts: PDFCharts.bizStatement(spec, children: children)) {
                    shareItems = ShareItems(items: [url])
                }
            }
            if r.subjectID.isEmpty && r.convID.isEmpty && (spec.parent?.linkable ?? false) {
                if spec.module == "travel" || spec.module == "kids" {
                    Button("Share with a chat or group", systemImage: "person.3") { sharingChat = true }
                }
                if spec.module != "travel" {
                    Button("Link iTeam contact (they see their records)", systemImage: "link") { linking = true }
                }
            }
            Button("Edit", systemImage: "pencil") { editParent = true }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
        .lookRows()
    }

    private func askPayment(_ r: BizRecord, _ amount: Double) {
        var text = "Hi \(r.title), a gentle reminder: \(BizSpecs.money(amount)) is pending (\(spec.title))."
        let id = upi.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty {
            let name = engine.myName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            text += "\nPay by UPI: upi://pay?pa=\(id)&pn=\(name)&am=\(Int(amount))&cu=INR"
        }
        if !r.convID.isEmpty, let conv = engine.conversation(r.convID) {
            engine.sendText(text, in: conv)
            Haptics.success()
        } else {
            shareItems = ShareItems(items: [text])
        }
    }

    private func statementHTML(_ r: BizRecord, _ balance: Double) -> String {
        func e(_ s: String) -> String { PDFMaker.esc(s) }
        var h = "<h2>\(e(r.title))</h2><p>\(e(r.subtitle))</p><table border='1' cellpadding='5' style='border-collapse:collapse;width:100%'><tr><th>Type</th><th>Details</th><th>Date</th><th>Amount</th><th>Status</th></tr>"
        for c in children.sorted(by: { ($0.date ?? $0.due ?? $0.createdAt) < ($1.date ?? $1.due ?? $1.createdAt) }) {
            let d = (c.date ?? c.due).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            h += "<tr><td>\(e(spec.kind(c.kind)?.label ?? c.kind))</td><td>\(e([c.title, c.subtitle, c.notes].filter { !$0.isEmpty }.joined(separator: " · ")))</td><td>\(d)</td><td>\(c.amount != 0 ? BizSpecs.money(c.amount) : "")</td><td>\(e(c.status))</td></tr>"
        }
        h += "</table>"
        if balance != 0 { h += "<h3>\(e(spec.balanceLabel)): \(BizSpecs.money(balance))</h3>" }
        h += "<p style='color:#888'>Prepared by \(e(engine.myName)) on \(Date.now.formatted(date: .long, time: .omitted)) with iTeam</p>"
        return h
    }
}

private struct KindBox: Identifiable {
    let kind: BizKind
    var id: String { kind.id }
}

/// Pick the iTeam contact this person record belongs to.
struct BizLinkContact: View {
    let record: BizRecord
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    var body: some View {
        List(contacts) { c in
            Button { engine.linkBiz(record, to: c); dismiss() } label: {
                HStack { AvatarView(name: c.name, imageData: c.avatar, size: 32); Text(c.name).foregroundStyle(Color.primary) }
            }
        }
        .navigationTitle("Link contact")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct BizLinkChat: View {
    let record: BizRecord
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Conversation> { !$0.left && !$0.isDemo }, sort: \Conversation.lastActivity, order: .reverse) private var chats: [Conversation]
    var body: some View {
        List(chats) { c in
            Button { engine.linkBiz(record, toChat: c); dismiss() } label: {
                HStack { AvatarView(name: c.title, imageData: c.avatar, size: 32, isGroup: c.isGroup); Text(c.title).foregroundStyle(Color.primary) }
            }
        }
        .navigationTitle("Share with")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// Deleted records are never erased: they stay here, marked who deleted them and when.
struct BizArchiveView: View {
    let spec: BizSpec
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<BizRecord> { $0.deleted }, sort: \BizRecord.updatedAt, order: .reverse) private var deleted: [BizRecord]
    @Query(sort: \BizRecord.title) private var everything: [BizRecord]

    var body: some View {
        let list = deleted.filter { $0.module == spec.module && ($0.ownerID == engine.me || $0.subjectID == engine.me || !$0.convID.isEmpty) }
        List {
            if list.isEmpty { Text("Nothing deleted.").foregroundStyle(.secondary) }
            ForEach(list) { r in
                VStack(alignment: .leading, spacing: 3) {
                    BizRow(record: r, spec: spec, showParent: true)
                    Text("Deleted by \(r.deletedBy.isEmpty ? engine.name(of: r.ownerID) : (r.deletedBy == engine.me ? "you" : engine.name(of: r.deletedBy))) · \(r.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Archive")
        .toolbar { Button("Done") { dismiss() } }
    }
}

// MARK: - Editor

struct BizEditor: View {
    let spec: BizSpec
    let kind: BizKind
    let parent: BizRecord?
    let existing: BizRecord?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var subtitle = ""
    @State private var phone = ""
    @State private var amount = ""
    @State private var date = Date.now
    @State private var due = Date.now.addingTimeInterval(7 * 86400)
    @State private var status = ""
    @State private var notes = ""
    @State private var files: [AttachmentRef] = []
    @State private var uploads: [String: String] = [:]
    @State private var extra: [String: String] = [:]
    @State private var linkTo = ""
    @State private var photoPicks: [PhotosPickerItem] = []
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]

    var body: some View {
        Form {
            if existing == nil && parent == nil && kind.linkable {
                Section {
                    Picker("Pick an iTeam user", selection: $linkTo) {
                        Text("Not on iTeam / later").tag("")
                        ForEach(contacts.filter { !$0.userID.hasPrefix("demo_") }, id: \.userID) { c in Text(c.name).tag(c.userID) }
                    }
                } footer: {
                    Text("A linked \(spec.clientWord) sees only their own records and gets notifications — they never pay for the module.")
                }
            }
            Section(kind.label) {
                ForEach(kind.fields, id: \.key.rawValue) { f in field(f) }
                ForEach(kind.extras, id: \.self) { label in
                    TextField(label, text: Binding(get: { extra[label] ?? "" }, set: { extra[label] = $0 }))
                        .keyboardType(label.contains("%") ? .decimalPad : .default)
                }
                if existing?.status == "Reverting" {
                    Label("Waiting for approval to move back to Due", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Attachments (receipt, bill, order, draft, agreement, photos)") {
                ForEach(files) { f in Label(f.name, systemImage: f.kind == "image" ? "photo" : f.kind == "video" ? "video" : "doc") }
                    .onDelete { files.remove(atOffsets: $0) }
                PhotosPicker(selection: $photoPicks, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                    Label("Add photos or videos", systemImage: "photo.on.rectangle")
                }
                Button("Add a document (PDF…)", systemImage: "doc.badge.plus") {
                    Presenter.file(types: [.pdf, .image, .data]) { url in
                        if let p = try? Attachments.prepareFile(url) { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                    }
                }
                if Presenter.hasCamera {
                    Button("Take a photo", systemImage: "camera") {
                        Presenter.camera { img in
                            if let d = img.jpegData(compressionQuality: 0.85), let p = try? Attachments.prepareImage(d) { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                        }
                    }
                }
            }
        }
        .onChange(of: photoPicks) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in
                for item in items {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let m = try? await item.loadTransferable(type: MovieFile.self),
                       let p = try? await VideoPrep.prepare(m.url, maxSeconds: 180) { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                    else if let d = try? await item.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(d) { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                }
                photoPicks = []
            }
        }
        .navigationTitle(existing == nil ? "New \(kind.label.lowercased())" : "Edit")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
        }
        .onAppear(perform: load)
    }

    private var valid: Bool {
        if kind.fields.contains(where: { $0.key == .title }) && kind.fields.first?.key == .title { return !title.trimmingCharacters(in: .whitespaces).isEmpty }
        if kind.fields.contains(where: { $0.key == .amount }) && kind.sign != 0 { return Double(amount) != nil }
        return true
    }

    @ViewBuilder
    private func field(_ f: BizField) -> some View {
        switch f.key {
        case .title: TextField(f.label, text: $title)
        case .subtitle:
            if f.options.isEmpty { TextField(f.label, text: $subtitle) }
            else { Picker(f.label, selection: $subtitle) { ForEach(f.options, id: \.self) { Text($0).tag($0) } } }
        case .phone: TextField(f.label, text: $phone).keyboardType(.phonePad)
        case .amount: TextField(f.label + " (₹)", text: $amount).keyboardType(.decimalPad)
        case .date: DatePicker(f.label, selection: $date, displayedComponents: f.label.lowercased().contains("time") ? [.hourAndMinute] : (kind.statuses.isEmpty ? [.date] : [.date, .hourAndMinute]))
        case .due: DatePicker(f.label, selection: $due, displayedComponents: [.date])
        case .status: Picker(f.label, selection: $status) { ForEach(kind.statuses, id: \.self) { Text($0).tag($0) } }
        case .notes: TextField(f.label, text: $notes, axis: .vertical).lineLimit(2...6)
        }
    }

    private func load() {
        status = kind.statuses.first ?? ""
        if let opt = kind.fields.first(where: { $0.key == .subtitle && !$0.options.isEmpty })?.options.first { subtitle = opt }
        if let p = parent, kind.id == "charge", p.amount > 0 { amount = String(Int(p.amount)) }
        guard let r = existing else { return }
        title = r.title; subtitle = r.subtitle; phone = r.phone; notes = r.notes
        amount = r.amount == 0 ? "" : (r.amount.rounded() == r.amount ? String(Int(r.amount)) : String(r.amount))
        if let d = r.date { date = d }
        if let d = r.due { due = d }
        if !r.status.isEmpty { status = r.status }
        files = r.files; extra = r.extra
    }

    private func save() {
        let keys = Set(kind.fields.map(\.key))
        let r = existing
        var p = BizPayload(r ?? BizRecord(id: spec.module.prefix(1) + "_" + UUID().uuidString))
        p.module = spec.module
        p.kind = kind.id
        p.parentID = parent?.id ?? r?.parentID ?? ""
        p.subjectID = parent?.subjectID ?? r?.subjectID ?? ""
        p.title = title.trimmingCharacters(in: .whitespaces)
        p.subtitle = subtitle; p.phone = phone; p.notes = notes
        p.amount = Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0
        p.date = keys.contains(.date) ? date : nil
        p.due = keys.contains(.due) ? due : nil
        p.status = keys.contains(.status) ? (existing?.status == "Reverting" && status == "Reverting" ? "Reverting" : status) : ""
        p.files = files; p.extra = extra
        p.at = .now
        engine.saveBiz(p, convID: parent?.convID ?? r?.convID ?? "", uploads: uploads)
        if spec.module == "petcare" { engine.petBridge(p) }
        if existing == nil, !linkTo.isEmpty, let c = engine.contact(linkTo),
           let rec = try? engine.context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == p.id })).first {
            engine.linkBiz(rec, to: c)
        }
        Haptics.success()
        dismiss()
    }
}

// MARK: - Demo

@MainActor
enum BizDemo {
    static func create(_ spec: BizSpec, engine: SyncEngine) {
        func add(_ kind: String, parent: String = "", title: String = "", subtitle: String = "", amount: Double = 0,
                 date: Date? = nil, due: Date? = nil, status: String = "", notes: String = "") -> String {
            let r = BizRecord(id: spec.module.prefix(1) + "_demo_" + UUID().uuidString)
            var p = BizPayload(r)
            p.module = spec.module; p.kind = kind; p.parentID = parent; p.title = title; p.subtitle = subtitle
            p.amount = amount; p.date = date; p.due = due; p.status = status; p.notes = notes
            engine.saveBiz(p, convID: "")
            return p.id
        }
        let day: (Int) -> Date = { Date.now.addingTimeInterval(Double($0) * 86400) }
        switch spec.module {
        case "khata":
            let c = add("customer", title: "Ramesh (demo)")
            _ = add("gave", parent: c, amount: 850, date: day(-6), notes: "Rice 5 kg, oil")
            _ = add("gave", parent: c, amount: 320, date: day(-2), notes: "Milk, bread")
            _ = add("got", parent: c, subtitle: "UPI", amount: 500, date: day(-1))
        case "tuition":
            let s = add("student", title: "Aarav (demo)", subtitle: "Class 8 · Maths")
            _ = add("attendance", parent: s, date: day(0), status: "Present")
            _ = add("fee", parent: s, title: "December", amount: 1500, due: day(5), status: "Due")
            _ = add("homework", parent: s, title: "Algebra ex. 4.2", due: day(2), status: "Assigned")
        case "rent":
            let t = add("tenant", title: "Mehta family (demo)", subtitle: "Flat 302", amount: 18000, due: day(10))
            _ = add("charge", parent: t, title: "Rent December", amount: 18000, due: day(10), status: "Due")
            _ = add("issue", parent: t, title: "Kitchen tap leaking", date: day(-1), status: "Open")
        case "legal":
            let m = add("case", title: "Patil vs. Shinde (demo)", subtitle: "Civil Court Thane · RCS 123/2025", status: "Pending")
            _ = add("hearing", parent: m, title: "Evidence", date: day(3), status: "Upcoming")
            _ = add("update", parent: m, title: "Written statement filed", date: day(-4))
            _ = add("fee", parent: m, title: "Appearance fee", amount: 5000, due: day(7), status: "Due")
        case "clinic":
            let p = add("patient", title: "Sunita (demo)", subtitle: "54 · F")
            _ = add("appointment", parent: p, title: "BP review", date: day(1), status: "Booked")
            _ = add("visit", parent: p, title: "Headache", date: day(-7), notes: "BP 150/95, advised low salt")
        case "kids":
            let k = add("child", title: "Riya (demo)", subtitle: "Class 3 · St. Mary's")
            _ = add("vaccine", parent: k, title: "Typhoid booster", due: day(12), status: "Due")
            _ = add("event", parent: k, title: "Parent-teacher meeting", date: day(4), status: "Upcoming")
            _ = add("timetable", parent: k, title: "Swimming", subtitle: "Saturday", notes: "7 AM, club pool")
        default:
            _ = add("bill", title: "Electricity (demo)", amount: 1240, due: day(4), status: "Due", notes: "Consumer no. 0001")
            _ = add("bill", title: "Car insurance (demo)", amount: 9800, due: day(25), status: "Due")
        }
    }
}


/// Read-only view of a record for the client / team: details, attachments, and the e-Vakalatnama PDF.
struct BizRecordViewer: View {
    let record: BizRecord
    let spec: BizSpec
    @EnvironmentObject var engine: SyncEngine
    @State private var shareItems: ShareItems?
    var body: some View {
        List {
            Section {
                Text(record.title).font(.headline)
                if !record.subtitle.isEmpty { Text(record.subtitle) }
                if let d = record.date ?? record.due { LabeledContent("Date", value: d.formatted(date: .abbreviated, time: .shortened)) }
                if record.amount != 0 { LabeledContent("Amount", value: BizSpecs.money(record.amount)) }
                if !record.status.isEmpty { LabeledContent("Status", value: record.status) }
                if !record.notes.isEmpty { Text(record.notes) }
                Text("Managed by \(engine.name(of: record.ownerID))").font(.caption).foregroundStyle(.secondary)
            }
            if !record.files.isEmpty { Section("Attachments") { BizFilesList(files: record.files) } }
            if record.kind == "vakalat" && record.status == "Signed" {
                Button("e-Vakalatnama record (PDF)", systemImage: "signature") {
                    if let u = PDFMaker.make(title: "e-Vakalatnama — client consent", bodyHTML: BizVakalat.html(record, engine: engine), fileName: "e-Vakalatnama",
                                             module: spec.title, icon: "signature", colors: spec.colors) { shareItems = ShareItems(items: [u]) }
                }
            }
        }
        .navigationTitle(spec.kind(record.kind)?.label ?? "Record")
        .navigationBarTitleDisplayMode(.inline)
        .shareSheet($shareItems)
    }
}

/// Tappable attachments (opens the file).
struct BizFilesList: View {
    let files: [AttachmentRef]
    @State private var error: String?
    var body: some View {
        ForEach(files) { f in
            Button {
                Task { @MainActor in
                    do { Presenter.preview(try await Attachments.load(f)) } catch { self.error = "Couldn't open — files are kept 45 days." }
                }
            } label: { Label(f.name, systemImage: f.kind == "image" ? "photo" : f.kind == "video" ? "video" : "doc") }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

@MainActor
enum BizVakalat {
    static func html(_ r: BizRecord, engine: SyncEngine) -> String {
        let e = PDFMaker.esc
        return """
        <p><b>Court & matter:</b> \(e(r.title))</p>
        <p><b>Advocate(s) / terms:</b> \(e(r.notes))</p>
        <p><b>Advocate (iTeam):</b> \(e(engine.name(of: r.ownerID)))</p>
        <p><b>Client (iTeam):</b> \(e(engine.name(of: r.subjectID)))</p>
        <p><b>Requested:</b> \((r.date ?? r.createdAt).formatted(date: .long, time: .shortened)) · <b>Signed by the client in iTeam:</b> \(r.updatedAt.formatted(date: .long, time: .shortened))</p>
        <p class="muted">This is a record of the client's consent given inside iTeam (end-to-end encrypted, signed with the client's iTeam key). It is not an official court e-filing Vakalatnama; file the official form where the court requires it.</p>
        """
    }
}
