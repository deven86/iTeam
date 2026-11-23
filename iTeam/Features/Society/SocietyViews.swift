import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Home (committee dashboard or flat owner view)

struct SocietyHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @AppStorage("activeSocietyID") private var activeID = ""
    @Query(filter: #Predicate<SocietyRecord> { !$0.deleted }) private var recs: [SocietyRecord]
    @State private var create = false
    @State private var kiosk = false

    private var societies: [SocietyRecord] { recs.filter { $0.kind == "society" }.sorted { $0.society.name < $1.society.name } }
    private var active: SocietyRecord? { societies.first { $0.id == activeID } ?? societies.first }

    var body: some View {
        NavigationStack {
            Group {
                if let s = active {
                    if s.society.isCommittee(engine.me) { SocCommitteeView(society: s, recs: recs.filter { $0.societyID == s.id }, kiosk: $kiosk) }
                    else { SocOwnerView(society: s, recs: recs.filter { $0.societyID == s.id }) }
                } else {
                    List {
                        VStack(spacing: 14) {
                            EmptyStateView(icon: "building.2.crop.circle.fill", title: "Society & Apartment",
                                           message: "Maintenance bills, complaints, notices, and a gate & reception kiosk where guards ask flat owners to approve visitors — and staff punch attendance.")
                            Button { create = true } label: { Label("Set up a society", systemImage: "plus") }.buttonStyle(.glassProminent).controlSize(.large)
                            Button { trackMyHome() } label: { Label("Just my own flat (personal)", systemImage: "house.fill") }.buttonStyle(.glass)
                            Text("Personal: track your flat's maintenance, payments, complaints and notices yourself — even if your society isn't on iTeam.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Try a demo") { SocietyDemo.create(engine) }
                        }
                        .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    }
                    .lookScreen()
                }
            }
            .navigationTitle(active?.society.name ?? "Society")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if societies.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(societies) { s in Button(s.society.name) { activeID = s.id } }
                        } label: { Image(systemName: "building.2") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Set up another society", systemImage: "plus") { create = true }
                        if let s = active, s.society.isCommittee(engine.me) {
                            Button("Gate & reception kiosk", systemImage: "rectangle.portrait.and.arrow.right") { kiosk = true }
                            ShareMenu(title: "\(s.society.name) – dues report", text: { SocShare.text(s, recs: recs, engine: engine) },
                                      html: { SocShare.html(s, recs: recs, engine: engine) }, module: "Society", icon: "building.2.crop.circle.fill",
                                      colors: [0x0F766E, 0x14B8A6], charts: { SocShare.charts(s, recs: recs) })
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .refreshable { await engine.sync() }
            .sheet(isPresented: $create) { NavigationStack { SocietyEditor { activeID = $0 } } }
            .fullScreenCover(isPresented: $kiosk) { if let s = active { SocietyKioskView(society: s) } }
        }
    }
}

extension SocietyHomeView {
    /// Self use: a private society with just my flat, on my own devices.
    func trackMyHome() {
        let sid = engine.socCreate(name: "My home", address: "", committee: [], maintenance: 0)
        activeID = sid
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let soc = engine.socRecord(sid) else { return }
            var u = SocUnitData()
            u.flat = "My flat"; u.ownerUserID = engine.me; u.ownerName = engine.myName; u.members = 1
            engine.socSaveUnit(society: soc, existing: nil, u)
            Haptics.big()
        }
    }
}

// MARK: - Committee

struct SocCommitteeView: View {
    let society: SocietyRecord
    let recs: [SocietyRecord]
    @Binding var kiosk: Bool
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @State private var notice = false

    private func of(_ k: String) -> [SocietyRecord] { recs.filter { $0.kind == k } }

