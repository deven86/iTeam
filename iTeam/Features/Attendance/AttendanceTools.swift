import SwiftUI
import SwiftData
import CoreLocation
import VisionKit
import UniformTypeIdentifiers

// MARK: - Location (one reading, for selfie + location punches)

@MainActor
final class AttLocator: NSObject, CLLocationManagerDelegate {
    static let shared = AttLocator()
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    func current() async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        return await withCheckedContinuation { c in
            waiting?.resume(returning: nil)
            waiting = c
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            else { manager.requestLocation() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self.finish(nil)
            }
        }
    }

    private func finish(_ l: CLLocation?) {
        waiting?.resume(returning: l)
        waiting = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let l = locations.last
        Task { @MainActor in self.finish(l) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            guard self.waiting != nil else { return }
            if s == .authorizedWhenInUse || s == .authorizedAlways { self.manager.requestLocation() }
            else if s == .denied || s == .restricted { self.finish(nil) }
        }
    }

    static func distance(_ l: CLLocation, _ c: AttCompanyData) -> Double? {
        c.hasOffice ? l.distance(from: CLLocation(latitude: c.lat, longitude: c.lon)) : nil
    }
}

// MARK: - Punch on my phone: QR → selfie → location, as the owner requires

struct AttPunchFlow {
    var token = 0
    var scanning = false
    var far: Double?
    var message: String?
    var qr = ""
    var photo: Data?
    var lat: Double?
    var lon: Double?
    var distance: Double?

    mutating func start(_ what: String) {
        self = AttPunchFlow(token: token + 1)
    }

    static func needs(_ c: AttCompanyData) -> String {
        var n: [String] = []
        if c.needQR { n.append("scan the office QR") }
        if c.needPhoto { n.append("take a selfie") }
        if c.needGeo { n.append("share your location") }
        return n.isEmpty ? "One tap — the time is recorded." : "You'll " + n.joined(separator: ", ") + "."
    }
}

struct AttPunchModifier: ViewModifier {
    @Binding var flow: AttPunchFlow
    let company: AttRecord
    let member: AttRecord
    @EnvironmentObject var engine: SyncEngine

    private var c: AttCompanyData { company.company }

    func body(content: Content) -> some View {
        content
            .onChange(of: flow.token) { _, _ in stepQR() }
            .sheet(isPresented: $flow.scanning) { scanner }
            .alert("Away from the office", isPresented: Binding(get: { flow.far != nil }, set: { if !$0 { flow.far = nil } })) {
                Button("Punch anyway") { flow.far = nil; finish() }
                Button("Cancel", role: .cancel) { flow.far = nil }
            } message: {
                Text("You're about \(Int(flow.far ?? 0)) m from the office (allowed \(Int(c.radius)) m). The punch will be flagged for your manager.")
            }
            .alert(flow.message ?? "", isPresented: Binding(get: { flow.message != nil }, set: { if !$0 { flow.message = nil } })) {
                Button("OK") {}
            }
    }

    private var scanner: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner { text in gotQR(text) }.ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera not available", systemImage: "camera.fill", description: Text("Allow camera access for iTeam in Settings."))
                }
            }
            .navigationTitle("Scan the office QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { flow.scanning = false } } }
        }
    }

    private func stepQR() {
        if c.needQR { flow.scanning = true } else { stepPhoto() }
    }

    private func gotQR(_ text: String) {
        guard flow.scanning else { return }
        flow.scanning = false
        guard Att.qrCompany(text) == company.id else {
            Haptics.warning()
            flow.message = "This QR code isn't for “\(c.name)”. Scan the code shown on the owner's or admin's phone."
            return
        }
        flow.qr = text
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            stepPhoto()
        }
    }

    private func stepPhoto() {
        guard c.needPhoto else { stepGeo(); return }
        guard Presenter.hasCamera else { flow.message = "A selfie is required, but no camera is available."; return }
        Presenter.camera(front: true) { img in
            Task { @MainActor in
                // Camera only (no gallery photos); the phone checks there is exactly one face in the selfie.
                let n = await PhotoCheck.faces(img)
                if n == 0 { flow.message = "No face seen in the selfie. Retake it facing the camera, in good light."; return }
                if n > 1 { flow.message = "More than one face in the selfie. Only you should be in the photo — retake it."; return }
                flow.photo = img.scaled(maxSide: 320).jpegData(compressionQuality: 0.6)
                stepGeo()
            }
        }
    }

    private func stepGeo() {
        guard c.needGeo else { finish(); return }
        Task { @MainActor in
            guard let l = await AttLocator.shared.current() else {
                flow.message = "Couldn't get your location. Turn on Location for iTeam in Settings and try again."
                return
            }
            flow.lat = l.coordinate.latitude; flow.lon = l.coordinate.longitude
            flow.distance = AttLocator.distance(l, c)
            if let d = flow.distance, d > c.radius { flow.far = d } else { finish() }
        }
    }

    private func finish() {
        let method = c.needQR ? "qr" : c.needPhoto ? "photo" : c.needGeo ? "geo" : "manual"
        let r = engine.attPunch(member, company: company, method: method, photo: flow.photo,
                                lat: flow.lat, lon: flow.lon, distance: flow.distance, qr: flow.qr)
        Haptics.success()
        let t = Date.now.formatted(date: .omitted, time: .shortened)
        flow.message = r == "in" ? "Punched in at \(t)" : r == "out" ? "Punched out at \(t)" : "You've already punched in and out today."
    }
}

// MARK: - Kiosk (owner's or admin's phone/iPad at the entrance)

