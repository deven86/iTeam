import SwiftUI
import SwiftData

// MARK: - Settings → AI

struct AISettingsView: View {
    @ObservedObject private var ai = AISettings.shared
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @State private var key = ""
    @State private var models: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var testResult: String?
    @State private var myDay = MyDaySettings.enabled
    @State private var morning = Self.date(MyDaySettings.morning)
    @State private var evening = Self.date(MyDaySettings.evening)
    @State private var autoShift = MyDaySettings.autoShift

    static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }
    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $ai.enabled) { Label("Use AI in iTeam", systemImage: "sparkles") }
                LabeledContent("Status", value: ai.statusText).font(.callout)
            } footer: {
                Text("Nothing is sent anywhere until you turn this on. With Apple Intelligence everything stays on your iPhone. With your own key, only the text needed for that task goes to the company you choose.")
            }
            .lookRows()

            if ai.enabled {
                Section("AI provider") {
                    Picker("Provider", selection: Binding(get: { ai.provider }, set: { ai.switchProvider($0); key = ai.key(for: $0); models = [] })) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                    }
                    if ai.provider == .apple {
                        if AIService.appleAvailable {
                            Label("Ready — free and private, on this device", systemImage: "checkmark.seal.fill").foregroundStyle(look.success)
                        } else {
                            Text(AIService.appleUnavailableReason).font(.caption).foregroundStyle(look.warning)
                        }
                    } else {
                        SecureField(ai.provider.keyHint, text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { ai.setKey(key, for: ai.provider) }
                        Button {
                            Task { await fetch() }
                        } label: {
                            HStack { Text(models.isEmpty ? "Save key & fetch models" : "Refresh models"); Spacer(); if loading { ProgressView() } }
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                        if !models.isEmpty || !ai.model.isEmpty {
                            Picker("Model", selection: $ai.model) {
                                if !models.contains(ai.model) && !ai.model.isEmpty { Text(ai.model).tag(ai.model) }
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Text("Your key is kept in your iCloud Keychain and sent only to \(ai.provider.short). The AI company bills you for what you use.")
                            .font(.caption).foregroundStyle(look.textSecondary)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(look.danger) }
                    Button("Test") { Task { await test() } }.disabled(!ai.ready)
                    if let testResult { Text(testResult).font(.caption) }
                }
                .lookRows()

                Section {
                    ForEach(AIFeature.allCases) { f in
                        Toggle(isOn: Binding(get: { ai.features.contains(f.rawValue) },
                                             set: { on in if on { ai.features.insert(f.rawValue) } else { ai.features.remove(f.rawValue) } })) {
                            Label(f.title, systemImage: f.icon)
                        }
                    }
                } header: {
                    Text("Where AI may be used")
                } footer: {
                    Text("New modules add their own switch here.")
                }
                .lookRows()
            }

            Section {
                Toggle(isOn: $myDay) { Label("My Day", systemImage: "sun.max.fill") }
                    .onChange(of: myDay) { _, v in MyDaySettings.enabled = v; reschedule() }
                if myDay {
                    DatePicker("Morning brief", selection: $morning, displayedComponents: .hourAndMinute)
                        .onChange(of: morning) { _, d in MyDaySettings.morning = Self.minutes(d); reschedule() }
                    DatePicker("End-of-day review", selection: $evening, displayedComponents: .hourAndMinute)
                        .onChange(of: evening) { _, d in MyDaySettings.evening = Self.minutes(d); reschedule() }
                    Toggle("Move unfinished tasks to tomorrow automatically", isOn: $autoShift)
                        .onChange(of: autoShift) { _, v in MyDaySettings.autoShift = v }
                }
            } header: {
                Text("My Day")
            } footer: {
                Text("Morning: what's due, approvals waiting, medicines and gym — with suggestions. Evening: what got done, and moving what's left to tomorrow (you approve, unless automatic is on). Works without AI too; AI adds the written summary.")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("AI")
        .onAppear { key = ai.key(for: ai.provider) }
    }

    private func reschedule() {
        if let ctx = engine.context { Reminders.shared.reschedule(context: ctx, me: engine.me) }
    }

    private func fetch() async {
        loading = true; error = nil
        defer { loading = false }
        ai.setKey(key, for: ai.provider)
        do {
            models = try await AIService.fetchModels(ai.provider, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
            if ai.model.isEmpty || !models.contains(ai.model) { ai.model = models.first ?? "" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func test() async {
        testResult = "…"
        do { testResult = try await AIService.complete("Say hello to the iTeam user in one short, friendly sentence.") }
        catch { testResult = error.localizedDescription }
    }
}

// MARK: - A reusable "Ask AI" button + result sheet

struct AIButton: View {
    let title: String
    let feature: AIFeature
    let instructions: String
    let context: () -> String
    /// When set and this group's AI runs on this phone, the result can be posted into the group.
    var postTo: Conversation? = nil
    @ObservedObject private var ai = AISettings.shared
    @State private var show = false

    var body: some View {
        if ai.allows(feature) {
            Button { show = true } label: { Label(title, systemImage: "sparkles") }
                .sheet(isPresented: $show) {
                    NavigationStack { AIResultView(title: title, instructions: instructions, context: context(), postTo: postTo) }
                }
        }
    }
}

struct AIResultView: View {
    let title: String
    let instructions: String
    let context: String
    var postTo: Conversation? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var text = ""
    @State private var error: String?
    @State private var loading = true
    @State private var posted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    HStack { ProgressView(); Text("Thinking…").foregroundStyle(look.textSecondary) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(look.warning)
                    Button("Try again") { Task { await run() } }
                } else {
                    Text(.init(text)).textSelection(.enabled)
                    Text("Made by \(AISettings.shared.provider.short) AI — check before acting on it.")
                        .font(.caption2).foregroundStyle(look.textSecondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .lookCard()
            .padding()
        }
        .lookScreen()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            if !text.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareMenu(title: title, text: { text }).labelStyle(.iconOnly)
                }
                if let postTo, AISettings.shared.groupAI.contains(postTo.id) {
                    ToolbarItem(placement: .bottomBar) {
                        Button(posted ? "Posted" : "Post to “\(postTo.title)”", systemImage: "paperplane.fill") {
                            engine.sendText("🤖 \(title)\n\n\(text)", in: postTo)
                            posted = true
                            Haptics.success()
                        }
                        .disabled(posted)
                    }
                }
            }
        }
        .task { await run() }
    }

    private func run() async {
        loading = true; error = nil
        defer { loading = false }
        do { text = try await AIService.complete(context, instructions: instructions) }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Data the AI sees

@MainActor
enum AIContext {
    private static func fmt(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "no date"
    }

    static func taskLine(_ t: TaskItem, engine: SyncEngine) -> String {
        var s = "- \(t.title) [\(t.status.title)\(t.isOverdue ? ", OVERDUE" : "")] due \(fmt(t.dueAt))"
        if !t.assignees.isEmpty { s += " · for " + t.assignees.map { engine.name(of: $0) }.joined(separator: ", ") }
        if let c = t.convID.flatMap({ engine.conversation($0) }) { s += " · in \(c.title)" }
        return s
    }

    /// Everything about today for one person, across modules.
    static func myDay(engine: SyncEngine, evening: Bool) -> String {
        guard let ctx = engine.context else { return "" }
        let me = engine.me
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? .now
        let tasks = ((try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted }))) ?? []).filter { $0.involves(me) }
        var out = ["Person: \(engine.myName). Now: \(Date.now.formatted(date: .complete, time: .shortened))."]
        let overdue = tasks.filter { $0.isOverdue && ($0.dueAt ?? .now) < start }
        let today = tasks.filter { !$0.isDone && ($0.dueAt.map { $0 >= start && $0 < end } ?? false) }
        let doneToday = tasks.filter { $0.isDone && ($0.completedAt.map { $0 >= start } ?? false) }
        let noDate = tasks.filter { !$0.isDone && $0.dueAt == nil }
        out.append("Overdue tasks (\(overdue.count)):\n" + overdue.prefix(15).map { taskLine($0, engine: engine) }.joined(separator: "\n"))
        out.append("Due today (\(today.count)):\n" + today.prefix(15).map { taskLine($0, engine: engine) }.joined(separator: "\n"))
        out.append("Completed today (\(doneToday.count)):\n" + doneToday.prefix(15).map { "- \($0.title)" }.joined(separator: "\n"))
        if !evening { out.append("Open tasks without a date: \(noDate.count)") }

        let approvals = ((try? ctx.fetch(FetchDescriptor<Approval>())) ?? []).filter { $0.status == .pending && $0.approvers.contains(me) && $0.decisions[me] == nil }
        if !approvals.isEmpty {
            out.append("Approvals waiting for me:\n" + approvals.prefix(10).map { "- \($0.title)\($0.amount.map { " " + Money.format($0) } ?? "") from \(engine.name(of: $0.requestedBy))" }.joined(separator: "\n"))
        }

        let meds = (try? ctx.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { $0.active && !$0.deleted }))) ?? []
        let profiles = Dictionary(uniqueKeysWithValues: ((try? ctx.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { !$0.deleted }))) ?? []).map { ($0.id, $0.name) })
        let logs = Set(((try? ctx.fetch(FetchDescriptor<DoseLog>(predicate: #Predicate { $0.scheduled >= start }))) ?? []).map(\.id))
        let doses = meds.flatMap { m in m.schedule(on: .now).map { (m, $0) } }
        if !doses.isEmpty {
            let missed = doses.filter { !logs.contains(DoseLog.key($0.0.id, $0.1)) && $0.1 < .now }
            out.append("Medicines today: \(doses.count) doses, \(missed.count) not yet marked" +
                       (missed.isEmpty ? "" : ": " + missed.prefix(6).map { "\(profiles[$0.0.profileID] ?? "") \($0.0.name) at \($0.1.formatted(date: .omitted, time: .shortened))" }.joined(separator: "; ")))
        }

        let plans = ((try? ctx.fetch(FetchDescriptor<GymPlan>(predicate: #Predicate { !$0.deleted }))) ?? []).filter { $0.isActive && $0.daysLeft <= 15 }
        let members = Dictionary(uniqueKeysWithValues: ((try? ctx.fetch(FetchDescriptor<GymMember>(predicate: #Predicate { !$0.deleted }))) ?? []).map { ($0.id, $0.name) })
        if !plans.isEmpty {
            out.append("Gym memberships ending soon: " + plans.map { "\(members[$0.memberID] ?? "") at \($0.gymName) in \($0.daysLeft) days" }.joined(separator: "; "))
        }
        let sessions = ((try? ctx.fetch(FetchDescriptor<GymSession>(predicate: #Predicate { !$0.deleted && $0.date >= start }))) ?? [])
        if !sessions.isEmpty { out.append("Training sessions logged today: " + sessions.map { members[$0.memberID] ?? "" }.joined(separator: ", ")) }

        let unread = ((try? ctx.fetch(FetchDescriptor<Conversation>())) ?? []).filter { $0.unread > 0 && !$0.muted }
        if !unread.isEmpty { out.append("Chats with unread messages: " + unread.prefix(8).map { "\($0.title) (\($0.unread))" }.joined(separator: ", ")) }
        return out.joined(separator: "\n\n")
    }

    static func chat(_ conv: Conversation, engine: SyncEngine, limit: Int = 150) -> String {
        guard let ctx = engine.context else { return "" }
        let id = conv.id
        var fd = FetchDescriptor<Message>(predicate: #Predicate { $0.convID == id && !$0.deleted }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        fd.fetchLimit = limit
        let msgs = ((try? ctx.fetch(fd)) ?? []).reversed()
        return "Chat: \(conv.title)\n" + msgs.map {
            "[\($0.createdAt.formatted(date: .abbreviated, time: .shortened))] \($0.isSystem ? "" : engine.name(of: $0.senderID) + ": ")\($0.preview)"
        }.joined(separator: "\n")
    }

    static func groupReport(_ conv: Conversation, engine: SyncEngine) -> String {
        guard let ctx = engine.context else { return "" }
        let id = conv.id
        let tasks = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.convID == id && !$0.deleted }))) ?? []
        let weekAgo = Date(timeIntervalSinceNow: -7 * 86400)
        var out = ["Group: \(conv.title). Members: " + conv.members.map(\.name).joined(separator: ", ")]
        out.append("Open tasks:\n" + tasks.filter { !$0.isDone }.prefix(40).map { taskLine($0, engine: engine) }.joined(separator: "\n"))
        out.append("Completed in the last 7 days:\n" + tasks.filter { $0.isDone && ($0.completedAt ?? .distantPast) >= weekAgo }
            .map { "- \($0.title) by \(engine.name(of: $0.completedBy ?? ""))" }.joined(separator: "\n"))
        let ids = Set(tasks.map(\.id))
        let expenses = ((try? ctx.fetch(FetchDescriptor<Expense>(predicate: #Predicate { !$0.deleted }))) ?? []).filter { ids.contains($0.taskID) }
        if !expenses.isEmpty {
            out.append("Expenses: total \(Money.format(expenses.reduce(0) { $0 + $1.amount })); last 7 days \(Money.format(expenses.filter { $0.date >= weekAgo }.reduce(0) { $0 + $1.amount }))")
        }
        return out.joined(separator: "\n\n")
    }
}

// MARK: - My Day

struct MyDayView: View {
    let evening: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @ObservedObject private var ai = AISettings.shared
    @Query(filter: #Predicate<TaskItem> { !$0.deleted }) private var allTasks: [TaskItem]
    @State private var brief = ""
    @State private var briefError: String?
    @State private var loading = false
    @State private var moveSelection: Set<String> = []
    @State private var moved = false

    private var me: String { engine.me }
    private var start: Date { Calendar.current.startOfDay(for: .now) }
    private var mine: [TaskItem] { allTasks.filter { $0.involves(me) } }
    private var overdue: [TaskItem] { mine.filter { $0.isOverdue && ($0.dueAt ?? .now) < start } }
    private var today: [TaskItem] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? .now
        return mine.filter { !$0.isDone && ($0.dueAt.map { $0 >= start && $0 < end } ?? false) }
    }
    private var doneToday: [TaskItem] { mine.filter { $0.isDone && ($0.completedAt.map { $0 >= start } ?? false) } }
    /// Unfinished work you may move: tasks you created or that are only yours.
    private var movable: [TaskItem] { (overdue + today).filter { $0.createdBy == me || $0.assignees == [me] } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(evening ? "How was your day, \(engine.myName.split(separator: " ").first.map(String.init) ?? "")?" : greeting)
                        .font(.title2.bold())
                    Text(Date.now.formatted(date: .complete, time: .omitted)).font(.subheadline).foregroundStyle(look.textSecondary)
                }
                HStack(spacing: 10) {
                    GymStat(value: "\(doneToday.count)", label: "Done today", icon: "checkmark.seal.fill")
                    GymStat(value: "\(today.count)", label: "Due today", icon: "calendar")
                    GymStat(value: "\(overdue.count)", label: "Overdue", icon: "exclamationmark.triangle.fill", warn: !overdue.isEmpty)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            .lookRows()

            Section {
                if ai.allows(.myDay) {
                    if loading { HStack { ProgressView(); Text("Writing your summary…").foregroundStyle(look.textSecondary) } }
                    else if let briefError { Text(briefError).font(.caption).foregroundStyle(look.warning) }
                    else if !brief.isEmpty { Text(.init(brief)).textSelection(.enabled) }
                    Button(brief.isEmpty ? "Write my summary" : "Write again", systemImage: "sparkles") { Task { await write() } }
                        .disabled(loading)
                } else {
                    Text("Turn on AI in Settings → AI for a written summary and suggestions. The lists below work without it.")
                        .font(.caption).foregroundStyle(look.textSecondary)
                }
            } header: { Label(evening ? "AI review" : "AI brief", systemImage: "sparkles") }
            .lookRows()

            if evening {
                if !doneToday.isEmpty {
                    Section("Completed today") { ForEach(doneToday) { t in Label(t.title, systemImage: "checkmark.circle.fill").foregroundStyle(look.success) } }
                        .lookRows()
                }
                if !movable.isEmpty {
                    Section {
                        ForEach(movable) { t in
                            Button {
                                if moveSelection.contains(t.id) { moveSelection.remove(t.id) } else { moveSelection.insert(t.id) }
                            } label: {
                                HStack {
                                    Image(systemName: moveSelection.contains(t.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(look.accent)
                                    VStack(alignment: .leading) {
                                        Text(t.title).foregroundStyle(Color.primary)
                                        Text("\(t.dueAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "") → \(Self.tomorrow(for: t).formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(look.textSecondary)
                                    }
                                }
                            }
                        }
                        Button(moved ? "Moved ✓" : "Move \(moveSelection.count) to tomorrow", systemImage: "arrow.forward.circle.fill") { move() }
                            .buttonStyle(.glassProminent).disabled(moveSelection.isEmpty || moved)
                    } header: {
                        Text("Not finished — move to tomorrow?")
                    } footer: {
                        Text("Everyone on the task sees the new date. Group tasks created by others can only be moved by their creator.")
                    }
                    .lookRows()
                }
            } else {
                if !overdue.isEmpty { taskSection("Overdue", overdue, tint: look.danger) }
                if !today.isEmpty { taskSection("Due today", today, tint: look.warning) }
                if overdue.isEmpty && today.isEmpty {
                    Section { Text("Nothing due today. 🎉").foregroundStyle(look.textSecondary) }.lookRows()
                }
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle(evening ? "End of day" : "My Day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            if !brief.isEmpty { ToolbarItem(placement: .primaryAction) { ShareMenu(title: evening ? "End of day" : "My Day", text: { brief }).labelStyle(.iconOnly) } }
        }
        .task {
            moveSelection = Set(movable.map(\.id))
            if evening && MyDaySettings.autoShift && !movable.isEmpty { move() }
            if ai.allows(.myDay) && brief.isEmpty { await write() }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        let name = engine.myName.split(separator: " ").first.map(String.init) ?? ""
        return (h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening") + (name.isEmpty ? "" : ", \(name)")
    }

    private func taskSection(_ title: String, _ items: [TaskItem], tint: Color) -> some View {
        Section {
            ForEach(items) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.subheadline.weight(.semibold))
                    Text([t.dueAt.map { $0.formatted(date: .omitted, time: .shortened) }, t.convID.flatMap { engine.conversation($0)?.title }]
                        .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(look.textSecondary)
                }
            }
        } header: { Text(title).foregroundStyle(tint) }
        .lookRows()
    }

    /// Same time of day, next day (skipping Sunday).
    static func tomorrow(for t: TaskItem) -> Date {
        let cal = Calendar.current
        let base = t.dueAt ?? cal.date(bySettingHour: 10, minute: 0, second: 0, of: .now) ?? .now
        let time = cal.dateComponents([.hour, .minute], from: base)
        var day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now
        if cal.component(.weekday, from: day) == 1 { day = cal.date(byAdding: .day, value: 1, to: day) ?? day }
        return cal.date(bySettingHour: time.hour ?? 10, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    private func move() {
        for t in movable where moveSelection.contains(t.id) {
            let next = Self.tomorrow(for: t)
            engine.updateTask(t, fields: ["dueAt"], change: "moved to \(next.formatted(date: .abbreviated, time: .shortened))") { $0.dueAt = next }
        }
        engine.save()
        if let ctx = engine.context { Reminders.shared.reschedule(context: ctx, me: engine.me) }
        moved = true
        Haptics.success()
    }

    private func write() async {
        loading = true; briefError = nil
        defer { loading = false }
        let instructions = evening
            ? "Write an end-of-day review: 2–3 lines on how the day went, what got done, what is left and why it matters, then 3 suggestions for tomorrow. Be encouraging but honest."
            : "Write a morning brief: the 3 most important things to do today in order, anything urgent (overdue tasks, approvals waiting, missed medicines, gym renewals), then 2–3 practical suggestions for planning the day in iTeam."
        do { brief = try await AIService.complete(AIContext.myDay(engine: engine, evening: evening), instructions: instructions) }
        catch { briefError = error.localizedDescription }
    }
}
