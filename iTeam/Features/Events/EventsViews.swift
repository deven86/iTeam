import SwiftUI
import SwiftData
import EventKit
import UserNotifications

// MARK: - Reminders

@MainActor
enum EventReminders {
    /// One hour before, for events I host or said Going / Maybe to.
    static func update(_ ev: InviteEvent, me: String) {
        let id = "invite." + ev.id
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        let answer = ev.rsvps[me]
        guard !ev.deleted, ev.hostID == me || answer == "going" || answer == "maybe" else { return }
        let fire = ev.start.addingTimeInterval(-3600)
        guard fire > .now else { return }
        let c = UNMutableNotificationContent()
        c.title = "In 1 hour: \(ev.title)"
        c.body = ev.place.isEmpty ? ev.start.formatted(date: .omitted, time: .shortened) : ev.place
        c.sound = .default
        c.userInfo = ["conv": ev.convID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)))
    }
}

extension SyncEngine {
    func sendInvite(_ p: InviteEventPayload, in conv: Conversation) {
        send(.invite(p), in: conv, loud: !p.deleted, preview: "🎉 \(p.title) — \(p.start.formatted(date: .abbreviated, time: .shortened))")
    }
    func rsvp(_ ev: InviteEvent, _ answer: String) {
        guard let conv = conversation(ev.convID) else { return }
        send(.rsvp(eventID: ev.id, answer: answer), in: conv, loud: ev.hostID != me, preview: nil)
    }
}

/// Adds the event to Apple Calendar (write-only access; iTeam never reads your calendar).
enum CalendarExport {
    static func add(_ ev: InviteEvent) async -> Bool {
        let store = EKEventStore()
        guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { return false }
        let e = EKEvent(eventStore: store)
        e.title = ev.title
        e.location = ev.place
        e.startDate = ev.start
        e.endDate = max(ev.end, ev.start.addingTimeInterval(1800))
        e.notes = ev.notes
        e.calendar = store.defaultCalendarForNewEvents
        e.addAlarm(EKAlarm(relativeOffset: -3600))
        return (try? store.save(e, span: .thisEvent)) != nil
    }
}

// MARK: - Events tab

struct EventsHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(sort: \InviteEvent.start) private var everything: [InviteEvent]
    private var events: [InviteEvent] { everything.filter { !$0.deleted } }
    @State private var creating = false
    @State private var shareItems: ShareItems?

    private var upcoming: [InviteEvent] { events.filter { $0.end >= .now || $0.start >= .now.addingTimeInterval(-3 * 3600) } }
    private var past: [InviteEvent] { Array(events.filter { !upcoming.contains($0) }.reversed()) }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 10) {
                    tile("\(upcoming.count)", "Upcoming", "calendar")
                    tile("\(upcoming.filter { $0.hostID == engine.me }.count)", "Hosting", "star.fill")
                    tile("\(upcoming.filter { $0.rsvps[engine.me] == nil && $0.hostID != engine.me }.count)", "To answer", "questionmark.circle")
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                if events.isEmpty {
                    EmptyStateView(icon: "party.popper", title: "Events", message: "Invite a chat or group to a birthday, meeting or trip. Everyone answers Going, Maybe or Can't, and gets a reminder.",
                                   actionTitle: "Create an event") { creating = true }
                        .listRowBackground(Color.clear)
                }
                if !upcoming.isEmpty {
                    Section("Upcoming") { ForEach(upcoming) { ev in NavigationLink { EventDetailView(eventID: ev.id) } label: { EventRow(event: ev) } } }.lookRows()
                }
                let archived = everything.filter(\.deleted)
                if !archived.isEmpty {
                    Section("Archive — cancelled") {
                        ForEach(archived.reversed()) { ev in
                            NavigationLink { EventDetailView(eventID: ev.id) } label: {
                                VStack(alignment: .leading) {
                                    EventRow(event: ev)
                                    Text("Cancelled by \(engine.name(of: ev.hostID)) · \(ev.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .lookRows()
                }
                if !past.isEmpty {
                    Section("Past") { ForEach(past.prefix(20)) { ev in NavigationLink { EventDetailView(eventID: ev.id) } label: { EventRow(event: ev) } } }.lookRows()
                }
            }
            .lookScreen()
            .navigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") } }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export guest lists (PDF)", systemImage: "doc.richtext") {
                        if let url = PDFMaker.make(title: "Events", bodyHTML: exportHTML, fileName: "Events", module: "Events", icon: "party.popper.fill", colors: [0xF953C6, 0xB91D73], charts: PDFCharts.events(upcoming + past)) { shareItems = ShareItems(items: [url]) }
                    }
                }
            }
            .shareSheet($shareItems)
            .refreshable { await engine.sync() }
            .sheet(isPresented: $creating) { NavigationStack { EventPickChat() } }
        }
    }
}

