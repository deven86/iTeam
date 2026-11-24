import SwiftUI
import SwiftData
import PhotosUI

/// iLife Care tab: everyone you look after (or who looks after you), today's medicines, recent health events.
struct CareHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @ObservedObject private var store = Store.shared
    @Environment(\.look) private var look
    @Query(filter: #Predicate<CareProfile> { !$0.deleted }, sort: \CareProfile.name) private var profiles: [CareProfile]
    @Query(filter: #Predicate<Medicine> { $0.active && !$0.deleted }) private var meds: [Medicine]
    @Query private var logs: [DoseLog]
    @Query(filter: #Predicate<BizRecord> { $0.kind == "vaccine" && $0.status == "Due" && !$0.deleted }) private var vaccines: [BizRecord]
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showPaywall = false

    private var upcomingVaccines: [BizRecord] {
        let limit = Date.now.addingTimeInterval(60 * 86400)
        return vaccines.filter { ($0.due ?? .distantFuture) < limit }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(12).map { $0 }
    }
    private func parentName(_ v: BizRecord) -> String {
        let pid = v.parentID
        return (try? engine.context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == pid })).first)?.title ?? ""
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if profiles.isEmpty {
                    Section {
                        VStack(spacing: 14) {
                            EmptyStateView(icon: "heart.text.square", title: "iLife Care",
                                           message: "Track medicines, injuries, major health events and recovery for someone you care for — together with family or your team. Everyone in the chat gets the alerts.")
                            Button { startNew() } label: { Label("Create a care profile", systemImage: "plus") }
                                .buttonStyle(.glassProminent).controlSize(.large)
                            Button("Try a demo care profile") {
                                if let id = DemoCare.create(engine) { path = [id] }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                    CarePrescriptionsSection()
                } else {
                    Section { todayCard.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                    CarePrescriptionsSection()
                    Section("People") {
                        ForEach(profiles.filter { $0.relation != "Pet" }) { p in
                            NavigationLink(value: p.id) { profileRow(p) }
                        }
                    }
                    .lookRows()
                    if !upcomingVaccines.isEmpty {
                        Section {
                            ForEach(upcomingVaccines) { v in
                                Button { router.openItem = Router.OpenItem(kind: "biz", module: v.module, id: v.parentID) } label: {
                                    HStack {
                                        Image(systemName: "syringe").foregroundStyle(look.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(v.title).font(.subheadline).lineLimit(2)
                                            Text("\(parentName(v)) · \(v.due?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                                                .font(.caption).foregroundStyle((v.due ?? .distantFuture) < .now ? look.danger : look.textSecondary)
                                        }
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        } header: { Text("Vaccinations due") } footer: { Text("From Kids and Pet Care, for the next 60 days.") }
                        .lookRows()
                    }
                    Section {
                        ForEach(profiles.filter { $0.relation == "Pet" }) { p in
                            NavigationLink(value: p.id) { profileRow(p) }
                        }
                        Button { newPet = true; showNew = true } label: { Label("Add a pet", systemImage: "pawprint.fill") }
                    } header: { Text("Pets") } footer: {
                        Text("Medicines, feeding and vaccinations for pets, with reminders for everyone you share with. Pets added in Pet Care appear here automatically.")
                    }
                    .lookRows()
                }
            }
            .listStyle(.insetGrouped)
            .lookScreen()
            .navigationTitle("iLife Care")
            .navigationDestination(for: String.self) { CareProfileView(profileID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startNew() } label: { Image(systemName: "plus") }.accessibilityLabel("New care profile")
                }
            }
            .refreshable { await engine.sync() }
            .sheet(isPresented: $showNew, onDismiss: { newPet = false }) { NavigationStack { CareProfileEditor(profile: nil, presetRelation: newPet ? "Pet" : "") { id in path = [id] } } }
            .sheet(isPresented: $showPaywall) { CarePaywall() }
            .onChange(of: router.openCare) { _, id in
                guard let id else { return }
                path = [id]
                router.openCare = nil
            }
            .onAppear { if let id = router.openCare { path = [id]; router.openCare = nil } }
        }
    }

    @State private var newPet = false

    private func startNew() {
        showNew = true   // Care is free for everyone
    }

    private var dueToday: [(Medicine, Date, CareProfile)] {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let done = Set(logs.map(\.id))
        return meds.flatMap { m in
            m.schedule(on: .now).compactMap { t -> (Medicine, Date, CareProfile)? in
                guard let p = byID[m.profileID], !done.contains(DoseLog.key(m.id, t)) else { return nil }
                return (m, t, p)
            }
        }
        .sorted { $0.1 < $1.1 }
    }

    private var todayCard: some View {
        let pending = dueToday
        let late = pending.filter { $0.1 < .now }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "pills.fill").foregroundStyle(look.accent)
                Text("Today's medicines").font(.headline)
                Spacer()
                if !late.isEmpty { Chip(text: "\(late.count) due", icon: "exclamationmark.circle.fill", color: look.danger) }
            }
            if pending.isEmpty {
                Text("All doses for today are marked. 🎉").font(.subheadline).foregroundStyle(look.textSecondary)
            }
            ForEach(Array(pending.prefix(6).enumerated()), id: \.offset) { _, item in
                DoseRow(med: item.0, profile: item.2, time: item.1, showName: true)
            }
        }
        .lookCard()
        .padding(.vertical, 4)
    }

    private func profileRow(_ p: CareProfile) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: p.name, imageData: p.avatar, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.headline)
                Text([p.relation, engine.conversation(p.convID)?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(look.textSecondary)
            }
        }
    }
}

/// One scheduled dose with Taken / Skip.
struct DoseRow: View {
    let med: Medicine
    let profile: CareProfile
    let time: Date
    var showName = false
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var log: [DoseLog]
    @State private var askSkip = false
    @State private var note = ""