struct AttKioskView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var recs: [AttRecord]
    @State private var pinFor: AttRecord?
    @State private var pin = ""
    @State private var tries = 0
    @State private var banner: String?
    private let cols = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack {
                            Text(ctx.date.formatted(date: .omitted, time: .standard)).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                            Text(ctx.date.formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary)
                        }
                    }
                    if let banner {
                        Text(banner).font(.headline).foregroundStyle(.white).padding().frame(maxWidth: .infinity)
                            .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 14)).transition(.scale)
                    }
                    Text("Tap your name").font(.title3.bold())
                    LazyVGrid(columns: cols, spacing: 14) {
                        ForEach(data.active.filter { $0.member.canPunch }) { m in
                            Button { tap(m, data) } label: { card(m, data) }.buttonStyle(PressStyle())
                        }
                    }
                }
                .padding()
            }
            .lookScreen()
            .navigationTitle("\(data.c.name) · Kiosk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Exit") { Task { if await DeviceAuth.check("Exit the attendance kiosk") { dismiss() } } }
                }
            }
            .sheet(item: $pinFor) { m in pinPad(m, data) }
        }
        .interactiveDismissDisabled()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func card(_ m: AttRecord, _ data: AttData) -> some View {
        let e = data.entry(m, .now)?.entry
        let state = e?.inAt == nil ? "Punch in" : e?.outAt == nil ? "Punch out" : "Done ✓"
        return VStack(spacing: 6) {
            AvatarView(name: data.name(m, engine), imageData: m.member.photo, size: 64)
            Text(data.name(m, engine)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
            Text(state).font(.caption2.bold()).foregroundStyle(e?.inAt == nil ? .green : e?.outAt == nil ? .orange : .secondary)
        }
        .frame(maxWidth: .infinity).padding(10).lookCard(padding: 4)
    }

    private func tap(_ m: AttRecord, _ data: AttData) {
        Haptics.tap()
        if data.entry(m, .now)?.entry.outAt != nil { show("\(data.name(m, engine)) — already done for today"); return }
        if m.member.pinHash.isEmpty { capture(m, data) } else { pin = ""; tries = 0; pinFor = m }
    }

    private func pinPad(_ m: AttRecord, _ data: AttData) -> some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN", text: $pin).keyboardType(.numberPad).font(.title)
                } footer: { Text(tries > 0 ? "Wrong PIN — try again." : "Enter your kiosk PIN.") }
            }
            .navigationTitle(data.name(m, engine))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pinFor = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if AttMemberData.hashPIN(pin) == m.member.pinHash {
                            pinFor = nil
                            Task { @MainActor in try? await Task.sleep(for: .milliseconds(500)); capture(m, data) }
                        } else { tries += 1; pin = ""; Haptics.warning(); if tries >= 3 { pinFor = nil } }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func capture(_ m: AttRecord, _ data: AttData) {
        guard let comp = data.company else { return }
        if data.c.needPhoto, Presenter.hasCamera {
            Presenter.camera(front: true) { img in punch(m, comp, data, photo: img.scaled(maxSide: 320).jpegData(compressionQuality: 0.6)) }
        } else {
            punch(m, comp, data, photo: nil)
        }
    }

    private func punch(_ m: AttRecord, _ comp: AttRecord, _ data: AttData, photo: Data?) {
        let r = engine.attPunch(m, company: comp, method: "kiosk", photo: photo)
        Haptics.success()
        let t = Date.now.formatted(date: .omitted, time: .shortened)
        show("\(data.name(m, engine)) — \(r == "in" ? "punched in" : "punched out") at \(t)")
    }

    private func show(_ s: String) {
        withAnimation(.snappy) { banner = s }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if banner == s { banner = nil } }
        }
    }
}

// MARK: - Rotating QR (shown by owner/admin; employees scan it)

struct AttQRView: View {
    let company: AttRecord
    @Environment(\.dismiss) private var dismiss
    @State private var daily = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if company.company.qrSecret.isEmpty {
                    ContentUnavailableView("QR not ready", systemImage: "qrcode", description: Text("This phone hasn't received the company's QR key yet. Pull to refresh on the dashboard, or ask the owner."))
                } else {
                    Picker("Kind", selection: $daily) { Text("Live (30 s)").tag(false); Text("Today's QR").tag(true) }
                        .pickerStyle(.segmented).padding(.horizontal)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let token = daily ? Att.qrDayToken(companyID: company.id, secret: company.company.qrSecret, at: ctx.date)
                                          : Att.qrToken(companyID: company.id, secret: company.company.qrSecret, at: ctx.date)
                        VStack(spacing: 12) {
                            if let img = QRCode.image(token) {
                                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                                    .frame(maxWidth: 320).padding().background(.white, in: RoundedRectangle(cornerRadius: 18))
                            }
                            if daily {
                                if let img = QRCode.image(token) {
                                    ShareLink(item: Image(uiImage: img), preview: SharePreview("Today's attendance QR", image: Image(uiImage: img))) {
                                        Label("Share / print today's QR", systemImage: "printer")
                                    }.buttonStyle(.borderedProminent)
                                }
                                Text("Valid all day today. A new code is made every day.").foregroundStyle(.secondary)
                            } else {
                                Text("New code in \(Int(Att.qrSlot) - Int(ctx.date.timeIntervalSince1970) % Int(Att.qrSlot)) s").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Employees scan this in iTeam → Attendance → Punch in. The code changes every 30 seconds, so a photo of it can't be reused later.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .padding()
            .navigationTitle(company.company.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - Members

struct AttMembersView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]
    @State private var adding = false
    @State private var search = ""

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        let shown = data.members.filter { search.isEmpty || data.name($0, engine).localizedCaseInsensitiveContains(search) || $0.member.department.localizedCaseInsensitiveContains(search) }
        List {
            let depts = Array(Set(shown.map { $0.member.department.isEmpty ? "No department" : $0.member.department })).sorted()
            ForEach(depts, id: \.self) { dept in
                Section(dept) {
                    ForEach(shown.filter { ($0.member.department.isEmpty ? "No department" : $0.member.department) == dept }) { m in
                        NavigationLink { AttMemberDetail(companyID: companyID, memberID: m.id) } label: {
                            AttMemberRow(member: m, name: data.name(m, engine), status: m.member.active ? data.status(m, .now) : "none", entry: data.entry(m, .now))
                                .opacity(m.member.active ? 1 : 0.5)
                        }
                    }
                }
                .lookRows()
            }
        }
        .searchable(text: $search)
        .lookScreen()
        .navigationTitle("Members")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "person.badge.plus") } } }
        .sheet(isPresented: $adding) { if let comp = data.company { NavigationStack { AttMemberEditor(company: comp, existing: nil) } } }
    }
}

// MARK: - Leaves