extension EventsHomeView {
    func tile(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(Color(hex: 0xF953C6))
            Text(v).font(.title3.bold())
            Text(l).font(.caption2).foregroundStyle(look.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).lookCard(padding: 6)
    }

    var exportHTML: String {
        var h = "<h2>Events</h2>"
        for ev in upcoming + past {
            h += "<h3>\(PDFMaker.esc(ev.title))</h3><p>\(ev.start.formatted(date: .complete, time: .shortened))\(ev.place.isEmpty ? "" : " · " + PDFMaker.esc(ev.place))</p><ul>"
            for (id, a) in ev.rsvps.sorted(by: { $0.key < $1.key }) { h += "<li>\(PDFMaker.esc(engine.name(of: id))): \(EventDetailView.word(a))</li>" }
            h += "</ul>"
        }
        return h
    }
}

struct EventRow: View {
    let event: InviteEvent
    @EnvironmentObject var engine: SyncEngine
    var body: some View {
        let going = event.rsvps.values.filter { $0 == "going" }.count
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(event.start.formatted(.dateTime.month(.abbreviated))).font(.caption2.bold()).foregroundStyle(.red)
                Text(event.start.formatted(.dateTime.day())).font(.title3.bold())
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.headline)
                Text([event.start.formatted(date: .omitted, time: .shortened), event.place, engine.conversation(event.convID)?.title ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(going) going\(event.rsvps[engine.me].map { " · you: " + EventDetailView.word($0) } ?? "")").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct EventPickChat: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Conversation> { !$0.left }, sort: \Conversation.lastActivity, order: .reverse) private var chats: [Conversation]
    var body: some View {
        List(chats) { c in
            NavigationLink { EventEditor(conv: c) } label: {
                HStack { AvatarView(name: c.title, imageData: c.avatar, size: 32, isGroup: c.isGroup); Text(c.title) }
            }
        }
        .navigationTitle("Invite which chat?")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct EventEditor: View {
    let conv: Conversation
    var existing: InviteEvent? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var place = ""
    @State private var start = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var hours = 2.0
    @State private var notes = ""

    var body: some View {
        Form {
            Section("Event") {
                TextField("What (Birthday, Meeting, Trip…)", text: $title)
                TextField("Where", text: $place)
                DatePicker("Starts", selection: $start)
                Stepper("Lasts \(hours.formatted()) h", value: $hours, in: 0.5...48, step: 0.5)
                TextField("Details (dress code, what to bring…)", text: $notes, axis: .vertical)
            }
            Section { Text("Everyone in “\(conv.title)” is invited and can answer Going, Maybe or Can't.").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle(existing == nil ? "New event" : "Edit event")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    let p = InviteEventPayload(id: existing?.id ?? "ev_" + UUID().uuidString, title: title.trimmingCharacters(in: .whitespaces),
                                               place: place, start: start, end: start.addingTimeInterval(hours * 3600), notes: notes, deleted: false, at: .now)
                    engine.sendInvite(p, in: conv)
                    Haptics.success()
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let e = existing else { return }
            title = e.title; place = e.place; start = e.start; notes = e.notes
            hours = max(0.5, e.end.timeIntervalSince(e.start) / 3600)
        }
    }
}

struct EventDetailView: View {
    let eventID: String
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [InviteEvent]
    @State private var editing = false
    @State private var calendarNote: String?
    @State private var shareItems: ShareItems?

    init(eventID: String) {
        self.eventID = eventID
        _found = Query(filter: #Predicate<InviteEvent> { $0.id == eventID })
    }

    static func word(_ a: String) -> String { a == "going" ? "Going" : a == "maybe" ? "Maybe" : "Can't" }

    var body: some View {
        if let ev = found.first { content(ev) } else { Text("Event not found") }
    }

    private func content(_ ev: InviteEvent) -> some View {
        let conv = engine.conversation(ev.convID)
        let mine = ev.rsvps[engine.me]
        return List {
            Section {
                Text(ev.title).font(.title2.bold())
                Label(ev.start.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                if !ev.place.isEmpty {
                    Button { if let u = URL(string: "https://maps.apple.com/?q=" + (ev.place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) { UIApplication.shared.open(u) } } label: {
                        Label(ev.place, systemImage: "mappin.and.ellipse")
                    }
                }
                if !ev.notes.isEmpty { Text(ev.notes) }
                Text("Hosted by \(ev.hostID == engine.me ? "you" : engine.name(of: ev.hostID))\(conv.map { " · in " + $0.title } ?? "")").font(.caption).foregroundStyle(.secondary)
                if ev.deleted { Text("Cancelled").foregroundStyle(.red) }
            }
            if !ev.deleted && ev.hostID != engine.me {
                Section("Your answer") {
                    HStack {
                        ForEach(["going", "maybe", "no"], id: \.self) { a in
                            Button(Self.word(a)) { engine.rsvp(ev, a) }
                                .buttonStyle(.bordered).tint(mine == a ? .accentColor : .gray)
                        }
                    }
                }
            }
            Section("Answers") {
                ForEach(conv?.members.filter { $0.id != ev.hostID } ?? [], id: \.id) { m in
                    LabeledContent(m.id == engine.me ? "You" : engine.name(of: m.id), value: ev.rsvps[m.id].map(Self.word) ?? "No answer")
                }
            }
            Section {
                Button("Add to Apple Calendar", systemImage: "calendar.badge.plus") {
                    Task { calendarNote = await CalendarExport.add(ev) ? "Added to your calendar." : "Allow calendar access in iPhone Settings → iTeam." }
                }
                if let calendarNote { Text(calendarNote).font(.caption) }
                Button("Share", systemImage: "square.and.arrow.up") {
                    shareItems = ShareItems(items: ["\(ev.title)\n\(ev.start.formatted(date: .complete, time: .shortened))\(ev.place.isEmpty ? "" : "\n" + ev.place)\(ev.notes.isEmpty ? "" : "\n" + ev.notes)"])
                }
                if let conv { Button("Open chat", systemImage: "bubble.left") { router.show(conversation: conv.id) } }
                if ev.hostID == engine.me && !ev.deleted {
                    Button("Edit", systemImage: "pencil") { editing = true }
                    Button("Cancel event", systemImage: "xmark.circle", role: .destructive) {
                        if let conv {
                            engine.sendInvite(InviteEventPayload(id: ev.id, title: ev.title, place: ev.place, start: ev.start, end: ev.end, notes: ev.notes, deleted: true, at: .now), in: conv)
                        }
                    }
                }
            }
        }
        .lookScreen()
        .navigationTitle("Event")
        .shareSheet($shareItems)
        .sheet(isPresented: $editing) { if let conv { NavigationStack { EventEditor(conv: conv, existing: ev) } } }
    }
}