    init(med: Medicine, profile: CareProfile, time: Date, showName: Bool = false) {
        self.med = med
        self.profile = profile
        self.time = time
        self.showName = showName
        let key = DoseLog.key(med.id, time)
        _log = Query(filter: #Predicate<DoseLog> { $0.id == key })
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(time.formatted(date: .omitted, time: .shortened)) · \(med.name) \(med.dose)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(time < .now && log.isEmpty ? look.danger : Color.primary)
                Text([showName ? profile.name : nil, med.instructions.isEmpty ? nil : med.instructions].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer(minLength: 0)
            if let l = log.first {
                Label(l.status == "taken" ? "Taken" : "Skipped", systemImage: l.status == "taken" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(l.status == "taken" ? look.success : look.warning)
                Text(engine.name(of: l.by)).font(.caption2).foregroundStyle(look.textSecondary)
            } else {
                Button("Skip") { askSkip = true }.buttonStyle(.bordered).controlSize(.small)
                Button("Taken") {
                    Haptics.success()
                    engine.logDose(med, profile: profile, scheduled: time, taken: true)
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(look.success)
            }
        }
        .alert("Skip this dose?", isPresented: $askSkip) {
            TextField("Reason (optional)", text: $note)
            Button("Skip", role: .destructive) { engine.logDose(med, profile: profile, scheduled: time, taken: false, note: note); note = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in “\(engine.conversation(profile.convID)?.title ?? "the chat")” gets an alert.")
        }
    }
}

// MARK: - Profile

struct CareProfileView: View {
    let profileID: String
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [CareProfile]
    @Query private var meds: [Medicine]
    @Query private var events: [HealthEvent]
    @Query private var vault: [VaultItem]
    @State private var editProfile = false
    @State private var editMed: Medicine?
    @State private var addMed = false
    @State private var editEvent: HealthEvent?
    @State private var addEvent = false
    @State private var newKind = HealthEventKind.injury
    @State private var addVault = false
    @State private var preview: URL?
    @State private var remindMe = true
    @State private var confirmDelete = false

    init(profileID: String) {
        self.profileID = profileID
        _found = Query(filter: #Predicate<CareProfile> { $0.id == profileID })
        _meds = Query(filter: #Predicate<Medicine> { $0.profileID == profileID && !$0.deleted }, sort: \Medicine.name)
        _events = Query(filter: #Predicate<HealthEvent> { $0.profileID == profileID && !$0.deleted }, sort: \HealthEvent.date, order: .reverse)
        _vault = Query(filter: #Predicate<VaultItem> { $0.profileID == profileID && !$0.deleted }, sort: \VaultItem.date, order: .reverse)
    }

    var body: some View {
        if let p = found.first, !p.deleted {
            content(p)
        } else {
            EmptyStateView(icon: "heart.text.square", title: "Not found", message: "This care profile was removed.")
        }
    }

    private func content(_ p: CareProfile) -> some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AvatarView(name: p.name, imageData: p.avatar, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name).font(.title2.bold())
                        if !p.relation.isEmpty { Text(p.relation).foregroundStyle(look.textSecondary) }
                        Text(p.createdBy == engine.me ? "Managed by you" : "Managed by \(engine.name(of: p.createdBy))")
                            .font(.caption2).foregroundStyle(look.textSecondary)
                        if p.linkedUserID == engine.me {
                            Label("This is your profile", systemImage: "person.crop.circle.badge.checkmark").font(.caption2).foregroundStyle(look.success)
                        } else if !p.linkedUserID.isEmpty {
                            Label("On iTeam: \(engine.name(of: p.linkedUserID))", systemImage: "checkmark.seal.fill").font(.caption2).foregroundStyle(look.success)
                        }
                        if let conv = engine.conversation(p.convID) {
                            Button { router.show(conversation: conv.id) } label: {
                                Label("Shared in \(conv.title)", systemImage: conv.isGroup ? "person.3" : "bubble.left").font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(look.accent)
                        }
                    }
                }
                .padding(.vertical, 6)
                Toggle("Remind me for doses", isOn: $remindMe)
                    .onChange(of: remindMe) { _, on in
                        var off = Set(UserDefaults.standard.stringArray(forKey: "care.remindOff") ?? [])
                        if on { off.remove(p.id) } else { off.insert(p.id) }
                        UserDefaults.standard.set(Array(off), forKey: "care.remindOff")
                        Reminders.shared.reschedule(context: engine.context, me: engine.me)
                    }
            }
            .lookRows()

            Section { medicalCard.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }

            let todays = meds.flatMap { m in m.schedule(on: .now).map { (m, $0) } }.sorted { $0.1 < $1.1 }
            if !todays.isEmpty {
                Section("Today") {
                    ForEach(Array(todays.enumerated()), id: \.offset) { _, item in DoseRow(med: item.0, profile: p, time: item.1) }
                }
                .lookRows()
            }

            Section {
                ForEach(meds) { m in
                    Button { editMed = m } label: {
                        HStack {
                            if let d = m.extra.photo, let img = UIImage(data: d) {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Image(systemName: "pills.fill").foregroundStyle(m.active ? look.accent : look.textSecondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(m.name) \(m.extra.strength.isEmpty ? m.dose : m.extra.strength)").font(.subheadline.weight(.semibold)).strikethrough(!m.active)
                                Text(m.times.map(Medicine.timeLabel).joined(separator: ", ") + (m.instructions.isEmpty ? "" : " · \(m.instructions)"))
                                    .font(.caption).foregroundStyle(look.textSecondary)
                            }
                            Spacer()
                            if let s = m.stock { Chip(text: "\(s) left", color: s <= 5 ? look.danger : look.textSecondary) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button { addMed = true } label: { Label("Add medicine", systemImage: "plus.circle") }
            } header: { Text("Medicines") }
            .lookRows()

            Section {
                ForEach(events.filter(\.isInjury)) { ev in
                    Button { editEvent = ev } label: { eventRow(ev) }.buttonStyle(.plain)
                }
                Button { newKind = .injury; addEvent = true } label: { Label("Log injury", systemImage: "plus.circle") }
            } header: { Text("Injuries") }
            .lookRows()

            Section {
                ForEach(events.filter { !$0.isInjury }) { ev in
                    Button { editEvent = ev } label: { eventRow(ev) }.buttonStyle(.plain)
                }
                Button { newKind = .illness; addEvent = true } label: { Label("Add health event", systemImage: "plus.circle") }
            } header: { Text("Major health events") } footer: { Text("Illness, surgery, hospital stays and emergencies — with diagnosis, doctor, hospital and follow-up.") }
            .lookRows()

            Section {
                if !vault.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(vault) { v in
                            VStack(spacing: 4) {
                                if let ref = v.attachment { AttachmentThumb(ref: ref, size: 90) }
                                Text(v.title).font(.caption2.weight(.medium)).lineLimit(1)
                                Text(VaultCategory(rawValue: v.category)?.title ?? v.category).font(.caption2).foregroundStyle(look.textSecondary)
                            }
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) { engine.removeVaultItem(v) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Button { addVault = true } label: { Label("Add report, prescription or scan", systemImage: "plus.circle") }
            } header: { Text("Medical vault") }
            .lookRows()

            Section {
                info("Blood group", p.bloodGroup, "drop.fill")
                info("Allergies", p.allergies, "allergens")
                info("Conditions", p.conditions, "heart.text.square")
                info("Emergency contact", p.emergencyContact, "phone.fill")
                if !p.notes.isEmpty { info("Notes", p.notes, "note.text") }
                Button("Edit medical info") { editProfile = true }
            } header: { Text("Medical info") }
            .lookRows()

            if AISettings.shared.allows(.care) {
                Section {
                    AIButton(title: "AI health summary", feature: .care,
                             instructions: "Summarise this person's health record for the family: current medicines and timings, recent events and recovery, anything to watch or ask the doctor. You are not a doctor: do not diagnose or change doses; suggest consulting the doctor where relevant.",
                             context: { ShareText.care(p, meds: meds, events: events) })
                }
                .lookRows()
            }
            CareOKSection(profile: p).lookRows()
            DocumentsSection(module: "care", recordID: p.id, recordOwner: p.createdBy, convID: p.convID, title: p.name).lookRows()
            if p.createdBy == engine.me {
                Section {
                    Button("Delete care profile", role: .destructive) { confirmDelete = true }
                }
                .lookRows()
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle(p.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareMenu(title: "Health summary – \(p.name)",
                          text: { ShareText.care(p, meds: meds, events: events) },
                          html: { ShareText.careHTML(p, meds: meds, events: events) },
                          module: "iLife Care", icon: "heart.text.square.fill", colors: [0xFF8A5B, 0xE5486B],
                          charts: { PDFCharts.care(meds: meds, events: events) })
                    .labelStyle(.iconOnly)
            }
        }
        .onAppear { remindMe = !(UserDefaults.standard.stringArray(forKey: "care.remindOff") ?? []).contains(p.id) }
        .sheet(isPresented: $editProfile) { NavigationStack { CareProfileEditor(profile: p) { _ in } } }
        .sheet(isPresented: $addMed) { NavigationStack { MedicineEditor(profile: p, med: nil) } }
        .sheet(item: $editMed) { m in NavigationStack { MedicineEditor(profile: p, med: m) } }
        .sheet(isPresented: $addEvent) { NavigationStack { HealthEventEditor(profile: p, event: nil, presetKind: newKind) } }
        .sheet(item: $editEvent) { ev in NavigationStack { HealthEventEditor(profile: p, event: ev) } }
        .sheet(isPresented: $addVault) { NavigationStack { VaultAddView(profile: p) } }
        .confirmationDialog("Delete \(p.name)'s care profile for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let conv = engine.conversation(p.convID) {
                    engine.saveCareProfile(in: conv, id: p.id, name: p.name, relation: p.relation, bloodGroup: p.bloodGroup,
                                           allergies: p.allergies, conditions: p.conditions, emergencyContact: p.emergencyContact,
                                           notes: p.notes, avatar: nil, deleted: true)
                }
                dismiss()
            }
        }
    }

    private var billsTotal: Double {
        events.reduce(0) { $0 + $1.extra.bill } + meds.filter { !$0.deleted }.reduce(0) { $0 + $1.extra.bill }
    }

    private var medicalCard: some View {
        let current = meds.filter { $0.active && ($0.endDate.map { $0 >= Calendar.current.startOfDay(for: .now) } ?? true) }.count
        let healing = events.filter { $0.isInjury && $0.status != "recovered" }.count
        let major = events.filter { !$0.isInjury }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Medical").font(.title3.bold())
                Spacer()
                if billsTotal > 0 { Text("Bills ₹\(Int(billsTotal).formatted())").font(.subheadline).foregroundStyle(look.textSecondary) }
            }
            medRow("cross.case.fill", [.red.opacity(0.8), .pink], "Medicines", "\(current) current")
            medRow("bandage.fill", [.orange, .orange.opacity(0.7)], "Injuries", "\(healing) healing")
            medRow("heart.text.square.fill", [.purple, .pink], "Major health events", "\(major) recorded")
        }
        .lookCard()
        .padding(.vertical, 4)
    }

    private func medRow(_ icon: String, _ colors: [Color], _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.headline).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(look.textSecondary)
        }
    }

    private func info(_ label: String, _ value: String, _ icon: String) -> some View {
        LabeledContent {
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        } label: {
            Label(label, systemImage: icon)
        }
    }

    private func eventRow(_ ev: HealthEvent) -> some View {
        let k = ev.kindValue
        let color: Color = ev.status == "recovered" ? look.success : (ev.severity >= 3 ? look.danger : look.warning)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: k.icon).foregroundStyle(color)
                .frame(width: 36, height: 36).background(color.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(ev.title).font(.subheadline.weight(.semibold))
                Text("\(k.title) · \(ev.date.formatted(date: .abbreviated, time: .omitted)) · \(ev.status.capitalized)")
                    .font(.caption).foregroundStyle(look.textSecondary)
                if ev.status != "recovered" {
                    ProgressView(value: Double(ev.recovery), total: 100).tint(color)
                    Text("\(ev.recovery)% recovered").font(.caption2).foregroundStyle(look.textSecondary)
                }
                let x = ev.extra
                let facts = [x.bodyPart, x.treatments.prefix(3).joined(separator: ", "), x.doctor.isEmpty ? "" : "Dr. " + x.doctor,
                             x.hospital, x.hospitalised ? "Hospitalised" : "", x.restrictions].filter { !$0.isEmpty }
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.caption2).foregroundStyle(look.textSecondary).lineLimit(2) }
                if let f = x.followUp, f > .now {
                    Label("Follow-up \(f.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar.badge.clock").font(.caption2).foregroundStyle(look.accent)
                }
                if let last = ev.updates.last {
                    Text("“\(last.text)” — \(engine.name(of: last.by))").font(.caption2).italic().foregroundStyle(look.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editors

struct CareProfileEditor: View {
    let profile: CareProfile?
    var presetRelation: String = ""
    var onSaved: (String) -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(sort: \Conversation.lastActivity, order: .reverse) private var conversations: [Conversation]
    @State private var chatID = ""
    @State private var name = ""
    @State private var relation = ""
    @State private var bloodGroup = ""
    @State private var allergies = ""
    @State private var conditions = ""
    @State private var emergency = ""
    @State private var notes = ""
    @State private var avatar: Data?
    @State private var photo: PhotosPickerItem?
    @State private var linkTo = ""
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]

    private let bloodGroups = ["", "A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        AvatarView(name: name.isEmpty ? "?" : name, imageData: avatar, size: 64)
                    }
                    TextField("Name (e.g. Mom)", text: $name).font(.title3)
                }
                RelationPicker(relation: $relation)
            }
            .lookRows()
            if presetRelation != "Pet" && relation != "Pet" {
                Section {
                    Picker("Pick an iTeam user", selection: $linkTo) {
                        Text("Not on iTeam / later").tag("")
                        ForEach(contacts.filter { !$0.userID.hasPrefix("demo_") && $0.userID != engine.me }, id: \.userID) { c in Text(c.name).tag(c.userID) }
                    }
                    .onChange(of: linkTo) { _, id in
                        guard let c = contacts.first(where: { $0.userID == id }) else { return }
                        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = c.name }
                        if avatar == nil { avatar = c.avatar }
                        if profile == nil { chatID = SyncEngine.directID(engine.me, c.userID) }
                    }
                } header: { Text("Family member on iTeam") } footer: {
                    Text(linkTo.isEmpty ? "Link them to share their medicines, injuries and reports with them — they get reminders and can mark doses themselves."
                         : "Shared in your chat with \(contacts.first { $0.userID == linkTo }?.name ?? "them"). They see and update it, and get the alerts.")
                }
                .lookRows()
            }
            if profile == nil {
                Section {
                    Picker("Share in", selection: $chatID) {
                        Text("Only me (Notes to self)").tag("")
                        if !linkTo.isEmpty, conversations.first(where: { $0.id == SyncEngine.directID(engine.me, linkTo) }) == nil {
                            Text("Chat with \(contacts.first { $0.userID == linkTo }?.name ?? "them")").tag(SyncEngine.directID(engine.me, linkTo))
                        }
                        ForEach(conversations.filter { !$0.left && !$0.id.hasPrefix("s_") }) { c in Text(c.title).tag(c.id) }
                    }
                } header: {
                    Text("Who can see and update it")
                } footer: {
                    Text("Pick a family or team group. Everyone in it can mark doses, log injuries and add reports, and gets the alerts. Only you need the subscription.")
                }
                .lookRows()
            }
            Section("Medical info") {
                Picker("Blood group", selection: $bloodGroup) { ForEach(bloodGroups, id: \.self) { Text($0.isEmpty ? "Not set" : $0).tag($0) } }
                TextField("Allergies", text: $allergies, axis: .vertical)
                TextField("Conditions (e.g. Diabetes, BP)", text: $conditions, axis: .vertical)
                TextField("Emergency contact (name & phone)", text: $emergency)
                TextField("Notes (doctor, hospital…)", text: $notes, axis: .vertical)
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle(profile == nil ? "New care profile" : "Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let linked = contacts.first { $0.userID == linkTo }
                    var conv = profile.flatMap { engine.conversation($0.convID) }
                        ?? (chatID.isEmpty ? DemoChats.notesToSelf(engine)
                            : (engine.conversation(chatID) ?? (chatID == linked.map { SyncEngine.directID(engine.me, $0.userID) } ? linked.map { engine.directConversation(with: $0) } : nil)))
                    // Linking a profile that was only on my phone: move it (and its history) into the chat with that person.
                    if let p = profile, let linked, p.linkedUserID != linked.userID, let cur = conv, cur.id == engine.selfConversationID {
                        let target = engine.directConversation(with: linked)
                        engine.moveCareProfile(p, to: target)
                        conv = target
                    }
                    guard let conv else { return }
                    let id = engine.saveCareProfile(in: conv, id: profile?.id, name: name.trimmingCharacters(in: .whitespaces), relation: relation,
                                                    bloodGroup: bloodGroup, allergies: allergies, conditions: conditions,
                                                    emergencyContact: emergency, notes: notes, avatar: avatar,
                                                    linkedUserID: linkTo.isEmpty ? (profile?.linkedUserID.isEmpty == false ? "" : nil) : linkTo)
                    Haptics.success()
                    dismiss()
                    onSaved(id)
                }
                .bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if profile == nil && !presetRelation.isEmpty && relation.isEmpty { relation = presetRelation }
            guard let p = profile else { return }
            name = p.name; relation = p.relation; bloodGroup = p.bloodGroup; allergies = p.allergies
            conditions = p.conditions; emergency = p.emergencyContact; notes = p.notes; avatar = p.avatar
            linkTo = p.linkedUserID
        }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = OnboardingView.avatarData(d) } }
        }
    }
}

