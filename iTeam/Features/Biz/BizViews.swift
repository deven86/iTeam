import SwiftUI
import SwiftData
import UserNotifications

// MARK: - Actions

extension SyncEngine {
    /// Saves a business record: in the linked person's direct chat (they see their own records), or only on my devices.
    func saveBiz(_ p: BizPayload, convID: String) {
        if !convID.isEmpty, let conv = conversation(convID) {
            let isNew = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == p.id })).first) == nil
            send(.biz(p), in: conv, loud: isNew && !p.deleted, preview: isNew ? BizSpecs.logLine(p, who: myName, isNew: true) : nil)
        } else {
            sendPersonal(.biz(p))
        }
        save()
        BizReminders.reschedule(self)
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
            .refreshable { await engine.sync() }
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

    init(spec: BizSpec, recordID: String) {
        self.spec = spec; self.recordID = recordID
        _found = Query(filter: #Predicate<BizRecord> { $0.id == recordID })
        _children = Query(filter: #Predicate<BizRecord> { $0.parentID == recordID && !$0.deleted }, sort: \BizRecord.updatedAt, order: .reverse)
    }

    var body: some View {
        if let r = found.first { content(r) } else { Text("Not found") }
    }

    private func content(_ r: BizRecord) -> some View {
        let mine = r.ownerID == engine.me
        let bal = children.reduce(0) { $0 + BizMath.contribution($1, spec) }
        return List {
            header(r, mine: mine, balance: bal)
            ForEach(spec.children, id: \.id) { k in
                let list = children.filter { $0.kind == k.id }.sorted { ($0.date ?? $0.due ?? $0.createdAt) > ($1.date ?? $1.due ?? $1.createdAt) }
                if !list.isEmpty || mine {
                    Section {
                        ForEach(list) { c in
                            Button { if mine { editing = c } } label: { BizRow(record: c, spec: spec, showParent: false) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    if mine, let done = k.doneStatuses.first, c.status != done {
                                        Button(done) { var p = BizPayload(c); p.status = done; engine.saveBiz(p, convID: c.convID) }.tint(.green)
                                    }
                                }
                        }
                        if mine { Button("Add \(k.label.lowercased())", systemImage: "plus") { adding = k } }
                    } header: { Text(k.plural) }
                    .lookRows()
                }
            }
            if mine { actions(r, balance: bal) }
        }
        .lookScreen()
        .navigationTitle(r.title)
        .sheet(item: Binding(get: { adding.map { KindBox(kind: $0) } }, set: { adding = $0?.kind })) { box in
            NavigationStack { BizEditor(spec: spec, kind: box.kind, parent: r, existing: nil) }
        }
        .sheet(item: $editing) { c in NavigationStack { BizEditor(spec: spec, kind: spec.kind(c.kind) ?? spec.children[0], parent: r, existing: c) } }
        .sheet(isPresented: $editParent) { NavigationStack { BizEditor(spec: spec, kind: spec.parent ?? spec.children[0], parent: nil, existing: r) } }
        .sheet(isPresented: $linking) { NavigationStack { BizLinkContact(record: r) } }
        .sheet(isPresented: $sharingChat) { NavigationStack { BizLinkChat(record: r) } }
        .shareSheet($shareItems)
        .confirmationDialog("Delete \(r.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { var p = BizPayload(r); p.deleted = true; engine.saveBiz(p, convID: r.convID); dismiss() }
        }
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

    var body: some View {
        Form {
            Section(kind.label) {
                ForEach(kind.fields, id: \.key.rawValue) { f in field(f) }
            }
            if existing == nil && parent == nil && kind.linkable {
                Section {
                    Text("After saving, open it and tap “Link iTeam contact” so the \(spec.clientWord) sees their own records — they never need to buy the module.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        case .date: DatePicker(f.label, selection: $date, displayedComponents: kind.statuses.isEmpty ? [.date] : [.date, .hourAndMinute])
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
        p.status = keys.contains(.status) ? status : ""
        p.at = .now
        engine.saveBiz(p, convID: parent?.convID ?? r?.convID ?? "")
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