struct AttLeavesView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]
    @State private var filter = "pending"
    @State private var adding = false

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        let shown = data.leaves.filter { filter == "all" || $0.status == filter }
        List {
            Picker("Show", selection: $filter) {
                Text("Pending").tag("pending"); Text("Approved").tag("approved"); Text("Rejected").tag("rejected"); Text("All").tag("all")
            }
            .pickerStyle(.segmented).listRowBackground(Color.clear)
            if shown.isEmpty { Text("Nothing here.").foregroundStyle(.secondary) }
            ForEach(shown) { l in
                NavigationLink { AttLeaveDetail(leaveID: l.id, companyID: companyID) } label: {
                    AttLine(icon: "beach.umbrella.fill", color: l.status == "approved" ? 0x34C759 : l.status == "rejected" ? 0xFF3B30 : 0xFF9500,
                            title: "\(data.name(l.memberID, engine)) — \(l.leave.type)", detail: AttFmt.leaveSpan(l.leave), trailing: l.status.capitalized)
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Leaves")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $adding) { if let comp = data.company { NavigationStack { AttLeaveEditor(company: comp, member: nil, staff: true) } } }
    }
}

struct AttLeaveDetail: View {
    let leaveID: String
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var recs: [AttRecord]
    @State private var note = ""
    @State private var paid = true
    @State private var loaded = false
    @State private var fileError: String?

    init(leaveID: String, companyID: String) {
        self.leaveID = leaveID; self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        if let l = recs.first(where: { $0.id == leaveID }) {
            form(data, l)
        } else {
            ContentUnavailableView("Leave not found", systemImage: "beach.umbrella")
        }
    }

    private func form(_ data: AttData, _ l: AttRecord) -> some View {
        let d = l.leave
        let staff = data.c.isStaff(engine.me)
        let mine = data.member(l.memberID)?.member.userID == engine.me
        return Form {
            Section {
                LabeledContent("Employee", value: data.name(l.memberID, engine))
                LabeledContent("Type", value: d.type)
                LabeledContent("Dates", value: AttFmt.leaveSpan(d))
                LabeledContent("Status", value: l.deleted ? "Cancelled" : l.status.capitalized)
                if !d.reason.isEmpty { Text(d.reason) }
                LabeledContent("Requested by", value: engine.name(of: l.by))
                if !d.decidedBy.isEmpty { LabeledContent("Decided by", value: engine.name(of: d.decidedBy)) }
                if !d.note.isEmpty { LabeledContent("Note", value: d.note) }
            }
            if !d.files.isEmpty {
                Section("Attachments") {
                    ForEach(d.files) { f in
                        Button { open(f) } label: { Label(f.name, systemImage: f.kind == "image" ? "photo" : "doc") }
                    }
                }
            }
            if staff && l.status == "pending" && !l.deleted, let w = AttSandwich.note(d, data: data) {
                Section { Label(w, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) } footer: { Text("Only a flag for you — you decide. Many companies count such offs as leave (sandwich rule).") }
            }
            if staff && l.status == "pending" && !l.deleted {
                Section("Decision") {
                    Toggle("Paid leave", isOn: $paid)
                    TextField("Note (optional)", text: $note)
                    Button("Approve", systemImage: "checkmark.circle.fill") { engine.attDecideLeave(l, approve: true, note: note, paid: paid); Haptics.success(); dismiss() }
                    Button("Reject", systemImage: "xmark.circle.fill", role: .destructive) { engine.attDecideLeave(l, approve: false, note: note, paid: paid); dismiss() }
                }
            }
            if !l.deleted {
                if mine && l.status == "pending" {
                    Button("Cancel my request", role: .destructive) {
                        if let comp = data.company, let m = data.member(l.memberID) { engine.attSaveLeave(company: comp, member: m, existing: l, d, status: "pending", deleted: true) }
                        dismiss()
                    }
                } else if data.c.ownerID == engine.me {
                    Button("Delete (moves to archive)", role: .destructive) { engine.attDelete(l); dismiss() }
                }
            }
        }
        .navigationTitle("Leave")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                ShareMenu(title: "Leave — \(data.name(l.memberID, engine))", text: { AttExport.leaveText(data, l, engine: engine) }, module: "Attendance", icon: "person.badge.clock.fill", colors: [0x11998E, 0x38EF7D])
            }
        }
        .onAppear { if !loaded { loaded = true; paid = d.paid } }
        .alert(fileError ?? "", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) { Button("OK") {} }
    }

    private func open(_ f: AttachmentRef) {
        Task { @MainActor in
            do { Presenter.preview(try await Attachments.load(f)) } catch { fileError = "Couldn't open the file. It may have expired (files are kept 45 days)." }
        }
    }
}

struct AttLeaveEditor: View {
    let company: AttRecord
    let member: AttRecord?
    let staff: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var recs: [AttRecord]
    @State private var who = ""
    @State private var d = AttLeaveData()
    @State private var approveNow = true
    @State private var uploads: [String: String] = [:]
    @State private var fileError: String?