struct MedicineEditor: View {
    let profile: CareProfile
    let med: Medicine?
    var linkedEventID: String = ""
    var presetCause: String = ""
    @EnvironmentObject var engine: SyncEngine
    @State private var mx = MedExtra()
    @State private var medPhoto: PhotosPickerItem?
    @State private var courseDays = 7
    @State private var billText = ""
    @Query private var profileEvents: [HealthEvent]
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var dose = ""
    @State private var form = "Tablet"
    @State private var times: [Date] = []
    @State private var instructions = "After food"
    @State private var start = Date.now
    @State private var hasEnd = false
    @State private var end = Date.now.addingTimeInterval(7 * 86400)
    @State private var stockText = ""
    @State private var active = true

    private let forms = ["Tablet", "Capsule", "Syrup", "Injection", "Drops", "Inhaler", "Ointment", "Other"]
    private let presets: [(String, Int)] = [("Morning 9:00", 540), ("Afternoon 2:00", 840), ("Night 9:00", 1260)]

    private var scanSpec: ScanSpec {
        ScanSpec(title: "Scan the prescription or medicine strip", what: "a doctor's prescription or a medicine strip/box",
                 fields: [.text("name", "Medicine name (brand and strength)"), .text("dose", "Dose (e.g. 1 tablet, 5 ml)"),
                          .choice("form", "Form", forms), .text("timing", "When to take (e.g. 1-0-1, morning & night)"),
                          .text("instructions", "Instructions (before/after food)"), .text("duration", "For how long (e.g. 5 days)")],
                 hint: "If there are several medicines, take only the first one. Copy timing exactly as written.")
    }

