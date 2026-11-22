import SwiftUI
import SwiftData

// MARK: - Formatting

enum BuildFmt {
    static var areaUnit: String { UserDefaults.standard.string(forKey: "build.area") ?? "sq ft" }

    static func display(_ f: BField, _ v: String) -> String {
        guard !v.isEmpty else { return "" }
        switch f.type {
        case .money: return Money.format(BuildData.number(v))
        case .area: return "\(v) \(areaUnit)"
        case .percent: return "\(v)%"
        case .date: return BuildData.date(v)?.formatted(date: .abbreviated, time: .omitted) ?? v
        default: return v
        }
    }

    static func subtitle(_ r: BuildRecord, engine: SyncEngine) -> String {
        switch r.kind {
        case "unit": return [r.f("type"), r.f("carpet").isEmpty ? "" : "\(r.f("carpet")) \(areaUnit)", r.num("price") > 0 ? Money.format(r.num("price")) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case "sale": return ["Unit \(engine.bRecord(r.parentID)?.title ?? "")", r.num("value") > 0 ? Money.format(r.num("value")) : "", r.f("loan") == "No loan" ? "" : r.f("bank")].filter { !$0.isEmpty }.joined(separator: " · ")
        case "party": return [r.f("role"), r.f("firm"), r.f("phone")].filter { !$0.isEmpty }.joined(separator: " · ")
        case "material":
            return "\(fmtQty(engine.bStock(r))) \(r.f("unit")) in stock" + (r.f("category").isEmpty ? "" : " · \(r.f("category"))")
        case "equipment": return [r.f("type"), r.f("own"), r.f("operator")].filter { !$0.isEmpty }.joined(separator: " · ")
        case "payment", "demand": return [Money.format(r.num("amount")), BuildData.date(r.f(r.kind == "demand" ? "due" : "date"))?.formatted(date: .abbreviated, time: .omitted) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case "move": return [r.f("qty"), r.f("party"), r.f("where"), BuildData.date(r.f("date"))?.formatted(date: .abbreviated, time: .omitted) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case "test": return [r.f("where"), r.f("result")].filter { !$0.isEmpty }.joined(separator: " · ")
        case "approval": return [r.f("authority"), r.f("number")].filter { !$0.isEmpty }.joined(separator: " · ")
        case "dispute": return [r.f("type"), r.f("against"), BuildData.date(r.f("next")).map { "next \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case "building": return [r.f("use"), r.f("wings").isEmpty ? "" : "Wings \(r.f("wings"))", r.f("floors").isEmpty ? "" : "\(r.f("floors")) floors"].filter { !$0.isEmpty }.joined(separator: " · ")
        default: return [r.f("category"), r.f("where"), r.f("type")].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    static func fmtQty(_ q: Double) -> String { q == q.rounded() ? String(Int(q)) : String(format: "%.2f", q) }

    static func statusColor(_ s: String) -> Color {
        switch s {
        case "Available", "Working", "Pass", "Approved", "Received", "Cleared", "Paid", "Satisfactory", "Title clear", "Completed", "In use", "Active", "Settled", "Closed", "Possession given":
            return .green
        case "Booked", "Agreement done", "Registered", "Applied", "Under construction", "Hold", "Scheduled", "Consent signed", "Rehab allotted":
            return .blue
        case "Fail", "Rejected", "Breakdown", "Bounced", "Stop-work notice", "Expired", "Lost", "Issue found", "Cancelled":
            return .red
        case "Due", "Query raised", "Compliance needed", "Pending", "Retest", "Idle", "Under service", "Notice", "Hearing", "Filed", "Consent pending":
            return .orange
        default: return .gray
        }
    }
}

// MARK: - Rows

struct BuildRow: View {
    let r: BuildRecord
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: BuildKinds.of(r.kind).icon)
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [Color(hex: 0xF59E0B), Color(hex: 0xB45309)], startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title.isEmpty ? BuildKinds.of(r.kind).label : r.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                let sub = BuildFmt.subtitle(r, engine: engine)
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(look.textSecondary).lineLimit(2) }
            }
            Spacer()
            if !r.status.isEmpty { BuildStatusPill(status: r.status) }
        }
    }
}

struct BuildStatusPill: View {
    let status: String
    var body: some View {
        Text(status).font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(BuildFmt.statusColor(status).opacity(0.18)))
            .foregroundStyle(BuildFmt.statusColor(status))
    }
}

// MARK: - Field editor

struct BuildFieldRow: View {
    let field: BField
    @Binding var d: BuildData
    private var value: Binding<String> { Binding(get: { d[field.key] }, set: { d[field.key] = $0 }) }

