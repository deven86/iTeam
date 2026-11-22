import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Home: company switcher, dashboard, needs attention, pipeline

struct CRMHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @AppStorage("activeCompanyID") private var companyID = ""
    @Query(filter: #Predicate<CRMLead> { !$0.deleted }, sort: \CRMLead.updatedAt, order: .reverse) private var leads: [CRMLead]
    @Query(filter: #Predicate<CRMGroup> { !$0.deleted }) private var groups: [CRMGroup]
    @State private var stage: String = "open"
    @State private var scope: String = "all"
    @State private var newLead = false
    @State private var newGroup = false
    @State private var newCompany = false
    @State private var companyName = ""
    @State private var path: [String] = []

    private var companies: [(id: String, name: String)] { engine.crmCompanies() }
    private var companyTitle: String { companies.first { $0.id == companyID }?.name ?? "Personal" }
    private var mine: [CRMLead] { leads.filter { !$0.clientCopy && $0.companyID == companyID } }
    private var shared: [CRMLead] { leads.filter { $0.clientCopy } }
    private var companyGroups: [CRMGroup] { groups.filter { $0.companyID == companyID || (companyID.isEmpty && $0.companyID.isEmpty) } }

    private var filtered: [CRMLead] {
        mine.filter { l in
            let s = stage == "open" ? l.isOpen : (stage == "all" ? true : l.stage == stage)
            let sc: Bool = switch scope {
            case "all": true
            case "me": l.ownerID == engine.me || l.assignees.contains(engine.me)
            default: l.groupConvID == scope
            }
            return s && sc
        }
    }
    private var attention: [CRMLead] {
        mine.filter { $0.followUpDue && ($0.ownerID == engine.me || $0.assignees.contains(engine.me) || !$0.groupConvID.isEmpty) }
            .sorted { ($0.nextFollowUp ?? .distantFuture) < ($1.nextFollowUp ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if mine.isEmpty && shared.isEmpty {
                    Section {
                        VStack(spacing: 14) {
                            EmptyStateView(icon: "person.crop.circle.badge.checkmark", title: "CRM",
                                           message: "Track leads, follow-ups and quotes for \(companyTitle). Make a team group so colleagues manage leads together.")
                            Button { newLead = true } label: { Label("Add a lead", systemImage: "plus") }
                                .buttonStyle(.glassProminent).controlSize(.large)
                            Button("Try a demo") { CRMDemo.create(engine) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section { stats.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                    if !attention.isEmpty {
                        Section("Needs attention") {
                            ForEach(attention) { l in NavigationLink(value: l.id) { CRMLeadRow(lead: l, showFollowUp: true) } }
                        }
                        .lookRows()
                    }
                    Section {
                        filters
                        if filtered.isEmpty { Text("No leads here.").foregroundStyle(look.textSecondary) }
                        ForEach(filtered) { l in NavigationLink(value: l.id) { CRMLeadRow(lead: l) } }
                    } header: { Text("Pipeline") }
                    .lookRows()
                    if !shared.isEmpty {
                        Section {
                            ForEach(shared) { l in NavigationLink(value: l.id) { CRMLeadRow(lead: l) } }
                        } header: { Text("Shared with you") } footer: { Text("Quotes and updates other businesses shared with you.") }
                        .lookRows()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .lookScreen()
            .navigationTitle("CRM")
            .navigationDestination(for: String.self) { CRMLeadDetailView(leadID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { companyMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newLead = true } label: { Image(systemName: "plus") }.accessibilityLabel("New lead")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New CRM team group", systemImage: "person.3.fill") { newGroup = true }
                        ShareMenu(title: "CRM pipeline – \(companyTitle)", text: { CRMShare.text(mine, engine: engine) },
                                  html: { CRMShare.html(mine, engine: engine) }, module: "CRM", icon: ModuleRegistry.crm.icon,
                                  colors: ModuleRegistry.crm.colors, charts: { CRMShare.charts(mine, groups: groups) })
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .refreshable { await engine.sync() }
            .sheet(isPresented: $newLead) { NavigationStack { CRMLeadEditor(lead: nil, companyID: companyID) { path = [$0] } } }
            .sheet(isPresented: $newGroup) { NavigationStack { CRMGroupEditor(companyID: companyID) } }
            .alert("New company", isPresented: $newCompany) {
                TextField("Company name", text: $companyName)
                Button("Create") {
                    let n = companyName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { companyID = engine.crmCreateCompany(name: n) }
                    companyName = ""
                }
                Button("Cancel", role: .cancel) { companyName = "" }
            } message: { Text("It also appears in Attendance.") }
            .onAppear { CRMReminders.reschedule(engine) }
        }
    }

    private var companyMenu: some View {
        Menu {
            Button { companyID = "" } label: { Label("Personal", systemImage: companyID.isEmpty ? "checkmark" : "person") }
            ForEach(companies, id: \.id) { c in
                Button { companyID = c.id } label: { Label(c.name, systemImage: companyID == c.id ? "checkmark" : "building.2") }
            }
            Divider()
            Button("Create new company", systemImage: "plus") { newCompany = true }
            Button("New CRM team group", systemImage: "person.3.fill") { newGroup = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.2.fill")
                Text(companyTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var stats: some View {
        let open = mine.filter(\.isOpen)
        let pipeline = open.reduce(0) { $0 + $1.dealValue }
        let due = mine.filter(\.followUpDue).count
        return HStack(spacing: 10) {
            GymStat(value: "\(open.count)", label: "Open leads", icon: "person.2.fill")
            GymStat(value: Money.format(pipeline), label: "Pipeline", icon: "indianrupeesign.circle")
            GymStat(value: "\(due)", label: "Due today", icon: "bell.fill", warn: due > 0)
        }
        .padding(.vertical, 4)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    pill("All team", scope == "all") { scope = "all" }
                    pill("My leads", scope == "me") { scope = "me" }
                    ForEach(companyGroups) { g in pill(g.name, scope == g.convID) { scope = g.convID } }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    pill("Open", stage == "open") { stage = "open" }
                    ForEach(CRMStage.allCases) { s in pill(s.title, stage == s.rawValue) { stage = s.rawValue } }
                    pill("All", stage == "all") { stage = "all" }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pill(_ t: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(on ? look.accent.opacity(0.22) : Color.gray.opacity(0.12)))
                .foregroundStyle(on ? look.accent : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct CRMLeadRow: View {
    let lead: CRMLead
    var showFollowUp = false
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    var body: some View {
        let st = CRMStage.of(lead.stage)
        HStack(spacing: 12) {
            Image(systemName: st.icon).foregroundStyle(.white).frame(width: 34, height: 34)
                .background(Circle().fill(Color(hex: st.color)))
            VStack(alignment: .leading, spacing: 2) {
                Text(lead.name).font(.headline).lineLimit(1)
                Text([lead.company, groupName, showFollowUp || lead.followUpDue ? lead.nextFollowUp.map { "Follow up \($0.formatted(.relative(presentation: .named)))" } : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(lead.followUpDue ? look.warning : look.textSecondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if lead.dealValue > 0 { Text(Money.format(lead.dealValue)).font(.subheadline.bold()) }
                Text(st.title).font(.caption2).foregroundStyle(look.textSecondary)
            }
        }
    }

    private var groupName: String? {
        if lead.clientCopy { return "Managed by \(engine.name(of: lead.ownerID))" }
        guard !lead.groupConvID.isEmpty else { return nil }
        return engine.conversation(lead.groupConvID)?.title
    }
}

// MARK: - Lead detail

struct CRMLeadDetailView: View {
    let leadID: String
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [CRMLead]
    @Query private var activities: [CRMActivity]
    @State private var edit = false
    @State private var logKind: String?
    @State private var confirmDelete = false
    @State private var declineFor: CRMActivity?
    @State private var reason = ""

    init(leadID: String) {
        self.leadID = leadID
        _found = Query(filter: #Predicate<CRMLead> { $0.id == leadID })
        _activities = Query(filter: #Predicate<CRMActivity> { $0.leadID == leadID && !$0.deleted }, sort: \CRMActivity.at, order: .reverse)
    }

    var body: some View {
        if let l = found.first, !l.deleted { content(l) }
        else if let l = found.first { EmptyStateView(icon: "trash", title: "Deleted", message: "Deleted by \(engine.name(of: l.deletedBy)).") }
        else { EmptyStateView(icon: "person.crop.circle.badge.questionmark", title: "Not found", message: "This lead may not have synced yet.") }
    }

    private func content(_ l: CRMLead) -> some View {
        let st = CRMStage.of(l.stage)
        let canEdit = !l.clientCopy
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l.name).font(.title2.bold())
                    if !l.company.isEmpty { Text(l.company).foregroundStyle(look.textSecondary) }
                    HStack(spacing: 8) {
                        Label(st.title, systemImage: st.icon).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color(hex: st.color).opacity(0.2)))
                        if l.dealValue > 0 { Text(Money.format(l.dealValue)).font(.headline) }
                        if canEdit && l.probability > 0 { Text("\(l.probability)%").font(.caption).foregroundStyle(look.textSecondary) }
                    }
                    Label(l.ownerID == engine.me ? "Managed by you" : "Managed by \(engine.name(of: l.ownerID))",
                          systemImage: "person.badge.shield.checkmark").font(.caption2).foregroundStyle(look.textSecondary)
                    if canEdit, let g = engine.conversation(l.groupConvID), g.isGroup {
                        Label("Team group: \(g.title)", systemImage: "person.3.fill").font(.caption)
                    }
                    if canEdit && !l.assignees.isEmpty {
                        Label("Assigned: " + l.assignees.map { $0 == engine.me ? "You" : engine.name(of: $0) }.joined(separator: ", "), systemImage: "person.2").font(.caption)
                    }
                    if canEdit && !l.clientID.isEmpty {
                        Label("Client on iTeam: \(engine.name(of: l.clientID))", systemImage: "person.crop.circle.badge.checkmark").font(.caption)
                    }
                    if let f = l.nextFollowUp, l.isOpen {
                        Label("Follow up \(f.formatted(date: .abbreviated, time: .shortened))", systemImage: "bell")
                            .font(.caption).foregroundStyle(l.followUpDue ? look.warning : look.textSecondary)
                    }
                }
            }
            .lookRows()

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if !l.phone.isEmpty, let url = URL(string: "tel://\(l.phone.filter { $0.isNumber || $0 == "+" })") {
                            action("Call", "phone.fill") { UIApplication.shared.open(url) }
                        }
                        if !l.groupConvID.isEmpty { action(canEdit ? "Team chat" : "Chat", "bubble.left.and.bubble.right.fill") { router.show(conversation: l.groupConvID) } }
                        if canEdit && !l.clientID.isEmpty { action("Client chat", "person.bubble.fill") { router.show(conversation: SyncEngine.directID(engine.me, l.clientID)) } }
                        if canEdit {
                            action("Log", "square.and.pencil") { logKind = "call" }
                            action("Quote", "doc.text.fill") { logKind = "quote" }
                        }
                    }
                }
                if canEdit {
                    Menu {
                        ForEach(CRMStage.allCases) { s in Button(s.title, systemImage: s.icon) { engine.crmSetStage(l, s); Haptics.big() } }
                    } label: { Label("Move stage", systemImage: "arrow.right.circle") }
                }
            }
            .lookRows()

            if canEdit && !l.notes.isEmpty { Section("Notes") { Text(l.notes) }.lookRows() }

            Section {
                if activities.isEmpty { Text("Nothing logged yet.").foregroundStyle(look.textSecondary) }
                ForEach(activities.filter { canEdit || $0.kind == "quote" }) { a in activityRow(a, lead: l) }
            } header: { Text(canEdit ? "Timeline" : "Quotes") }
            .lookRows()

            if canEdit && AISettings.shared.allows(.crm) {
                Section {
                    AIButton(title: "Draft a follow-up", feature: .crm,
                             instructions: "Write a short, polite follow-up message to this lead based on the stage and timeline, then 3 next-step suggestions. No made-up facts.",
                             context: { CRMShare.leadText(l, activities: activities, engine: engine) })
                }
                .lookRows()
            }
            if l.ownerID == engine.me {
                Section { Button("Delete lead", role: .destructive) { confirmDelete = true } }.lookRows()
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle(l.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareMenu(title: "Lead – \(l.name)", text: { CRMShare.leadText(l, activities: activities, engine: engine) },
                          html: { CRMShare.html([l], engine: engine, activities: activities) }, module: "CRM", icon: ModuleRegistry.crm.icon,
                          colors: ModuleRegistry.crm.colors, charts: { [] })
                    .labelStyle(.iconOnly)
            }
            if canEdit { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { edit = true } } }
        }
        .sheet(isPresented: $edit) { NavigationStack { CRMLeadEditor(lead: l, companyID: l.companyID) { _ in } } }
        .sheet(item: Binding(get: { logKind.map { KindBox(kind: $0) } }, set: { logKind = $0?.kind })) { b in
            NavigationStack { CRMActivityEditor(lead: l, kind: b.kind) }
        }
        .confirmationDialog("Delete “\(l.name)” for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { var p = engine.crmPayload(l); p.deleted = true; engine.crmSaveLead(p); dismiss() }
        }
        .alert("Decline this quote?", isPresented: Binding(get: { declineFor != nil }, set: { if !$0 { declineFor = nil } })) {
            TextField("Reason (optional)", text: $reason)
            Button("Decline", role: .destructive) { if let a = declineFor { engine.crmAnswerQuote(a, lead: l, accept: false, reason: reason) }; reason = "" }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func action(_ t: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(t).font(.caption2) }
                .frame(width: 70, height: 56)
        }
        .buttonStyle(.glass)
    }

    @ViewBuilder private func activityRow(_ a: CRMActivity, lead: CRMLead) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: CRMShare.icon(a.kind)).foregroundStyle(look.accent)
                Text(a.title.isEmpty ? a.kind.capitalized : a.title).font(.subheadline.weight(.semibold))
                Spacer()
                if a.amount > 0 { Text(Money.format(a.amount)).font(.subheadline.bold()) }
            }
            if !a.detail.isEmpty { Text(a.detail).font(.caption) }
            Text("\(a.authorID == engine.me ? "You" : engine.name(of: a.authorID)) · \(a.at.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(look.textSecondary)
            if !a.files.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(a.files) { AttachmentThumb(ref: $0, size: 56) } } }
            }
            if a.kind == "quote" && a.needsAcceptance {
                switch a.acceptance {
                case "accepted": Label("Accepted by the client", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(look.success)
                case "declined": Label("Declined\(a.declineReason.isEmpty ? "" : " — “\(a.declineReason)”")", systemImage: "xmark.seal").font(.caption.bold()).foregroundStyle(look.danger)
                default:
                    if lead.clientCopy && lead.clientID == engine.me {
                        HStack {
                            Button { engine.crmAnswerQuote(a, lead: lead, accept: true, reason: ""); Haptics.big() } label: { Label("Accept", systemImage: "checkmark") }
                                .buttonStyle(.glassProminent)
                            Button(role: .destructive) { declineFor = a } label: { Label("Decline", systemImage: "xmark") }.buttonStyle(.glass)
                        }
                    } else {
                        Label("Waiting for the client", systemImage: "hourglass").font(.caption).foregroundStyle(look.warning)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct KindBox: Identifiable { let kind: String; var id: String { kind } }

// MARK: - Editors

struct CRMLeadEditor: View {
    let lead: CRMLead?
    let companyID: String
    var onSaved: (String) -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved }, sort: \Contact.name) private var contacts: [Contact]
    @Query(filter: #Predicate<CRMGroup> { !$0.deleted }) private var groups: [CRMGroup]
    @State private var name = ""
    @State private var company = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var source = ""
    @State private var stage = CRMStage.new
    @State private var value = ""
    @State private var probability = 20.0
    @State private var hasFollowUp = true
    @State private var followUp = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!.addingTimeInterval(11 * 3600)
    @State private var notes = ""
    @State private var groupConvID = ""
    @State private var assignees: Set<String> = []
    @State private var clientID = ""

    private var people: [(id: String, name: String)] {
        let company = engine.crmCompanyPeople(companyID).filter { $0.id != engine.me }
        return company.isEmpty ? contacts.map { ($0.userID, $0.name) } : company
    }

    var body: some View {
        Form {
            Section {
                TextField("Lead / client name", text: $name).font(.title3)
                TextField("Company or project", text: $company)
                TextField("Phone", text: $phone).keyboardType(.phonePad)
                TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Source (referral, website, walk-in…)", text: $source)
            }
            Section("Deal") {
                Picker("Stage", selection: $stage) { ForEach(CRMStage.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                TextField("Deal value", text: $value).keyboardType(.decimalPad)
                VStack(alignment: .leading) {
                    Text("Probability \(Int(probability))%").font(.subheadline)
                    Slider(value: $probability, in: 0...100, step: 5)
                }
                Toggle("Follow-up reminder", isOn: $hasFollowUp)
                if hasFollowUp { DatePicker("Follow up", selection: $followUp) }
                TextField("Notes (team only)", text: $notes, axis: .vertical)
            }
            Section {
                Picker("Team group", selection: $groupConvID) {
                    Text("None").tag("")
                    ForEach(groups.filter { $0.companyID == companyID || companyID.isEmpty }) { g in Text(g.name).tag(g.convID) }
                }
                NavigationLink {
                    List(people, id: \.id) { p in
                        Button { if assignees.contains(p.id) { assignees.remove(p.id) } else { assignees.insert(p.id) } } label: {
                            HStack { Text(p.name); Spacer(); if assignees.contains(p.id) { Image(systemName: "checkmark").foregroundStyle(.blue) } }
                        }
                        .foregroundStyle(.primary)
                    }
                    .navigationTitle("Assign to")
                } label: {
                    HStack { Text("Assign to"); Spacer(); Text(assignees.isEmpty ? "Only me" : "\(assignees.count) people").foregroundStyle(.secondary) }
                }
            } header: { Text("Who manages it") } footer: {
                Text("In a team group, everyone in it sees and updates the lead. Otherwise it's shared with the people you assign.")
            }
            Section {
                Picker("Client on iTeam", selection: $clientID) {
                    Text("Not on iTeam").tag("")
                    ForEach(contacts) { c in Text(c.name).tag(c.userID) }
                }
            } footer: { Text("A linked client sees the lead's name, stage and the quotes you send, and can accept or decline them. Never your notes.") }
        }
        .navigationTitle(lead == nil ? "New lead" : "Edit lead")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let l = lead else { return }
            name = l.name; company = l.company; phone = l.phone; email = l.email; source = l.source
            stage = CRMStage.of(l.stage); value = l.dealValue > 0 ? String(format: "%.0f", l.dealValue) : ""
            probability = Double(l.probability); hasFollowUp = l.nextFollowUp != nil; followUp = l.nextFollowUp ?? followUp
            notes = l.notes; groupConvID = l.groupConvID; assignees = Set(l.assignees); clientID = l.clientID
        }
    }

    private func save() {
        let p = CRMLeadPayload(id: lead?.id ?? "crml_" + UUID().uuidString, companyID: lead?.companyID ?? companyID, groupConvID: groupConvID,
                               ownerID: lead?.ownerID ?? engine.me, assignees: Array(assignees), clientID: clientID,
                               name: name.trimmingCharacters(in: .whitespaces), company: company, phone: phone, email: email, source: source,
                               stage: stage.rawValue, dealValue: Double(value.replacingOccurrences(of: ",", with: "")) ?? 0,
                               probability: Int(probability), nextFollowUp: hasFollowUp ? followUp : nil, notes: notes, deleted: false, at: .now)
        let id = engine.crmSaveLead(p)
        Haptics.big()
        dismiss()
        onSaved(id)
    }
}

struct CRMActivityEditor: View {
    let lead: CRMLead
    @State var kind: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var amount = ""
    @State private var date = Date.now
    @State private var files: [AttachmentRef] = []
    @State private var uploads: [String: String] = [:]
    @State private var photo: PhotosPickerItem?

    private let kinds = [("call", "Call"), ("meeting", "Meeting"), ("visit", "Site visit"), ("note", "Note"), ("quote", "Quote")]

    var body: some View {
        Form {
            Picker("Type", selection: $kind) { ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented)
            Section {
                TextField(kind == "quote" ? "Quote title (e.g. Fit-out quote v1)" : "Title", text: $title)
                if kind == "quote" { TextField("Amount", text: $amount).keyboardType(.decimalPad).font(.title3) }
                TextField("Details", text: $detail, axis: .vertical)
                DatePicker("When", selection: $date)
            } footer: {
                if kind == "quote" {
                    Text(lead.clientID.isEmpty ? "Link the client on iTeam (Edit lead) so they can accept the quote in their chat."
                         : "\(engine.name(of: lead.clientID)) gets it in your chat and can accept or decline.")
                }
            }
            Section("Photos & documents") {
                ScrollView(.horizontal) { HStack { ForEach(files) { AttachmentThumb(ref: $0, size: 56) } } }
                PhotosPicker(selection: $photo, matching: .images) { Label("Add photo", systemImage: "photo") }
            }
        }
        .navigationTitle(kind == "quote" ? "Send quote" : "Log activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(kind == "quote" ? "Send" : "Save") {
                    engine.crmSaveActivity(lead, kind: kind, title: title, detail: detail,
                                           amount: Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0, date: date, files: files, uploads: uploads)
                    Haptics.big()
                    dismiss()
                }
                .bold()
                .disabled(kind == "quote" ? (Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0) <= 0 : (title.isEmpty && detail.isEmpty))
            }
        }
        .onChange(of: photo) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(d) {
                    files.append(p.ref); uploads[p.upload.0] = p.upload.1
                }
            }
        }
    }
}

struct CRMGroupEditor: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved }, sort: \Contact.name) private var contacts: [Contact]
    @State private var name = ""
    @State private var picked: Set<String> = []

    private var people: [(id: String, name: String)] {
        let company = engine.crmCompanyPeople(companyID).filter { $0.id != engine.me && engine.contact($0.id) != nil }
        return company.isEmpty ? contacts.map { ($0.userID, $0.name) } : company
    }

    var body: some View {
        Form {
            Section { TextField("Group name (e.g. Dombivli Sales Pod)", text: $name) }
            Section {
                ForEach(people, id: \.id) { p in
                    Button { if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) } } label: {
                        HStack { Text(p.name); Spacer(); if picked.contains(p.id) { Image(systemName: "checkmark").foregroundStyle(.blue) } }
                    }
                    .foregroundStyle(.primary)
                }
            } header: { Text("Members") } footer: {
                Text("Creates an encrypted group chat. Leads you put in this group are managed by everyone in it.")
            }
        }
        .navigationTitle("New CRM team group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    _ = engine.crmCreateGroup(name: name.trimmingCharacters(in: .whitespaces), companyID: companyID, memberIDs: Array(picked))
                    Haptics.big()
                    dismiss()
                }
                .bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
            }
        }
    }
}

// MARK: - Share / PDF

enum CRMShare {
    static func icon(_ kind: String) -> String {
        switch kind {
        case "call": "phone.fill"
        case "meeting": "person.2.fill"
        case "visit": "mappin.and.ellipse"
        case "quote": "doc.text.fill"
        default: "note.text"
        }
    }

    @MainActor static func leadText(_ l: CRMLead, activities: [CRMActivity], engine: SyncEngine) -> String {
        var t = ["💼 \(l.name)\(l.company.isEmpty ? "" : " — \(l.company)")",
                 "Stage: \(CRMStage.of(l.stage).title) · Value: \(Money.format(l.dealValue)) · \(l.probability)%"]
        if let f = l.nextFollowUp { t.append("Next follow-up: \(f.formatted(date: .abbreviated, time: .shortened))") }
        if !l.notes.isEmpty && !l.clientCopy { t.append("Notes: \(l.notes)") }
        for a in activities.prefix(20) {
            t.append("- \(a.at.formatted(date: .abbreviated, time: .omitted)) \(a.kind): \(a.title) \(a.detail)\(a.amount > 0 ? " \(Money.format(a.amount))" : "")")
        }
        return t.joined(separator: "\n")
    }

    @MainActor static func text(_ leads: [CRMLead], engine: SyncEngine) -> String {
        (["💼 CRM pipeline"] + leads.filter { !$0.deleted }.map { "• \($0.name) — \(CRMStage.of($0.stage).title) · \(Money.format($0.dealValue))" })
            .joined(separator: "\n")
    }

    @MainActor static func html(_ leads: [CRMLead], engine: SyncEngine, activities: [CRMActivity] = []) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let open = leads.filter(\.isOpen)
        var h = "<h2>CRM pipeline</h2><p>\(open.count) open leads · pipeline \(esc(Money.format(open.reduce(0) { $0 + $1.dealValue })))"
        h += " · won \(esc(Money.format(leads.filter { $0.stage == "won" }.reduce(0) { $0 + $1.dealValue })))</p>"
        h += "<table><tr><th>Lead</th><th>Company</th><th>Stage</th><th>Value</th><th>Follow-up</th></tr>"
        for l in leads where !l.deleted {
            h += "<tr><td>\(esc(l.name))</td><td>\(esc(l.company))</td><td>\(CRMStage.of(l.stage).title)</td><td>\(esc(Money.format(l.dealValue)))</td>"
            h += "<td>\(l.nextFollowUp?.formatted(date: .abbreviated, time: .omitted) ?? "–")</td></tr>"
        }
        h += "</table>"
        if !activities.isEmpty {
            h += "<h3>Timeline</h3><table><tr><th>Date</th><th>Type</th><th>Title</th><th>Amount</th></tr>"
            for a in activities {
                h += "<tr><td>\(a.at.formatted(date: .abbreviated, time: .omitted))</td><td>\(a.kind.capitalized)</td><td>\(esc(a.title)) \(esc(a.detail))</td><td>\(a.amount > 0 ? esc(Money.format(a.amount)) : "")</td></tr>"
            }
            h += "</table>"
        }
        return h
    }

    @MainActor static func charts(_ leads: [CRMLead], groups: [CRMGroup]) -> [PDFChart] {
        let live = leads.filter { !$0.deleted }
        var sLabels: [String] = [], sCounts: [Double] = [], sColors: [UInt32] = []
        var vLabels: [String] = [], vValues: [Double] = []
        for st in CRMStage.allCases {
            let these = live.filter { $0.stage == st.rawValue }
            if !these.isEmpty { sLabels.append(st.title); sCounts.append(Double(these.count)); sColors.append(st.color) }
            vLabels.append(st.title)
            vValues.append(these.reduce(0.0) { $0 + $1.dealValue })
        }
        var out: [PDFChart] = [PDFChart(kind: .pie, title: "Leads by stage", labels: sLabels, values: sCounts, colors: sColors)]
        out.append(PDFChart(kind: .bar, title: "Pipeline value by stage", labels: vLabels, values: vValues))
        var byGroup: [String: Double] = [:]
        for l in live where l.isOpen {
            let name: String = groups.first(where: { $0.convID == l.groupConvID })?.name ?? "No group"
            byGroup[name, default: 0] += l.dealValue
        }
        let keys = byGroup.keys.sorted()
        if keys.count > 1 { out.append(PDFChart(kind: .bar, title: "Open pipeline by team group", labels: keys, values: keys.map { byGroup[$0] ?? 0 })) }
        return out
    }
}
