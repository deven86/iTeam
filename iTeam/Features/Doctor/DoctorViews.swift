import SwiftUI
import SwiftData

/// Doctor & Patient (free): doctors write prescriptions in a chat; patients accept them into Care.
struct DoctorHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Prescription> { !$0.deleted }, sort: \Prescription.createdAt, order: .reverse) private var all: [Prescription]
    @State private var writing = false
    @State private var shareItems: ShareItems?

    private var written: [Prescription] { all.filter { $0.doctorID == engine.me } }
    private var received: [Prescription] { all.filter { $0.patientID == engine.me } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        stat("\(received.filter { $0.status == "waiting" }.count)", "To review", "tray.full.fill")
                        stat("\(written.filter { $0.status == "waiting" }.count)", "Waiting", "hourglass")
                        stat("\(upcomingVisits)", "Visits 7 days", "calendar")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if all.isEmpty {
                    EmptyStateView(icon: "stethoscope", title: "Doctor & Patient",
                                   message: "Doctors: open a patient's chat → ＋ → Prescription. Patients: prescriptions you receive appear here — accept them and they go into Care with reminders.",
                                   actionTitle: "Write a prescription") { writing = true }
                        .listRowBackground(Color.clear)
                }
                if !received.isEmpty {
                    Section("From my doctors") {
                        ForEach(received) { rx in NavigationLink { PrescriptionView(rxID: rx.id) } label: { RxRow(rx: rx, mine: false) } }
                    }
                    .lookRows()
                }
                if !written.isEmpty {
                    Section("Prescriptions I wrote") {
                        ForEach(written) { rx in NavigationLink { PrescriptionView(rxID: rx.id) } label: { RxRow(rx: rx, mine: true) } }
                    }
                    .lookRows()
                }
            }
            .lookScreen()
            .navigationTitle("Doctor & Patient")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { writing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New prescription")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export all (PDF)", systemImage: "doc.richtext") {
                        let html = all.map { PrescriptionView.html($0, engine: engine) }.joined(separator: "<hr>")
                        if let url = PDFMaker.make(title: "Prescriptions", bodyHTML: html, fileName: "Prescriptions") { shareItems = ShareItems(items: [url]) }
                    }
                }
            }
            .shareSheet($shareItems)
            .refreshable { await engine.sync() }
            .sheet(isPresented: $writing) { NavigationStack { PickPatientView() } }
        }
    }

    private var upcomingVisits: Int {
        let week = Date.now.addingTimeInterval(7 * 86400)
        return all.filter { ($0.nextVisit ?? .distantPast) > .now && ($0.nextVisit ?? .distantFuture) < week }.count
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(look.accent)
            Text(value).font(.title2.bold())
            Text(label).font(.caption2).foregroundStyle(look.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).lookCard(padding: 6)
    }
}

