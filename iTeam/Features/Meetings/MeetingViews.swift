import SwiftUI
import SwiftData
import PhotosUI
import UserNotifications

// MARK: - Actions & reminders

extension SyncEngine {
    func saveMeeting(_ p: MeetingPayload, in conv: Conversation, uploads: [String: String] = [:], isNew: Bool) {
        send(.meeting(p), in: conv, loud: isNew || p.deleted,
             preview: isNew ? "📅 \(p.title) — \(p.start.formatted(date: .abbreviated, time: .shortened))" : nil, uploads: uploads)
    }
    func voteMeeting(_ m: Meeting, poll: String, option: Int) {
        guard let conv = conversation(m.convID) else { return }
        send(.meetingVote(meetingID: m.id, pollID: poll, option: option), in: conv, loud: false)
    }
    func attendMeeting(_ m: Meeting) {
        guard let conv = conversation(m.convID) else { return }
        send(.meetingAttend(meetingID: m.id), in: conv, loud: false)
    }
}

@MainActor
enum MeetingReminders {
    /// 15 minutes before, for admins and people expected to attend.
    static func update(_ m: Meeting, me: String) {
        let id = "meeting." + m.id
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        guard !m.deleted, m.status == "scheduled", m.isAdmin(me) || m.expected.contains(me) else { return }
        let fire = m.start.addingTimeInterval(-15 * 60)
        guard fire > .now else { return }
        let c = UNMutableNotificationContent()
        c.title = "In 15 min: \(m.title)"
        c.body = m.online ? "Online — tap to open" : (m.place.isEmpty ? "In person" : m.place)
        c.sound = .default
        c.userInfo = ["conv": m.convID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)))
    }
}

// MARK: - Dashboard

struct MeetingsHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(sort: \Meeting.start) private var everything: [Meeting]
    private var meetings: [Meeting] { everything.filter { !$0.deleted } }
    @State private var creating = false
    @State private var shareItems: ShareItems?

    private var mine: [Meeting] { meetings.filter { $0.isAdmin(engine.me) || $0.expected.contains(engine.me) || engine.conversation($0.convID) != nil } }
    private var upcoming: [Meeting] { mine.filter { $0.status == "scheduled" && $0.end >= .now } }
    private var past: [Meeting] { Array(mine.filter { $0.status != "scheduled" || $0.end < .now }.reversed()) }
    private var thisWeek: Int { upcoming.filter { $0.start < .now.addingTimeInterval(7 * 86400) }.count }
    private var minutesDue: Int { past.filter { $0.status != "cancelled" && $0.minutes.isEmpty && $0.isAdmin(engine.me) }.count }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 10) {
                    tile("\(thisWeek)", "This week", "calendar")
                    tile("\(upcoming.count)", "Upcoming", "clock")
                    tile("\(minutesDue)", "Minutes due", "doc.text")
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                if meetings.isEmpty {
                    EmptyStateView(icon: "person.3.fill", title: "Meetings",
                                   message: "Schedule a meeting in any chat, group or task — agenda, who attends, online link or place, votes, notes, minutes and a PDF.",
                                   actionTitle: "Schedule a meeting") { creating = true }
                        .listRowBackground(Color.clear)
                }
                if !upcoming.isEmpty {
                    Section("Upcoming") { ForEach(upcoming) { m in link(m) } }.lookRows()
                }
                if !past.isEmpty {
                    Section("Past") { ForEach(past.prefix(30)) { m in link(m) } }.lookRows()
                }
                let archived = everything.filter(\.deleted)
                if !archived.isEmpty {
                    Section("Archive — cancelled") {
                        ForEach(archived.reversed()) { m in
                            NavigationLink { MeetingDetailView(meetingID: m.id) } label: {
                                VStack(alignment: .leading) {
                                    MeetingRow(meeting: m)
                                    Text("Cancelled by \(engine.name(of: m.createdBy)) · \(m.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .lookRows()
                }
            }
            .lookScreen()
            .navigationTitle("Meetings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") } }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export all as PDF", systemImage: "doc.richtext") {
                        if let url = PDFMaker.make(title: "Meetings", bodyHTML: MeetingPDF.list(mine, engine: engine), fileName: "Meetings", module: "Meetings", icon: "person.3.fill", colors: [0x4568DC, 0xB06AB3], charts: PDFCharts.meetings(mine)) { shareItems = ShareItems(items: [url]) }
                    }
                }
            }
            .refreshable { await engine.sync() }
            .sheet(isPresented: $creating) { NavigationStack { MeetingPickChat() } }
            .shareSheet($shareItems)
        }
    }

    private func link(_ m: Meeting) -> some View {
        NavigationLink { MeetingDetailView(meetingID: m.id) } label: { MeetingRow(meeting: m) }
    }

    private func tile(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(Color(hex: 0x4568DC))
            Text(v).font(.title3.bold())
            Text(l).font(.caption2).foregroundStyle(look.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).lookCard(padding: 6)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    @EnvironmentObject var engine: SyncEngine
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: meeting.online ? "video.fill" : "person.3.fill")
                .foregroundStyle(.white).frame(width: 36, height: 36)
                .background(Color(hex: 0x4568DC), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.headline)
                Text("\(meeting.start.formatted(date: .abbreviated, time: .shortened)) · \(engine.conversation(meeting.convID)?.title ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if meeting.status != "scheduled" {
                Text(meeting.status == "done" ? "Done" : "Cancelled").font(.caption2.bold()).foregroundStyle(meeting.status == "done" ? .green : .red)
            }
        }
    }
}