    private func applyScan(_ o: ScanOutput) {
        if let v = o.str("name") { name = v }
        if let v = o.str("dose") { dose = v }
        if let v = o.str("form"), forms.contains(v) { form = v }
        if let v = o.str("instructions") { instructions = v }
        if let v = o.str("timing") { let m = RxTiming.minutes(v); if !m.isEmpty { times = m.map(RxTiming.date) } }
        if let v = o.str("duration"), let n = RxTiming.days(v) { hasEnd = true; end = Calendar.current.date(byAdding: .day, value: n, to: start) ?? end }
    }

    private var events: [HealthEvent] { profileEvents.filter { $0.profileID == profile.id && !$0.deleted } }

    private var summary: String {
        let n = times.count
        let freq = n == 1 ? "once a day" : n == 2 ? "twice a day" : "\(n) times a day"
        let course = hasEnd ? "for \(max(1, (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start), to: Calendar.current.startOfDay(for: end)).day ?? 0) + 1)) days" : "ongoing"
        return "\(name.isEmpty ? "Medicine" : name): \(freq), every day \(course)."
    }

    var body: some View {
        Form {
            AIScanSection(spec: scanSpec, onApply: applyScan)
            Section {
                HStack(spacing: 14) {
                    Group {
                        if let d = mx.photo, let img = UIImage(data: d) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: "pills.fill").font(.title).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(LinearGradient(colors: [.red.opacity(0.75), .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                    PhotosPicker(selection: $medPhoto, matching: .images) { Label("Photo of the medicine", systemImage: "camera.fill") }
                }
                Text(summary).font(.subheadline).foregroundStyle(.tint)
            }
            .lookRows()
            Section {
                TextField("Name (e.g. Augmentin, Pan-D)", text: $name).font(.title3)
                TextField("Strength (e.g. 625 mg, 40 mg)", text: $mx.strength)
                TextField("Company / brand", text: $mx.brand)
                Picker("Type", selection: $form) { ForEach(forms, id: \.self) { Text($0).tag($0) } }
                TextField("Dose each time (e.g. 1 tablet)", text: $dose)
                TextField("Instructions (e.g. after food, with water)", text: $instructions)
            } header: { Text("Medicine") }
            .lookRows()
            Section {
                TextField("Cause / condition (e.g. throat infection)", text: $mx.cause)
                TextField("Doctor's name", text: $mx.doctor)
                TextField("Doctor's phone (optional)", text: $mx.doctorPhone).keyboardType(.phonePad)
                Picker("Linked to", selection: $mx.linkedEventID) {
                    Text("Nothing").tag("")
                    ForEach(events) { e in Text(e.title).tag(e.id) }
                }
                TextField("Cost ₹ (optional)", text: $billText).keyboardType(.decimalPad)
            } header: { Text("Prescribed for") }
            .lookRows()
            Section {
                ForEach(times.indices, id: \.self) { i in
                    HStack {
                        DatePicker("Dose \(i + 1)", selection: $times[i], displayedComponents: .hourAndMinute)
                        Button { times.remove(at: i) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                    }
                }
                Menu {
                    ForEach(presets, id: \.1) { preset in
                        Button(preset.0) { times.append(date(preset.1)) }
                    }
                    Button("Custom time") { times.append(.now) }
                } label: { Label("Add a time", systemImage: "plus.circle") }
            } header: { Text("Times every day") }
            .lookRows()
            Section {
                DatePicker("Start", selection: $start, displayedComponents: .date)
                Toggle("Ongoing (no end date)", isOn: Binding(get: { !hasEnd }, set: { hasEnd = !$0 }).animation())
                if hasEnd {
                    Stepper("For \(courseDays) days", value: $courseDays, in: 1...365)
                        .onChange(of: courseDays) { _, n in end = Calendar.current.date(byAdding: .day, value: n - 1, to: start) ?? end }
                    DatePicker("Last day", selection: $end, in: start..., displayedComponents: .date)
                }
                TextField("Tablets / doses in stock (optional)", text: $stockText).keyboardType(.numberPad)
                if med != nil { Toggle("Active", isOn: $active) }
            }
            .lookRows()
            if let med {
                Section {
                    Button("Delete medicine", role: .destructive) {
                        engine.saveMedicine(profile, id: med.id, name: med.name, dose: med.dose, form: med.form, times: med.times,
                                            instructions: med.instructions, startDate: med.startDate, endDate: med.endDate,
                                            stock: med.stock, active: false, deleted: true)
                        dismiss()
                    }
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle(med == nil ? "Add medicine" : "Edit medicine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let minutes = times.map { d -> Int in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
                    }
                    var extra = mx
                    extra.bill = Double(billText.replacingOccurrences(of: ",", with: "")) ?? 0
                    engine.saveMedicine(profile, id: med?.id, name: name.trimmingCharacters(in: .whitespaces), dose: dose, form: form,
                                        times: Array(Set(minutes)), instructions: instructions, startDate: start,
                                        endDate: hasEnd ? end : nil, stock: Int(stockText), active: active, extra: extra)
                    Haptics.success()
                    dismiss()
                }
                .bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || times.isEmpty)
            }
        }
        .onAppear {
            if let m = med {
                name = m.name; dose = m.dose; form = m.form; instructions = m.instructions; start = m.startDate
                times = m.times.map(date); active = m.active
                if let e = m.endDate {
                    hasEnd = true; end = e
                    courseDays = max(1, (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: m.startDate), to: Calendar.current.startOfDay(for: e)).day ?? 6) + 1)
                }
                if let s = m.stock { stockText = "\(s)" }
                mx = m.extra
                if mx.bill > 0 { billText = String(format: "%.0f", mx.bill) }
            } else if times.isEmpty {
                times = [date(540)]
                hasEnd = true
                end = Calendar.current.date(byAdding: .day, value: courseDays - 1, to: start) ?? end
                mx.linkedEventID = linkedEventID
                mx.cause = presetCause
            }
        }
        .onChange(of: medPhoto) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    mx.photo = img.scaled(maxSide: 360).jpegData(compressionQuality: 0.6)
                }
            }
        }
    }

    private func date(_ minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }
}

