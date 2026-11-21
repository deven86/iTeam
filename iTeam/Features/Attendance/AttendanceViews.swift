import SwiftUI
import SwiftData
import PhotosUI

// MARK: - One company's records, worked out once per screen

struct AttData {
    let company: AttRecord?
    let c: AttCompanyData
    let members: [AttRecord]
    let entries: [AttRecord]
    let leaves: [AttRecord]
    let holidays: [AttRecord]
    let changes: [AttRecord]
    let archived: [AttRecord]

    init(_ recs: [AttRecord], companyID: String) {
        let live = recs.filter { !$0.deleted }
        company = recs.first { $0.kind == "company" && $0.id == companyID }
        c = company?.company ?? AttCompanyData()
        members = live.filter { $0.kind == "member" }.sorted { $0.member.name.localizedCaseInsensitiveCompare($1.member.name) == .orderedAscending }
        entries = live.filter { $0.kind == "entry" }
        leaves = live.filter { $0.kind == "leave" }.sorted { $0.leave.from > $1.leave.from }
        holidays = live.filter { $0.kind == "holiday" }.sorted { $0.day < $1.day }
        changes = live.filter { $0.kind == "change" }.sorted { $0.updatedAt > $1.updatedAt }
        archived = recs.filter { $0.deleted && $0.kind != "company" }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var active: [AttRecord] { members.filter { $0.member.active } }

    func entry(_ m: AttRecord, _ day: Date) -> AttRecord? {
        let k = Att.key(day)
        return entries.first { $0.memberID == m.id && $0.day == k }
    }
    func status(_ m: AttRecord, _ day: Date) -> String {
        Att.status(member: m, company: c, day: day, entry: entry(m, day), leaves: leaves, holidays: holidays)
    }
    func summary(_ m: AttRecord, month: Date) -> Att.Summary {
        Att.summary(member: m, company: c, days: Att.monthDays(month), entries: entries, leaves: leaves, holidays: holidays)
    }
    func member(_ id: String) -> AttRecord? { members.first { $0.id == id } }
    @MainActor func name(_ m: AttRecord?, _ engine: SyncEngine) -> String {
        guard let m else { return "Removed member" }
        let d = m.member
        if !d.name.isEmpty { return d.name }
        return d.isUser ? engine.name(of: d.userID) : "Unnamed"
    }
    @MainActor func name(_ id: String, _ engine: SyncEngine) -> String { name(member(id), engine) }
}

// MARK: - Home

struct AttendanceHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Query(filter: #Predicate<AttRecord> { ($0.kind == "company" || $0.kind == "member") && !$0.deleted }) private var heads: [AttRecord]
    @AppStorage("att.current") private var currentID = ""

    private var companies: [AttRecord] {
        let me = engine.me
        let mine = Set(heads.filter { $0.kind == "member" && $0.member.userID == me && $0.member.accepted != false }.map(\.companyID))
        return heads.filter { $0.kind == "company" && ($0.company.ownerID == me || mine.contains($0.id)) }
            .sorted { $0.company.name < $1.company.name }
    }
    private var current: AttRecord? { companies.first { $0.id == currentID } ?? companies.first }

    var body: some View {
        NavigationStack {
            Group {
                if let comp = current {
                    if comp.company.isStaff(engine.me) {
                        AttStaffDashboard(companyID: comp.id)
                    } else if let m = heads.first(where: { $0.kind == "member" && $0.companyID == comp.id && $0.member.userID == engine.me }) {
                        AttMyView(companyID: comp.id, memberID: m.id)
                    }
                } else {
                    AttWelcomeView()
                }
            }
            .toolbar {
                if companies.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(companies) { c in
                                Button { currentID = c.id } label: {
                                    Label(c.company.name, systemImage: c.id == current?.id ? "checkmark" : "building.2")
                                }
                            }
                        } label: { Image(systemName: "building.2.crop.circle") }
                    }
                }
            }
        }
    }
}

