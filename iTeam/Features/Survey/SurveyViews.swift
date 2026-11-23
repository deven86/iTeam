import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Sync

extension EventApplier {
    func applySurvey(_ p: SurveyPayload, _ e: Event, conv: Conversation?, personal: Bool) -> Result {
        var n = 0
        for it in p.items {
            let id = it.id
            let ex = try? ctx.fetch(FetchDescriptor<SurveyRecord>(predicate: #Predicate { $0.id == id })).first
            if let ex { guard ex.by == e.from || ex.ownerID == e.from, it.at >= ex.updatedAt else { continue } }
            if it.kind == "response", ex == nil {
                let sid = it.surveyID
                guard let s = try? ctx.fetch(FetchDescriptor<SurveyRecord>(predicate: #Predicate { $0.id == sid })).first, s.survey.open || s.ownerID == e.from else { continue }
            }
            let r = ex ?? { let x = SurveyRecord(id: it.id); x.by = e.from; x.createdAt = e.at; x.ownerID = it.kind == "survey" ? e.from : ""; ctx.insert(x); return x }()
            r.kind = it.kind; r.surveyID = it.surveyID; r.data = it.data; r.updatedAt = it.at
            if it.kind == "response", r.ownerID.isEmpty {
                let sid = it.surveyID
                r.ownerID = (try? ctx.fetch(FetchDescriptor<SurveyRecord>(predicate: #Predicate { $0.id == sid })).first)?.ownerID ?? ""
            }
            if !personal, let conv, r.convID.isEmpty { r.convID = conv.id }
            if it.deleted { r.deleted = true }
            n += 1
            if let conv, !personal {
                let who = e.from == me ? "You" : engine.name(of: e.from)
                if it.kind == "survey" && ex == nil { system(conv, "📋 \(who) started a survey — “\(r.survey.title)”", at: e.at) }
                if it.kind == "response" && ex == nil {
                    let sid = it.surveyID
                    let title = (try? ctx.fetch(FetchDescriptor<SurveyRecord>(predicate: #Predicate { $0.id == sid })).first)?.survey.title ?? "a survey"
                    system(conv, "📝 \(who) answered “\(title)”", at: e.at)
                }
            }
        }
        return n > 0 ? .applied : .ignored
    }
}

@MainActor
extension SyncEngine {
    func surveySave(_ r: SurveyRecord?, id: String? = nil, kind: String, surveyID: String, data: Data, convID: String, deleted: Bool = false, uploads: [String: String] = [:]) {
        let item = SurveyItem(id: r?.id ?? id ?? "sv_" + UUID().uuidString, kind: kind, surveyID: surveyID, deleted: deleted, at: .now, data: data)
        let body = Event.Body.survey(SurveyPayload(items: [item]))
        if let conv = conversation(convID), !conv.left {
            send(body, in: conv, loud: r == nil, preview: r == nil ? (kind == "survey" ? "📋 New survey — please answer" : "📝 New survey response") : nil, uploads: uploads)
        } else {
            send(body, convID: selfConversationID, recipients: [], keyVersion: 0, loud: false, uploads: uploads)
        }
    }

    /// Answers go privately to the survey's creator (direct chat), or stay on my phone when I'm the surveyor (offline).
    func surveyRespond(_ s: SurveyRecord, _ resp: SurveyResponse, uploads: [String: String]) {
        let data = (try? JSONEncoder().encode(resp)) ?? Data()
        let id = "svr_" + UUID().uuidString
        if s.ownerID == me {
            surveySave(nil, id: id, kind: "response", surveyID: s.id, data: data, convID: "", uploads: uploads)
        } else if let c = contact(s.ownerID) {
            // The creator needs the survey to exist on their side — it does, they made it.
            surveySave(nil, id: id, kind: "response", surveyID: s.id, data: data, convID: directConversation(with: c).id, uploads: uploads)
        } else {
            surveySave(nil, id: id, kind: "response", surveyID: s.id, data: data, convID: s.convID, uploads: uploads)
        }
    }
}

// MARK: - Home

struct SurveyHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Query(filter: #Predicate<SurveyRecord> { !$0.deleted }, sort: \SurveyRecord.createdAt, order: .reverse) private var all: [SurveyRecord]
    @State private var creating = false
    @State private var shareItems: ShareItems?

    var body: some View {
        let surveys = all.filter { $0.kind == "survey" }
        let responses = all.filter { $0.kind == "response" }
        let mine = surveys.filter { $0.ownerID == engine.me }
        let toAnswer = surveys.filter { s in s.ownerID != engine.me && s.survey.open && !responses.contains { $0.surveyID == s.id && $0.by == engine.me } }
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        AttTile(value: "\(mine.count)", label: "My surveys", icon: "list.clipboard.fill", color: 0x6366F1)
                        AttTile(value: "\(responses.filter { r in mine.contains { $0.id == r.surveyID } }.count)", label: "Responses", icon: "tray.full.fill", color: 0x10B981)
                        AttTile(value: "\(toAnswer.count)", label: "To answer", icon: "questionmark.circle.fill", color: 0xF59E0B)
                    }
                }
                .listRowBackground(Color.clear)
                if !toAnswer.isEmpty {
                    Section("Needs your answer") {
                        ForEach(toAnswer) { s in NavigationLink { SurveyRespondView(surveyID: s.id) } label: { row(s, responses) } }
                    }
                    .lookRows()
                }
                Section("My surveys") {
                    if mine.isEmpty {
                        Button("Create a survey", systemImage: "plus") { creating = true }
                        Button("Personal checklist just for me", systemImage: "person.fill.checkmark") { creating = true }
                        Button("Try a demo", systemImage: "wand.and.stars") { SurveyDemo.create(engine) }
                    }
                    ForEach(mine) { s in NavigationLink { SurveyDetailView(surveyID: s.id) } label: { row(s, responses) } }
                }
                .lookRows()
                let others = surveys.filter { $0.ownerID != engine.me && !toAnswer.contains($0) }
                if !others.isEmpty {
                    Section("Answered / closed") {
                        ForEach(others) { s in NavigationLink { SurveyRespondView(surveyID: s.id) } label: { row(s, responses) } }
                    }
                    .lookRows()
                }
            }
            .lookScreen()
            .navigationTitle("Surveys")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") } } }
            .sheet(isPresented: $creating) { NavigationStack { SurveyEditor(existing: nil) } }
            .refreshable { await engine.sync() }
        }
    }

    private func row(_ s: SurveyRecord, _ responses: [SurveyRecord]) -> some View {
        let d = s.survey
        let icon = SurveyKinds.types.first { $0.0 == d.type }?.2 ?? "list.clipboard"
        return HStack {
            Image(systemName: icon).font(.title3).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(.headline)
                Text("\(SurveyKinds.types.first { $0.0 == d.type }?.1 ?? "Survey") · \(d.questions.count) questions · \(responses.filter { $0.surveyID == s.id }.count) responses\(d.open ? "" : " · closed")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Create / edit

struct SurveyEditor: View {
    let existing: SurveyRecord?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.lastActivity, order: .reverse) private var chats: [Conversation]
    @State private var d = SurveyData()
    @State private var convID = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Title (e.g. Plot survey — Gat 112)", text: $d.title)
                Picker("Type", selection: $d.type) { ForEach(SurveyKinds.types, id: \.0) { Text($0.1).tag($0.0) } }
                TextField("About / instructions", text: $d.about, axis: .vertical)
                Toggle("Open for answers", isOn: $d.open)
            }
            if existing == nil {
                Section {
                    Picker("Send to", selection: $convID) {
                        Text("Just me — personal / field survey (offline)").tag("")
                        ForEach(chats.filter { !$0.left && !$0.id.hasPrefix("s_") }) { c in Text(c.title).tag(c.id) }
                    }
                } footer: { Text("Online: everyone in the chat or group can answer; answers come privately to you. Just me: fill it yourself — a personal checklist, site visit or plot-by-plot field survey. Works without internet and stays on your own devices.") }
            }
            Section("Questions") {
                ForEach($d.questions) { $q in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Question", text: $q.text)
                        Picker("Answer type", selection: $q.type) { ForEach(SurveyKinds.questionTypes, id: \.0) { Text($0.1).tag($0.0) } }
                        if q.type == "choice" || q.type == "multi" {
                            TextField("Options, separated by commas", text: Binding(get: { q.options.joined(separator: ", ") },
                                                                                   set: { q.options = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                                .font(.caption)
                        }
                        Toggle("Required", isOn: $q.required).font(.caption)
                    }
                }
                .onDelete { d.questions.remove(atOffsets: $0) }
                .onMove { d.questions.move(fromOffsets: $0, toOffset: $1) }
                Button("Add question", systemImage: "plus") { d.questions.append(SurveyQuestion()) }
                Button("Use the \(SurveyKinds.types.first { $0.0 == d.type }?.1.lowercased() ?? "survey") template", systemImage: "wand.and.stars") { d.questions = SurveyKinds.template(d.type) }
            }
        }
        .navigationTitle(existing == nil ? "New survey" : "Edit survey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    engine.surveySave(existing, kind: "survey", surveyID: "", data: (try? JSONEncoder().encode(d)) ?? Data(), convID: existing?.convID ?? convID)
                    Haptics.success(); dismiss()
                }
                .disabled(d.title.trimmingCharacters(in: .whitespaces).isEmpty || d.questions.isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let existing { d = existing.survey } else { d.questions = SurveyKinds.template("online") }
        }
    }
}

// MARK: - Results

struct SurveyDetailView: View {
    let surveyID: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var found: [SurveyRecord]
    @Query private var responses: [SurveyRecord]
    @State private var editing = false
    @State private var collecting = false
    @State private var shareItems: ShareItems?

    init(surveyID: String) {
        self.surveyID = surveyID
        _found = Query(filter: #Predicate<SurveyRecord> { $0.id == surveyID })
        _responses = Query(filter: #Predicate<SurveyRecord> { $0.surveyID == surveyID && !$0.deleted }, sort: \SurveyRecord.createdAt, order: .reverse)
    }

    var body: some View {
        if let s = found.first { content(s) } else { Text("Survey not found") }
    }

    private func content(_ s: SurveyRecord) -> some View {
        let d = s.survey
        return List {
            Section {
                if !d.about.isEmpty { Text(d.about) }
                LabeledContent("Responses", value: "\(responses.count)")
                LabeledContent("Status", value: d.open ? "Open" : "Closed")
                Button(d.open ? "Close survey" : "Re-open survey") {
                    var x = d; x.open.toggle()
                    engine.surveySave(s, kind: "survey", surveyID: "", data: (try? JSONEncoder().encode(x)) ?? Data(), convID: s.convID)
                }
                Button("Collect a response (offline / field)", systemImage: "square.and.pencil") { collecting = true }
            }
            Section("Results") {
                ForEach(d.questions) { q in result(q) }
            }
            Section("Responses") {
                ForEach(responses) { r in
                    NavigationLink { SurveyResponseView(survey: d, response: r) } label: {
                        VStack(alignment: .leading) {
                            Text(r.response.respondent.isEmpty ? engine.name(of: r.by) : r.response.respondent).font(.subheadline.weight(.semibold))
                            Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .lookScreen()
        .navigationTitle(d.title)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) { Button("Edit questions", systemImage: "pencil") { editing = true } }
            ToolbarItem(placement: .secondaryAction) {
                Button("Export report (PDF)", systemImage: "doc.richtext") {
                    if let u = PDFMaker.make(title: d.title, bodyHTML: SurveyExport.html(d, responses, engine: engine), fileName: "Survey \(d.title)", module: "Survey",
                                             icon: "list.clipboard.fill", colors: [0x6366F1, 0x10B981], charts: SurveyExport.charts(d, responses)) { shareItems = ShareItems(items: [u]) }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Export Excel (CSV)", systemImage: "tablecells") {
                    if let u = Exporter.file(SurveyExport.csv(d, responses, engine: engine), name: "Survey \(d.title).csv") { shareItems = ShareItems(items: [u]) }
                }
            }
        }
        .sheet(isPresented: $editing) { NavigationStack { SurveyEditor(existing: s) } }
        .sheet(isPresented: $collecting) { NavigationStack { SurveyRespondView(surveyID: s.id, offline: true) } }
        .shareSheet($shareItems)
    }

    @ViewBuilder
    private func result(_ q: SurveyQuestion) -> some View {
        let answers = responses.compactMap { $0.response.answers[q.id] }
        VStack(alignment: .leading, spacing: 4) {
            Text(q.text).font(.subheadline.weight(.semibold))
            switch q.type {
            case "choice", "multi", "yesno":
                let opts = q.type == "yesno" ? ["Yes", "No"] : q.options
                ForEach(opts, id: \.self) { o in
                    let n = answers.filter { $0.choices.contains(o) }.count
                    HStack { Text(o).font(.caption); Spacer(); Text("\(n)").font(.caption.bold()) }
                    ProgressView(value: Double(n), total: Double(max(answers.count, 1)))
                }
            case "rating", "number":
                let nums = answers.compactMap(\.number)
                Text(nums.isEmpty ? "No answers" : "Average \((nums.reduce(0, +) / Double(nums.count)).formatted(.number.precision(.fractionLength(0...1)))) · \(nums.count) answers").font(.caption)
            case "photo", "video":
                Text("\(answers.reduce(0) { $0 + $1.files.count }) files").font(.caption)
            default:
                Text("\(answers.filter { !$0.text.isEmpty || $0.lat != nil || $0.date != nil }.count) answers").font(.caption)
            }
        }
    }
}

struct SurveyResponseView: View {
    let survey: SurveyData
    let response: SurveyRecord
    @EnvironmentObject var engine: SyncEngine
    var body: some View {
        let r = response.response
        List {
            Section {
                LabeledContent("By", value: r.respondent.isEmpty ? engine.name(of: response.by) : "\(r.respondent) (collected by \(engine.name(of: response.by)))")
                LabeledContent("When", value: response.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            ForEach(survey.questions) { q in
                Section(q.text) {
                    let a = r.answers[q.id]
                    if let a {
                        if !a.text.isEmpty { Text(a.text) }
                        if let n = a.number { Text(n.formatted()) }
                        if !a.choices.isEmpty { Text(a.choices.joined(separator: ", ")) }
                        if let d = a.date { Text(d.formatted(date: .long, time: .omitted)) }
                        if let lat = a.lat, let lon = a.lon, let u = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") {
                            Link("📍 \(String(format: "%.5f, %.5f", lat, lon)) — open in Maps", destination: u)
                        }
                        BizFilesList(files: a.files)
                    } else { Text("—").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Response")
    }
}

// MARK: - Answer

struct SurveyRespondView: View {
    let surveyID: String
    var offline = false
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [SurveyRecord]
    @State private var resp = SurveyResponse()
    @State private var uploads: [String: String] = [:]
    @State private var picks: [String: [PhotosPickerItem]] = [:]
    @State private var busy = false
    @State private var sent = false

    init(surveyID: String, offline: Bool = false) {
        self.surveyID = surveyID; self.offline = offline
        _found = Query(filter: #Predicate<SurveyRecord> { $0.id == surveyID })
    }

    var body: some View {
        if let s = found.first { form(s) } else { Text("Survey not found") }
    }

    private func form(_ s: SurveyRecord) -> some View {
        let d = s.survey
        return Form {
            AIScanSection(spec: scanSpec(d)) { o in applyScan(o, d) }
            Section {
                if !d.about.isEmpty { Text(d.about) }
                if offline { TextField("Who / what is surveyed (owner, plot, flat…)", text: $resp.respondent) }
                if !d.open && !offline { Text("This survey is closed.").foregroundStyle(.red) }
            }
            ForEach(d.questions) { q in
                Section { answer(q) } header: { Text(q.text + (q.required ? " *" : "")) }
            }
            if sent { Label("Sent — thank you!", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .navigationTitle(d.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(offline ? "Save response" : "Send") {
                    engine.surveyRespond(s, resp, uploads: uploads)
                    Haptics.success()
                    if offline { resp = SurveyResponse(); uploads = [:] } else { sent = true; dismiss() }
                }
                .disabled(busy || (!d.open && !offline) || d.questions.contains { $0.required && !answered($0) })
            }
        }
    }

    /// A filled paper form → answers (text, numbers, ratings, choices, dates). Photos and location stay manual.
    private func scanSpec(_ d: SurveyData) -> ScanSpec {
        var fs: [ScanField] = [.text("_who", "Who / what is surveyed (name, plot, flat)")]
        for q in d.questions {
            switch q.type {
            case "number", "rating": fs.append(.number(q.id, q.text + (q.type == "rating" ? " (1–5)" : "")))
            case "yesno": fs.append(.choice(q.id, q.text, ["Yes", "No"]))
            case "choice": fs.append(.choice(q.id, q.text, q.options))
            case "multi": fs.append(.text(q.id, q.text + " (any of: " + q.options.joined(separator: ", ") + ")"))
            case "date": fs.append(.date(q.id, q.text))
            case "location", "photo", "video": continue
            default: fs.append(.long(q.id, q.text))
            }
        }
        return ScanSpec(title: "Scan a filled paper form", what: "a filled-in paper survey or questionnaire: \(d.title)", fields: fs,
                        hint: "Copy each answer as the person wrote or ticked it.")
    }

    private func applyScan(_ o: ScanOutput, _ d: SurveyData) {
        if let v = o.str("_who") { resp.respondent = v }
        for q in d.questions {
            guard let v = o.str(q.id) else { continue }
            var a = resp.answers[q.id] ?? SurveyAnswer()
            switch q.type {
            case "number": a.number = ScanFill.number(v)
            case "rating": a.number = ScanFill.number(v).map { min(5, max(1, $0.rounded())) }
            case "yesno", "choice": a.choices = [v]
            case "multi": a.choices = q.options.filter { v.lowercased().contains($0.lowercased()) }
            case "date": a.date = ScanFill.date(v)
            default: a.text = v
            }
            resp.answers[q.id] = a
        }
        for p in o.files { uploads[p.upload.0] = p.upload.1 }
        if let q = d.questions.first(where: { $0.type == "photo" }), !o.files.isEmpty {
            var a = resp.answers[q.id] ?? SurveyAnswer(); a.files += o.files.map(\.ref); resp.answers[q.id] = a
        } else { for p in o.files { uploads.removeValue(forKey: p.upload.0) } }
    }

    private func answered(_ q: SurveyQuestion) -> Bool {
        guard let a = resp.answers[q.id] else { return false }
        return !a.text.isEmpty || a.number != nil || !a.choices.isEmpty || !a.files.isEmpty || a.lat != nil || a.date != nil
    }

    private func bind(_ q: SurveyQuestion) -> Binding<SurveyAnswer> {
        Binding(get: { resp.answers[q.id] ?? SurveyAnswer() }, set: { resp.answers[q.id] = $0 })
    }

    @ViewBuilder
    private func answer(_ q: SurveyQuestion) -> some View {
        let a = bind(q)
        switch q.type {
        case "number": TextField("Number", value: a.number, format: .number).keyboardType(.decimalPad)
        case "rating":
            Picker("Rating", selection: Binding(get: { Int(a.wrappedValue.number ?? 0) }, set: { a.wrappedValue.number = Double($0) })) {
                Text("—").tag(0); ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
            }.pickerStyle(.segmented)
        case "yesno", "choice":
            let opts = q.type == "yesno" ? ["Yes", "No"] : q.options
            Picker("Choice", selection: Binding(get: { a.wrappedValue.choices.first ?? "" }, set: { a.wrappedValue.choices = [$0] })) {
                Text("—").tag(""); ForEach(opts, id: \.self) { Text($0).tag($0) }
            }
        case "multi":
            ForEach(q.options, id: \.self) { o in
                Toggle(o, isOn: Binding(get: { a.wrappedValue.choices.contains(o) }, set: { on in
                    if on { a.wrappedValue.choices.append(o) } else { a.wrappedValue.choices.removeAll { $0 == o } }
                }))
            }
        case "date": DatePicker("Date", selection: Binding(get: { a.wrappedValue.date ?? .now }, set: { a.wrappedValue.date = $0 }), displayedComponents: .date)
        case "location":
            if let lat = a.wrappedValue.lat, let lon = a.wrappedValue.lon { Text(String(format: "📍 %.5f, %.5f", lat, lon)) }
            Button(busy ? "Getting location…" : "Use my current location", systemImage: "location.fill") {
                busy = true
                Task { @MainActor in
                    if let l = await AttLocator.shared.current() { a.wrappedValue.lat = l.coordinate.latitude; a.wrappedValue.lon = l.coordinate.longitude }
                    busy = false
                }
            }
        case "photo", "video":
            ForEach(a.wrappedValue.files) { f in Label(f.name, systemImage: f.kind == "video" ? "video" : "photo") }
            PhotosPicker(selection: Binding(get: { picks[q.id] ?? [] }, set: { picks[q.id] = $0; load(q, $0) }), maxSelectionCount: q.type == "video" ? 1 : 10,
                         matching: q.type == "video" ? .videos : .images) { Label(q.type == "video" ? "Add video" : "Add photos", systemImage: "photo.badge.plus") }
            if q.type == "photo" && Presenter.hasCamera {
                Button("Take photo", systemImage: "camera") {
                    Presenter.camera { img in
                        if let d = img.jpegData(compressionQuality: 0.85), let p = try? Attachments.prepareImage(d) { a.wrappedValue.files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                    }
                }
            }
            if busy { ProgressView() }
        default: TextField("Answer", text: a.text, axis: .vertical)
        }
    }

    private func load(_ q: SurveyQuestion, _ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        busy = true
        Task { @MainActor in
            var ans = resp.answers[q.id] ?? SurveyAnswer()
            for item in items {
                if q.type == "video", let m = try? await item.loadTransferable(type: MovieFile.self), let p = try? await VideoPrep.prepare(m.url, maxSeconds: 300) {
                    ans.files.append(p.ref); uploads[p.upload.0] = p.upload.1
                } else if let d = try? await item.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(d) {
                    ans.files.append(p.ref); uploads[p.upload.0] = p.upload.1
                }
            }
            resp.answers[q.id] = ans
            picks[q.id] = []
            busy = false
        }
    }
}

// MARK: - Export & demo

@MainActor
enum SurveyExport {
    static func value(_ a: SurveyAnswer?) -> String {
        guard let a else { return "" }
        var parts: [String] = []
        if !a.text.isEmpty { parts.append(a.text) }
        if let n = a.number { parts.append(n.formatted()) }
        if !a.choices.isEmpty { parts.append(a.choices.joined(separator: "; ")) }
        if let d = a.date { parts.append(Att.key(d)) }
        if let lat = a.lat, let lon = a.lon { parts.append(String(format: "%.5f,%.5f", lat, lon)) }
        if !a.files.isEmpty { parts.append("\(a.files.count) file(s)") }
        return parts.joined(separator: " · ")
    }
    static func csv(_ d: SurveyData, _ rs: [SurveyRecord], engine: SyncEngine) -> String {
        func c(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let head = ["Respondent", "By", "Date"] + d.questions.map(\.text)
        return ([head.map(c).joined(separator: ",")] + rs.map { r in
            ([r.response.respondent, engine.name(of: r.by), r.createdAt.formatted(date: .numeric, time: .shortened)] + d.questions.map { value(r.response.answers[$0.id]) })
                .map(c).joined(separator: ",")
        }).joined(separator: "\n")
    }
    static func html(_ d: SurveyData, _ rs: [SurveyRecord], engine: SyncEngine) -> String {
        var h = "<p>\(PDFMaker.esc(d.about))</p><p>\(rs.count) responses</p><table><tr><th>Respondent</th>"
        for q in d.questions.prefix(6) { h += "<th>\(PDFMaker.esc(q.text))</th>" }
        h += "</tr>"
        for r in rs {
            h += "<tr><td>\(PDFMaker.esc(r.response.respondent.isEmpty ? engine.name(of: r.by) : r.response.respondent))</td>"
            for q in d.questions.prefix(6) { h += "<td>\(PDFMaker.esc(value(r.response.answers[q.id])))</td>" }
            h += "</tr>"
        }
        return h + "</table>"
    }
    static func charts(_ d: SurveyData, _ rs: [SurveyRecord]) -> [PDFChart] {
        var out: [PDFChart] = []
        for q in d.questions where ["choice", "yesno", "multi"].contains(q.type) {
            let opts = q.type == "yesno" ? ["Yes", "No"] : q.options
            out.append(PDFChart(kind: q.type == "multi" ? .bar : .pie, title: q.text, labels: opts,
                                values: opts.map { o in Double(rs.filter { $0.response.answers[q.id]?.choices.contains(o) == true }.count) }))
        }
        for q in d.questions where q.type == "rating" {
            out.append(PDFChart(kind: .bar, title: q.text, labels: (1...5).map { "\($0)★" },
                                values: (1...5).map { s in Double(rs.filter { Int($0.response.answers[q.id]?.number ?? 0) == s }.count) }))
        }
        let cal = Calendar.current
        let days = (0..<14).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
        out.append(PDFChart(kind: .line, title: "Responses per day", labels: days.map { $0.formatted(.dateTime.day()) },
                            values: days.map { d in Double(rs.filter { cal.isDate($0.createdAt, inSameDayAs: d) }.count) }))
        return Array(out.prefix(6))
    }
}

@MainActor
enum SurveyDemo {
    static func create(_ engine: SyncEngine) {
        var d = SurveyData(); d.title = "Building survey — Sai Heights (demo)"; d.type = "building"; d.questions = SurveyKinds.template("building")
        let sid = "sv_demo_" + UUID().uuidString.prefix(6)
        engine.surveySave(nil, id: String(sid), kind: "survey", surveyID: "", data: (try? JSONEncoder().encode(d)) ?? Data(), convID: "")
        for (i, flat) in ["A-101", "A-102", "B-201"].enumerated() {
            var r = SurveyResponse(); r.respondent = "Flat \(flat)"
            r.answers[d.questions[0].id] = SurveyAnswer(text: flat)
            r.answers[d.questions[1].id] = SurveyAnswer(number: 7)
            r.answers[d.questions[2].id] = SurveyAnswer(number: Double(3 + i % 3))
            r.answers[d.questions[3].id] = SurveyAnswer(choices: i == 1 ? ["Leakage", "Seepage"] : ["None"])
            r.answers[d.questions[4].id] = SurveyAnswer(choices: [["Owner", "Tenant", "Vacant"][i]])
            engine.surveySave(nil, kind: "response", surveyID: String(sid), data: (try? JSONEncoder().encode(r)) ?? Data(), convID: "")
        }
    }
}