    init(company: AttRecord, member: AttRecord?, staff: Bool) {
        self.company = company; self.member = member; self.staff = staff
        let cid = company.id
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == cid && $0.kind == "member" && !$0.deleted })
    }

    private var scanSpec: ScanSpec {
        ScanSpec(title: "Scan a medical certificate or leave letter", what: "a medical certificate, fitness certificate or leave application letter",
                 fields: [.date("from", "Leave from"), .date("to", "Leave to"), .choice("type", "Leave type", company.company.leaveTypes),
                          .long("reason", "Reason (as written; doctor and hospital if any)")],
                 hint: "If only 'rest for N days from DATE' is written, 'to' is DATE plus N−1 days.")
    }

    private func applyScan(_ o: ScanOutput) {
        if let v = o.date("from") { d.from = v; if d.to < v { d.to = v } }
        if let v = o.date("to"), v >= d.from { d.to = v }
        if let v = o.str("type"), company.company.leaveTypes.contains(v) { d.type = v }
        if let v = o.str("reason") { d.reason = d.reason.isEmpty ? v : d.reason + "\n" + v }
        for p in o.files { d.files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
    }

    var body: some View {
        Form {
            AIScanSection(spec: scanSpec, onApply: applyScan)
            if member == nil {
                Picker("Employee", selection: $who) {
                    Text("Choose…").tag("")
                    ForEach(recs.filter { $0.member.active }) { m in Text(m.member.name.isEmpty ? engine.name(of: m.member.userID) : m.member.name).tag(m.id) }
                }
            }
            Section {
                DatePicker("From", selection: $d.from, displayedComponents: .date)
                DatePicker("To", selection: $d.to, in: d.from..., displayedComponents: .date)
                if Calendar.current.isDate(d.from, inSameDayAs: d.to) { Toggle("Half day", isOn: $d.halfDay) }
                Picker("Type", selection: $d.type) { ForEach(company.company.leaveTypes, id: \.self) { Text($0).tag($0) } }
                Toggle(staff ? "Paid leave" : "Request as paid leave", isOn: $d.paid)
                TextField("Reason", text: $d.reason, axis: .vertical)
            } footer: { Text("\(d.days.formatted()) day\(d.days == 1 ? "" : "s")") }
            Section("Attachments (medical certificate, letter…)") {
                ForEach(d.files) { f in Label(f.name, systemImage: f.kind == "image" ? "photo" : "doc") }
                    .onDelete { d.files.remove(atOffsets: $0) }
                Button("Add document or photo", systemImage: "paperclip") {
                    Presenter.file(types: [.pdf, .image, .data]) { url in
                        do { let p = try Attachments.prepareFile(url); d.files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                        catch { fileError = "Couldn't attach that file." }
                    }
                }
                if Presenter.hasCamera {
                    Button("Take a photo", systemImage: "camera") {
                        Presenter.camera { img in
                            if let data = img.jpegData(compressionQuality: 0.9), let p = try? Attachments.prepareImage(data) {
                                d.files.append(p.ref); uploads[p.upload.0] = p.upload.1
                            }
                        }
                    }
                }
            }
            if staff { Section { Toggle("Approve now", isOn: $approveNow) } footer: { Text("Approved leave shows on the employee's calendar and in payable days.") } }
        }
        .navigationTitle(staff ? "Record leave" : "Apply for leave")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(staff ? "Save" : "Send") { save() }.disabled(member == nil && who.isEmpty) }
        }
        .onAppear { if let t = company.company.leaveTypes.first, !company.company.leaveTypes.contains(d.type) { d.type = t } }
        .alert(fileError ?? "", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) { Button("OK") {} }
    }

    private func save() {
        guard let m = member ?? recs.first(where: { $0.id == who }) else { return }
        if !Calendar.current.isDate(d.from, inSameDayAs: d.to) { d.halfDay = false }
        if d.to < d.from { d.to = d.from }
        engine.attSaveLeave(company: company, member: m, existing: nil, d, status: staff && approveNow ? "approved" : "pending", uploads: uploads)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Holidays

struct AttHolidaysView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]
    @State private var adding = false
    @State private var date = Date.now
    @State private var name = ""
    @State private var type = "govt"

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        let isOwner = data.c.ownerID == engine.me
        List {
            let pending = data.holidays.filter { $0.status == "pending" }
            if !pending.isEmpty {
                Section("Waiting for the owner") {
                    ForEach(pending) { h in
                        HStack {
                            row(h)
                            if isOwner, let comp = data.company {
                                Button("Approve") { engine.attSaveHoliday(company: comp, existing: h, date: Att.date(h.day), name: h.holiday.name, type: h.holiday.type, status: "approved") }
                                    .buttonStyle(.glassProminent).controlSize(.small)
                                Button { engine.attSaveHoliday(company: comp, existing: h, date: Att.date(h.day), name: h.holiday.name, type: h.holiday.type, status: "rejected") } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.glass).controlSize(.small)
                            }
                        }
                    }
                }
                .lookRows()
            }
            Section("Holidays") {
                let approved = data.holidays.filter { $0.status == "approved" }
                if approved.isEmpty { Text("No holidays yet.").foregroundStyle(.secondary) }
                ForEach(approved) { h in row(h) }
                    .onDelete { idx in if isOwner { idx.map { approved[$0] }.forEach { engine.attDelete($0) } } }
            }
            .lookRows()
            if isOwner, let comp = data.company {
                Section {
                    Button("Add national holidays for \(Calendar.current.component(.year, from: .now))", systemImage: "flag.2.crossed") { addNational(comp, data) }
                } footer: { Text("Adds Republic Day (26 Jan), Independence Day (15 Aug) and Gandhi Jayanti (2 Oct). Festival dates change every year — add them yourself.") }
            }
        }
        .lookScreen()
        .navigationTitle("Holidays")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Name (e.g. Diwali)", text: $name)
                    Picker("Kind", selection: $type) { Text("Government").tag("govt"); Text("Other").tag("other") }.pickerStyle(.segmented)
                    if !isOwner { Text("The owner approves holidays added by admins.").font(.footnote).foregroundStyle(.secondary) }
                }
                .navigationTitle("Add holiday")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let comp = data.company { engine.attSaveHoliday(company: comp, date: date, name: name, type: type) }
                            name = ""; adding = false
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func row(_ h: AttRecord) -> some View {
        AttLine(icon: h.holiday.type == "govt" ? "building.columns.fill" : "flag.fill", color: 0x007AFF, title: h.holiday.name,
                detail: Att.date(h.day).formatted(date: .complete, time: .omitted) + (h.by.isEmpty ? "" : " · added by \(engine.name(of: h.by))"), trailing: "")
    }

    private func addNational(_ comp: AttRecord, _ data: AttData) {
        let y = Calendar.current.component(.year, from: .now)
        for (m, d, n) in [(1, 26, "Republic Day"), (8, 15, "Independence Day"), (10, 2, "Gandhi Jayanti")] {
            guard let date = Calendar.current.date(from: DateComponents(year: y, month: m, day: d)),
                  !data.holidays.contains(where: { $0.day == Att.key(date) }) else { continue }
            engine.attSaveHoliday(company: comp, date: date, name: n, type: "govt")
        }
        Haptics.success()
    }
}

// MARK: - Change requests from admins (owner approves)