struct AttWelcomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var modules: ModuleRegistry
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                EmptyStateView(icon: "person.badge.clock.fill", title: "Attendance",
                               message: "Punch in and out by phone, selfie with location, rotating QR or a kiosk. Late and half-day rules, leaves, holidays, and registers in PDF, Excel (CSV) and Tally.",
                               actionTitle: modules.isOn(ModuleRegistry.attendance) ? "Set up my company" : nil) { creating = true }
                if modules.isOn(ModuleRegistry.attendance) {
                    Button("Try a demo", systemImage: "wand.and.stars") { AttDemo.create(engine) }.buttonStyle(.glass)
                } else {
                    NavigationLink { ModuleStoreView() } label: { Label("Get Attendance in the Module Store", systemImage: "bag.fill") }
                        .buttonStyle(.glassProminent)
                    Text("Employees never pay — when your employer adds you, your attendance appears here.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .padding()
        }
        .lookScreen()
        .navigationTitle("Attendance")
        .alert("Company or branch name", isPresented: $creating) {
            TextField("e.g. Jondhale & Co.", text: $name)
            Button("Create") {
                let n = name.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { UserDefaults.standard.set(engine.attCreateCompany(name: n), forKey: "att.current") }
                name = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Owner / admin dashboard

struct AttStaffDashboard: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var recs: [AttRecord]
    @State private var day = Date.now
    @State private var addMember = false
    @State private var mark = false
    @State private var kiosk = false
    @State private var qr = false
    @State private var recordLeave = false
    @State private var shareItems: ShareItems?
    @State private var leaveToDecide: AttRecord?
    @State private var newCompany = false
    @State private var newName = ""

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    private var d: AttData { AttData(recs, companyID: companyID) }
    private var isOwner: Bool { d.c.ownerID == engine.me }

    var body: some View {
        let data = d
        let statuses = data.active.map { AttSt(m: $0, s: data.status($0, day)) }
        List {
            tiles(statuses)
            actions(data)
            attention(data)
            todaySection(data, statuses)
            manage(data)
        }
        .lookScreen()
        .navigationTitle(data.c.name.isEmpty ? "Attendance" : data.c.name)
        .toolbar { toolbar(data) }
        .refreshable { await engine.sync() }
        .sheet(isPresented: $addMember) { if let comp = data.company { NavigationStack { AttMemberEditor(company: comp, existing: nil) } } }
        .sheet(isPresented: $mark) { if let comp = data.company { NavigationStack { AttMarkSheet(company: comp, data: data) } } }
        .sheet(isPresented: $recordLeave) { if let comp = data.company { NavigationStack { AttLeaveEditor(company: comp, member: nil, staff: true) } } }
        .sheet(isPresented: $qr) { if let comp = data.company { AttQRView(company: comp) } }
        .sheet(item: $leaveToDecide) { l in NavigationStack { AttLeaveDetail(leaveID: l.id, companyID: companyID) } }
        .fullScreenCover(isPresented: $kiosk) { AttKioskView(companyID: companyID) }
        .alert("New company or branch", isPresented: $newCompany) {
            TextField("Name", text: $newName)
            Button("Create") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { UserDefaults.standard.set(engine.attCreateCompany(name: n), forKey: "att.current") }
                newName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Switch between companies with the building button at the top left.") }
        .shareSheet($shareItems)
    }

    @ViewBuilder
    private func tiles(_ statuses: [AttSt]) -> some View {
        let present = statuses.filter { ["present", "grace", "late", "halfday"].contains($0.s) }.count
        let late = statuses.filter { ["late", "halfday"].contains($0.s) }.count
        let absent = statuses.filter { $0.s == "absent" }.count
        let leave = statuses.filter { ["leave", "unpaid"].contains($0.s) }.count
        Section {
            HStack(spacing: 8) {
                AttTile(value: "\(present)/\(statuses.count)", label: "Present", icon: "checkmark.circle.fill", color: 0x34C759)
                AttTile(value: "\(late)", label: "Late", icon: "clock.badge.exclamationmark", color: 0xFF9500)
                AttTile(value: "\(absent)", label: "Absent", icon: "xmark.circle.fill", color: 0xFF3B30)
                AttTile(value: "\(leave)", label: "On leave", icon: "beach.umbrella.fill", color: 0x5856D6)
            }
            DatePicker("Day", selection: $day, in: ...Date.now, displayedComponents: .date)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func actions(_ data: AttData) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if data.c.kiosk { AttAction(title: "Kiosk", icon: "rectangle.portrait.and.arrow.right") { kiosk = true } }
                    if data.c.needQR || data.c.selfPunch { AttAction(title: "Show QR", icon: "qrcode") { qr = true } }
                    AttAction(title: "Mark", icon: "hand.tap.fill") { mark = true }
                    AttAction(title: "Leave", icon: "beach.umbrella") { recordLeave = true }
                    AttAction(title: "Member", icon: "person.badge.plus") { addMember = true }
                }
                .padding(.vertical, 2)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    @ViewBuilder
    private func attention(_ data: AttData) -> some View {
        let leaves = data.leaves.filter { $0.status == "pending" }
        let changes = isOwner ? data.changes.filter { $0.status == "pending" } : []
        let holidays = isOwner ? data.holidays.filter { $0.status == "pending" } : []
        let waiting = data.members.filter { $0.member.isUser && $0.member.accepted == nil }
        let declined = data.members.filter { $0.member.isUser && $0.member.accepted == false }
        if !(leaves.isEmpty && changes.isEmpty && holidays.isEmpty && waiting.isEmpty && declined.isEmpty) {
            Section("Needs attention") {
                ForEach(leaves) { l in
                    Button { leaveToDecide = l } label: {
                        AttLine(icon: "beach.umbrella.fill", color: 0x5856D6, title: "\(data.name(l.memberID, engine)) — \(l.leave.type) leave",
                                detail: AttFmt.leaveSpan(l.leave), trailing: "Decide")
                    }
                }
                ForEach(changes) { x in
                    NavigationLink { AttChangesView(companyID: companyID) } label: {
                        AttLine(icon: "pencil.circle.fill", color: 0xFF9500, title: "Change for \(data.name(x.memberID, engine))",
                                detail: "\(Att.date(x.day).formatted(date: .abbreviated, time: .omitted)) · by \(engine.name(of: x.by))", trailing: "Review")
                    }
                }
                ForEach(holidays) { h in
                    NavigationLink { AttHolidaysView(companyID: companyID) } label: {
                        AttLine(icon: "flag.fill", color: 0x007AFF, title: "Holiday “\(h.holiday.name)”",
                                detail: "\(Att.date(h.day).formatted(date: .abbreviated, time: .omitted)) · proposed by \(engine.name(of: h.by))", trailing: "Approve")
                    }
                }
                ForEach(waiting) { m in
                    AttLine(icon: "hourglass", color: 0x8E8E93, title: data.name(m, engine), detail: "Hasn't accepted the invitation yet", trailing: "")
                }
                ForEach(declined) { m in
                    AttLine(icon: "person.fill.xmark", color: 0xFF3B30, title: data.name(m, engine), detail: "Declined — mark them by kiosk or yourself", trailing: "")
                }
            }
            .lookRows()
        }
    }

    @ViewBuilder
    private func todaySection(_ data: AttData, _ statuses: [AttSt]) -> some View {
        Section(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(date: .complete, time: .omitted)) {
            if statuses.isEmpty {
                Button("Add your first member", systemImage: "person.badge.plus") { addMember = true }
            }
            ForEach(statuses) { pair in
                NavigationLink { AttMemberDetail(companyID: companyID, memberID: pair.m.id) } label: {
                    AttMemberRow(member: pair.m, name: data.name(pair.m, engine), status: pair.s, entry: data.entry(pair.m, day))
                }
            }
        }
        .lookRows()
    }

    @ViewBuilder
    private func manage(_ data: AttData) -> some View {
        Section("Manage") {
            NavigationLink { AttMembersView(companyID: companyID) } label: { Label("Members (\(data.members.count))", systemImage: "person.3.fill") }
            NavigationLink { AttLeavesView(companyID: companyID) } label: { Label("Leaves", systemImage: "beach.umbrella.fill") }
            NavigationLink { AttHolidaysView(companyID: companyID) } label: { Label("Holidays", systemImage: "flag.fill") }
            if isOwner { NavigationLink { AttChangesView(companyID: companyID) } label: { Label("Change requests", systemImage: "pencil.and.list.clipboard") } }
            NavigationLink { AttReportsView(companyID: companyID) } label: { Label("Reports & export (PDF · Excel · Tally)", systemImage: "chart.bar.doc.horizontal.fill") }
            if isOwner { NavigationLink { AttSettingsView(companyID: companyID) } label: { Label("Rules & settings", systemImage: "slider.horizontal.3") } }
            NavigationLink { AttArchiveView(companyID: companyID) } label: { Label("Archive (\(data.archived.count))", systemImage: "archivebox.fill") }
            if let mine = data.members.first(where: { $0.member.userID == engine.me }) {
                NavigationLink { AttMyView(companyID: companyID, memberID: mine.id) } label: { Label("My attendance", systemImage: "person.crop.circle.badge.clock") }
            }
        }
        .lookRows()
    }

    @ToolbarContentBuilder
    private func toolbar(_ data: AttData) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { Button { addMember = true } label: { Image(systemName: "person.badge.plus") } }
        ToolbarItem(placement: .secondaryAction) {
            Button("Add another company", systemImage: "building.2.fill") { newCompany = true }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Export report (PDF)", systemImage: "doc.richtext") {
                if let url = PDFMaker.make(title: "\(data.c.name) — Attendance \(day.formatted(.dateTime.month(.wide).year()))",
                                           bodyHTML: AttExport.registerHTML(data, month: day, engine: engine), fileName: "Attendance register", module: "Attendance", icon: "person.badge.clock.fill", colors: [0x11998E, 0x38EF7D], charts: PDFCharts.attendance(data, month: day, engine: engine)) {
                    shareItems = ShareItems(items: [url])
                }
            }
        }
    }
}

// MARK: - Small pieces

struct AttTile: View {
    let value: String
    let label: String
    let icon: String
    let color: UInt32
    @Environment(\.look) private var look
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(Color(hex: color))
            Text(value).font(.headline.bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(look.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).lookCard(padding: 4)
    }
}

struct AttAction: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button { Haptics.tap(); action() } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(width: 68, height: 54)
        }
        .buttonStyle(.glass)
    }
}