    var body: some View {
        let units = of("unit"), bills = of("bill"), complaints = of("complaint"), visitors = of("visitor")
        let dues = bills.filter { $0.status != "paid" }.reduce(0) { $0 + $1.bill.amount }
        let open = complaints.filter { $0.status != "resolved" }
        let waiting = visitors.filter { $0.status == "waiting" }
        let verify = bills.filter { $0.status == "verifying" }
        List {
            Section {
                HStack(spacing: 10) {
                    GymStat(value: "\(units.count)", label: "Flats", icon: "house.fill")
                    GymStat(value: Money.format(dues), label: "Dues pending", icon: "indianrupeesign.circle", warn: dues > 0)
                    GymStat(value: "\(open.count)", label: "Open complaints", icon: "wrench.and.screwdriver.fill", warn: !open.isEmpty)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Button { kiosk = true } label: { Label("Open gate & reception kiosk", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.large).listRowBackground(Color.clear)
            }
            if !waiting.isEmpty || !verify.isEmpty || !open.isEmpty {
                Section("Needs attention") {
                    ForEach(waiting) { v in SocVisitorRow(r: v, recs: recs, canAnswer: true) }
                    ForEach(verify) { b in SocBillRow(r: b, recs: recs, committee: true) }
                    ForEach(open.prefix(5)) { c in NavigationLink { SocComplaintDetail(r: c, recs: recs, committee: true) } label: { SocComplaintRow(r: c, recs: recs) } }
                }
                .lookRows()
            }
            Section {
                NavigationLink { SocUnitsView(society: society, recs: recs) } label: { Label("Flats & owners (\(units.count))", systemImage: "house.fill") }
                NavigationLink { SocBillsView(society: society, recs: recs) } label: { Label("Maintenance bills", systemImage: "doc.text.fill") }
                NavigationLink { SocComplaintsView(society: society, recs: recs, committee: true) } label: { Label("Complaints (\(open.count) open)", systemImage: "wrench.and.screwdriver.fill") }
                NavigationLink { SocVisitorsView(recs: recs) } label: { Label("Visitor log", systemImage: "person.badge.clock.fill") }
                NavigationLink { SocNoticesView(society: society, recs: recs, committee: true) } label: { Label("Notices", systemImage: "megaphone.fill") }
                Button { UserDefaults.standard.set(society.society.attCompanyID, forKey: "att.current"); router.go(.attendance) } label: {
                    Label("Staff attendance (guards, housekeeping)", systemImage: "person.badge.clock")
                }
                if let g = engine.conversation(society.society.committeeConvID) {
                    Button { router.show(conversation: g.id) } label: { Label("Committee chat", systemImage: "bubble.left.and.bubble.right.fill") }
                }
            }
            .lookRows()
            DocumentsSection(module: "society", recordID: society.id, recordOwner: society.society.ownerID, convID: society.society.committeeConvID,
                             title: society.society.name).lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
    }
}

// MARK: - Flat owner

struct SocOwnerView: View {
    let society: SocietyRecord
    let recs: [SocietyRecord]
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @State private var complain: String?

    var body: some View {
        let myUnits = recs.filter { $0.kind == "unit" && $0.unit.ownerUserID == engine.me }
        let ids = Set(myUnits.map(\.id))
        let mine = recs.filter { ids.contains($0.unitID) }
        let waiting = mine.filter { $0.kind == "visitor" && $0.status == "waiting" }
        let bills = mine.filter { $0.kind == "bill" }.sorted { $0.bill.due > $1.bill.due }
        let notices = recs.filter { $0.kind == "notice" }.sorted { $0.createdAt > $1.createdAt }
        List {
            Section {
                ForEach(myUnits) { u in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flat \(u.unit.label)").font(.title3.bold())
                        Text(society.society.name + (society.society.address.isEmpty ? "" : " · \(society.society.address)")).font(.caption).foregroundStyle(look.textSecondary)
                        Text("Managed by \(engine.name(of: society.society.ownerID)) & committee").font(.caption2).foregroundStyle(look.textSecondary)
                    }
                }
            }
            if !waiting.isEmpty {
                Section("At the gate — approve?") { ForEach(waiting) { SocVisitorRow(r: $0, recs: recs, canAnswer: true) } }.lookRows()
            }
            Section {
                if bills.isEmpty { Text("No bills yet.").foregroundStyle(look.textSecondary) }
                ForEach(bills) { SocBillRow(r: $0, recs: recs, committee: false) }
            } header: { Text("Maintenance") } footer: {
                if !society.society.upi.isEmpty { Text("Pay by UPI to \(society.society.upi), then tap the bill to send the reference.") }
            }
            .lookRows()
            Section {
                ForEach(mine.filter { $0.kind == "complaint" }) { c in
                    NavigationLink { SocComplaintDetail(r: c, recs: recs, committee: false) } label: { SocComplaintRow(r: c, recs: recs) }
                }
                if let u = myUnits.first { Button("Raise a complaint", systemImage: "plus") { complain = u.id } }
            } header: { Text("Complaints") }
            .lookRows()
            Section("Notices") {
                if notices.isEmpty { Text("No notices.").foregroundStyle(look.textSecondary) }
                ForEach(notices.prefix(20)) { SocNoticeRow(r: $0) }
            }
            .lookRows()
            Section("Visitor history") {
                ForEach(mine.filter { $0.kind == "visitor" && $0.status != "waiting" }.sorted { $0.createdAt > $1.createdAt }.prefix(20)) {
                    SocVisitorRow(r: $0, recs: recs, canAnswer: false)
                }
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .sheet(item: Binding(get: { complain.map(SocIDBox.init) }, set: { complain = $0?.id })) { b in
            NavigationStack { SocComplaintEditor(society: society, unitID: b.id) }
        }
    }
}

struct SocIDBox: Identifiable { let id: String }

// MARK: - Rows

struct SocVisitorRow: View {
    let r: SocietyRecord
    let recs: [SocietyRecord]
    let canAnswer: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    var body: some View {
        let v = r.visitor
        let flat = recs.first { $0.id == r.unitID }?.unit.label ?? ""
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let d = v.photo, let img = UIImage(data: d) {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(Circle())
                } else {
                    Image(systemName: icon(v.purpose)).frame(width: 44, height: 44).background(Circle().fill(Color.gray.opacity(0.15)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(v.name) · \(v.purpose)").font(.headline)
                    Text(["Flat \(flat)", v.vehicle, v.at.formatted(date: .omitted, time: .shortened)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(look.textSecondary)
                }
                Spacer()
                if r.status != "waiting" { Text(r.status.capitalized).font(.caption.bold()).foregroundStyle(r.status == "denied" ? look.danger : look.success) }
            }
            if r.status == "waiting" && canAnswer {
                HStack {
                    Button { engine.socAnswerVisitor(r, status: "approved"); Haptics.big() } label: { Label("Allow", systemImage: "checkmark") }.buttonStyle(.glassProminent).tint(.green)
                    Button(role: .destructive) { engine.socAnswerVisitor(r, status: "denied") } label: { Label("Deny", systemImage: "xmark") }.buttonStyle(.glass)
                }
            }
        }
    }

    private func icon(_ p: String) -> String {
        switch p { case "Delivery": "shippingbox.fill"; case "Cab": "car.fill"; case "Service": "wrench.fill"; default: "person.fill" }
    }
}

struct SocBillRow: View {
    let r: SocietyRecord
    let recs: [SocietyRecord]
    let committee: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @State private var pay = false

    var body: some View {
        let b = r.bill
        let flat = recs.first { $0.id == r.unitID }?.unit.label ?? ""
        Button { if r.status != "paid" { pay = true } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(committee ? "Flat \(flat) · \(b.title)" : b.title).font(.subheadline.weight(.semibold))
                    Text(r.status == "paid" ? "Paid \(b.paidOn?.formatted(date: .abbreviated, time: .omitted) ?? "")" :
                            r.status == "verifying" ? "Paid · waiting for committee to verify\(b.reference.isEmpty ? "" : " · Ref \(b.reference)")" :
                            "Due \(b.due.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(r.status == "due" && b.due < .now ? look.danger : look.textSecondary)
                }
                Spacer()
                Text(Money.format(b.amount)).font(.subheadline.bold())
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $pay) { NavigationStack { SocPaySheet(r: r, committee: committee) } }
    }
}

struct SocComplaintRow: View {
    let r: SocietyRecord
    let recs: [SocietyRecord]
    @Environment(\.look) private var look
    var body: some View {
        let flat = recs.first { $0.id == r.unitID }?.unit.label ?? ""
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.complaint.title).font(.subheadline.weight(.semibold))
                Text("Flat \(flat) · \(r.complaint.category) · \(r.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer()
            Text(r.status.capitalized).font(.caption.bold()).foregroundStyle(r.status == "resolved" ? look.success : look.warning)
        }
    }
}

struct SocNoticeRow: View {
    let r: SocietyRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(r.notice.title).font(.headline)
            if !r.notice.body.isEmpty { Text(r.notice.body).font(.subheadline) }
            Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Lists & editors

struct SocUnitsView: View {
    let society: SocietyRecord
    let recs: [SocietyRecord]
    @State private var edit: SocietyRecord?
    @State private var add = false
    var body: some View {
        let units = recs.filter { $0.kind == "unit" }.sorted { $0.unit.label.localizedStandardCompare($1.unit.label) == .orderedAscending }
        List {
            ForEach(units) { u in
                Button { edit = u } label: {
                    HStack {
                        Text(u.unit.label).font(.headline).frame(width: 70, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(u.unit.ownerName).font(.subheadline)
                            Text([u.unit.tenantName.isEmpty ? "" : "Tenant \(u.unit.tenantName)", u.unit.parking.isEmpty ? "" : "Parking \(u.unit.parking)"]
                                .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if u.unit.maintenance > 0 { Text(Money.format(u.unit.maintenance)).font(.caption) }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Flats & owners")
        .toolbar { Button { add = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $add) { NavigationStack { SocUnitEditor(society: society, unit: nil) } }
        .sheet(item: $edit) { u in NavigationStack { SocUnitEditor(society: society, unit: u) } }
    }
}

/// Rule A: a flat owner must be on iTeam — Save stays off until an iTeam contact is picked.
struct SocUnitEditor: View {
    let society: SocietyRecord
    let unit: SocietyRecord?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved }, sort: \Contact.name) private var contacts: [Contact]
    @State private var d = SocUnitData()
    @State private var maintenance = ""

    var body: some View {
        Form {
            Section {
                TextField("Wing (e.g. A)", text: $d.wing)
                TextField("Flat no. (e.g. 101)", text: $d.flat)
                TextField("Floor", text: $d.floor)
            }
            Section {
                Picker("Owner on iTeam", selection: $d.ownerUserID) {
                    Text("Choose…").tag("")
                    if d.ownerUserID == engine.me { Text("Me").tag(engine.me) }
                    ForEach(contacts) { c in Text(c.name).tag(c.userID) }
                    if !d.ownerUserID.isEmpty, d.ownerUserID != engine.me, !contacts.contains(where: { $0.userID == d.ownerUserID }) { Text(d.ownerName).tag(d.ownerUserID) }
                }
                Button("I own this flat") { d.ownerUserID = engine.me }
            } header: { Text("Flat owner") } footer: {
                Text(d.ownerUserID.isEmpty ? "The owner must be on iTeam — bills, visitor approvals and notices reach them there. Not on iTeam yet? Share your invite (Settings → My QR) and add them as a contact first." :
                        "Bills, visitor requests and notices go to the owner's iTeam.")
            }
            Section {
                TextField("Tenant name (optional)", text: $d.tenantName)
                TextField("Phone (optional)", text: $d.phone).keyboardType(.phonePad)
                Stepper("Residents: \(d.members)", value: $d.members, in: 0...20)
                TextField("Parking slot", text: $d.parking)
                TextField("Monthly maintenance", text: $maintenance).keyboardType(.decimalPad)
            }
            if let unit {
                Section { Button("Remove flat", role: .destructive) { engine.socDelete(unit); dismiss() } }
            }
        }
        .navigationTitle(unit == nil ? "Add flat" : "Flat \(d.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if d.ownerUserID == engine.me { d.ownerName = engine.myName }
                    else if let c = contacts.first(where: { $0.userID == d.ownerUserID }) { d.ownerName = c.name }
                    d.maintenance = Double(maintenance.replacingOccurrences(of: ",", with: "")) ?? 0
                    engine.socSaveUnit(society: society, existing: unit, d)
                    Haptics.success()
                    dismiss()
                }
                .bold().disabled(d.flat.trimmingCharacters(in: .whitespaces).isEmpty || d.ownerUserID.isEmpty)
            }
        }
        .onAppear {
            if let unit { d = unit.unit; maintenance = d.maintenance > 0 ? String(format: "%.0f", d.maintenance) : "" }
            else if society.society.defaultMaintenance > 0 { maintenance = String(format: "%.0f", society.society.defaultMaintenance) }
        }
    }
}

struct SocBillsView: View {
    let society: SocietyRecord
    let recs: [SocietyRecord]
    @EnvironmentObject var engine: SyncEngine
    @State private var month = Date.now
    var body: some View {
        let bills = recs.filter { $0.kind == "bill" }.sorted { $0.bill.due > $1.bill.due }
        List {
            Section {
                DatePicker("Month", selection: $month, displayedComponents: .date)
                Button("Create maintenance bills for every flat", systemImage: "doc.badge.plus") { engine.socGenerateBills(society: society, month: month); Haptics.big() }
            } footer: { Text("One bill per flat (its own amount, or the society default), due on day \(society.society.dueDay). Already-billed flats are skipped.") }
            ForEach(["verifying", "due", "paid"], id: \.self) { st in
                let these = bills.filter { $0.status == st }
                if !these.isEmpty {
                    Section(st == "verifying" ? "Paid — verify" : st.capitalized) { ForEach(these) { SocBillRow(r: $0, recs: recs, committee: true) } }
                }
            }
        }
        .navigationTitle("Maintenance bills")
    }
}

struct SocPaySheet: View {
    let r: SocietyRecord
    let committee: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var method = "UPI"
    @State private var reference = ""
    @State private var receipts: [AttachmentRef] = []
    @State private var uploads: [String: String] = [:]
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                LabeledContent(r.bill.title, value: Money.format(r.bill.amount))
                if r.status == "verifying" {
                    LabeledContent("Paid by", value: "\(r.bill.method) · \(r.bill.reference)")
                    if !r.bill.receipts.isEmpty { ScrollView(.horizontal) { HStack { ForEach(r.bill.receipts) { AttachmentThumb(ref: $0) } } } }
                }
            }
            if r.status == "verifying" && committee {
                Section {
                    Button("Payment received ✓") { engine.socVerifyBill(r, ok: true); dismiss() }
                    Button("Not received", role: .destructive) { engine.socVerifyBill(r, ok: false); dismiss() }
                }
            } else {
                Section {
                    Picker("Paid by", selection: $method) { ForEach(["UPI", "Bank transfer", "Cash", "Cheque"], id: \.self) { Text($0) } }
                    TextField("UTR / reference", text: $reference)
                    PhotosPicker(selection: $photo, matching: .images) { Label("Add receipt screenshot", systemImage: "doc.viewfinder") }
                    ScrollView(.horizontal) { HStack { ForEach(receipts) { AttachmentThumb(ref: $0) } } }
                } footer: { Text(committee ? "Recording a payment received from the owner." : "The committee verifies it, then it shows as paid.") }
            }
        }
        .navigationTitle(committee ? "Bill" : "Pay maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            if !(r.status == "verifying" && committee) {
                ToolbarItem(placement: .confirmationAction) {
                    Button(committee ? "Mark paid" : "Send") { engine.socPayBill(r, method: method, reference: reference, receipts: receipts, uploads: uploads); Haptics.big(); dismiss() }.bold()
                }
            }
        }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(d) { receipts.append(p.ref); uploads[p.upload.0] = p.upload.1 } }
        }
    }
}

struct SocComplaintsView: View {
    let society: SocietyRecord
    let recs: [SocietyRecord]
    let committee: Bool
    var body: some View {
        let all = recs.filter { $0.kind == "complaint" }.sorted { $0.createdAt > $1.createdAt }
        List {
            ForEach(["open", "in progress", "resolved"], id: \.self) { st in
                let these = all.filter { $0.status == st }
                if !these.isEmpty {
                    Section(st.capitalized) {
                        ForEach(these) { c in NavigationLink { SocComplaintDetail(r: c, recs: recs, committee: committee) } label: { SocComplaintRow(r: c, recs: recs) } }
                    }
                }
            }
            if all.isEmpty { Text("No complaints.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Complaints")
    }
}

struct SocComplaintDetail: View {
    let r: SocietyRecord
    let recs: [SocietyRecord]
    let committee: Bool
    @EnvironmentObject var engine: SyncEngine
    @State private var reply = ""
    var body: some View {
        Form {
            Section {
                Text(r.complaint.title).font(.headline)
                Text("\(r.complaint.category) · raised by \(engine.name(of: r.by)) · \(r.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                if !r.complaint.detail.isEmpty { Text(r.complaint.detail) }
                if !r.complaint.photos.isEmpty { ScrollView(.horizontal) { HStack { ForEach(r.complaint.photos) { AttachmentThumb(ref: $0, size: 80) } } } }
            }
            if !r.complaint.reply.isEmpty { Section("Committee reply") { Text(r.complaint.reply) } }
            if committee && AISettings.shared.allows(.advisor) {
                Section {
                    AISuggest(title: "Possible solutions & reply",
                              instructions: "You help a housing society committee in India. For this complaint, list practical solutions (who to call, rough cost range, by-law angle if relevant), then draft a short polite reply to the flat owner.",
                              context: { "Complaint: \(r.complaint.title)\nCategory: \(r.complaint.category)\nDetails: \(r.complaint.detail)\nRaised: \(r.createdAt.formatted(date: .abbreviated, time: .omitted))\nStatus: \(r.status)\nSimilar past complaints: " + recs.filter { $0.kind == "complaint" && $0.id != r.id && $0.complaint.category == r.complaint.category }.prefix(8).map { "\($0.complaint.title) (\($0.status))" }.joined(separator: "; ") })
                }
            }
            Section("Status: \(r.status.capitalized)") {
                if committee {
                    TextField("Reply to the owner", text: $reply, axis: .vertical)
                    Button("Mark in progress") { engine.socUpdateComplaint(r, status: "in progress", reply: reply.isEmpty ? r.complaint.reply : reply) }
                    Button("Mark resolved ✓") { engine.socUpdateComplaint(r, status: "resolved", reply: reply.isEmpty ? r.complaint.reply : reply); Haptics.big() }
                } else if r.status == "resolved" {
                    Button("Not fixed — reopen") { engine.socUpdateComplaint(r, status: "open", reply: r.complaint.reply) }
                }
            }
        }
        .navigationTitle("Complaint")
    }
}

struct SocComplaintEditor: View {
    let society: SocietyRecord
    let unitID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var d = SocComplaintData()
    @State private var uploads: [String: String] = [:]
    @State private var photo: PhotosPickerItem?
    var body: some View {
        Form {
            AIScanSection(spec: ScanSpec(title: "Scan a written complaint", what: "a written complaint letter to a housing society",
                                         fields: [.text("title", "What's wrong (short)"), .choice("category", "Category", ["Maintenance", "Plumbing", "Electrical", "Lift", "Security", "Cleaning", "Parking", "Noise", "Other"]),
                                                  .long("detail", "Details")])) { o in
                if let v = o.str("title") { d.title = v }
                if let v = o.str("category") { d.category = v }
                if let v = o.str("detail") { d.detail = v }
                for p in o.files { d.photos.append(p.ref); uploads[p.upload.0] = p.upload.1 }
            }
            TextField("What's wrong?", text: $d.title)
            Picker("Category", selection: $d.category) {
                ForEach(["Maintenance", "Plumbing", "Electrical", "Lift", "Security", "Cleaning", "Parking", "Noise", "Other"], id: \.self) { Text($0) }
            }
            TextField("Details", text: $d.detail, axis: .vertical)
            PhotosPicker(selection: $photo, matching: .images) { Label("Add photo", systemImage: "camera") }
            ScrollView(.horizontal) { HStack { ForEach(d.photos) { AttachmentThumb(ref: $0) } } }
        }
        .navigationTitle("Raise a complaint")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { engine.socRaiseComplaint(society: society, unitID: unitID, d, uploads: uploads); Haptics.big(); dismiss() }
                    .bold().disabled(d.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onChange(of: photo) { _, item in
            Task { if let data = try? await item?.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(data) { d.photos.append(p.ref); uploads[p.upload.0] = p.upload.1 } }
        }
    }
}

struct SocVisitorsView: View {
    let recs: [SocietyRecord]
    var body: some View {
        let all = recs.filter { $0.kind == "visitor" }.sorted { $0.createdAt > $1.createdAt }
        List {
            if all.isEmpty { Text("No visitors logged.").foregroundStyle(.secondary) }
            ForEach(all.prefix(200)) { SocVisitorRow(r: $0, recs: recs, canAnswer: false) }
        }
        .navigationTitle("Visitor log")
    }
}

struct SocNoticesView: View {
    let society: SocietyRecord
    let recs: [SocietyRecord]
    let committee: Bool
    @EnvironmentObject var engine: SyncEngine
    @State private var add = false
    @State private var n = SocNoticeData()
    var body: some View {
        List {
            ForEach(recs.filter { $0.kind == "notice" }.sorted { $0.createdAt > $1.createdAt }) { SocNoticeRow(r: $0) }
        }
        .navigationTitle("Notices")
        .toolbar { if committee { Button { add = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $add) {
            NavigationStack {
                Form {
                    AIScanSection(spec: ScanSpec(title: "Scan a printed notice or agenda", what: "a housing society notice, circular or AGM/meeting agenda",
                                                 fields: [.text("title", "Title"), .long("body", "Full text of the notice")])) { o in
                        if let v = o.str("title") { n.title = v }
                        if let v = o.str("body") { n.body = v }
                    }
                    TextField("Title", text: $n.title)
                    TextField("Message", text: $n.body, axis: .vertical)
                    if AISettings.shared.allows(.advisor) {
                        AISuggest(title: "Draft a meeting agenda / notice",
                                  instructions: "Draft a formal notice for an Indian co-operative housing society: meeting type, date/time/venue placeholders, numbered agenda (confirm last minutes, accounts, maintenance, repairs, complaints, any other matter with the chair's permission) and the secretary's sign-off. Use the title and message as the topic.",
                                  context: { "Society: \(society.society.name)\nTitle: \(n.title)\nMessage so far: \(n.body)\nOpen complaints: " + recs.filter { $0.kind == "complaint" && $0.status != "resolved" }.prefix(15).map { $0.complaint.title }.joined(separator: "; ") })
                    }
                }
                .navigationTitle("New notice")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { add = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Post to all flats") { engine.socPostNotice(society: society, n, uploads: [:]); n = SocNoticeData(); add = false }
                            .bold().disabled(n.title.isEmpty)
                    }
                }
            }
        }
    }
}

struct SocietyEditor: View {
    var onCreated: (String) -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved }, sort: \Contact.name) private var contacts: [Contact]
    @State private var name = ""
    @State private var address = ""
    @State private var maintenance = ""
    @State private var committee: Set<String> = []
    var body: some View {
        Form {
            Section {
                TextField("Society name", text: $name)
                TextField("Address", text: $address)
                TextField("Default monthly maintenance", text: $maintenance).keyboardType(.decimalPad)
            }
            Section {
                ForEach(contacts) { c in
                    Button { if committee.contains(c.userID) { committee.remove(c.userID) } else { committee.insert(c.userID) } } label: {
                        HStack { Text(c.name); Spacer(); if committee.contains(c.userID) { Image(systemName: "checkmark").foregroundStyle(.blue) } }
                    }
                    .foregroundStyle(.primary)
                }
            } header: { Text("Committee (secretary, treasurer…)") } footer: {
                Text("Creates a committee group chat. You are the chairperson. A staff Attendance company is created for guards and housekeeping.")
            }
        }
        .navigationTitle("Set up society")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    let id = engine.socCreate(name: name.trimmingCharacters(in: .whitespaces), address: address, committee: Array(committee),
                                              maintenance: Double(maintenance.replacingOccurrences(of: ",", with: "")) ?? 0)
                    Haptics.big(); dismiss(); onCreated(id)
                }
                .bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Gate & reception kiosk (Rule B)

struct SocietyKioskView: View {
    let society: SocietyRecord
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<SocietyRecord> { !$0.deleted }) private var recs: [SocietyRecord]
    @State private var mode = 1
    @State private var staffKiosk = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    Text("Visitors & deliveries").tag(1)
                    Text("Staff attendance").tag(0)
                }
                .pickerStyle(.segmented).padding()
                if mode == 1 { SocGateVisitors(society: society, recs: recs.filter { $0.societyID == society.id }) }
                else {
                    VStack(spacing: 14) {
                        Image(systemName: "person.badge.clock.fill").font(.system(size: 54)).foregroundStyle(.teal)
                        Text("Guards, housekeeping and reception punch in and out with their PIN.").multilineTextAlignment(.center)
                        Button("Open staff punch screen") { staffKiosk = true }.buttonStyle(.glassProminent).controlSize(.large)
                        Text("Add staff in Attendance → \(society.society.name) · Staff.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding()
                }
            }
            .navigationTitle("\(society.society.name) · Gate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Exit") { Task { if await DeviceAuth.check("Exit the gate kiosk") { dismiss() } } }
                }
            }
            .fullScreenCover(isPresented: $staffKiosk) { AttKioskView(companyID: society.society.attCompanyID) }
        }
        .interactiveDismissDisabled()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

struct SocGateVisitors: View {
    let society: SocietyRecord
    let recs: [SocietyRecord]
    @EnvironmentObject var engine: SyncEngine
    @State private var v = SocVisitorData()
    @State private var unitID = ""
    @State private var camera = false

    var body: some View {
        let units = recs.filter { $0.kind == "unit" }.sorted { $0.unit.label.localizedStandardCompare($1.unit.label) == .orderedAscending }
        let today = recs.filter { $0.kind == "visitor" && Calendar.current.isDateInToday($0.createdAt) }.sorted { $0.createdAt > $1.createdAt }
        Form {
            Section("New visitor") {
                Picker("Purpose", selection: $v.purpose) { ForEach(["Guest", "Delivery", "Cab", "Service"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                TextField("Name", text: $v.name)
                TextField("Vehicle no. (optional)", text: $v.vehicle).textInputAutocapitalization(.characters)
                TextField("Phone (optional)", text: $v.phone).keyboardType(.phonePad)
                Picker("Flat", selection: $unitID) {
                    Text("Choose flat").tag("")
                    ForEach(units) { u in Text("\(u.unit.label) · \(u.unit.ownerName)").tag(u.id) }
                }
                HStack {
                    Button(v.photo == nil ? "Take photo" : "Retake photo", systemImage: "camera") { camera = true }
                    if let d = v.photo, let img = UIImage(data: d) { Image(uiImage: img).resizable().scaledToFill().frame(width: 40, height: 40).clipShape(Circle()) }
                }
                Button {
                    engine.socLogVisitor(society: society, unitID: unitID, v)
                    Haptics.big()
                    v = SocVisitorData(); unitID = ""
                } label: { Label("Ask flat owner", systemImage: "bell.badge.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).disabled(v.name.isEmpty || unitID.isEmpty)
            }
            Section("Today") {
                if today.isEmpty { Text("No visitors yet today.").foregroundStyle(.secondary) }
                ForEach(today) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        SocVisitorRow(r: r, recs: recs, canAnswer: false)
                        if r.status == "waiting" { Label("Waiting for the owner…", systemImage: "hourglass").font(.caption).foregroundStyle(.orange) }
                        if r.status == "approved" { Button("Mark left") { engine.socAnswerVisitor(r, status: "left") }.font(.caption) }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { img in v.photo = img.preparingThumbnail(of: CGSize(width: 320, height: 320))?.jpegData(compressionQuality: 0.6) }.ignoresSafeArea()
        }
    }
}

// MARK: - Share / PDF

enum SocShare {
    @MainActor static func text(_ s: SocietyRecord, recs: [SocietyRecord], engine: SyncEngine) -> String {
        let bills = recs.filter { $0.kind == "bill" && $0.societyID == s.id }
        let due = bills.filter { $0.status != "paid" }
        return (["🏢 \(s.society.name) — dues", "Pending: \(Money.format(due.reduce(0) { $0 + $1.bill.amount })) from \(due.count) bills"] +
                due.map { b in "• Flat \(recs.first { $0.id == b.unitID }?.unit.label ?? "") \(b.bill.title): \(Money.format(b.bill.amount))" }).joined(separator: "\n")
    }

    @MainActor static func html(_ s: SocietyRecord, recs: [SocietyRecord], engine: SyncEngine) -> String {
        let mine = recs.filter { $0.societyID == s.id }
        var h = "<h2>\(s.society.name)</h2><p>\(s.society.address)</p><h3>Maintenance</h3><table><tr><th>Flat</th><th>Owner</th><th>Bill</th><th>Amount</th><th>Status</th></tr>"
        for b in mine.filter({ $0.kind == "bill" }).sorted(by: { $0.bill.due > $1.bill.due }) {
            let u = mine.first { $0.id == b.unitID }?.unit
            h += "<tr><td>\(u?.label ?? "")</td><td>\(u?.ownerName ?? "")</td><td>\(b.bill.title)</td><td>\(Money.format(b.bill.amount))</td><td>\(b.status)</td></tr>"
        }
        h += "</table><h3>Complaints</h3><table><tr><th>Date</th><th>Flat</th><th>Complaint</th><th>Status</th></tr>"
        for c in mine.filter({ $0.kind == "complaint" }) {
            h += "<tr><td>\(c.createdAt.formatted(date: .abbreviated, time: .omitted))</td><td>\(mine.first { $0.id == c.unitID }?.unit.label ?? "")</td><td>\(c.complaint.title)</td><td>\(c.status)</td></tr>"
        }
        return h + "</table>"
    }

    @MainActor static func charts(_ s: SocietyRecord, recs: [SocietyRecord]) -> [PDFChart] {
        let mine = recs.filter { $0.societyID == s.id }
        var paid = 0.0, due = 0.0, verifying = 0.0
        for b in mine where b.kind == "bill" {
            switch b.status { case "paid": paid += b.bill.amount; case "verifying": verifying += b.bill.amount; default: due += b.bill.amount }
        }
        var cats: [String: Double] = [:]
        for c in mine where c.kind == "complaint" { cats[c.complaint.category, default: 0] += 1 }
        let keys = cats.keys.sorted()
        return [PDFChart(kind: .pie, title: "Maintenance collected", labels: ["Paid", "Verifying", "Due"], values: [paid, verifying, due], colors: [0x34C759, 0xFF9500, 0xFF3B30]),
                PDFChart(kind: .bar, title: "Complaints by category", labels: keys, values: keys.map { cats[$0] ?? 0 })]
    }
}