struct HealthEventEditor: View {
    let profile: CareProfile
    let event: HealthEvent?
    var presetKind: HealthEventKind? = nil
    @EnvironmentObject var engine: SyncEngine
    @State private var x = HealthExtra()
    @State private var eventID = UUID().uuidString
    @State private var hasEnded = false
    @State private var hasFollowUp = false
    @State private var billText = ""
    @State private var addMed = false
    @State private var editMed: Medicine?
    @Query private var allMeds: [Medicine]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var kind = HealthEventKind.injury
    @State private var title = ""
    @State private var details = ""
    @State private var date = Date.now
    @State private var severity = 1
    @State private var status = "ongoing"
    @State private var recovery = 0.0
    @State private var update = ""
    @State private var pending = PendingAttachments()

    private var scanSpec: ScanSpec {
        ScanSpec(title: "Scan a report or discharge paper", what: "a medical report, lab report, discharge summary or doctor's note",
                 fields: [.choice("kind", "Type", HealthEventKind.allCases.map(\.title)), .text("title", "What happened / test name"),
                          .long("details", "Details (doctor, hospital, findings, values)"), .date("date", "Date")],
                 hint: "Copy lab values with units exactly. Do not interpret or diagnose.")
    }

    private func applyScan(_ o: ScanOutput) {
        if let v = o.str("kind"), let k = HealthEventKind.allCases.first(where: { $0.title == v }) { kind = k }
        if let v = o.str("title") { title = v }
        if let v = o.str("details") { details = details.isEmpty ? v : details + "\n" + v }
        if let v = o.date("date") { date = v }
        for p in o.files { pending.add(p) }
    }