    var body: some View {
        switch field.type {
        case .choice: choice
        case .date: BuildDateRow(label: field.label, value: value)
        case .long: TextField(field.label, text: value, axis: .vertical).lineLimit(2...6)
        case .money: TextField(field.label, text: value).keyboardType(.decimalPad)
        case .number, .percent: TextField(field.type == .percent ? field.label + " (%)" : field.label, text: value).keyboardType(.decimalPad)
        case .area: TextField("\(field.label) (\(BuildFmt.areaUnit))", text: value).keyboardType(.decimalPad)
        case .phone: TextField(field.label, text: value).keyboardType(.phonePad).textContentType(.telephoneNumber)
        case .email: TextField(field.label, text: value).keyboardType(.emailAddress).textInputAutocapitalization(.never)
        case .text: TextField(field.label, text: value)
        }
    }

    @ViewBuilder private var choice: some View {
        if field.options.count > 8 {
            Picker(field.label, selection: value) {
                Text("—").tag("")
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
                if !d[field.key].isEmpty && !field.options.contains(d[field.key]) { Text(d[field.key]).tag(d[field.key]) }
            }
            .pickerStyle(.navigationLink)
        } else {
            Picker(field.label, selection: value) {
                Text("—").tag("")
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
                if !d[field.key].isEmpty && !field.options.contains(d[field.key]) { Text(d[field.key]).tag(d[field.key]) }
            }
        }
    }
}

struct BuildDateRow: View {
    let label: String
    @Binding var value: String
    var body: some View {
        if let date = BuildData.date(value) {
            HStack {
                DatePicker(label, selection: Binding(get: { date }, set: { value = BuildData.dateString($0) }), displayedComponents: .date)
                Button { value = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        } else {
            Button { value = BuildData.dateString(.now) } label: { Label("Add \(label.lowercased())", systemImage: "calendar.badge.plus") }
        }
    }
}

// MARK: - Generic editor

struct BuildEditor: View {
    let kind: String
    var existing: BuildRecord? = nil
    let company: String
    let project: String
    var parent: String = ""
    var preset: [String: String] = [:]
    var onSaved: ((String) -> Void)? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var d = BuildData()
    @State private var status = ""
    @State private var pending = PendingAttachments()
    @State private var loaded = false

    private var k: BKind { BuildKinds.of(kind) }
    private var visible: [BField] { k.fields.filter { f in f.roles.map { $0.contains(d["role"]) } ?? true } }
    private var sections: [String] {
        var out: [String] = []
        for f in visible where !out.contains(f.section) { out.append(f.section) }
        return out
    }
    private var canSave: Bool { !d.title(kind).trimmingCharacters(in: .whitespaces).isEmpty || ["payment", "move", "log", "demand"].contains(kind) }

    var body: some View {
        Form {
            ForEach(sections, id: \.self) { sec in
                Section(sec.isEmpty ? k.label : sec) {
                    ForEach(visible.filter { $0.section == sec }) { f in BuildFieldRow(field: f, d: $d) }
                }
            }
            if !k.statuses.isEmpty {
                Section("Status") {
                    Picker("Status", selection: $status) { ForEach(k.statuses, id: \.self) { Text($0).tag($0) } }
                }
            }
            if kind == "sale" || kind == "party" { subjectSection }
            Section {
                if !d.files.isEmpty { Text("\(d.files.count) already attached").foregroundStyle(.secondary) }
                AttachmentAdder(pending: $pending, title: kind == "vault" ? "Add document" : "Add photo, plan, agreement or file")
            } header: { Text(kind == "vault" ? "Document" : "Documents & photos") } footer: {
                if kind == "vault" { Text("Vault documents go only to your own devices, end-to-end encrypted.") }
            }
        }
        .navigationTitle(existing == nil ? "New \(k.label.lowercased())" : k.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(!canSave) }
        }
        .onAppear(perform: load)
    }

    private var subjectSection: some View {
        Section {
            Picker(kind == "sale" ? "Buyer on iTeam" : "On iTeam", selection: $d.subjectID) {
                Text("Not on iTeam").tag("")
                ForEach(contacts) { c in Text(c.name).tag(c.userID) }
            }
        } footer: {
            Text(kind == "sale" ? "Linked buyers see only their own unit, schedule and payments in their chat with you."
                 : "Linked partners, landowners and rehab tenants see only their own record.")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let e = existing { d = e.d; status = e.status; return }
        for (key, v) in preset { d[key] = v }
        status = preset["_status"] ?? k.statuses.first ?? ""
        d["_status"] = ""
        for f in k.fields where f.type == .date && (f.key == "date" || f.key == "booked") && d[f.key].isEmpty { d[f.key] = BuildData.dateString(.now) }
    }

    private func save() {
        var data = d
        data.files += pending.refs
        let isNewSale = kind == "sale" && existing == nil
        let id = engine.bSave(kind: kind, existing: existing, company: company, project: project, parent: existing?.parentID ?? parent,
                              status: status, data: data, uploads: pending.uploads)
        if isNewSale, let unit = engine.bRecord(parent), ["Available", "Hold", ""].contains(unit.status) { engine.bSetStatus(unit, "Booked") }
        Haptics.tap()
        onSaved?(id)
        dismiss()
    }
}

// MARK: - Lists

struct BuildListView: View {
    let kind: String
    let project: BuildRecord
    let recs: [BuildRecord]
    var title: String? = nil
    @EnvironmentObject var engine: SyncEngine
    @State private var search = ""
    @State private var adding = false

    private var items: [BuildRecord] {
        recs.filter { $0.kind == kind }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || BuildFmt.subtitle($0, engine: engine).localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private var canAdd: Bool { engine.bIsAdmin(project) || (BuildKinds.of(kind).operational && project.d.team.contains(engine.me)) }

    var body: some View {
        List {
            if items.isEmpty {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            }
            if kind == "party" {
                ForEach(BuildKinds.roles, id: \.self) { role in
                    let group = items.filter { $0.f("role") == role }
                    if !group.isEmpty {
                        Section(role) { ForEach(group) { r in NavigationLink { BuildDetail(r: r) } label: { BuildRow(r: r) } } }
                    }
                }
                let other = items.filter { !BuildKinds.roles.contains($0.f("role")) }
                if !other.isEmpty { Section("Other") { ForEach(other) { r in NavigationLink { BuildDetail(r: r) } label: { BuildRow(r: r) } } } }
            } else {
                ForEach(items) { r in NavigationLink { BuildDetail(r: r) } label: { BuildRow(r: r) } }
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .searchable(text: $search)
        .navigationTitle(title ?? BuildKinds.of(kind).plural)
        .toolbar {
            if canAdd { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") } } }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { BuildEditor(kind: kind, company: project.companyID, project: project.id) }
        }
    }
}

// MARK: - Detail

struct BuildDetail: View {
    let r: BuildRecord
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Query private var kids: [BuildRecord]
    @State private var editing = false
    @State private var adding: BuildAdd?
    @State private var confirmDelete = false
    @State private var post: String?
    @State private var plan = false

    init(r: BuildRecord) {
        self.r = r
        let id = r.id
        _kids = Query(filter: #Predicate<BuildRecord> { $0.parentID == id && !$0.deleted })
    }

    private var project: BuildRecord? { r.kind == "project" ? r : engine.bRecord(r.projectID) }
    private var isAdmin: Bool { r.ownerID == engine.me || (project?.d.admins.contains(engine.me) ?? false) }
    private var isTeam: Bool { isAdmin || (project?.d.team.contains(engine.me) ?? false) }
    private var canEdit: Bool { isAdmin || (isTeam && BuildKinds.of(r.kind).operational) }
    private var k: BKind { BuildKinds.of(r.kind) }

    var body: some View {
        List {
            header
            fieldSections
            if !r.d.files.isEmpty { Section("Documents & photos") { BizFilesList(files: r.d.files) }.lookRows() }
            kindSections
            actions
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle(k.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if canEdit { Button("Edit", systemImage: "pencil") { editing = true } }
                    ShareMenu(title: "\(k.label) – \(r.title)", text: { BuildShare.recordText(r, engine: engine) },
                              html: { BuildShare.recordHTML(r, kids: kids, engine: engine) }, label: "Share / PDF", module: "Builder & Infra",
                              icon: "building.columns.fill", colors: [0xF59E0B, 0xB45309])
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { BuildEditor(kind: r.kind, existing: r, company: r.companyID, project: r.projectID) }
        }
        .sheet(item: $adding) { a in
            NavigationStack { BuildEditor(kind: a.kind, company: r.companyID, project: r.kind == "project" ? r.id : r.projectID, parent: r.id, preset: a.preset) }
        }
        .sheet(item: Binding(get: { post.map { BuildText(id: $0) } }, set: { post = $0?.id })) { t in
            NavigationStack { NewPostView(status: false, kind: .achievement, prefill: t.id) }
        }
        .sheet(isPresented: $plan) { NavigationStack { BuildPlanSheet(sale: r) } }
        .confirmationDialog("Delete \(k.label.lowercased())?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { engine.bDelete(r); dismiss() }
        } message: { Text("It stays visible to the team as deleted. Money entries linked in Finance are removed too.") }
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title.isEmpty ? k.label : r.title).font(.title3.bold())
                let sub = BuildFmt.subtitle(r, engine: engine)
                if !sub.isEmpty { Text(sub).font(.subheadline).foregroundStyle(look.textSecondary) }
                if r.ownerID != engine.me { Text("Managed by \(engine.name(of: r.ownerID))").font(.caption).foregroundStyle(look.textSecondary) }
                if r.by != r.ownerID && !r.by.isEmpty { Text("Added by \(engine.name(of: r.by)) · \(r.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(look.textSecondary) }
            }
            if !k.statuses.isEmpty {
                if canEdit {
                    Picker("Status", selection: Binding(get: { r.status }, set: { engine.bSetStatus(r, $0); Haptics.tap() })) {
                        ForEach(k.statuses, id: \.self) { Text($0).tag($0) }
                        if !k.statuses.contains(r.status) { Text(r.status).tag(r.status) }
                    }
                } else if !r.status.isEmpty {
                    HStack { Text("Status"); Spacer(); BuildStatusPill(status: r.status) }
                }
            }
        }
        .lookRows()
    }

    @ViewBuilder private var fieldSections: some View {
        let fields = k.fields.filter { f in !r.f(f.key).isEmpty && f.key != "name" && f.key != "buyer" && (f.roles.map { $0.contains(r.f("role")) } ?? true) }
        let secs = Self.sections(fields)
        ForEach(secs, id: \.self) { s in
            Section(s.isEmpty ? "Details" : s) {
                ForEach(fields.filter { $0.section == s }) { f in
                    if f.type == .long {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.label).font(.caption).foregroundStyle(look.textSecondary)
                            Text(r.f(f.key)).textSelection(.enabled)
                        }
                    } else {
                        LabeledContent(f.label, value: BuildFmt.display(f, r.f(f.key))).textSelection(.enabled)
                    }
                }
            }
            .lookRows()
        }
    }

    static func sections(_ fields: [BField]) -> [String] {
        var o: [String] = []
        for f in fields where !o.contains(f.section) { o.append(f.section) }
        return o
    }

    @ViewBuilder private var kindSections: some View {
        switch r.kind {
        case "building": BuildUnitsGrid(building: r, units: kids.filter { $0.kind == "unit" }, canAdmin: isAdmin)
        case "unit": unitSection
        case "sale": saleSections
        case "party": paymentsSection(title: BuildKinds.money.contains(r.f("role")) ? "Capital & payouts" : "Payments")
        case "material": materialSection
        case "equipment": equipmentSection
        case "asset": Section("QR sticker") { BuildQRCard(r: r) }.lookRows()
        default: EmptyView()
        }
    }

    @ViewBuilder private var unitSection: some View {
        let sales = kids.filter { $0.kind == "sale" }
        Section("Sale") {
            ForEach(sales) { s in NavigationLink { BuildDetail(r: s) } label: { BuildRow(r: s) } }
            if sales.filter({ $0.status != "Cancelled" }).isEmpty && isAdmin {
                Button("Book this unit", systemImage: "person.text.rectangle") { adding = BuildAdd(kind: "sale") }
            }
        }
        .lookRows()
    }

    @ViewBuilder private var saleSections: some View {
        let pays = kids.filter { $0.kind == "payment" && $0.status != "Bounced" }
        let paid = pays.reduce(0) { $0 + $1.num("amount") }
        let value = r.num("value")
        let demands = kids.filter { $0.kind == "demand" }.sorted { (BuildData.date($0.f("due")) ?? .distantFuture) < (BuildData.date($1.f("due")) ?? .distantFuture) }
        Section {
            HStack(spacing: 10) {
                GymStat(value: Money.format(value), label: "Agreement", icon: "doc.text.fill")
                GymStat(value: Money.format(paid), label: "Received", icon: "checkmark.circle.fill")
                GymStat(value: Money.format(max(0, value - paid)), label: "Balance", icon: "hourglass", warn: value - paid > 0)
            }
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        Section {
            ForEach(demands) { dm in
                HStack {
                    NavigationLink { BuildDetail(r: dm) } label: { BuildRow(r: dm) }
                }
                .swipeActions { if isAdmin && dm.status == "Due" { Button("Paid") { engine.bSetStatus(dm, "Paid") }.tint(.green) } }
            }
            if isAdmin {
                if demands.isEmpty && value > 0 { Button("Add payment schedule", systemImage: "calendar.badge.plus") { plan = true } }
                Button("Add demand", systemImage: "plus") { adding = BuildAdd(kind: "demand") }
            }
        } header: { Text("Payment schedule") } footer: { if isAdmin { Text("Swipe a demand to mark it paid.") } }
        .lookRows()
        paymentsSection(title: "Payments received")
    }

    private func paymentsSection(title: String) -> some View {
        let pays = kids.filter { $0.kind == "payment" }.sorted { (BuildData.date($0.f("date")) ?? $0.createdAt) > (BuildData.date($1.f("date")) ?? $1.createdAt) }
        return Section {
            ForEach(pays) { p in NavigationLink { BuildDetail(r: p) } label: { BuildRow(r: p) } }
            if isAdmin { Button("Record payment", systemImage: "indianrupeesign.circle") { adding = BuildAdd(kind: "payment", preset: ["_status": "Received"]) } }
        } header: { Text(title) } footer: {
            if isAdmin { Text("Payments are added to the company's Finance book automatically.") }
        }
        .lookRows()
    }

    @ViewBuilder private var materialSection: some View {
        let stock = engine.bStock(r)
        let low = r.num("reorder") > 0 && stock <= r.num("reorder")
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(BuildFmt.fmtQty(stock)) \(r.f("unit"))").font(.largeTitle.bold()).foregroundStyle(low ? .red : .primary)
                    Text(low ? "Below re-order level (\(r.f("reorder")))" : "In stock").font(.caption).foregroundStyle(low ? .red : look.textSecondary)
                }
                Spacer()
            }
            if canEdit {
                HStack {
                    Button { adding = BuildAdd(kind: "move", preset: ["type": "Received"]) } label: { Label("Receive", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                    Button { adding = BuildAdd(kind: "move", preset: ["type": "Issued"]) } label: { Label("Issue", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass)
                }
            }
        }
        .lookRows()
        Section("QR sticker") { BuildQRCard(r: r) }.lookRows()
        Section("Stock entries") {
            ForEach(kids.filter { $0.kind == "move" }.sorted { $0.createdAt > $1.createdAt }) { m in NavigationLink { BuildDetail(r: m) } label: { BuildRow(r: m) } }
        }
        .lookRows()
    }

    @ViewBuilder private var equipmentSection: some View {
        let logs = kids.filter { $0.kind == "log" }.sorted { $0.createdAt > $1.createdAt }
        Section {
            if canEdit { Button("Log today's work, fuel or repair", systemImage: "gauge.with.needle") { adding = BuildAdd(kind: "log") } }
            ForEach(logs) { l in NavigationLink { BuildDetail(r: l) } label: { BuildRow(r: l) } }
        } header: { Text("Machine log") } footer: {
            let hours = logs.reduce(0) { $0 + $1.num("hours") }, cost = logs.reduce(0) { $0 + $1.num("cost") }
            if !logs.isEmpty { Text("Total \(BuildFmt.fmtQty(hours)) h/km · \(Money.format(cost))") }
        }
        .lookRows()
        Section("QR sticker") { BuildQRCard(r: r) }.lookRows()
    }

    @ViewBuilder private var actions: some View {
        Section {
            if r.kind == "dispute" && isAdmin {
                Button("Open in Legal Matters", systemImage: "building.columns") { engine.bToLegal(r); router.go(.legal) }
            }
            if ["progress", "reward", "building", "test", "approval"].contains(r.kind) {
                Button("Share to Views", systemImage: "sparkles.rectangle.stack") { post = BuildShare.viewsText(r, engine: engine) }
            }
            if let p = project, let g = engine.conversation(p.d.convID) {
                Button("Open project chat", systemImage: "bubble.left.and.bubble.right.fill") { router.show(conversation: g.id) }
            }
            if canEdit && r.kind != "project" {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .lookRows()
    }
}

struct BuildAdd: Identifiable {
    let kind: String
    var preset: [String: String] = [:]
    var id: String { kind + preset.description }
}
struct BuildText: Identifiable { let id: String }

// MARK: - Payment plan

struct BuildPlanSheet: View {
    let sale: BuildRecord
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var stages: [(String, Double)] = BuildCatalog.clpStages
    private var total: Double { stages.reduce(0) { $0 + $1.1 } }

    var body: some View {
        Form {
            Section {
                ForEach(stages.indices, id: \.self) { i in
                    HStack {
                        TextField("Stage", text: Binding(get: { stages[i].0 }, set: { stages[i].0 = $0 }))
                        TextField("%", value: Binding(get: { stages[i].1 }, set: { stages[i].1 = $0 }), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                        Text("%")
                    }
                }
                .onDelete { stages.remove(atOffsets: $0) }
                Button("Add stage", systemImage: "plus") { stages.append(("New stage", 0)) }
            } header: { Text("Construction-linked plan") } footer: {
                Text("Total \(BuildFmt.fmtQty(total))% of \(Money.format(sale.num("value")))" + (abs(total - 100) > 0.01 ? " — should be 100%" : ""))
                    .foregroundStyle(abs(total - 100) > 0.01 ? .red : .secondary)
            }
        }
        .navigationTitle("Payment schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { engine.bAddPlan(sale, stages: stages); Haptics.big(); dismiss() }.bold().disabled(stages.isEmpty)
            }
        }
    }
}

// MARK: - Units grid (wing → floors)

struct BuildUnitsGrid: View {
    let building: BuildRecord
    let units: [BuildRecord]
    let canAdmin: Bool
    @State private var wing = ""
    @State private var generate = false

    private var wings: [String] {
        let w = Set(units.map { $0.f("wing") })
        return w.sorted()
    }
    private var shown: [BuildRecord] { units.filter { wing.isEmpty || $0.f("wing") == wing } }
    private var floors: [Int] { Set(shown.map { Int($0.num("floor")) }).sorted(by: >) }

    var body: some View {
        Section {
            if wings.count > 1 {
                Picker("Wing", selection: $wing) {
                    Text("All").tag("")
                    ForEach(wings, id: \.self) { Text($0.isEmpty ? "—" : "Wing \($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if units.isEmpty { Text("No units yet.").foregroundStyle(.secondary) }
            ForEach(floors, id: \.self) { fl in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fl == 0 ? "Ground" : "Floor \(fl)").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shown.filter { Int($0.num("floor")) == fl }.sorted { $0.title < $1.title }) { u in
                                NavigationLink { BuildDetail(r: u) } label: {
                                    Text(u.title).font(.caption2.weight(.bold)).frame(minWidth: 54, minHeight: 34)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(BuildFmt.statusColor(u.status).opacity(0.22)))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BuildFmt.statusColor(u.status), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if canAdmin { Button("Generate units for wings & floors", systemImage: "square.grid.3x3.fill") { generate = true } }
        } header: { Text("Units (\(units.count))") } footer: {
            let sold = units.filter { ["Booked", "Agreement done", "Registered", "Possession given"].contains($0.status) }.count
            Text("Green available · blue booked/sold · \(sold) of \(units.count) sold")
        }
        .sheet(isPresented: $generate) { NavigationStack { BuildGenerateUnits(building: building) } }
    }
}

struct BuildGenerateUnits: View {
    let building: BuildRecord
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var perFloor = 4
    @State private var from = 1
    @State private var to = 7
    @State private var type = "2 BHK"
    @State private var carpet = ""
    @State private var price = ""

    var body: some View {
        Form {
            Section {
                Text("Wings: \(building.f("wings").isEmpty ? "none (single block)" : building.f("wings"))").foregroundStyle(.secondary)
                Stepper("Units per floor: \(perFloor)", value: $perFloor, in: 1...40)
                Stepper("From floor: \(from == 0 ? "Ground" : String(from))", value: $from, in: 0...200)
                Stepper("To floor: \(to)", value: $to, in: max(from, 0)...200)
                Picker("Type", selection: $type) { ForEach(BuildKinds.unitTypes, id: \.self) { Text($0).tag($0) } }.pickerStyle(.navigationLink)
                TextField("Carpet area (\(BuildFmt.areaUnit))", text: $carpet).keyboardType(.decimalPad)
                TextField("Price (optional)", text: $price).keyboardType(.decimalPad)
            } footer: {
                let w = max(1, building.f("wings").split(separator: ",").count)
                Text("Creates \(w * perFloor * (to - from + 1)) units numbered like 101, 102 … per wing. Existing numbers are skipped; edit any unit later.")
            }
        }
        .navigationTitle("Generate units")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    engine.bGenerateUnits(building, perFloor: perFloor, type: type, carpet: carpet, price: price, fromFloor: from, toFloor: to)
                    Haptics.big(); dismiss()
                }.bold()
            }
        }
    }
}
