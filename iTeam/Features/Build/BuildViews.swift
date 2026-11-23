import SwiftUI
import SwiftData

// MARK: - Home

struct BuildHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @AppStorage("build.project") private var activeID = ""
    @Query(filter: #Predicate<BuildRecord> { !$0.deleted }) private var recs: [BuildRecord]
    @State private var sheet: BuildSheet?

    private var projects: [BuildRecord] { recs.filter { $0.kind == "project" }.sorted { $0.title < $1.title } }
    /// Projects I run or work on (not just a buyer / partner copy).
    private var workProjects: [BuildRecord] {
        projects.filter { $0.ownerID == engine.me || $0.d.team.contains(engine.me) || $0.d.admins.contains(engine.me) }
    }
    private var active: BuildRecord? { workProjects.first { $0.id == activeID } ?? workProjects.first }
    /// Records that are about me (buyer, partner, rehab tenant) in other people's projects.
    private var aboutMe: [BuildRecord] { recs.filter { ($0.kind == "sale" || $0.kind == "party") && $0.d.subjectID == engine.me && $0.ownerID != engine.me } }

    var body: some View {
        NavigationStack {
            Group {
                if let p = active {
                    BuildDashboard(project: p, recs: recs.filter { $0.projectID == p.id || $0.id == p.id }, aboutMe: aboutMe, sheet: $sheet)
                } else if !aboutMe.isEmpty {
                    BuildClientView(items: aboutMe, recs: recs)
                } else {
                    empty
                }
            }
            .navigationTitle(active?.title ?? "Builder & Infra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { await engine.sync() }
            .sheet(item: $sheet) { s in sheetView(s) }
        }
    }

    private var empty: some View {
        List {
            VStack(spacing: 14) {
                EmptyStateView(icon: "building.columns.fill", title: "Builder & Infra",
                               message: "Company → projects → buildings → units. Sales with buyer KYC, agreements and loans, partners and investors, rehab tenants, stock with QR stickers, machines, tests, approvals and disputes — all connected to Finance, CRM, Tasks and Attendance.")
                Button { sheet = .newProject } label: { Label("Set up company & project", systemImage: "plus") }
                    .buttonStyle(.glassProminent).controlSize(.large)
                Button("Try a demo") { BuildDemo.create(engine) }
                NavigationLink { BuildFSIView() } label: { Label("FSI calculator", systemImage: "ruler") }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity).listRowBackground(Color.clear)
        }
        .lookScreen()
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if workProjects.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(workProjects) { p in Button(p.title) { activeID = p.id } }
                } label: { Image(systemName: "building.2") }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { sheet = .scan } label: { Image(systemName: "qrcode.viewfinder") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("New project", systemImage: "plus") { sheet = .newProject }
                if let p = active, engine.bIsAdmin(p) {
                    Button("Edit project & team", systemImage: "pencil") { sheet = .editProject(p.id) }
                    Button("Company profile", systemImage: "building.2.fill") { sheet = .company(p.companyID) }
                    ShareMenu(title: "\(p.title) – project report", text: { BuildShare.projectText(p, recs: projRecs(p), engine: engine) },
                              html: { BuildShare.projectHTML(p, recs: projRecs(p), engine: engine) }, label: "Export report (PDF)",
                              module: "Builder & Infra", icon: "building.columns.fill", colors: [0xF59E0B, 0xB45309],
                              charts: { BuildShare.charts(projRecs(p)) })
                }
                Menu("Area unit") {
                    Button("Square feet") { UserDefaults.standard.set("sq ft", forKey: "build.area") }
                    Button("Square metres") { UserDefaults.standard.set("sq m", forKey: "build.area") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func projRecs(_ p: BuildRecord) -> [BuildRecord] { recs.filter { $0.projectID == p.id } }

    @ViewBuilder private func sheetView(_ s: BuildSheet) -> some View {
        switch s {
        case .newProject: NavigationStack { BuildProjectEditor(existing: nil) { activeID = $0 } }
        case .editProject(let id): NavigationStack { BuildProjectEditor(existing: engine.bRecord(id)) { _ in } }
        case .company(let cid):
            NavigationStack {
                let rec = recs.first { $0.kind == "company" && $0.companyID == cid }
                BuildEditor(kind: "company", existing: rec, company: cid, project: "", preset: ["name": engine.attRecord(cid)?.company.name ?? ""])
            }
        case .scan: BuildScanView()
        case .task(let conv): if let c = engine.conversation(conv) { NavigationStack { TaskEditorView(conv: c, source: nil) } }
        case .approval(let conv): if let c = engine.conversation(conv) { NavigationStack { ApprovalRequestView(conv: c) } }
        case .event(let conv): if let c = engine.conversation(conv) { NavigationStack { EventEditor(conv: c) } }
        case .enquiry(let cid): NavigationStack { BuildEnquirySheet(company: cid, project: active?.title ?? "") }
        case .bill: NavigationStack { BuildBillSheet(project: active?.title ?? "") }
        case .post(let text): NavigationStack { NewPostView(status: false, kind: .moment, prefill: text) }
        }
    }
}

enum BuildSheet: Identifiable {
    case newProject, editProject(String), company(String), scan, task(String), approval(String), event(String), enquiry(String), bill, post(String)
    var id: String {
        switch self {
        case .newProject: "new"
        case .editProject(let i): "edit" + i
        case .company(let i): "co" + i
        case .scan: "scan"
        case .task(let i): "task" + i
        case .approval(let i): "appr" + i
        case .event(let i): "ev" + i
        case .enquiry(let i): "enq" + i
        case .bill: "bill"
        case .post(let t): "post" + t
        }
    }
}

// MARK: - Dashboard

struct BuildDashboard: View {
    let project: BuildRecord
    let recs: [BuildRecord]
    let aboutMe: [BuildRecord]
    @Binding var sheet: BuildSheet?
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look

    private func of(_ k: String) -> [BuildRecord] { recs.filter { $0.kind == k } }
    private var isAdmin: Bool { engine.bIsAdmin(project) }
    private var conv: Conversation? { engine.conversation(project.d.convID) }

    var body: some View {
        List {
            stats
            attention
            setupSection
            salesSection
            siteSection
            complianceSection
            connectedSection
            if isAdmin && AISettings.shared.allows(.build) {
                Section {
                    AIButton(title: "Project summary & risks", feature: .build,
                             instructions: "Summarise this construction project for the owner: sales and collections, stock to re-order, approvals pending, failed tests, open disputes and machines. Then list the 5 most important next actions. Use only the facts given.",
                             context: { BuildShare.projectText(project, recs: recs, engine: engine) }, postTo: conv)
                }
                .lookRows()
            }
            if isAdmin && AISettings.shared.allows(.advisor) {
                Section {
                    AISuggest(title: "Units in high & low demand",
                              instructions: "From the units, enquiries and sales: which unit types / floors / facings sell fast and which are slow, with numbers. Suggest pricing or offer ideas for slow units.",
                              context: { BuildShare.projectText(project, recs: recs, engine: engine) }, postTo: conv)
                    AISuggest(title: "Team effort & critical errors",
                              instructions: "From the daily logs, progress, tests and inspections: who is reporting regularly and who isn't (counts only — never accuse), critical errors (failed tests, safety issues, delays) and what to fix first.",
                              context: { BuildShare.projectText(project, recs: recs, engine: engine) })
                    AISuggest(title: "Government approvals — step by step",
                              instructions: "You help an Indian builder (Maharashtra if not stated). From the approvals already in the data, list the usual remaining approvals in order (e.g. land title, NA/zone, building permission/commencement certificate, environment, RERA registration, plinth, occupancy/completion, fire NOC, water/electricity) with the documents normally needed. Say clearly that rules differ by city — confirm with the local authority or an architect.",
                              context: { BuildShare.projectText(project, recs: recs, engine: engine) })
                    AISuggest(title: "Disputes — possible solutions",
                              instructions: "For each open dispute in the data, suggest practical ways to settle it (talks, documents to collect, notices, mediation, RERA/consumer/civil forum) and the risk of each. Advice only; suggest consulting the lawyer.",
                              context: { BuildShare.projectText(project, recs: recs, engine: engine) })
                } header: { Text("✨ AI suggestions") }
                .lookRows()
            }
            if !aboutMe.isEmpty {
                Section { NavigationLink { BuildClientView(items: aboutMe, recs: [] ) } label: { Label("My homes & shares in others' projects", systemImage: "house.and.flag.fill") } }.lookRows()
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
    }

    // MARK: Stats

    private var stats: some View {
        let units = of("unit")
        let sold = units.filter { ["Booked", "Agreement done", "Registered", "Possession given"].contains($0.status) }.count
        let saleIDs = Set(of("sale").filter { $0.status != "Cancelled" }.map(\.id))
        let collected = of("payment").filter { saleIDs.contains($0.parentID) && $0.status != "Bounced" }.reduce(0) { $0 + $1.num("amount") }
        let week = Date.now.addingTimeInterval(7 * 86400)
        let dueSoon = of("demand").filter { $0.status == "Due" && (BuildData.date($0.f("due")) ?? .distantFuture) <= week }
        return Section {
            HStack(spacing: 10) {
                GymStat(value: "\(sold)/\(units.count)", label: "Units sold", icon: "house.fill")
                GymStat(value: Money.format(collected), label: "Collected", icon: "indianrupeesign.circle")
                GymStat(value: "\(dueSoon.count)", label: "Due in 7 days", icon: "calendar.badge.exclamationmark", warn: !dueSoon.isEmpty)
            }
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            VStack(alignment: .leading, spacing: 2) {
                Text([project.f("type"), project.f("city"), project.status].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline.weight(.semibold))
                Text(engine.attRecord(project.companyID)?.company.name ?? "").font(.caption).foregroundStyle(look.textSecondary)
                if project.ownerID != engine.me { Text("Managed by \(engine.name(of: project.ownerID))").font(.caption2).foregroundStyle(look.textSecondary) }
            }
        }
    }

    // MARK: Needs attention

    @ViewBuilder private var attention: some View {
        let now = Date.now
        let overdue = of("demand").filter { $0.status == "Due" && (BuildData.date($0.f("due")) ?? .distantFuture) < now.addingTimeInterval(7 * 86400) }
        let low = of("material").filter { $0.num("reorder") > 0 && engine.bStock($0) <= $0.num("reorder") }
        let failed = of("test").filter { $0.status == "Fail" || $0.status == "Retest" }
        let queries = of("approval").filter { ["Query raised", "Rejected", "Expired"].contains($0.status) }
        let broken = of("equipment").filter { $0.status == "Breakdown" }
        let hearings = of("dispute").filter { !["Settled", "Closed"].contains($0.status) && (BuildData.date($0.f("next")) ?? .distantFuture) < now.addingTimeInterval(7 * 86400) }
        let comply = of("inspection").filter { $0.status == "Compliance needed" || $0.status == "Stop-work notice" }
        let all = overdue + low + failed + queries + broken + hearings + comply
        if !all.isEmpty {
            Section("Needs attention") {
                ForEach(all.prefix(12)) { r in NavigationLink { BuildDetail(r: r) } label: { BuildRow(r: r) } }
            }
            .lookRows()
        }
    }

    // MARK: Sections

    private func link(_ kind: String, _ title: String? = nil, icon: String? = nil) -> some View {
        let n = of(kind).count
        return NavigationLink { BuildListView(kind: kind, project: project, recs: recs, title: title) } label: {
            Label("\(title ?? BuildKinds.of(kind).plural) (\(n))", systemImage: icon ?? BuildKinds.of(kind).icon)
        }
    }

    private var setupSection: some View {
        Section("Project") {
            NavigationLink { BuildDetail(r: project) } label: { Label("Project details & documents", systemImage: "building.columns.fill") }
            link("building", "Buildings, wings & units")
            link("land")
            link("party", "People: partners, landowners, rehab, architect, RCC…")
            if isAdmin { NavigationLink { BuildVaultView(company: project.companyID, project: project.id) } label: { Label("Secure vault", systemImage: "lock.doc.fill") } }
            NavigationLink { BuildFSIView(plotPreset: project.f("plot")) } label: { Label("FSI calculator", systemImage: "ruler") }
        }
        .lookRows()
    }

    private var salesSection: some View {
        Section("Sales") {
            NavigationLink { BuildSalesView(project: project, recs: recs) } label: { Label("Bookings, agreements & loans (\(of("sale").count))", systemImage: "person.text.rectangle.fill") }
            NavigationLink { BuildAvailableView(project: project, recs: recs) } label: {
                Label("Available units (\(of("unit").filter { $0.status == "Available" }.count))", systemImage: "square.grid.3x3.fill")
            }
            if isAdmin { Button("Add an enquiry to CRM", systemImage: "person.crop.circle.badge.plus") { sheet = .enquiry(project.companyID) } }
        }
        .lookRows()
    }

    private var siteSection: some View {
        Section("Site") {
            link("progress", "Daily site reports")
            link("material", "Stock & materials")
            link("equipment", "Machines & equipment")
            link("asset", "Fixed assets")
            NavigationLink { BuildLabelsView(project: project, recs: recs) } label: { Label("Print QR stickers", systemImage: "printer.fill") }
            Button { sheet = .scan } label: { Label("Scan a sticker", systemImage: "qrcode.viewfinder") }
            link("test", "Quality tests")
        }
        .lookRows()
    }

    private var complianceSection: some View {
        Section("Approvals & legal") {
            link("approval", "Government approvals & NOCs")
            link("inspection", "Inspections")
            link("dispute", "Disputes")
            link("reward", "Rewards")
        }
        .lookRows()
    }

    private var connectedSection: some View {
        Section {
            if let c = conv {
                Button { router.show(conversation: c.id) } label: { Label("Project chat", systemImage: "bubble.left.and.bubble.right.fill") }
                Button { sheet = .task(c.id) } label: { Label("Group task", systemImage: "checklist") }
                Button { sheet = .approval(c.id) } label: { Label("Group approval", systemImage: "checkmark.seal") }
                Button { sheet = .event(c.id) } label: { Label("Event (bhoomi pujan, launch, possession)", systemImage: "party.popper.fill") }
            }
            Button { UserDefaults.standard.set(project.companyID, forKey: "att.current"); router.go(.attendance) } label: {
                Label("Staff & labour attendance", systemImage: "person.badge.clock.fill")
            }
            Button { router.go(.finance) } label: { Label("Company finance", systemImage: "indianrupeesign.circle.fill") }
            if isAdmin { Button { sheet = .bill } label: { Label("Add a bill (electricity, water, insurance)", systemImage: "calendar.badge.exclamationmark") } }
            Button { router.go(.survey) } label: { Label("Surveys (site, buyer feedback)", systemImage: "list.clipboard.fill") }
            Button { router.go(.crm) } label: { Label("CRM pipeline", systemImage: "person.crop.circle.badge.checkmark") }
            Button { sheet = .post("🏗️ \(project.title): ") } label: { Label("Share progress to Views", systemImage: "sparkles.rectangle.stack") }
        } header: { Text("Connected modules") } footer: {
            if conv == nil { Text("Add a team in Edit project to get a project chat with group tasks, approvals and events.") }
        }
        .lookRows()
    }
}

// MARK: - Sales list

struct BuildSalesView: View {
    let project: BuildRecord
    let recs: [BuildRecord]
    @EnvironmentObject var engine: SyncEngine
    @State private var filter = "All"

    private var sales: [BuildRecord] {
        recs.filter { $0.kind == "sale" && (filter == "All" || $0.status == filter) }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            Picker("Status", selection: $filter) {
                Text("All").tag("All")
                ForEach(BuildKinds.sale.statuses, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Section {
                if sales.isEmpty { Text("No bookings yet. Open a unit and tap Book this unit.").foregroundStyle(.secondary) }
                ForEach(sales) { s in
                    let paid = recs.filter { $0.kind == "payment" && $0.parentID == s.id && $0.status != "Bounced" }.reduce(0) { $0 + $1.num("amount") }
                    NavigationLink { BuildDetail(r: s) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            BuildRow(r: s)
                            ProgressView(value: s.num("value") > 0 ? min(1, paid / s.num("value")) : 0)
                                .tint(.green)
                            Text("Received \(Money.format(paid)) of \(Money.format(s.num("value")))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Sales")
    }
}

struct BuildAvailableView: View {
    let project: BuildRecord
    let recs: [BuildRecord]
    var body: some View {
        List {
            ForEach(recs.filter { $0.kind == "building" }) { b in
                BuildUnitsGrid(building: b, units: recs.filter { $0.kind == "unit" && $0.parentID == b.id }, canAdmin: false)
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Units")
    }
}

// MARK: - Buyer / partner / rehab tenant view

struct BuildClientView: View {
    let items: [BuildRecord]
    let recs: [BuildRecord]
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    var body: some View {
        List {
            ForEach(items) { r in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.kind == "sale" ? "Unit \(engine.bRecord(r.parentID)?.title ?? "")" : r.f("role")).font(.title3.bold())
                        Text(engine.bRecord(r.projectID)?.title ?? "").font(.subheadline)
                        Text("Managed by \(engine.name(of: r.ownerID))").font(.caption).foregroundStyle(look.textSecondary)
                    }
                    if r.kind == "party" && BuildKinds.money.contains(r.f("role")) {
                        LabeledContent("Capital invested", value: Money.format(r.num("invest")))
                        LabeledContent("Investment share", value: r.f("investShare").isEmpty ? "—" : "\(r.f("investShare"))%")
                        LabeledContent("Profit share", value: r.f("profitShare").isEmpty ? "—" : "\(r.f("profitShare"))%")
                    }
                    if r.f("role") == "Rehab tenant / occupant" {
                        LabeledContent("Old area", value: r.f("oldArea").isEmpty ? "—" : "\(r.f("oldArea")) \(BuildFmt.areaUnit)")
                        LabeledContent("New area entitled", value: r.f("newArea").isEmpty ? "—" : "\(r.f("newArea")) \(BuildFmt.areaUnit)")
                        LabeledContent("Rehab unit", value: r.f("rehabUnit").isEmpty ? "—" : r.f("rehabUnit"))
                    }
                    if !r.status.isEmpty { HStack { Text("Status"); Spacer(); BuildStatusPill(status: r.status) } }
                    NavigationLink { BuildDetail(r: r) } label: { Label(r.kind == "sale" ? "Schedule, payments & documents" : "Details", systemImage: "doc.text.magnifyingglass") }
                }
                .lookRows()
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("My properties")
    }
}

// MARK: - Project editor (company + team)

struct BuildProjectEditor: View {
    let existing: BuildRecord?
    var onSaved: (String) -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<AttRecord> { $0.kind == "company" && !$0.deleted }) private var companies: [AttRecord]
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var d = BuildData()
    @State private var status = "Planning"
    @State private var company = ""
    @State private var newCompany = ""
    @State private var team: Set<String> = []
    @State private var admins: Set<String> = []
    @State private var loaded = false

    private var myCompanies: [AttRecord] { companies.filter { $0.company.isStaff(engine.me) } }
    private var ok: Bool { !d["name"].trimmingCharacters(in: .whitespaces).isEmpty && (existing != nil || !company.isEmpty || !newCompany.trimmingCharacters(in: .whitespaces).isEmpty) }

    var body: some View {
        Form {
            if existing == nil {
                Section {
                    Picker("Company", selection: $company) {
                        Text("New company…").tag("")
                        ForEach(myCompanies) { c in Text(c.company.name).tag(c.id) }
                    }
                    if company.isEmpty { TextField("Company name", text: $newCompany) }
                } header: { Text("Company") } footer: {
                    Text("The company is shared with Finance (its own book), CRM and Attendance, so everything stays connected.")
                }
            }
            Section("Project") {
                ForEach(BuildKinds.project.fields) { f in BuildFieldRow(field: f, d: $d) }
                Picker("Stage", selection: $status) { ForEach(BuildKinds.project.statuses, id: \.self) { Text($0).tag($0) } }
            }
            Section {
                if contacts.isEmpty { Text("Add your team as contacts first.").foregroundStyle(.secondary) }
                ForEach(contacts) { c in
                    HStack {
                        Button {
                            if team.contains(c.userID) { team.remove(c.userID); admins.remove(c.userID) } else { team.insert(c.userID) }
                        } label: {
                            HStack {
                                Image(systemName: team.contains(c.userID) ? "checkmark.circle.fill" : "circle").foregroundStyle(team.contains(c.userID) ? .blue : .secondary)
                                Text(c.name)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if team.contains(c.userID) {
                            Button(admins.contains(c.userID) ? "Admin" : "Site") {
                                if admins.contains(c.userID) { admins.remove(c.userID) } else { admins.insert(c.userID) }
                            }
                            .buttonStyle(.bordered).controlSize(.small).tint(admins.contains(c.userID) ? .orange : .gray)
                        }
                    }
                }
            } header: { Text("Team") } footer: {
                Text("Team members join the project chat. Site members add stock, machine logs, tests and site reports. Admins can also handle sales, payments, approvals and disputes. Partner and vault details stay only on your devices.")
            }
        }
        .navigationTitle(existing == nil ? "New project" : "Edit project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(!ok) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let e = existing { d = e.d; status = e.status; team = Set(e.d.team); admins = Set(e.d.admins); company = e.companyID }
            else { company = myCompanies.first?.id ?? "" }
        }
    }

    private func save() {
        let engine = engine, existing = existing, d = d, team = Array(team), admins = Array(admins), status = status, company = company
        let newCompany = newCompany.trimmingCharacters(in: .whitespaces), onSaved = onSaved
        Haptics.big()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if let e = existing {
                var data = d
                data.team = team; data.admins = admins
                engine.bSaveProject(e, data: data, status: status)
                onSaved(e.id)
            } else {
                var cid = company
                if cid.isEmpty {
                    var co = BuildData()
                    co["name"] = newCompany
                    cid = engine.bCreateCompany(co)
                }
                onSaved(engine.bCreateProject(company: cid, data: d, team: team, admins: admins))
            }
        }
    }
}

// MARK: - Small connected sheets

struct BuildEnquirySheet: View {
    let company: String
    let project: String
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var budget = ""
    @State private var want = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Phone", text: $phone).keyboardType(.phonePad)
                TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Budget", text: $budget).keyboardType(.decimalPad)
                TextField("Looking for (e.g. 2 BHK, east facing)", text: $want, axis: .vertical)
            } footer: { Text("Goes to CRM as a new lead with a follow-up tomorrow. Book the unit here when it converts.") }
        }
        .navigationTitle("Enquiry → CRM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    _ = engine.bToCRM(name: name, phone: phone, email: email, value: BuildData.number(budget), note: "\(project): \(want)", company: company)
                    Haptics.tap(); dismiss()
                }
                .bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct BuildBillSheet: View {
    let project: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amount = ""
    @State private var due = Date.now

    var body: some View {
        Form {
            Section {
                TextField("Bill (electricity meter, water, insurance…)", text: $title)
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                DatePicker("Due", selection: $due, displayedComponents: .date)
            } footer: { Text("Saved in Bills & Renewals with a reminder.") }
        }
        .navigationTitle("Project bill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { engine.bToBill(title: "\(project): \(title)", amount: BuildData.number(amount), due: due); dismiss() }
                    .bold().disabled(title.isEmpty)
            }
        }
    }
}