    private var linkedMeds: [Medicine] {
        allMeds.filter { !$0.deleted && $0.extra.linkedEventID == eventID }
    }

    var body: some View {
        Form {
            AIScanSection(spec: scanSpec, onApply: applyScan)
            Section {
                TextField(kind == .injury ? "Title (e.g. Sprained right ankle)" : "Name (e.g. Appendix surgery, Dengue)", text: $title, axis: .vertical)
                Picker("Type", selection: $kind) {
                    ForEach(HealthEventKind.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                if kind == .injury {
                    TextField("Body part", text: $x.bodyPart)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(HealthExtra.bodyParts, id: \.self) { part in
                                Button(part) { x.bodyPart = part; Haptics.tap() }
                                    .buttonStyle(.bordered).tint(x.bodyPart == part ? .accentColor : .gray)
                            }
                        }
                    }
                }
                DatePicker(kind == .injury ? "When" : "Started / date", selection: $date)
                TextField(kind == .injury ? "How it happened (e.g. during squats at the gym)" : "Details", text: $details, axis: .vertical).lineLimit(2...6)
                if kind != .injury {
                    Toggle("Has ended", isOn: $hasEnded.animation())
                    if hasEnded { DatePicker("Ended", selection: Binding(get: { x.ended ?? .now }, set: { x.ended = $0 }), displayedComponents: .date) }
                }
                Picker("Severity", selection: $severity) {
                    Text("Minor").tag(1); Text("Moderate").tag(2); Text("Severe").tag(3)
                }
                .pickerStyle(.segmented)
            } header: { Text(kind == .injury ? "What happened" : "Event") }
            .lookRows()
            if kind == .injury {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
                        ForEach(HealthExtra.treatmentOptions, id: \.self) { t in
                            Button {
                                if let i = x.treatments.firstIndex(of: t) { x.treatments.remove(at: i) } else { x.treatments.append(t) }
                                Haptics.tap()
                            } label: {
                                Label(t, systemImage: x.treatments.contains(t) ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline).foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("Doctor", text: $x.doctor)
                    TextField("Hospital / clinic", text: $x.hospital)
                    Toggle("Hospitalised", isOn: $x.hospitalised)
                } header: { Text("Treatment") }
                .lookRows()
            } else {
                Section {
                    TextField("Diagnosis", text: $x.diagnosis, axis: .vertical)
                    TextField("Procedure (e.g. laparoscopic appendectomy)", text: $x.procedure, axis: .vertical)
                    TextField("Doctor's name", text: $x.doctor)
                    TextField("Speciality (e.g. orthopaedic surgeon)", text: $x.speciality)
                    TextField("Hospital", text: $x.hospital)
                    Toggle("Hospitalised", isOn: $x.hospitalised)
                    Toggle("Follow-up appointment", isOn: $hasFollowUp.animation())
                    if hasFollowUp { DatePicker("Follow-up", selection: Binding(get: { x.followUp ?? .now.addingTimeInterval(7 * 86400) }, set: { x.followUp = $0 })) }
                } header: { Text("Medical details") }
                .lookRows()
            }
            Section {
                TextField("Medical bills ₹ (optional)", text: $billText).keyboardType(.decimalPad)
            } footer: { Text("Bills add up in the Medical card on the profile.") }
            .lookRows()
            Section {
                ForEach(linkedMeds) { m in
                    Button { editMed = m } label: {
                        Label("\(m.name) \(m.extra.strength.isEmpty ? m.dose : m.extra.strength)", systemImage: "pills.fill")
                    }
                }
                Button { addMed = true } label: { Label("Add a medicine for this", systemImage: "plus.circle.fill") }
            } header: { Text("Medicines (\(linkedMeds.count))") } footer: {
                Text("Medicines added here also appear in Medicines, with reminders and dose tracking.")
            }
            .lookRows()
            Section {
                Picker("Status", selection: $status) {
                    Text(kind == .injury ? "Active" : "Under treatment").tag("ongoing"); Text("Recovering").tag("recovering"); Text(kind == .injury ? "Healed" : "Recovered").tag("recovered")
                }
                .pickerStyle(.segmented)
                if status != "recovered" {
                    VStack(alignment: .leading) {
                        Text("Recovery \(Int(recovery))%").font(.subheadline)
                        Slider(value: $recovery, in: 0...100, step: 5)
                    }
                }
                if event != nil {
                    TextField("Progress update for everyone (e.g. Plaster removed)", text: $update, axis: .vertical)
                }
                if kind == .injury {
                    TextField("Restrictions (e.g. no running for 3 weeks)", text: $x.restrictions, axis: .vertical)
                }
            } header: { Text("Recovery") }
            .lookRows()
            if let event, !event.updates.isEmpty {
                Section("Timeline") {
                    ForEach(event.updates.reversed(), id: \.self) { u in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.text).font(.subheadline)
                            Text("\(engine.name(of: u.by)) · \(Fmt.chatTime(u.at)) · \(u.recovery)%").font(.caption2).foregroundStyle(look.textSecondary)
                        }
                    }
                }
                .lookRows()
            }
            Section {
                if let event, !event.attachments.isEmpty {
                    ScrollView(.horizontal) { HStack { ForEach(event.attachments) { AttachmentThumb(ref: $0) } } }
                }
                AttachmentAdder(pending: $pending, title: "Add photo, report or bill")
            }
            .lookRows()
            if let event {
                Section {
                    Button("Delete", role: .destructive) { save(event: event, deleted: true) }
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle(event == nil ? "Log health event" : "Update")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(event == nil ? "Log & alert" : "Save") { save(event: event, deleted: false) }
                    .bold()
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let e = event else { if let k = presetKind { kind = k }; return }
            kind = e.kindValue; title = e.title; details = e.details; date = e.date
            severity = e.severity; status = e.status; recovery = Double(e.recovery)
            eventID = e.id
            x = e.extra
            hasEnded = x.ended != nil
            hasFollowUp = x.followUp != nil
            if x.bill > 0 { billText = String(format: "%.0f", x.bill) }
        }
        .sheet(isPresented: $addMed) { NavigationStack { MedicineEditor(profile: profile, med: nil, linkedEventID: eventID, presetCause: title) } }
        .sheet(item: $editMed) { m in NavigationStack { MedicineEditor(profile: profile, med: m) } }
    }

    private func save(event: HealthEvent?, deleted: Bool) {
        let rec = status == "recovered" ? 100 : Int(recovery)
        var extra = x
        if !hasEnded { extra.ended = nil }
        if !hasFollowUp { extra.followUp = nil }
        extra.bill = Double(billText.replacingOccurrences(of: ",", with: "")) ?? 0
        engine.saveHealthEvent(profile, existing: event, id: eventID, kind: kind.rawValue, title: title.trimmingCharacters(in: .whitespaces),
                               details: details, date: date, severity: severity, status: status, recovery: rec,
                               update: update.trimmingCharacters(in: .whitespaces).isEmpty ? nil : update,
                               attachments: (event?.attachments ?? []) + pending.refs, uploads: pending.uploads, deleted: deleted,
                               extra: extra)
        Haptics.success()
        dismiss()
    }
}

struct VaultAddView: View {
    let profile: CareProfile
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = VaultCategory.report
    @State private var date = Date.now
    @State private var pending = PendingAttachments()