struct AttLine: View {
    let icon: String
    let color: UInt32
    let title: String
    let detail: String
    let trailing: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white).frame(width: 32, height: 32)
                .background(Color(hex: color), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !trailing.isEmpty { Text(trailing).font(.caption.bold()).foregroundStyle(Color(hex: color)) }
        }
    }
}

struct AttStatusChip: View {
    let status: String
    var body: some View {
        Text(Att.code(status) == "·" ? "—" : Att.label(status))
            .font(.caption2.bold()).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color(hex: Att.color(status)), in: Capsule())
    }
}

struct AttMemberRow: View {
    let member: AttRecord
    let name: String
    let status: String
    let entry: AttRecord?
    var body: some View {
        let m = member.member
        HStack(spacing: 12) {
            AvatarView(name: name, imageData: m.photo, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name).font(.subheadline.weight(.semibold))
                    if member.status == "admin" { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
                    if !m.isUser { Image(systemName: "person.crop.square").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(AttFmt.times(entry?.entry) ?? [m.designation, m.department].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            AttStatusChip(status: status)
        }
    }
}

enum AttFmt {
    static func t(_ d: Date?) -> String { d?.formatted(date: .omitted, time: .shortened) ?? "—" }
    static func times(_ e: AttEntryData?) -> String? {
        guard let e, let i = e.inAt else { return nil }
        var s = "In \(t(i))"
        if let o = e.outAt { s += " · Out \(t(o)) · \(hours(Int(o.timeIntervalSince(i) / 60)))" }
        return s
    }
    static func hours(_ minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }
    static func leaveSpan(_ l: AttLeaveData) -> String {
        let f = l.from.formatted(.dateTime.day().month(.abbreviated))
        let to = l.to.formatted(.dateTime.day().month(.abbreviated))
        let days = l.halfDay ? "½ day" : "\(l.days.formatted()) day\(l.days == 1 ? "" : "s")"
        return "\(l.days > 1 ? f + " – " + to : f) · \(days) · \(l.paid ? "paid" : "unpaid")"
    }
    static func method(_ m: String) -> String {
        switch m {
        case "qr": "QR"
        case "photo": "Selfie"
        case "geo": "Location"
        case "kiosk": "Kiosk"
        case "edit": "Edited"
        default: "Manual"
        }
    }
}

/// Month calendar with a coloured code per day.
struct AttMonthGrid: View {
    let month: Date
    let status: (Date) -> String
    var onTap: ((Date) -> Void)? = nil
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        let days = Att.monthDays(month)
        let lead = ((days.first.map { Calendar.current.component(.weekday, from: $0) } ?? 1) - Calendar.current.firstWeekday + 7) % 7
        VStack(spacing: 6) {
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(Array(Calendar.current.veryShortStandaloneWeekdaySymbols.rotated(Calendar.current.firstWeekday - 1).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.bold()).foregroundStyle(.secondary)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 38) }
                ForEach(days, id: \.self) { d in cell(d) }
            }
        }
    }