struct MeetingPickChat: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Conversation> { !$0.left }, sort: \Conversation.lastActivity, order: .reverse) private var chats: [Conversation]
    var body: some View {
        List(chats) { c in
            NavigationLink { MeetingEditor(conv: c) } label: {
                HStack { AvatarView(name: c.title, imageData: c.avatar, size: 32, isGroup: c.isGroup); Text(c.title) }
            }
        }
        .navigationTitle("Meeting in which chat?")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

// MARK: - Editor

struct MeetingEditor: View {
    let conv: Conversation
    var taskID: String = ""
    var existing: Meeting? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var online = false
    @State private var link = ""
    @State private var place = ""
    @State private var start = Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now
    @State private var minutesLong = 60.0
    @State private var agenda: [String] = [""]
    @State private var expected: Set<String> = []
    @State private var admins: Set<String> = []
    @State private var polls: [MeetingPoll] = []
    @State private var files: [AttachmentRef] = []
    @State private var uploads: [String: String] = [:]
    @State private var pick: [PhotosPickerItem] = []
    @State private var fileError: String?

    private var people: [MemberInfo] { conv.members }

    private var scanSpec: ScanSpec {
        ScanSpec(title: "Scan a meeting notice or agenda", what: "a meeting notice, circular or agenda (company, society, trust or committee)",
                 fields: [.text("title", "Meeting title"), .date("start", "Date and time"), .text("place", "Venue / link"), .number("minutes", "Duration in minutes (if written)")],
                 rows: [.text("item", "Agenda point")], rowsLabel: "Agenda points")
    }

    private func applyScan(_ o: ScanOutput) {
        if let v = o.str("title") { title = v }
        if let v = o.date("start") { start = v }
        if let v = o.str("place") {
            if v.lowercased().hasPrefix("http") { online = true; link = v } else { place = v }
        }
        if let v = o.number("minutes"), v >= 15 { minutesLong = min(480, v) }
        let points = o.rows.compactMap { $0["item"] }.filter { !$0.isEmpty }
        if !points.isEmpty { agenda = agenda.filter { !$0.isEmpty } + points }
        for p in o.files { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
    }

    var body: some View {
        Form {
            AIScanSection(spec: scanSpec, onApply: applyScan)
            Section("Meeting") {
                TextField("Title", text: $title)
                DatePicker("Starts", selection: $start)
                HolidayWarning(date: start)
                Stepper("Duration \(Int(minutesLong)) min", value: $minutesLong, in: 15...480, step: 15)
                Picker("Where", selection: $online) { Text("In person").tag(false); Text("Online").tag(true) }.pickerStyle(.segmented)
                if online {
                    TextField("Meeting link (FaceTime, Meet, Zoom…)", text: $link).keyboardType(.URL).textInputAutocapitalization(.never)
                    Button("Create a FaceTime link", systemImage: "video") { if let u = URL(string: "facetime://") { UIApplication.shared.open(u) } }
                        .font(.caption)
                    Text("In FaceTime tap “Create Link”, copy it and paste it here.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    TextField("Place / room / address", text: $place)
                }
            }
            Section("Agenda") {
                ForEach(agenda.indices, id: \.self) { i in
                    TextField("Point \(i + 1)", text: Binding(get: { agenda[i] }, set: { agenda[i] = $0 }))
                }
                Button("Add point", systemImage: "plus") { agenda.append("") }
            }
            Section {
                ForEach(people, id: \.id) { m in
                    let name = m.id == engine.me ? "You" : engine.name(of: m.id)
                    HStack {
                        Text(name)
                        Spacer()
                        toggleChip("Attends", on: expected.contains(m.id)) { flip(&expected, m.id) }
                        toggleChip("Admin", on: admins.contains(m.id) || m.id == (existing?.createdBy ?? engine.me)) { if m.id != (existing?.createdBy ?? engine.me) { flip(&admins, m.id) } }
                    }
                }
            } header: { Text("Who attends") } footer: { Text("Admins can edit the meeting, mark attendance, add votes and write the minutes.") }
            Section("Votes") {
                ForEach(polls.indices, id: \.self) { i in
                    TextField("Question", text: Binding(get: { polls[i].question }, set: { polls[i].question = $0 }))
                    TextField("Options, comma separated", text: Binding(get: { polls[i].options.joined(separator: ", ") },
                                                                          set: { polls[i].options = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        .font(.caption)
                }
                Button("Add a vote", systemImage: "chart.bar") { polls.append(MeetingPoll()) }
            }
            Section("Presentation & files") {
                ForEach(files) { f in Label(f.name, systemImage: f.kind == "image" ? "photo" : "doc") }
                PhotosPicker(selection: $pick, maxSelectionCount: 10, matching: .images) { Label("Add photos", systemImage: "photo.on.rectangle") }
                Button("Add presentation or document", systemImage: "doc.badge.plus") {
                    Presenter.file(types: [.pdf, .presentation, .spreadsheet, .data, .item]) { url in addFile(url) }
                }
                if let fileError { Text(fileError).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle(existing == nil ? "New meeting" : "Edit meeting")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(existing == nil ? "Schedule" : "Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .onChange(of: pick) { _, items in Task { await addPhotos(items) } }
        .onAppear(perform: load)
    }

    private func toggleChip(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(text, action: action).font(.caption2).buttonStyle(.bordered).tint(on ? .accentColor : .gray)
    }

    private func flip(_ set: inout Set<String>, _ id: String) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }

    @MainActor private func addFile(_ url: URL) {
        do {
            let p = try Attachments.prepareFile(url)
            files.append(p.ref); uploads[p.upload.0] = p.upload.1
        } catch { fileError = error.localizedDescription }
    }

    @MainActor private func addPhotos(_ items: [PhotosPickerItem]) async {
        for i in items {
            guard let d = try? await i.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(d) else { continue }
            files.append(p.ref); uploads[p.upload.0] = p.upload.1
        }
        pick = []
    }

    private func load() {
        guard let m = existing else {
            expected = Set(people.map(\.id))
            return
        }
        title = m.title; online = m.online; link = m.link; place = m.place; start = m.start
        minutesLong = max(15, m.end.timeIntervalSince(m.start) / 60)
        agenda = m.agenda.isEmpty ? [""] : m.agenda
        expected = Set(m.expected); admins = Set(m.admins); polls = m.polls; files = m.files
    }

    private func save() {
        let m = existing ?? Meeting(id: "mt_" + UUID().uuidString)
        var p = MeetingPayload(m)
        p.taskID = existing?.taskID ?? taskID
        p.title = title.trimmingCharacters(in: .whitespaces); p.online = online; p.link = online ? link : ""; p.place = online ? "" : place
        p.start = start; p.end = start.addingTimeInterval(minutesLong * 60)
        p.agenda = agenda.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.expected = Array(expected); p.admins = Array(admins)
        p.polls = polls.filter { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty && $0.options.count >= 2 }
        p.files = files
        p.at = .now
        engine.saveMeeting(p, in: conv, uploads: uploads, isNew: existing == nil)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Detail

struct MeetingDetailView: View {
    let meetingID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var found: [Meeting]
    @State private var editing = false
    @State private var minutes = ""
    @State private var notes = ""
    @State private var shareItems: ShareItems?
    @State private var quickLook: URL?

    init(meetingID: String) {
        self.meetingID = meetingID
        _found = Query(filter: #Predicate<Meeting> { $0.id == meetingID })
    }

    var body: some View {
        if let m = found.first { content(m) } else { Text("Meeting not found") }
    }

    private func content(_ m: Meeting) -> some View {
        let admin = m.isAdmin(engine.me)
        return List {
            infoSection(m)
            if !m.agenda.isEmpty {
                Section("Agenda") { ForEach(Array(m.agenda.enumerated()), id: \.offset) { i, a in Text("\(i + 1). \(a)") } }.lookRows()
            }
            attendanceSection(m, admin: admin)
            if !m.polls.isEmpty { pollsSection(m) }
            if !m.files.isEmpty {
                Section("Presentation & files") {
                    ForEach(m.files) { f in AttachmentView(ref: f) { url in quickLook = url } }
                }
                .lookRows()
            }
            notesSection(m, admin: admin)
            actionsSection(m, admin: admin)
        }
        .lookScreen()
        .navigationTitle("Meeting")
        .onAppear { minutes = m.minutes; notes = m.notes }
        .shareSheet($shareItems)
        .sheet(isPresented: $editing) {
            if let conv = engine.conversation(m.convID) { NavigationStack { MeetingEditor(conv: conv, existing: m) } }
        }
        .sheet(item: Binding(get: { quickLook.map(PreviewItem.init) }, set: { quickLook = $0?.url })) { item in QuickLookView(url: item.url).ignoresSafeArea() }
    }

    private func infoSection(_ m: Meeting) -> some View {
        Section {
            Text(m.title).font(.title2.bold())
            Label("\(m.start.formatted(date: .complete, time: .shortened)) – \(m.end.formatted(date: .omitted, time: .shortened))", systemImage: "calendar")
            if m.online {
                if let u = URL(string: m.link), !m.link.isEmpty {
                    Link(destination: u) { Label("Join online", systemImage: "video.fill").bold() }
                } else { Label("Online — link not added yet", systemImage: "video") }
            } else if !m.place.isEmpty {
                Label(m.place, systemImage: "mappin.and.ellipse")
            }
            Text("Admin: \(([m.createdBy] + m.admins.filter { $0 != m.createdBy }).map { $0 == engine.me ? "You" : engine.name(of: $0) }.joined(separator: ", ")) · in \(engine.conversation(m.convID)?.title ?? "")")
                .font(.caption).foregroundStyle(look.textSecondary)
            if let t = engine.task(m.taskID) { Label("For task: \(t.title)", systemImage: "checklist").font(.caption) }
            if m.status != "scheduled" { Text(m.status == "done" ? "Completed" : "Cancelled").bold().foregroundStyle(m.status == "done" ? .green : .red) }
        }
        .lookRows()
    }

    private func attendanceSection(_ m: Meeting, admin: Bool) -> some View {
        Section {
            ForEach(m.expected, id: \.self) { id in
                HStack {
                    Text(id == engine.me ? "You" : engine.name(of: id))
                    Spacer()
                    if admin {
                        Button { toggleAttended(m, id) } label: {
                            Image(systemName: m.attended.contains(id) ? "checkmark.circle.fill" : "circle").foregroundStyle(m.attended.contains(id) ? .green : .secondary)
                        }.buttonStyle(.borderless)
                    } else if m.attended.contains(id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            if m.expected.contains(engine.me) && !m.attended.contains(engine.me) && m.status == "scheduled" {
                Button("I'm attending now", systemImage: "hand.raised.fill") { engine.attendMeeting(m) }
            }
        } header: { Text("Attendance · \(m.attended.count) of \(m.expected.count)") }
        .lookRows()
    }

    private func pollsSection(_ m: Meeting) -> some View {
        Section("Votes") {
            ForEach(m.polls) { poll in
                let votes = m.votes[poll.id] ?? [:]
                VStack(alignment: .leading, spacing: 6) {
                    Text(poll.question).font(.headline)
                    ForEach(Array(poll.options.enumerated()), id: \.offset) { i, o in
                        let n = votes.values.filter { $0 == i }.count
                        Button { engine.voteMeeting(m, poll: poll.id, option: i) } label: {
                            HStack {
                                Image(systemName: votes[engine.me] == i ? "largecircle.fill.circle" : "circle")
                                Text(o)
                                Spacer()
                                Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .lookRows()
    }

    private func notesSection(_ m: Meeting, admin: Bool) -> some View {
        Section {
            if admin {
                TextField("Notes during the meeting", text: $notes, axis: .vertical).lineLimit(3...10)
                TextField("Minutes: decisions, action items, owners, dates", text: $minutes, axis: .vertical).lineLimit(4...20)
                if notes != m.notes || minutes != m.minutes {
                    Button("Save notes & minutes", systemImage: "square.and.arrow.down") { saveText(m) }
                }
                AIButton(title: "Draft minutes with AI", feature: .taskReports,
                         instructions: "Write formal minutes of meeting: attendees, agenda points discussed, decisions, action items with owners and dates. Use only these notes; mark anything unclear. The user will copy what they want into the minutes.",
                         context: { MeetingPDF.text(m, engine: engine) + "\nNotes: " + notes })
            } else {
                if !m.notes.isEmpty { Text(m.notes) }
                Text(m.minutes.isEmpty ? "Minutes will appear here after the meeting." : m.minutes).foregroundStyle(m.minutes.isEmpty ? .secondary : .primary)
            }
        } header: { Text("Notes & minutes") }
        .lookRows()
    }

    private func actionsSection(_ m: Meeting, admin: Bool) -> some View {
        Section {
            Button("Export minutes (PDF)", systemImage: "doc.richtext") {
                if let url = PDFMaker.make(title: "Minutes — \(m.title)", bodyHTML: MeetingPDF.html(m, engine: engine), fileName: "Minutes \(m.title)", module: "Meetings", icon: "person.3.fill", colors: [0x4568DC, 0xB06AB3], charts: PDFCharts.minutes(m)) {
                    shareItems = ShareItems(items: [url])
                }
            }
            if admin && !m.deleted {
                Button("Edit meeting", systemImage: "pencil") { editing = true }
                if m.status == "scheduled" {
                    Button("Mark as done", systemImage: "checkmark.seal") { update(m) { $0.status = "done" } }
                    if m.createdBy == engine.me {
                        Button("Cancel meeting", systemImage: "xmark.circle", role: .destructive) { update(m) { $0.status = "cancelled"; $0.deleted = true } }
                    }
                }
            }
        }
        .lookRows()
    }

    private func update(_ m: Meeting, _ change: (inout MeetingPayload) -> Void) {
        guard let conv = engine.conversation(m.convID) else { return }
        var p = MeetingPayload(m)
        change(&p)
        p.at = .now
        engine.saveMeeting(p, in: conv, isNew: false)
    }

    private func toggleAttended(_ m: Meeting, _ id: String) {
        update(m) { p in if p.attended.contains(id) { p.attended.removeAll { $0 == id } } else { p.attended.append(id) } }
    }

    private func saveText(_ m: Meeting) {
        update(m) { $0.notes = notes; $0.minutes = minutes }
        Haptics.success()
    }
}

// MARK: - PDF / text

@MainActor
enum MeetingPDF {
    static func text(_ m: Meeting, engine: SyncEngine) -> String {
        var t = "Meeting: \(m.title)\nWhen: \(m.start.formatted(date: .complete, time: .shortened))\n"
        t += m.online ? "Online: \(m.link)\n" : "Place: \(m.place)\n"
        t += "Expected: " + m.expected.map { engine.name(of: $0) }.joined(separator: ", ") + "\n"
        t += "Attended: " + m.attended.map { engine.name(of: $0) }.joined(separator: ", ") + "\n"
        t += "Agenda:\n" + m.agenda.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        for p in m.polls {
            let v = m.votes[p.id] ?? [:]
            t += "\nVote — \(p.question): " + p.options.enumerated().map { item in "\(item.element) \(v.values.filter { $0 == item.offset }.count)" }.joined(separator: ", ")
        }
        return t
    }

    static func html(_ m: Meeting, engine: SyncEngine) -> String {
        func e(_ s: String) -> String { PDFMaker.esc(s) }
        var h = "<h2>Minutes of Meeting</h2><h3>\(e(m.title))</h3>"
        h += "<p><b>Date:</b> \(m.start.formatted(date: .long, time: .shortened)) – \(m.end.formatted(date: .omitted, time: .shortened))<br>"
        h += m.online ? "<b>Online:</b> \(e(m.link))" : "<b>Venue:</b> \(e(m.place))"
        h += "<br><b>Chaired by:</b> \(e(engine.name(of: m.createdBy)))</p>"
        h += "<p><b>Present (\(m.attended.count)):</b> \(e(m.attended.map { engine.name(of: $0) }.joined(separator: ", ")))<br>"
        let absent = m.expected.filter { !m.attended.contains($0) }
        if !absent.isEmpty { h += "<b>Absent:</b> \(e(absent.map { engine.name(of: $0) }.joined(separator: ", ")))" }
        h += "</p>"
        if !m.agenda.isEmpty { h += "<h4>Agenda</h4><ol>" + m.agenda.map { "<li>\(e($0))</li>" }.joined() + "</ol>" }
        if !m.polls.isEmpty {
            h += "<h4>Votes</h4>"
            for p in m.polls {
                let v = m.votes[p.id] ?? [:]
                h += "<p><b>\(e(p.question))</b><br>" + p.options.enumerated().map { item in "\(e(item.element)): \(v.values.filter { $0 == item.offset }.count)" }.joined(separator: " · ") + "</p>"
            }
        }
        if !m.notes.isEmpty { h += "<h4>Notes</h4><p>\(e(m.notes).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
        h += "<h4>Minutes</h4><p>\(m.minutes.isEmpty ? "—" : e(m.minutes).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        if !m.files.isEmpty { h += "<p><b>Attachments:</b> " + e(m.files.map(\.name).joined(separator: ", ")) + "</p>" }
        return h
    }

    static func list(_ ms: [Meeting], engine: SyncEngine) -> String {
        var h = "<h2>Meetings</h2><table border='1' cellpadding='5' style='border-collapse:collapse;width:100%'><tr><th>Date</th><th>Meeting</th><th>Chat</th><th>Attended</th><th>Status</th></tr>"
        for m in ms.sorted(by: { $0.start > $1.start }) {
            h += "<tr><td>\(m.start.formatted(date: .abbreviated, time: .shortened))</td><td>\(PDFMaker.esc(m.title))</td><td>\(PDFMaker.esc(engine.conversation(m.convID)?.title ?? ""))</td><td>\(m.attended.count)/\(m.expected.count)</td><td>\(m.status)</td></tr>"
        }
        return h + "</table>"
    }
}


/// In a task: its meetings and "Schedule meeting".
struct TaskMeetingsRow: View {
    let task: TaskItem
    @EnvironmentObject var engine: SyncEngine
    @Query private var meetings: [Meeting]
    @State private var creating = false

    init(task: TaskItem) {
        self.task = task
        let id = task.id
        _meetings = Query(filter: #Predicate<Meeting> { $0.taskID == id && !$0.deleted }, sort: \Meeting.start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(meetings) { m in
                NavigationLink { MeetingDetailView(meetingID: m.id) } label: {
                    Label("\(m.title) · \(m.start.formatted(date: .abbreviated, time: .shortened))", systemImage: m.online ? "video.fill" : "person.3.fill").font(.caption)
                }
            }
            if let cid = task.convID, engine.conversation(cid) != nil {
                Button("Schedule meeting", systemImage: "calendar.badge.plus") { creating = true }
                    .font(.caption.weight(.semibold)).buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $creating) {
            if let cid = task.convID, let conv = engine.conversation(cid) {
                NavigationStack { MeetingEditor(conv: conv, taskID: task.id) }
            }
        }
    }
}


/// On a person's profile: meetings they attend or run, now and upcoming.
struct PersonMeetingsSection: View {
    let personID: String
    @EnvironmentObject var engine: SyncEngine
    @Query(filter: #Predicate<Meeting> { !$0.deleted && $0.status == "scheduled" }, sort: \Meeting.start) private var meetings: [Meeting]

    var body: some View {
        let list = meetings.filter { m in
            m.end >= .now && (m.expected.contains(personID) || m.isAdmin(personID)) && (m.expected.contains(engine.me) || m.isAdmin(engine.me))
        }
        if !list.isEmpty {
            Section("Meetings") {
                ForEach(list) { m in
                    NavigationLink { MeetingDetailView(meetingID: m.id) } label: {
                        HStack {
                            MeetingRow(meeting: m)
                            if m.start <= .now { Text("Now").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(.red, in: Capsule()) }
                        }
                    }
                }
            }
            .lookRows()
        }
    }
}