struct AttChangesView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]
    @State private var notes: [String: String] = [:]

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        let isOwner = data.c.ownerID == engine.me
        List {
            if data.changes.isEmpty { Text("No change requests.").foregroundStyle(.secondary) }
            ForEach(data.changes) { x in
                Section {
                    card(data, x)
                    if isOwner && x.status == "pending" {
                        TextField("Note (optional)", text: Binding(get: { notes[x.id] ?? "" }, set: { notes[x.id] = $0 }))
                        HStack {
                            Button("Approve") { engine.attDecideChange(x, approve: true, note: notes[x.id] ?? ""); Haptics.success() }.buttonStyle(.glassProminent)
                            Button("Reject", role: .destructive) { engine.attDecideChange(x, approve: false, note: notes[x.id] ?? "") }.buttonStyle(.glass)
                        }
                    }
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle("Change requests")
    }

    private func card(_ data: AttData, _ x: AttRecord) -> some View {
        let ch = x.change
        let old = ch.entryID.isEmpty ? nil : recs.first { $0.id == ch.entryID }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(data.name(x.memberID, engine)) · \(Att.date(x.day).formatted(date: .abbreviated, time: .omitted))").font(.headline)
                Spacer()
                Text(x.status.capitalized).font(.caption.bold()).foregroundStyle(x.status == "approved" ? .green : x.status == "rejected" ? .red : .orange)
            }
            Text("Now: \(AttFmt.times(old?.entry) ?? "no punch")\(old?.status.isEmpty == false ? " · " + Att.label(old!.status) : "")").font(.caption)
            Text(ch.deleteEntry ? "Asked: delete the entry" : "Asked: \(AttFmt.times(ch.proposed) ?? "no punch")\(ch.proposedStatus.isEmpty ? "" : " · " + Att.label(ch.proposedStatus))")
                .font(.caption.bold())
            if !ch.reason.isEmpty { Text("Reason: \(ch.reason)").font(.caption).foregroundStyle(.secondary) }
            Text("By \(engine.name(of: x.by)) · \(x.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reports & export

struct AttReportsView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]
    @State private var month = Date.now
    @State private var shareItems: ShareItems?

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        let title = "\(data.c.name) — \(month.formatted(.dateTime.month(.wide).year()))"
        List {
            Section { AttMonthPicker(month: $month) }.listRowBackground(Color.clear)
            Section("Summary") {
                HStack { Text("Name").frame(maxWidth: .infinity, alignment: .leading); ForEach(["P", "L", "H", "A", "LV", "Pay"], id: \.self) { Text($0).frame(width: 30) } }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(data.active) { m in
                    let s = data.summary(m, month: month)
                    HStack {
                        Text(data.name(m, engine)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Group {
                            Text("\(s.present)"); Text("\(s.n("late") + s.n("grace"))"); Text("\(s.n("halfday"))")
                            Text("\(s.n("absent"))"); Text("\(s.n("leave") + s.n("unpaid"))"); Text(s.payable.formatted())
                        }
                        .frame(width: 30)
                    }
                    .font(.caption)
                }
            }
            .lookRows()
            AttPunctualitySection(data: data, month: month).lookRows()
            Section {
                Button("Register (PDF)", systemImage: "doc.richtext") {
                    if let url = PDFMaker.make(title: title, bodyHTML: AttExport.registerHTML(data, month: month, engine: engine), fileName: "Attendance register", module: "Attendance", icon: "person.badge.clock.fill", colors: [0x11998E, 0x38EF7D], charts: PDFCharts.attendance(data, month: month, engine: engine)) { shareItems = ShareItems(items: [url]) }
                }
                Button("Daily log (Excel CSV)", systemImage: "tablecells") {
                    if let url = Exporter.file(AttExport.dailyCSV(data, month: month, engine: engine), name: "Attendance \(Att.key(month).prefix(7)).csv") { shareItems = ShareItems(items: [url]) }
                }
                Button("Monthly summary (Excel CSV)", systemImage: "tablecells.badge.ellipsis") {
                    if let url = Exporter.file(AttExport.summaryCSV(data, month: month, engine: engine), name: "Attendance summary \(Att.key(month).prefix(7)).csv") { shareItems = ShareItems(items: [url]) }
                }
                Button("Tally (XML attendance vouchers)", systemImage: "arrow.down.doc") {
                    if let url = Exporter.file(AttExport.tallyXML(data, month: month, engine: engine), name: "Tally attendance \(Att.key(month).prefix(7)).xml") { shareItems = ShareItems(items: [url]) }
                }
            } header: { Text("Export") } footer: {
                Text("Tally: in TallyPrime Payroll, create the employees with exactly the same names and the attendance types “Present” and “Absent”, then Import → Transactions. Present = payable days (incl. paid leave, holidays and weekly offs).")
            }
            .lookRows()
            Section {
                AIButton(title: "Attendance insights", feature: .attendance,
                         instructions: "You are an HR assistant. From this month's attendance, point out patterns: who is often late or absent, half days, leave trends, and fair, practical suggestions. Short bullets. Advice only — never accuse anyone.",
                         context: { AttExport.aiContext(data, month: month, engine: engine) })
            }
        }
        .lookScreen()
        .navigationTitle("Reports")
        .shareSheet($shareItems)
    }
}

// MARK: - Settings (owner)

struct AttSettingsView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var recs: [AttRecord]
    @State private var d = AttCompanyData()
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var types = ""
    @State private var loaded = false
    @State private var locating = false
    @State private var confirmClose = false
    @AppStorage("att.remind") private var remind = true

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.id == companyID })
    }

    var body: some View {
        Form {
            Section("Company") { TextField("Name", text: $d.name) }
            Section {
                DatePicker("Duty starts", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Duty ends", selection: $end, displayedComponents: .hourAndMinute)
                Stepper("Grace: \(d.grace) min", value: $d.grace, in: 0...120, step: 5)
                Stepper("Half day after: \(d.halfDayAfter) min", value: $d.halfDayAfter, in: max(d.grace, 5)...300, step: 15)
            } header: { Text("Timings") } footer: {
                Text("Up to \(Att.clock(Att.minutes(start))) = Present · till \(Att.clock(Att.minutes(start) + d.grace)) = Present (grace) · till \(Att.clock(Att.minutes(start) + d.halfDayAfter)) = Late · after that = Half day · not marked = Absent.")
            }
            Section("Weekly off") {
                ForEach(1...7, id: \.self) { wd in
                    Toggle(Calendar.current.weekdaySymbols[wd - 1], isOn: Binding(get: { d.weeklyOff.contains(wd) }, set: { on in
                        if on { d.weeklyOff.append(wd) } else { d.weeklyOff.removeAll { $0 == wd } }
                    }))
                }
            }
            Section {
                Toggle("Employees punch on their own phone", isOn: $d.selfPunch)
                if d.selfPunch {
                    Toggle("Require QR scan (rotating code)", isOn: $d.needQR)
                    Toggle("Require selfie", isOn: $d.needPhoto)
                    Toggle("Require location", isOn: $d.needGeo)
                }
                Toggle("Kiosk on owner/admin phone or iPad", isOn: $d.kiosk)
            } header: { Text("How attendance is marked") } footer: {
                Text("Without any requirement, a tap is enough (direct input). The owner and admins can always mark anyone. Kiosk asks for the person's PIN and takes a selfie when “Require selfie” is on.")
            }
            Section {
                if d.hasOffice {
                    LabeledContent("Office", value: String(format: "%.5f, %.5f", d.lat, d.lon))
                }
                Button(locating ? "Getting location…" : "Use my current location as the office", systemImage: "location.fill") {
                    locating = true
                    Task { @MainActor in
                        if let l = await AttLocator.shared.current() { d.lat = l.coordinate.latitude; d.lon = l.coordinate.longitude }
                        locating = false
                    }
                }
                .disabled(locating)
                Stepper("Allowed distance: \(Int(d.radius)) m", value: $d.radius, in: 50...2000, step: 50)
            } header: { Text("Office location") } footer: { Text("Punches farther than this are allowed but flagged ⚠️.") }
            Section("Leave types (comma separated)") { TextField("Casual, Sick, Earned", text: $types) }
            Section {
                Toggle("Punch reminders on my phone", isOn: $remind)
                Button("Change the QR key", systemImage: "arrow.triangle.2.circlepath") { d.qrSecret = Att.newSecret() }
            } footer: { Text("Changing the QR key makes old printed or photographed codes useless.") }
            Section {
                Button("Close this company", role: .destructive) { confirmClose = true }
            } footer: { Text("Everything stays readable and exportable in the archive.") }
        }
        .navigationTitle("Rules & settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save(deleted: false) } } }
        .confirmationDialog("Close “\(d.name)”?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close company", role: .destructive) { save(deleted: true) }
        }
        .onAppear(perform: load)
        .onChange(of: remind) { _, _ in AttReminders.update(engine) }
    }

    private func load() {
        guard !loaded, let r = recs.first else { return }
        loaded = true
        d = r.company
        start = Att.at(d.dutyStart, on: .now); end = Att.at(d.dutyEnd, on: .now)
        types = d.leaveTypes.joined(separator: ", ")
    }

    private func save(deleted: Bool) {
        guard let r = recs.first else { return }
        d.dutyStart = Att.minutes(start); d.dutyEnd = Att.minutes(end)
        d.leaveTypes = types.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if d.leaveTypes.isEmpty { d.leaveTypes = ["Casual"] }
        if d.halfDayAfter < d.grace { d.halfDayAfter = d.grace }
        engine.attSaveCompany(r, d, deleted: deleted)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Archive

struct AttArchiveView: View {
    let companyID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var recs: [AttRecord]

    init(companyID: String) {
        self.companyID = companyID
        _recs = Query(filter: #Predicate<AttRecord> { $0.companyID == companyID })
    }

    var body: some View {
        let data = AttData(recs, companyID: companyID)
        List {
            if data.archived.isEmpty { Text("Nothing deleted.").foregroundStyle(.secondary) }
            ForEach(data.archived) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(r, data)).font(.subheadline.weight(.semibold))
                    Text("Deleted by \(engine.name(of: r.deletedBy)) · \(r.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Archive")
    }

    private func title(_ r: AttRecord, _ data: AttData) -> String {
        let day = Att.date(r.day).formatted(date: .abbreviated, time: .omitted)
        switch r.kind {
        case "member": return "👤 \(r.member.name)"
        case "entry": return "🕘 \(recs.first { $0.id == r.memberID }?.member.name ?? "") — \(day) · \(AttFmt.times(r.entry) ?? "")"
        case "leave": return "🌴 \(recs.first { $0.id == r.memberID }?.member.name ?? "") — \(AttFmt.leaveSpan(r.leave))"
        case "holiday": return "🎌 \(r.holiday.name) — \(day)"
        default: return r.kind
        }
    }
}

// MARK: - Exports (PDF register, CSV, Tally XML, text, AI context)

@MainActor
enum AttExport {
    private static func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func registerHTML(_ data: AttData, month: Date, engine: SyncEngine) -> String {
        let days = Att.monthDays(month)
        var h = "<p class=\"muted\">Duty \(Att.clock(data.c.dutyStart))–\(Att.clock(data.c.dutyEnd)) · grace \(data.c.grace) min · half day after \(data.c.halfDayAfter) min. "
        h += "P present · G grace · L late · H half day · A absent · PL paid leave · UL unpaid leave · HO holiday · WO weekly off</p>"
        h += "<table style=\"font-size:6.5pt\"><tr><th>Name</th>"
        for d in days { h += "<th>\(Calendar.current.component(.day, from: d))</th>" }
        h += "<th>P</th><th>H</th><th>A</th><th>LV</th><th>Pay</th></tr>"
        for m in data.active {
            let s = data.summary(m, month: month)
            h += "<tr><td>\(PDFMaker.esc(data.name(m, engine)))</td>"
            for d in days {
                let st = data.status(m, d)
                h += "<td style=\"color:#\(String(format: "%06X", Att.color(st)))\">\(Att.code(st) == "·" ? "" : Att.code(st))</td>"
            }
            h += "<td>\(s.present)</td><td>\(s.n("halfday"))</td><td>\(s.n("absent"))</td><td>\(s.n("leave") + s.n("unpaid"))</td><td><b>\(s.payable.formatted())</b></td></tr>"
        }
        return h + "</table>"
    }

    static func memberHTML(_ data: AttData, _ m: AttRecord, month: Date, engine: SyncEngine) -> String {
        let s = data.summary(m, month: month)
        let md = m.member
        var h = "<p>\(PDFMaker.esc([md.designation, md.department].filter { !$0.isEmpty }.joined(separator: " · ")))</p>"
        h += "<p>Present \(s.present) · Late/grace \(s.n("late") + s.n("grace")) · Half days \(s.n("halfday")) · Absent \(s.n("absent")) · Leave \(s.n("leave") + s.n("unpaid")) · Holidays \(s.n("holiday")) · Weekly off \(s.n("off")) · <b>Payable days \(s.payable.formatted())</b> · Hours \(AttFmt.hours(s.minutesWorked))</p>"
        h += "<table><tr><th>Date</th><th>Status</th><th>In</th><th>Out</th><th>Hours</th><th>How</th><th>Note</th></tr>"
        for d in Att.monthDays(month) where d <= .now {
            let e = data.entry(m, d)?.entry
            let mins = e.flatMap { x in x.inAt.flatMap { i in x.outAt.map { Int($0.timeIntervalSince(i) / 60) } } }
            h += "<tr><td>\(d.formatted(date: .abbreviated, time: .omitted))</td><td>\(Att.label(data.status(m, d)))</td><td>\(AttFmt.t(e?.inAt))</td><td>\(AttFmt.t(e?.outAt))</td>"
            h += "<td>\(mins.map(AttFmt.hours) ?? "")</td><td>\(e.map { AttFmt.method($0.method) } ?? "")</td><td>\(PDFMaker.esc(e?.note ?? ""))</td></tr>"
        }
        return h + "</table>"
    }

    static func dailyCSV(_ data: AttData, month: Date, engine: SyncEngine) -> String {
        var rows = ["Name,Department,Designation,Date,Day,Status,In,Out,Hours,Method,Distance (m),Note"]
        for m in data.active {
            for d in Att.monthDays(month) where d <= .now {
                let e = data.entry(m, d)?.entry
                let mins = e.flatMap { x in x.inAt.flatMap { i in x.outAt.map { Int($0.timeIntervalSince(i) / 60) } } }
                let inT: String = e?.inAt?.formatted(date: .omitted, time: .shortened) ?? ""
                let outT: String = e?.outAt?.formatted(date: .omitted, time: .shortened) ?? ""
                let hrs: String = mins.map { String(format: "%.2f", Double($0) / 60) } ?? ""
                let how: String = e.map { AttFmt.method($0.method) } ?? ""
                let dist: String = e?.distance.map { String(Int($0)) } ?? ""
                var cols: [String] = [csv(data.name(m, engine)), csv(m.member.department), csv(m.member.designation), Att.key(d)]
                cols += [d.formatted(.dateTime.weekday(.abbreviated)), csv(Att.label(data.status(m, d))), inT, outT, hrs, how, dist, csv(e?.note ?? "")]
                rows.append(cols.joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n")
    }

    static func summaryCSV(_ data: AttData, month: Date, engine: SyncEngine) -> String {
        var rows = ["Name,Department,Mobile,Present,Grace,Late,Half days,Absent,Paid leave,Unpaid leave,Holidays,Weekly off,Payable days,Hours worked"]
        for m in data.active {
            let s = data.summary(m, month: month)
            rows.append([csv(data.name(m, engine)), csv(m.member.department), csv(m.member.mobile), "\(s.n("present"))", "\(s.n("grace"))", "\(s.n("late"))",
                         "\(s.n("halfday"))", "\(s.n("absent"))", "\(s.n("leave"))", "\(s.n("unpaid"))", "\(s.n("holiday"))", "\(s.n("off"))",
                         s.payable.formatted(), String(format: "%.1f", Double(s.minutesWorked) / 60)].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    /// TallyPrime payroll attendance vouchers: one voucher dated the month's last day, Present and Absent days per employee.
    static func tallyXML(_ data: AttData, month: Date, engine: SyncEngine) -> String {
        let last = Att.monthDays(month).last ?? month
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        var lines = ""
        for m in data.active {
            let s = data.summary(m, month: month)
            let absent = Double(s.n("absent") + s.n("unpaid")) + Double(s.n("halfday")) * 0.5
            let name = xml(data.name(m, engine))
            lines += """
                  <ATTENDANCEENTRIES.LIST>
                   <NAME>\(name)</NAME>
                   <ATTENDANCETYPE>Present</ATTENDANCETYPE>
                   <ATTDTYPEVALUE> \(s.payable.formatted(.number.grouping(.never)))</ATTDTYPEVALUE>
                  </ATTENDANCEENTRIES.LIST>
                  <ATTENDANCEENTRIES.LIST>
                   <NAME>\(name)</NAME>
                   <ATTENDANCETYPE>Absent</ATTENDANCETYPE>
                   <ATTDTYPEVALUE> \(absent.formatted(.number.grouping(.never)))</ATTDTYPEVALUE>
                  </ATTENDANCEENTRIES.LIST>

            """
        }
        return """
        <ENVELOPE>
         <HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER>
         <BODY>
          <IMPORTDATA>
           <REQUESTDESC>
            <REPORTNAME>Vouchers</REPORTNAME>
            <STATICVARIABLES><SVCURRENTCOMPANY>\(xml(data.c.name))</SVCURRENTCOMPANY></STATICVARIABLES>
           </REQUESTDESC>
           <REQUESTDATA>
            <TALLYMESSAGE xmlns:UDF="TallyUDF">
             <VOUCHER VCHTYPE="Attendance" ACTION="Create" OBJVIEW="Attendance Voucher View">
              <DATE>\(f.string(from: last))</DATE>
              <VOUCHERTYPENAME>Attendance</VOUCHERTYPENAME>
              <NARRATION>Attendance for \(month.formatted(.dateTime.month(.wide).year())) from iTeam</NARRATION>
        \(lines)     </VOUCHER>
            </TALLYMESSAGE>
           </REQUESTDATA>
          </IMPORTDATA>
         </BODY>
        </ENVELOPE>
        """
    }

    static func leaveText(_ data: AttData, _ l: AttRecord, engine: SyncEngine) -> String {
        let d = l.leave
        return ["Leave — \(data.c.name)", "Employee: \(data.name(l.memberID, engine))", "Type: \(d.type)", "Dates: \(AttFmt.leaveSpan(d))",
                "Status: \(l.status.capitalized)", d.reason.isEmpty ? "" : "Reason: \(d.reason)", d.note.isEmpty ? "" : "Note: \(d.note)"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func aiContext(_ data: AttData, month: Date, engine: SyncEngine) -> String {
        var out = ["Company: \(data.c.name). Month: \(month.formatted(.dateTime.month(.wide).year())). Duty \(Att.clock(data.c.dutyStart))–\(Att.clock(data.c.dutyEnd)), grace \(data.c.grace) min."]
        for m in data.active.prefix(60) {
            let s = data.summary(m, month: month)
            let lateDays = Att.monthDays(month).filter { ["late", "halfday"].contains(data.status(m, $0)) }
                .map { $0.formatted(.dateTime.weekday(.abbreviated)) }
            out.append("- \(data.name(m, engine)) (\(m.member.department)): present \(s.present), late \(s.n("late")), grace \(s.n("grace")), half \(s.n("halfday")), absent \(s.n("absent")), leave \(s.n("leave") + s.n("unpaid"))\(lateDays.isEmpty ? "" : ", late on " + lateDays.joined(separator: " "))")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Demo company (local, sample people not on iTeam)

@MainActor
enum AttDemo {
    static func create(_ engine: SyncEngine) {
        let me = engine.me
        let cid = "attc_demo_" + UUID().uuidString.prefix(8)
        var c = AttCompanyData()
        c.name = "Demo Traders (sample)"; c.ownerID = me; c.qrSecret = Att.newSecret(); c.dutyStart = 570; c.dutyEnd = 1110
        var items = [AttItem(id: cid, kind: "company", companyID: cid, data: AttItem.enc(c), by: me)]
        let people = [("Asha", "Patil", "Accounts", "Accountant"), ("Rahul", "Shinde", "Sales", "Executive"), ("Meera", "Joshi", "Sales", "Manager"),
                      ("Sunil", "Kale", "Store", "Helper"), ("Priya", "Deshmukh", "Office", "Receptionist")]
        var ids: [String] = []
        for (i, p) in people.enumerated() {
            var m = AttMemberData()
            m.first = p.0; m.last = p.1; m.department = p.2; m.designation = p.3; m.accepted = true
            m.joined = Calendar.current.date(byAdding: .day, value: -30, to: .now); m.mobile = "98\(20000000 + i * 1111111)"
            let id = "attm_demo_\(cid.suffix(8))_\(i)"
            ids.append(id)
            items.append(AttItem(id: id, kind: "member", companyID: cid, status: "employee", data: AttItem.enc(m), by: me))
        }
        let cal = Calendar.current
        for back in 0...14 {
            guard let day = cal.date(byAdding: .day, value: -back, to: .now), !c.weeklyOff.contains(cal.component(.weekday, from: day)) else { continue }
            for (i, id) in ids.enumerated() {
                if (i + back) % 9 == 4 { continue }   // absent now and then
                let offset = [-12, 3, 9, 25, -5, 70, 14][(i * 3 + back) % 7]
                let inAt = Att.at(c.dutyStart + offset, on: day)
                if back == 0 && inAt > .now { continue }
                var e = AttEntryData(); e.inAt = inAt; e.method = ["kiosk", "qr", "photo", "manual"][(i + back) % 4]; e.markedBy = me
                if back > 0 { e.outAt = Att.at(c.dutyEnd + (i * 7 % 30), on: day) }
                items.append(AttItem(id: "atte_\(id)_\(Att.key(day))", kind: "entry", companyID: cid, memberID: id, day: Att.key(day), data: AttItem.enc(e), by: me))
            }
        }
        var l = AttLeaveData(); l.from = cal.date(byAdding: .day, value: 2, to: .now) ?? .now; l.to = cal.date(byAdding: .day, value: 3, to: .now) ?? .now
        l.type = "Casual"; l.reason = "Sister's wedding"
        items.append(AttItem(id: "attl_demo_\(cid.suffix(8))", kind: "leave", companyID: cid, memberID: ids[1], day: Att.key(l.from), status: "pending", data: AttItem.enc(l), by: me))
        if let h = cal.date(byAdding: .day, value: 10, to: .now) {
            items.append(AttItem(id: "atth_demo_\(cid.suffix(8))", kind: "holiday", companyID: cid, day: Att.key(h), status: "approved",
                                 data: AttItem.enc(AttHolidayData(name: "Company foundation day", type: "other")), by: me))
        }
        engine.sendPersonal(.attendance(AttPayload(items: items, bulk: true)))
        UserDefaults.standard.set(cid, forKey: "att.current")
        Haptics.success()
    }
}


// MARK: - Leave next to a weekend / holiday (flag only; the manager decides)

enum AttSandwich {
    static func isOff(_ day: Date, _ data: AttData) -> Bool {
        data.c.weeklyOff.contains(Calendar.current.component(.weekday, from: day)) ||
            data.holidays.contains { $0.day == Att.key(day) && $0.status == "approved" }
    }

    static func note(_ d: AttLeaveData, data: AttData) -> String? {
        let cal = Calendar.current
        guard let before = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: d.from)),
              let after = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d.to)) else { return nil }
        let b = isOff(before, data), a = isOff(after, data)
        guard b || a else { return nil }
        let side = b && a ? "both before and after" : b ? "right after a weekly off / holiday" : "right before a weekly off / holiday"
        return "This leave falls \(side). Check it isn't stretching a long weekend."
    }
}

// MARK: - Comes on time / leaves on time (from punches — no AI judgement)

struct AttPunctualitySection: View {
    let data: AttData
    let month: Date
    @EnvironmentObject var engine: SyncEngine

    private struct Row: Identifiable { let id: String; let name: String; let onTime: Int; let leftOnTime: Int; let days: Int }

    private var rows: [Row] {
        let days = Set(Att.monthDays(month).map(Att.key))
        return data.active.compactMap { m in
            let es = data.entries.filter { $0.memberID == m.id && days.contains($0.day) && $0.entry.inAt != nil }
            guard !es.isEmpty else { return nil }
            let start = Att.dutyStart(m.member, data.c) + data.c.grace, end = Att.dutyEnd(m.member, data.c)
            let inOK = es.filter { Att.minutes($0.entry.inAt!) <= start }.count
            let outs = es.compactMap(\.entry.outAt)
            let outOK = outs.filter { Att.minutes($0) >= end }.count
            return Row(id: m.id, name: data.name(m, engine), onTime: inOK * 100 / es.count,
                       leftOnTime: outs.isEmpty ? 0 : outOK * 100 / outs.count, days: es.count)
        }
        .sorted { ($0.onTime + $0.leftOnTime) > ($1.onTime + $1.leftOnTime) }
    }

    var body: some View {
        let r = rows
        if !r.isEmpty {
            Section {
                ForEach(r) { x in
                    HStack {
                        Text(x.name).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(x.onTime)%").frame(width: 50).foregroundStyle(x.onTime >= 90 ? .green : x.onTime >= 70 ? .orange : .red)
                        Text("\(x.leftOnTime)%").frame(width: 50).foregroundStyle(x.leftOnTime >= 90 ? .green : x.leftOnTime >= 70 ? .orange : .red)
                    }
                    .font(.caption)
                }
            } header: { Text("Comes on time · Leaves on time") } footer: {
                Text("From punches this month (duty start + grace, duty end). Facts, not a judgement of anyone's loyalty.")
            }
        }
    }
}