    var body: some View {
        Form {
            Section {
                AttachmentAdder(pending: $pending, title: "Choose document (camera, photo or PDF)")
            }
            .lookRows()
            Section {
                TextField("Title (e.g. Blood test – Nov)", text: $title)
                Picker("Type", selection: $category) {
                    ForEach(VaultCategory.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Add to vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    for (i, ref) in pending.refs.enumerated() {
                        let t = title.trimmingCharacters(in: .whitespaces)
                        let name = t.isEmpty ? category.title : (pending.refs.count > 1 ? "\(t) (\(i + 1))" : t)
                        engine.addVaultItem(profile, title: name, category: category.rawValue, date: date, attachment: ref,
                                            uploads: pending.uploads.filter { $0.key == ref.blob })
                    }
                    dismiss()
                }
                .bold()
                .disabled(pending.isEmpty)
            }
        }
    }
}

// MARK: - Paywall

/// The iLife Care page from the Module Store.
struct CarePaywall: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ModuleDetailView(module: ModuleRegistry.iLifeCare)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// A demo care profile ("Aai (demo)") in the demo team, so the module can be tried alone.
@MainActor
enum DemoCare {
    static func create(_ engine: SyncEngine) -> String? {
        let team = DemoChats.create(engine)
        let pid = "c_demo"
        if engine.careProfile(pid) != nil { return pid }
        let now = Date.now
        func apply(_ body: Event.Body, from: String) {
            _ = EventApplier(engine: engine).apply(Event(id: UUID().uuidString, conv: team.id, from: from, at: now, body: body), local: false)
        }
        apply(.care(CareProfilePayload(id: pid, name: "Aai (demo)", relation: "Mother", bloodGroup: "B+", allergies: "Penicillin",
                                       conditions: "Diabetes, BP", emergencyContact: "Dr. Kulkarni · 98200 00000",
                                       notes: "Fortis Hospital, Kalyan", avatar: nil, deleted: false, at: now)), from: DemoChats.asha)
        apply(.medicine(MedicinePayload(id: "m_demo1", profileID: pid, name: "Metformin", dose: "500 mg", form: "Tablet",
                                        times: [540, 1260], instructions: "After food", startDate: now.addingTimeInterval(-7 * 86400),
                                        endDate: nil, stock: 24, active: true, deleted: false, at: now)), from: DemoChats.asha)
        apply(.medicine(MedicinePayload(id: "m_demo2", profileID: pid, name: "Amlodipine", dose: "5 mg", form: "Tablet",
                                        times: [600], instructions: "Morning", startDate: now.addingTimeInterval(-30 * 86400),
                                        endDate: nil, stock: 4, active: true, deleted: false, at: now)), from: DemoChats.rahul)
        apply(.healthEvent(HealthEventPayload(id: "h_demo", profileID: pid, kind: "injury", title: "Fractured left wrist",
                                              details: "Fell at home. Plaster for 6 weeks — Dr. Kulkarni.", date: now.addingTimeInterval(-10 * 86400),
                                              severity: 2, status: "recovering", recovery: 40, update: "Swelling is down, follow-up on Monday",
                                              attachments: [], deleted: false, at: now)), from: DemoChats.rahul)
        engine.save()
        Reminders.shared.reschedule(context: engine.context, me: engine.me)
        return pid
    }
}


// MARK: - Daily "I'm OK" check-in (instead of watching anyone)

@MainActor
enum CareOK {
    static let marker = "✅ I'm OK"
    /// profile → minutes after midnight, on the phone of the person being cared for.
    static var remind: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "care.ok.remind") as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "care.ok.remind") }
    }
    /// profile → minutes after midnight, on family phones ("alert me if no check-in by").
    static var watch: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "care.ok.watch") as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "care.ok.watch") }
    }

    static func checkedIn(_ p: CareProfile, on day: Date, by who: String?, context: ModelContext) -> Bool {
        let cid = p.convID, start = Calendar.current.startOfDay(for: day), end = start.addingTimeInterval(86400)
        let msgs = (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.convID == cid && $0.createdAt >= start && $0.createdAt < end && !$0.deleted }))) ?? []
        return msgs.contains { $0.text.hasPrefix(marker) && (who == nil || $0.senderID == who) }
    }
}