    private func cell(_ d: Date) -> some View {
        let st = status(d)
        let known = Att.code(st) != "·"
        return Button { onTap?(d) } label: {
            VStack(spacing: 1) {
                Text("\(Calendar.current.component(.day, from: d))").font(.caption.weight(.semibold))
                Text(known ? Att.code(st) : " ").font(.system(size: 8, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .foregroundStyle(known ? .white : .primary)
            .background(known ? Color(hex: Att.color(st)) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay { if Calendar.current.isDateInToday(d) { RoundedRectangle(cornerRadius: 7).stroke(Color.primary, lineWidth: 1.5) } }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

extension Array {
    func rotated(_ n: Int) -> [Element] {
        guard !isEmpty else { return self }
        let k = ((n % count) + count) % count
        return Array(self[k...] + self[..<k])
    }
}

struct AttSummaryTiles: View {
    let s: Att.Summary
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                AttTile(value: "\(s.present)", label: "Present", icon: "checkmark.circle.fill", color: 0x34C759)
                AttTile(value: "\(s.n("late") + s.n("grace"))", label: "Late/grace", icon: "clock.fill", color: 0xFF9500)
                AttTile(value: "\(s.n("halfday"))", label: "Half days", icon: "circle.lefthalf.filled", color: 0xFFCC00)
            }
            HStack(spacing: 8) {
                AttTile(value: "\(s.n("absent"))", label: "Absent", icon: "xmark.circle.fill", color: 0xFF3B30)
                AttTile(value: "\(s.n("leave") + s.n("unpaid"))", label: "Leave", icon: "beach.umbrella.fill", color: 0x5856D6)
                AttTile(value: s.payable.formatted(), label: "Payable days", icon: "indianrupeesign.circle.fill", color: 0x007AFF)
            }
        }
    }
}

// MARK: - One member: calendar, entries, profile

struct AttMemberDetail: View {
    let companyID: String
    let memberID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]
    @State private var month = Date.now
    @State private var editDay: AttDay?
    @State private var editProfile = false
    @State private var leave = false
    @State private var confirmRemove = false
    @State private var shareItems: ShareItems?
    @Environment(\.dismiss) private var dismiss

    init(companyID: String, memberID: String) {
        self.companyID = companyID; self.memberID = memberID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        if let m = data.members.first(where: { $0.id == memberID }), let comp = data.company {
            content(data, m, comp)
        } else {
            ContentUnavailableView("Member removed", systemImage: "person.fill.xmark")
        }
    }

    private func content(_ data: AttData, _ m: AttRecord, _ comp: AttRecord) -> some View {
        let isOwner = data.c.ownerID == engine.me
        return List {
            AttProfileHeader(member: m, name: data.name(m, engine), company: data.c)
            Section {
                AttMonthPicker(month: $month)
                AttMonthGrid(month: month, status: { data.status(m, $0) }) { d in editDay = AttDay(date: d) }
                AttSummaryTiles(s: data.summary(m, month: month))
            }
            .listRowBackground(Color.clear)
            entriesSection(data, m)
            Section {
                Button("Edit profile", systemImage: "person.text.rectangle") { editProfile = true }
                Button("Record leave", systemImage: "beach.umbrella") { leave = true }
                if isOwner, m.member.isUser {
                    Button(m.status == "admin" ? "Remove as admin" : "Make admin", systemImage: "star") {
                        engine.attSetAdmin(company: comp, m, on: m.status != "admin")
                    }
                }
                if isOwner { Button("Remove member", systemImage: "person.fill.xmark", role: .destructive) { confirmRemove = true } }
            } footer: {
                Text(isOwner ? "Admins mark everyone's attendance and approve leaves. Changing an existing entry by an admin needs your approval."
                             : "Changes to existing entries go to the owner for approval.")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle(data.name(m, engine))
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Export (PDF)", systemImage: "doc.richtext") {
                    if let url = PDFMaker.make(title: "\(data.name(m, engine)) — \(month.formatted(.dateTime.month(.wide).year()))",
                                               bodyHTML: AttExport.memberHTML(data, m, month: month, engine: engine), fileName: "Attendance \(data.name(m, engine))", module: "Attendance", icon: "person.badge.clock.fill", colors: [0x11998E, 0x38EF7D], charts: PDFCharts.attendanceMember(data, m, month: month)) {
                        shareItems = ShareItems(items: [url])
                    }
                }
            }
        }
        .sheet(item: $editDay) { d in NavigationStack { AttEntryEditor(company: comp, member: m, day: d.date, existing: data.entry(m, d.date)) } }
        .sheet(isPresented: $editProfile) { NavigationStack { AttMemberEditor(company: comp, existing: m) } }
        .sheet(isPresented: $leave) { NavigationStack { AttLeaveEditor(company: comp, member: m, staff: true) } }
        .confirmationDialog("Remove \(data.name(m, engine))?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { engine.attRemoveMember(company: comp, m); dismiss() }
        } message: { Text("Their records stay in the archive and in your exports.") }
        .shareSheet($shareItems)
    }

    @ViewBuilder
    private func entriesSection(_ data: AttData, _ m: AttRecord) -> some View {
        let days = Att.monthDays(month).filter { $0 <= .now }.reversed()
        Section("Days — tap to edit") {
            ForEach(Array(days), id: \.self) { d in
                Button { editDay = AttDay(date: d) } label: {
                    AttDayRow(day: d, status: data.status(m, d), entry: data.entry(m, d), company: data.c)
                }
                .foregroundStyle(Color.primary)
            }
        }
        .lookRows()
    }
}

struct AttSt: Identifiable { let m: AttRecord; let s: String; var id: String { m.id } }

struct AttDay: Identifiable { let date: Date; var id: String { Att.key(date) } }

struct AttDayRow: View {
    let day: Date
    let status: String
    let entry: AttRecord?
    let company: AttCompanyData
    var body: some View {
        HStack(spacing: 10) {
            VStack {
                Text(day.formatted(.dateTime.day())).font(.headline)
                Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(AttFmt.times(entry?.entry) ?? Att.label(status)).font(.subheadline)
                if let e = entry?.entry { detail(e) }
            }
            Spacer(minLength: 0)
            if let p = entry?.entry.photoIn, let img = UIImage(data: p) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(Circle())
            }
            AttStatusChip(status: status)
        }
    }

    private func detail(_ e: AttEntryData) -> some View {
        var bits = [AttFmt.method(e.method)]
        if let dist = e.distance {
            bits.append(company.hasOffice && dist > company.radius ? "⚠️ \(Int(dist)) m from office" : "📍 \(Int(dist)) m")
        }
        if !e.qrIn.isEmpty, !company.qrSecret.isEmpty, let i = e.inAt {
            bits.append(Att.qrValid(e.qrIn, secret: company.qrSecret, at: i) ? "QR ✓" : "⚠️ QR not valid")
        }
        if !e.note.isEmpty { bits.append(e.note) }
        return Text(bits.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
    }
}

struct AttMonthPicker: View {
    @Binding var month: Date
    var body: some View {
        HStack {
            Button { month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            Button { month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDate(month, equalTo: .now, toGranularity: .month))
        }
        .buttonStyle(.glass)
    }
}

struct AttProfileHeader: View {
    let member: AttRecord
    let name: String
    let company: AttCompanyData
    @EnvironmentObject var engine: SyncEngine
    var body: some View {
        let m = member.member
        Section {
            HStack(spacing: 14) {
                AvatarView(name: name, imageData: m.photo, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.title3.bold())
                    Text([m.designation, m.department].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    Text(member.status == "admin" ? "Admin" : m.isUser ? (m.accepted == true ? "On iTeam" : m.accepted == false ? "Declined" : "Invitation sent") : "Not on iTeam")
                        .font(.caption.bold()).foregroundStyle(member.status == "admin" ? .orange : .secondary)
                }
            }
            LabeledContent("Duty", value: "\(Att.clock(Att.dutyStart(m, company))) – \(Att.clock(Att.dutyEnd(m, company)))")
            if !m.mobile.isEmpty { LabeledContent("Mobile", value: m.mobile) }
            if !m.email.isEmpty { LabeledContent("Email", value: m.email) }
            if let a = m.age { LabeledContent("Age", value: "\(a)") }
            if !m.sex.isEmpty { LabeledContent("Sex", value: m.sex) }
            ForEach(m.fields) { f in LabeledContent(f.label, value: f.value) }
        }
        .lookRows()
    }
}

// MARK: - Employee: my attendance

struct AttMyView: View {
    let companyID: String
    let memberID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]
    @State private var month = Date.now
    @State private var applyLeave = false
    @State private var punch = AttPunchFlow()

    init(companyID: String, memberID: String) {
        self.companyID = companyID; self.memberID = memberID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        if let m = data.members.first(where: { $0.id == memberID }), let comp = data.company {
            list(data, m, comp)
                .sheet(isPresented: $applyLeave) { NavigationStack { AttLeaveEditor(company: comp, member: m, staff: false) } }
                .modifier(AttPunchModifier(flow: $punch, company: comp, member: m))
        } else {
            ContentUnavailableView("Not found", systemImage: "person.fill.questionmark")
        }
    }

    private func list(_ data: AttData, _ m: AttRecord, _ comp: AttRecord) -> some View {
        List {
            if m.member.accepted == nil && m.member.isUser {
                invite(data, m)
            } else {
                today(data, m)
                Section {
                    AttMonthPicker(month: $month)
                    AttMonthGrid(month: month, status: { data.status(m, $0) })
                    AttSummaryTiles(s: data.summary(m, month: month))
                }
                .listRowBackground(Color.clear)
                leaves(data, m)
                holidays(data)
            }
        }
        .lookScreen()
        .navigationTitle(data.c.name)
        .refreshable { await engine.sync() }
        .toolbar {
            if m.member.accepted == true {
                ToolbarItem(placement: .primaryAction) { Button("Apply leave", systemImage: "beach.umbrella") { applyLeave = true } }
            }
        }
    }

    private func invite(_ data: AttData, _ m: AttRecord) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("\(engine.name(of: data.c.ownerID)) added you to “\(data.c.name)” attendance", systemImage: "building.2.fill").font(.headline)
                Text("You'll punch in and out here, apply for leave and see your own record. Only you, the owner and the admins see your attendance.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Accept") { engine.attAnswerInvite(m, accept: true) }.buttonStyle(.glassProminent)
                    Button("Decline", role: .destructive) { engine.attAnswerInvite(m, accept: false) }.buttonStyle(.glass)
                }
            }
            .padding(.vertical, 6)
        }
        .lookRows()
    }

    private func today(_ data: AttData, _ m: AttRecord) -> some View {
        let e = data.entry(m, .now)
        let st = data.status(m, .now)
        let md = m.member
        return Section {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Date.now.formatted(date: .complete, time: .omitted)).font(.subheadline.weight(.semibold))
                        Text("Duty \(Att.clock(Att.dutyStart(md, data.c))) – \(Att.clock(Att.dutyEnd(md, data.c))) · grace \(data.c.grace) min")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    AttStatusChip(status: st)
                }
                Text(AttFmt.times(e?.entry) ?? "Not punched in yet").font(.title3.bold())
                if data.c.selfPunch && md.canPunch {
                    let done = e?.entry.outAt != nil
                    Button {
                        punch.start(e?.entry.inAt == nil ? "in" : "out")
                    } label: {
                        Label(done ? "Done for today" : (e?.entry.inAt == nil ? "Punch in" : "Punch out"),
                              systemImage: e?.entry.inAt == nil ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(done || ["holiday", "leave", "unpaid"].contains(st) && e == nil)
                    Text(AttPunchFlow.needs(data.c)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Your attendance is marked by the kiosk or your manager.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        .lookRows()
    }

    @ViewBuilder
    private func leaves(_ data: AttData, _ m: AttRecord) -> some View {
        let mine = data.leaves.filter { $0.memberID == m.id }
        Section("My leaves") {
            if mine.isEmpty { Text("No leave applications yet.").foregroundStyle(.secondary) }
            ForEach(mine) { l in
                NavigationLink { AttLeaveDetail(leaveID: l.id, companyID: companyID) } label: {
                    AttLine(icon: "beach.umbrella.fill", color: l.status == "approved" ? 0x34C759 : l.status == "rejected" ? 0xFF3B30 : 0xFF9500,
                            title: "\(l.leave.type) leave", detail: AttFmt.leaveSpan(l.leave), trailing: l.status.capitalized)
                }
            }
        }
        .lookRows()
    }

    @ViewBuilder
    private func holidays(_ data: AttData) -> some View {
        let upcoming = data.holidays.filter { $0.status == "approved" && Att.date($0.day) >= Calendar.current.startOfDay(for: .now) }
        if !upcoming.isEmpty {
            Section("Upcoming holidays") {
                ForEach(upcoming.prefix(8)) { h in
                    LabeledContent(h.holiday.name, value: Att.date(h.day).formatted(date: .abbreviated, time: .omitted))
                }
            }
            .lookRows()
        }
    }
}

// MARK: - Editors

struct AttMemberEditor: View {
    let company: AttRecord
    let existing: AttRecord?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var d = AttMemberData()
    @State private var onITeam = false
    @State private var pin = ""
    @State private var ageText = ""
    @State private var ownTimes = false
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var photoPick: PhotosPickerItem?
    @State private var loaded = false

    var body: some View {
        Form {
            if existing == nil {
                Section {
                    Picker("Who", selection: $onITeam) { Text("Not on iTeam").tag(false); Text("iTeam contact").tag(true) }.pickerStyle(.segmented)
                    if onITeam {
                        Picker("Contact", selection: $d.userID) {
                            Text("Choose…").tag("")
                            ForEach(contacts, id: \.userID) { c in Text(c.name).tag(c.userID) }
                        }
                    }
                } footer: {
                    Text(onITeam ? "They get an invitation; once they accept they punch in on their own phone and see only their own attendance."
                                 : "People without iTeam are marked by the kiosk, the owner or an admin.")
                }
            }
            Section("Profile") {
                HStack {
                    AvatarView(name: d.name.isEmpty ? "?" : d.name, imageData: d.photo, size: 56)
                    PhotosPicker(selection: $photoPick, matching: .images) { Label(d.photo == nil ? "Add photo" : "Change photo", systemImage: "camera") }
                    Button { Presenter.camera(front: true) { img in d.photo = img.jpegData(compressionQuality: 0.9).flatMap { ImageShrink.jpeg($0, side: 240) } } } label: {
                        Image(systemName: "camera.fill")
                    }
                    .buttonStyle(.borderless)
                }
                TextField("First name", text: $d.first)
                TextField("Last name", text: $d.last)
                TextField("Age", text: $ageText).keyboardType(.numberPad)
                Picker("Sex", selection: $d.sex) { Text("—").tag(""); Text("Male").tag("Male"); Text("Female").tag("Female"); Text("Other").tag("Other") }
                TextField("Department", text: $d.department)
                TextField("Designation", text: $d.designation)
                TextField("Mobile", text: $d.mobile).keyboardType(.phonePad)
                TextField("Email", text: $d.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
            }
            Section("Custom fields") {
                ForEach($d.fields) { $f in
                    HStack {
                        TextField("Label", text: $f.label).frame(maxWidth: 120)
                        TextField("Value", text: $f.value)
                    }
                }
                .onDelete { d.fields.remove(atOffsets: $0) }
                Button("Add field", systemImage: "plus") { d.fields.append(AttField(label: "", value: "")) }
            }
            Section {
                Toggle("Own duty timings", isOn: $ownTimes)
                if ownTimes {
                    DatePicker("Duty starts", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("Duty ends", selection: $end, displayedComponents: .hourAndMinute)
                }
                SecureField(d.pinHash.isEmpty ? "Kiosk PIN (optional, 4–6 digits)" : "New kiosk PIN (leave empty to keep)", text: $pin).keyboardType(.numberPad)
                Toggle("Active", isOn: $d.active)
            } header: { Text("Timings & kiosk") } footer: {
                Text("Company duty: \(Att.clock(company.company.dutyStart)) – \(Att.clock(company.company.dutyEnd)). Inactive members are kept but not counted.")
            }
        }
        .navigationTitle(existing == nil ? "Add member" : "Edit member")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
        }
        .onChange(of: d.userID) { _, id in
            if let c = contacts.first(where: { $0.userID == id }), d.first.isEmpty {
                let parts = c.name.split(separator: " ", maxSplits: 1).map(String.init)
                d.first = parts.first ?? ""; d.last = parts.count > 1 ? parts[1] : ""
                if d.photo == nil, let a = c.avatar { d.photo = ImageShrink.jpeg(a, side: 240) }
            }
        }
        .onChange(of: photoPick) { _, item in
            Task { if let data = try? await item?.loadTransferable(type: Data.self) { d.photo = ImageShrink.jpeg(data, side: 240) } }
        }
        .onAppear(perform: load)
    }

    private var valid: Bool { !(d.first.trimmingCharacters(in: .whitespaces).isEmpty) && (!onITeam || !d.userID.isEmpty) }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let c = company.company
        if let existing {
            d = existing.member
            onITeam = d.isUser
            ageText = d.age.map(String.init) ?? ""
            ownTimes = d.dutyStart != nil
        }
        start = Att.at(d.dutyStart ?? c.dutyStart, on: .now)
        end = Att.at(d.dutyEnd ?? c.dutyEnd, on: .now)
    }

    private func save() {
        if !onITeam { d.userID = existing?.member.userID ?? "" }
        d.age = Int(ageText)
        d.dutyStart = ownTimes ? Att.minutes(start) : nil
        d.dutyEnd = ownTimes ? Att.minutes(end) : nil
        if !pin.isEmpty { d.pinHash = AttMemberData.hashPIN(pin) }
        d.fields = d.fields.filter { !$0.label.isEmpty || !$0.value.isEmpty }
        engine.attSaveMember(company: company, existing: existing, d)
        Haptics.success()
        dismiss()
    }
}

struct AttEntryEditor: View {
    let company: AttRecord
    let member: AttRecord
    let day: Date
    let existing: AttRecord?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var hasIn = false
    @State private var hasOut = false
    @State private var inAt = Date.now
    @State private var outAt = Date.now
    @State private var status = ""
    @State private var note = ""
    @State private var reason = ""
    @State private var loaded = false

    private var isOwner: Bool { company.company.ownerID == engine.me }
    private var needsApproval: Bool { !isOwner && existing != nil }

    var body: some View {
        Form {
            Section(day.formatted(date: .complete, time: .omitted)) {
                Toggle("Punched in", isOn: $hasIn)
                if hasIn { DatePicker("In", selection: $inAt, displayedComponents: .hourAndMinute) }
                Toggle("Punched out", isOn: $hasOut).disabled(!hasIn)
                if hasOut && hasIn { DatePicker("Out", selection: $outAt, displayedComponents: .hourAndMinute) }
                Picker("Status", selection: $status) {
                    Text("Automatic (from punch-in time)").tag("")
                    ForEach(Att.statuses, id: \.self) { s in Text(Att.label(s)).tag(s) }
                }
                TextField("Note", text: $note)
            }
            if needsApproval {
                Section {
                    TextField("Reason for the change", text: $reason, axis: .vertical)
                } footer: { Text("Changing an existing entry needs the owner's approval. It applies once approved.") }
            }
            if existing != nil {
                Section {
                    Button(needsApproval ? "Ask to delete this entry" : "Delete entry", role: .destructive) { save(delete: true) }
                } footer: { Text("Deleted entries stay in the archive.") }
            }
        }
        .navigationTitle(member.member.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(needsApproval ? "Send for approval" : "Save") { save(delete: false) }
                    .disabled(needsApproval && reason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let m = member.member, c = company.company
            inAt = Att.at(Att.dutyStart(m, c), on: day); outAt = Att.at(Att.dutyEnd(m, c), on: day)
            if let e = existing {
                status = e.status; note = e.entry.note
                if let i = e.entry.inAt { hasIn = true; inAt = i }
                if let o = e.entry.outAt { hasOut = true; outAt = o }
            }
        }
    }

    private func save(delete: Bool) {
        var d = existing?.entry ?? AttEntryData()
        d.inAt = hasIn ? Att.at(Att.minutes(inAt), on: day) : nil
        d.outAt = hasIn && hasOut ? Att.at(Att.minutes(outAt), on: day) : nil
        d.note = note
        if existing == nil { d.method = "edit" }
        engine.attSaveEntry(company: company, member: member, existing: existing, day: day, data: d, status: status, delete: delete, reason: reason)
        Haptics.success()
        dismiss()
    }
}

/// Owner/admin marks someone now (or picks a status) without the kiosk.
struct AttMarkSheet: View {
    let company: AttRecord
    let data: AttData
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var done: [String: String] = [:]

    var body: some View {
        List {
            Section {
                ForEach(data.active.filter { $0.member.canPunch }) { m in
                    let e = data.entry(m, .now)
                    HStack {
                        AttMemberRow(member: m, name: data.name(m, engine), status: data.status(m, .now), entry: e)
                        if e?.entry.outAt == nil {
                            Button(done[m.id] ?? (e?.entry.inAt == nil ? "In" : "Out")) {
                                let r = engine.attPunch(m, company: company, method: "manual")
                                done[m.id] = r == "in" ? "✓ In" : "✓ Out"
                                Haptics.success()
                            }
                            .buttonStyle(.glassProminent).controlSize(.small)
                        }
                    }
                }
            } footer: { Text("Marks the current time. To set another time or status, open the member and tap the day.") }
        }
        .navigationTitle("Mark attendance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
