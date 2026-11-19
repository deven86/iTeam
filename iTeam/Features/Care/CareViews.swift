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
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showPaywall = false

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
                } else {
                    Section { todayCard.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                    Section("People") {
                        ForEach(profiles) { p in
                            NavigationLink(value: p.id) { profileRow(p) }
                        }
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
            .sheet(isPresented: $showNew) { NavigationStack { CareProfileEditor(profile: nil) { id in path = [id] } } }
            .sheet(isPresented: $showPaywall) { CarePaywall() }
            .onChange(of: router.openCare) { _, id in
                guard let id else { return }
                path = [id]
                router.openCare = nil
            }
            .onAppear { if let id = router.openCare { path = [id]; router.openCare = nil } }
        }
    }

    private func startNew() {
        if store.careUnlocked { showNew = true } else { showPaywall = true }
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
                            Image(systemName: "pills.fill").foregroundStyle(m.active ? look.accent : look.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(m.name) \(m.dose)").font(.subheadline.weight(.semibold)).strikethrough(!m.active)
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
                ForEach(events) { ev in
                    Button { editEvent = ev } label: { eventRow(ev) }.buttonStyle(.plain)
                }
                Button { addEvent = true } label: { Label("Log injury or health event", systemImage: "plus.circle") }
            } header: { Text("Injuries & health events") }
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
                          html: { ShareText.careHTML(p, meds: meds, events: events) })
                    .labelStyle(.iconOnly)
            }
        }
        .onAppear { remindMe = !(UserDefaults.standard.stringArray(forKey: "care.remindOff") ?? []).contains(p.id) }
        .sheet(isPresented: $editProfile) { NavigationStack { CareProfileEditor(profile: p) { _ in } } }
        .sheet(isPresented: $addMed) { NavigationStack { MedicineEditor(profile: p, med: nil) } }
        .sheet(item: $editMed) { m in NavigationStack { MedicineEditor(profile: p, med: m) } }
        .sheet(isPresented: $addEvent) { NavigationStack { HealthEventEditor(profile: p, event: nil) } }
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
            if profile == nil {
                Section {
                    Picker("Share in", selection: $chatID) {
                        Text("Only me (Notes to self)").tag("")
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
                    let conv = profile.flatMap { engine.conversation($0.convID) }
                        ?? (chatID.isEmpty ? DemoChats.notesToSelf(engine) : engine.conversation(chatID))
                    guard let conv else { return }
                    let id = engine.saveCareProfile(in: conv, id: profile?.id, name: name.trimmingCharacters(in: .whitespaces), relation: relation,
                                                    bloodGroup: bloodGroup, allergies: allergies, conditions: conditions,
                                                    emergencyContact: emergency, notes: notes, avatar: avatar)
                    Haptics.success()
                    dismiss()
                    onSaved(id)
                }
                .bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let p = profile else { return }
            name = p.name; relation = p.relation; bloodGroup = p.bloodGroup; allergies = p.allergies
            conditions = p.conditions; emergency = p.emergencyContact; notes = p.notes; avatar = p.avatar
        }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = OnboardingView.avatarData(d) } }
        }
    }
}

struct MedicineEditor: View {
    let profile: CareProfile
    let med: Medicine?
    @EnvironmentObject var engine: SyncEngine
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

    var body: some View {
        Form {
            Section {
                TextField("Medicine name", text: $name).font(.title3)
                TextField("Dose (e.g. 500 mg, 1 tablet, 5 ml)", text: $dose)
                Picker("Form", selection: $form) { ForEach(forms, id: \.self) { Text($0).tag($0) } }
                TextField("Instructions (e.g. After food)", text: $instructions)
            }
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
                Toggle("End date", isOn: $hasEnd.animation())
                if hasEnd { DatePicker("Last day", selection: $end, in: start..., displayedComponents: .date) }
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
                    engine.saveMedicine(profile, id: med?.id, name: name.trimmingCharacters(in: .whitespaces), dose: dose, form: form,
                                        times: Array(Set(minutes)), instructions: instructions, startDate: start,
                                        endDate: hasEnd ? end : nil, stock: Int(stockText), active: active)
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
                if let e = m.endDate { hasEnd = true; end = e }
                if let s = m.stock { stockText = "\(s)" }
            } else if times.isEmpty {
                times = [date(540)]
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
    @EnvironmentObject var engine: SyncEngine
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

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(HealthEventKind.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                TextField("What happened? (e.g. Fractured left wrist)", text: $title, axis: .vertical)
                TextField("Details, doctor, hospital…", text: $details, axis: .vertical).lineLimit(2...6)
                DatePicker("When", selection: $date)
                Picker("Severity", selection: $severity) {
                    Text("Mild").tag(1); Text("Moderate").tag(2); Text("Severe").tag(3)
                }
                .pickerStyle(.segmented)
            }
            .lookRows()
            Section {
                Picker("Status", selection: $status) {
                    Text("Ongoing").tag("ongoing"); Text("Recovering").tag("recovering"); Text("Recovered").tag("recovered")
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
                AttachmentAdder(pending: $pending, title: "Add photo, X-ray or report")
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
            guard let e = event else { return }
            kind = e.kindValue; title = e.title; details = e.details; date = e.date
            severity = e.severity; status = e.status; recovery = Double(e.recovery)
        }
    }

    private func save(event: HealthEvent?, deleted: Bool) {
        let rec = status == "recovered" ? 100 : Int(recovery)
        engine.saveHealthEvent(profile, existing: event, kind: kind.rawValue, title: title.trimmingCharacters(in: .whitespaces),
                               details: details, date: date, severity: severity, status: status, recovery: rec,
                               update: update.trimmingCharacters(in: .whitespaces).isEmpty ? nil : update,
                               attachments: (event?.attachments ?? []) + pending.refs, uploads: pending.uploads, deleted: deleted)
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