struct CareOKSection: View {
    let profile: CareProfile
    @EnvironmentObject var engine: SyncEngine
    @State private var remindOn = false
    @State private var remindAt = RxTiming.date(600)
    @State private var watchOn = false
    @State private var watchAt = RxTiming.date(720)
    @State private var sent = false

    var body: some View {
        Section {
            Button(sent ? "Sent — family notified" : "I'm OK — tell the family", systemImage: "checkmark.seal.fill") {
                if let c = engine.conversation(profile.convID) {
                    engine.sendText("\(CareOK.marker) — \(engine.name(of: engine.me)) checked in at \(Date.now.formatted(date: .omitted, time: .shortened))", in: c)
                    sent = true; Haptics.success(); reschedule()
                }
            }
            .disabled(sent || engine.conversation(profile.convID) == nil)
            .onAppear(perform: load)
            .onChange(of: remindOn) { _, _ in save() }
            .onChange(of: remindAt) { _, _ in save() }
            .onChange(of: watchOn) { _, _ in save() }
            .onChange(of: watchAt) { _, _ in save() }
            Toggle("Remind me daily to check in", isOn: $remindOn)
            if remindOn { DatePicker("At", selection: $remindAt, displayedComponents: .hourAndMinute) }
            Toggle("Alert me if no check-in by", isOn: $watchOn)
            if watchOn { DatePicker("By", selection: $watchAt, displayedComponents: .hourAndMinute) }
        } header: { Text("Daily check-in") } footer: {
            Text("The person taps “I'm OK” once a day. If it hasn't arrived by your time, your phone alerts you. Apple Watch fall detection also calls emergency contacts. Nobody's photos or location are watched.")
        }
    }

    private func minutes(_ d: Date) -> Int { let c = Calendar.current.dateComponents([.hour, .minute], from: d); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }

    private func load() {
        if let m = CareOK.remind[profile.id] { remindOn = true; remindAt = RxTiming.date(m) }
        if let m = CareOK.watch[profile.id] { watchOn = true; watchAt = RxTiming.date(m) }
        if let ctx = engine.context { sent = CareOK.checkedIn(profile, on: .now, by: engine.me, context: ctx) }
    }

    private func save() {
        var r = CareOK.remind; r[profile.id] = remindOn ? minutes(remindAt) : nil; CareOK.remind = r
        var w = CareOK.watch; w[profile.id] = watchOn ? minutes(watchAt) : nil; CareOK.watch = w
        reschedule()
    }

    private func reschedule() { if let ctx = engine.context { Reminders.shared.reschedule(context: ctx, me: engine.me) } }
}