struct RxRow: View {
    let rx: Prescription
    let mine: Bool
    @EnvironmentObject var engine: SyncEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(mine ? rx.patientName : "Dr. " + engine.name(of: rx.doctorID)).font(.headline)
                Spacer()
                RxStatusBadge(status: rx.status)
            }
            Text(rx.diagnosis.isEmpty ? rx.items.map(\.name).joined(separator: ", ") : rx.diagnosis)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(rx.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RxStatusBadge: View {
    let status: String
    var body: some View {
        let (t, c): (String, Color) = status == "accepted" ? ("Accepted", .green) : status == "declined" ? ("Declined", .red) : ("Waiting", .orange)
        Text(t).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(c.opacity(0.18), in: Capsule()).foregroundStyle(c)
    }
}

/// Doctor picks which patient (contact) to write for; the prescription goes into their direct chat.
struct PickPatientView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    var body: some View {
        List {
            if contacts.isEmpty { Text("Add your patient as a contact first (scan their iTeam QR code).").foregroundStyle(.secondary) }
            ForEach(contacts) { c in
                NavigationLink { PrescriptionEditor(conv: engine.directConversation(with: c), patientID: c.userID, patientName: c.name) } label: {
                    HStack { AvatarView(name: c.name, imageData: c.avatar, size: 34); Text(c.name) }
                }
            }
        }
        .navigationTitle("Choose patient")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// Write or edit a prescription.
struct PrescriptionEditor: View {
    let conv: Conversation
    let patientID: String
    let patientName: String
    var existing: Prescription? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosis = ""
    @State private var advice = ""
    @State private var items: [RxItem] = [RxItem()]
    @State private var hasVisit = false
    @State private var visit = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now

    var body: some View {
        Form {
            Section("Patient") {
                Text(patientName).font(.headline)
                TextField("Diagnosis / reason", text: $diagnosis)
            }
            ForEach($items) { $item in
                Section {
                    TextField("Medicine name", text: $item.name)
                    HStack {
                        TextField("Dose (e.g. 500 mg)", text: $item.dose)
                        Picker("", selection: $item.form) {
                            ForEach(["Tablet", "Capsule", "Syrup", "Drops", "Injection", "Cream", "Inhaler"], id: \.self) { Text($0) }
                        }.labelsHidden()
                    }
                    RxTimesEditor(times: $item.times)
                    Stepper(item.days == 0 ? "Until stopped" : "\(item.days) days", value: $item.days, in: 0...365)
                    TextField("How to take (after food…)", text: $item.instructions)
                    if items.count > 1 {
                        Button("Remove", role: .destructive) { items.removeAll { $0.id == item.id } }
                    }
                } header: { Text("Medicine") }
            }
            Section {
                Button("Add another medicine", systemImage: "plus.circle") { items.append(RxItem()) }
            }
            Section("Advice & follow-up") {
                TextField("Advice (diet, rest, tests…)", text: $advice, axis: .vertical)
                Toggle("Next visit", isOn: $hasVisit)
                if hasVisit { DatePicker("Date", selection: $visit, displayedComponents: [.date, .hourAndMinute]) }
            }
            Section {
                Text("Advice only — always confirm doses with the doctor in person when in doubt. The patient must accept before anything is added to their Care reminders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(existing == nil ? "New prescription" : "Edit prescription")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    let clean = items.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                    let p = PrescriptionPayload(id: existing?.id ?? "rx_" + UUID().uuidString, patientID: patientID, patientName: patientName,
                                                diagnosis: diagnosis, advice: advice, items: clean,
                                                nextVisit: hasVisit ? visit : nil, deleted: false, at: .now)
                    engine.sendPrescription(p, in: conv)
                    Haptics.success()
                    dismiss()
                }
                .disabled(items.allSatisfy { $0.name.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .onAppear {
            guard let rx = existing else { return }
            diagnosis = rx.diagnosis; advice = rx.advice; items = rx.items.isEmpty ? [RxItem()] : rx.items
            if let v = rx.nextVisit { hasVisit = true; visit = v }
        }
    }
}

struct RxTimesEditor: View {
    @Binding var times: [Int]
    private let presets: [(String, Int)] = [("Morning 9", 540), ("Afternoon 2", 840), ("Evening 6", 1080), ("Night 9", 1260)]
    var body: some View {
        HStack {
            ForEach(presets, id: \.1) { p in
                let on = times.contains(p.1)
                Button(p.0) {
                    if on { times.removeAll { $0 == p.1 } } else { times.append(p.1); times.sort() }
                }
                .font(.caption2).buttonStyle(.bordered).tint(on ? .accentColor : .gray)
            }
        }
    }
}

/// Prescription detail: patient accepts into Care; doctor sees status, edits or cancels.
struct PrescriptionView: View {
    let rxID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [Prescription]
    @Query(filter: #Predicate<CareProfile> { !$0.deleted }, sort: \CareProfile.name) private var profiles: [CareProfile]
    @State private var profileID = ""
    @State private var declining = false
    @State private var note = ""
    @State private var editing = false
    @State private var shareItems: ShareItems?

    init(rxID: String) {
        self.rxID = rxID
        _found = Query(filter: #Predicate<Prescription> { $0.id == rxID })
    }

    var body: some View {
        if let rx = found.first { content(rx) } else { Text("Prescription not found") }
    }

    private func content(_ rx: Prescription) -> some View {
        let mineAsDoctor = rx.doctorID == engine.me
        let mineAsPatient = rx.patientID == engine.me
        return List {
            Section {
                LabeledContent("Doctor", value: mineAsDoctor ? "You" : "Dr. " + engine.name(of: rx.doctorID))
                LabeledContent("Patient", value: mineAsPatient ? "You" : rx.patientName)
                LabeledContent("Status") { RxStatusBadge(status: rx.status) }
                if !rx.diagnosis.isEmpty { LabeledContent("Diagnosis", value: rx.diagnosis) }
                if let v = rx.nextVisit { LabeledContent("Next visit", value: v.formatted(date: .abbreviated, time: .shortened)) }
                if !rx.answerNote.isEmpty { LabeledContent("Patient's note", value: rx.answerNote) }
                if rx.deleted { Text("Cancelled by the doctor").foregroundStyle(.red) }
            }
            Section("Medicines") {
                ForEach(rx.items) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i.name) \(i.dose)").font(.headline)
                        Text("\(i.form) · \(i.times.map(Self.clock).joined(separator: ", ")) · \(i.days == 0 ? "until stopped" : "\(i.days) days")")
                            .font(.caption).foregroundStyle(.secondary)
                        if !i.instructions.isEmpty { Text(i.instructions).font(.caption) }
                    }
                }
            }
            if !rx.advice.isEmpty { Section("Advice") { Text(rx.advice) } }

            if mineAsPatient && rx.status == "waiting" && !rx.deleted {
                Section {
                    Picker("Add to Care profile", selection: $profileID) {
                        Text("Me (new profile)").tag("")
                        ForEach(profiles) { p in Text(p.name).tag(p.id) }
                    }
                    Button("Accept — add to Care with reminders", systemImage: "checkmark.circle.fill") { accept(rx) }
                        .buttonStyle(.glassProminent)
                    Button("Decline", role: .destructive) { declining = true }
                } footer: { Text("Nothing is added to your medicines until you accept.") }
            }
            if mineAsDoctor && !rx.deleted {
                Section {
                    Button("Edit and resend", systemImage: "pencil") { editing = true }
                    Button("Cancel prescription", systemImage: "xmark.circle", role: .destructive) {
                        guard let conv = engine.conversation(rx.convID) else { return }
                        engine.sendPrescription(PrescriptionPayload(id: rx.id, patientID: rx.patientID, patientName: rx.patientName, diagnosis: rx.diagnosis,
                                                                    advice: rx.advice, items: rx.items, nextVisit: rx.nextVisit, deleted: true, at: .now), in: conv)
                    }
                }
            }
            Section {
                Button("Share as PDF", systemImage: "doc.richtext") {
                    if let url = PDFMaker.make(title: "Prescription", bodyHTML: Self.html(rx, engine: engine), fileName: "Prescription \(rx.patientName)") { shareItems = ShareItems(items: [url]) }
                }
            }
        }
        .lookScreen()
        .navigationTitle("Prescription")
        .shareSheet($shareItems)
        .alert("Decline prescription", isPresented: $declining) {
            TextField("Reason (optional)", text: $note)
            Button("Decline", role: .destructive) { engine.answerPrescription(rx, accept: false, note: note, into: nil) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editing) {
            if let conv = engine.conversation(rx.convID) {
                NavigationStack { PrescriptionEditor(conv: conv, patientID: rx.patientID, patientName: rx.patientName, existing: rx) }
            }
        }
        .onAppear { if profileID.isEmpty { profileID = profiles.first { $0.relation == "Me" || $0.name == engine.myName }?.id ?? "" } }
    }

    private func accept(_ rx: Prescription) {
        var profile = profiles.first { $0.id == profileID }
        if profile == nil {
            let conv = DemoChats.notesToSelf(engine)
            let id = engine.saveCareProfile(in: conv, name: engine.myName, relation: "Me", bloodGroup: "", allergies: "",
                                            conditions: "", emergencyContact: "", notes: "", avatar: engine.myAvatar)
            profile = try? engine.context.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { $0.id == id })).first
        }
        engine.answerPrescription(rx, accept: true, note: "", into: profile)
        Haptics.success()
    }

    static func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    static func html(_ rx: Prescription, engine: SyncEngine) -> String {
        func e(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        var h = "<h2>℞ Prescription</h2><p><b>Doctor:</b> Dr. \(e(engine.name(of: rx.doctorID)))<br><b>Patient:</b> \(e(rx.patientName))<br><b>Date:</b> \(rx.createdAt.formatted(date: .long, time: .omitted))</p>"
        if !rx.diagnosis.isEmpty { h += "<p><b>Diagnosis:</b> \(e(rx.diagnosis))</p>" }
        h += "<table border='1' cellpadding='6' style='border-collapse:collapse;width:100%'><tr><th>Medicine</th><th>Dose</th><th>When</th><th>Days</th><th>Notes</th></tr>"
        for i in rx.items {
            h += "<tr><td>\(e(i.name))</td><td>\(e(i.dose)) \(e(i.form))</td><td>\(i.times.map(clock).joined(separator: ", "))</td><td>\(i.days == 0 ? "—" : "\(i.days)")</td><td>\(e(i.instructions))</td></tr>"
        }
        h += "</table>"
        if !rx.advice.isEmpty { h += "<p><b>Advice:</b> \(e(rx.advice))</p>" }
        if let v = rx.nextVisit { h += "<p><b>Next visit:</b> \(v.formatted(date: .long, time: .shortened))</p>" }
        return h
    }
}
