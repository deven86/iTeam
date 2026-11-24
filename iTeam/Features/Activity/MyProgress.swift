import SwiftUI
import SwiftData

// MARK: - 🔥 My Progress — daily challenges, productivity score, weekly summary, community, badges, milestones
//
// Everything is computed on this phone from what you already do in iTeam (tasks, chats, Views, workouts, water).
// Nothing is uploaded; nothing is ranked against other people.

struct ProgressStats {
    var tasksToday = 0, onTimeToday = 0, tasksWeek = 0, tasksLastWeek = 0, onTimeWeek = 0
    var tasksAll = 0, onTimeAll = 0, earlyBird = false
    var groupMsgsToday = 0, groupMsgsWeek = 0, groupMsgsAll = 0, thanksToday = 0
    var postsToday = 0, postsWeek = 0, postsAll = 0
    var workoutsToday = 0, workoutsWeek = 0
    var waterToday = 0.0
    var plannedToday = 0               // tasks created today with a due date
    var bestDay: (Date, Int)? = nil
    var streak = 0

    @MainActor static func compute(me: String, context ctx: ModelContext, conversations: [Conversation]) -> ProgressStats {
        var s = ProgressStats()
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let week = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? today
        let lastWeek = cal.date(byAdding: .day, value: -7, to: week) ?? week
        let tasks = ((try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted && $0.completedAt != nil }))) ?? [])
            .filter { $0.assignees.contains(me) || ($0.assignees.isEmpty && $0.createdBy == me) }
        func onTime(_ t: TaskItem) -> Bool { t.dueAt.map { (t.completedAt ?? .now) <= $0 } ?? true }
        for t in tasks {
            guard let c = t.completedAt else { continue }
            s.tasksAll += 1; if onTime(t) { s.onTimeAll += 1 }
            if c >= today { s.tasksToday += 1; if onTime(t) { s.onTimeToday += 1 } }
            if c >= week { s.tasksWeek += 1; if onTime(t) { s.onTimeWeek += 1 } }
            if c >= lastWeek && c < week { s.tasksLastWeek += 1 }
            if cal.component(.hour, from: c) < 9 { s.earlyBird = true }
        }
        let created = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted && $0.createdAt >= today }))) ?? []
        s.plannedToday = created.filter { $0.createdBy == me && $0.dueAt != nil }.count

        let groups = Set(conversations.filter { $0.isGroup }.map(\.id))
        let since = lastWeek
        let msgs = (try? ctx.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.senderID == me && !$0.deleted && !$0.isSystem }))) ?? []
        for m in msgs where groups.contains(m.convID) {
            s.groupMsgsAll += 1
            if m.createdAt >= week { s.groupMsgsWeek += 1 }
            if m.createdAt >= today { s.groupMsgsToday += 1 }
        }
        s.thanksToday = msgs.filter { $0.createdAt >= today && ($0.text.lowercased().contains("thank") || $0.text.contains("🙏") || $0.text.lowercased().contains("dhanyavad")) }.count
        _ = since

        let posts = (try? ctx.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.author == me }))) ?? []
        s.postsAll = posts.count
        s.postsWeek = posts.filter { $0.createdAt >= week }.count
        s.postsToday = posts.filter { $0.createdAt >= today }.count

        let logs = (try? ctx.fetch(FetchDescriptor<WorkoutLog>(predicate: #Predicate { $0.start >= week }))) ?? []
        s.workoutsWeek = logs.count
        s.workoutsToday = logs.filter { $0.start >= today }.count
        s.waterToday = ((try? ctx.fetch(FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.date >= today }))) ?? []).reduce(0) { $0 + $1.millilitres }

        // Best day this week + streak of active days (a finished task, a group message or a post).
        var activeDays = Set<Date>()
        var perDay: [Date: Int] = [:]
        for t in tasks { if let c = t.completedAt { let d = cal.startOfDay(for: c); activeDays.insert(d); if c >= week { perDay[d, default: 0] += 1 } } }
        for m in msgs where groups.contains(m.convID) { activeDays.insert(cal.startOfDay(for: m.createdAt)) }
        for p in posts { activeDays.insert(cal.startOfDay(for: p.createdAt)) }
        s.bestDay = perDay.max { $0.value < $1.value }.map { ($0.key, $0.value) }
        var d = today
        if !activeDays.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        while activeDays.contains(d) { s.streak += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return s
    }
}

struct Challenge: Identifiable {
    let id: String
    let title: String
    let icon: String
    let progress: (ProgressStats) -> (Int, Int)
    func done(_ s: ProgressStats) -> Bool { let p = progress(s); return p.0 >= p.1 }
}

enum Challenges {
    static let pool: [Challenge] = [
        Challenge(id: "tasks3", title: "Finish 3 tasks", icon: "checkmark.circle") { ($0.tasksToday, 3) },
        Challenge(id: "ontime", title: "Finish a task before it's due", icon: "clock.badge.checkmark") { ($0.onTimeToday, 1) },
        Challenge(id: "group", title: "Help out in a group chat", icon: "bubble.left.and.bubble.right") { ($0.groupMsgsToday, 1) },
        Challenge(id: "post", title: "Share something on Views", icon: "play.rectangle") { ($0.postsToday, 1) },
        Challenge(id: "workout", title: "Log a workout", icon: "figure.run") { ($0.workoutsToday, 1) },
        Challenge(id: "plan", title: "Plan ahead: add a task with a due date", icon: "calendar.badge.plus") { ($0.plannedToday, 1) },
        Challenge(id: "water", title: "Drink 2 litres of water", icon: "drop.fill") { (Int($0.waterToday / 100), 20) },
        Challenge(id: "thanks", title: "Thank a teammate", icon: "hands.clap") { ($0.thanksToday, 1) },
    ]

    /// Three challenges for today, the same all day, different each day.
    static func today() -> [Challenge] {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        var picks: [Challenge] = []
        var i = day % pool.count
        while picks.count < 3 { let c = pool[i % pool.count]; if !picks.contains(where: { $0.id == c.id }) { picks.append(c) }; i += 3 }
        return picks
    }
}

struct Badge: Identifiable {
    let id: String, title: String, icon: String, detail: String
    let value: (ProgressStats) -> (Int, Int)
}

enum Badges {
    static let all: [Badge] = [
        Badge(id: "first", title: "First win", icon: "flag.fill", detail: "Finish your first task") { ($0.tasksAll, 1) },
        Badge(id: "t10", title: "Getting things done", icon: "checkmark.seal.fill", detail: "Finish 10 tasks") { ($0.tasksAll, 10) },
        Badge(id: "t50", title: "Workhorse", icon: "bolt.fill", detail: "Finish 50 tasks") { ($0.tasksAll, 50) },
        Badge(id: "t100", title: "Century", icon: "rosette", detail: "Finish 100 tasks") { ($0.tasksAll, 100) },
        Badge(id: "ontime20", title: "On-time hero", icon: "clock.fill", detail: "20 tasks done before their due time") { ($0.onTimeAll, 20) },
        Badge(id: "s7", title: "7-day streak", icon: "flame.fill", detail: "Active 7 days in a row") { ($0.streak, 7) },
        Badge(id: "s30", title: "30-day streak", icon: "flame.circle.fill", detail: "Active 30 days in a row") { ($0.streak, 30) },
        Badge(id: "team", title: "Team player", icon: "person.3.fill", detail: "100 messages in groups") { ($0.groupMsgsAll, 100) },
        Badge(id: "creator", title: "Storyteller", icon: "play.rectangle.fill", detail: "Share 10 posts on Views") { ($0.postsAll, 10) },
        Badge(id: "early", title: "Early bird", icon: "sunrise.fill", detail: "Finish a task before 9 am") { ($0.earlyBird ? 1 : 0, 1) },
    ]
}

enum ProductivityScore {
    /// 0–100 for today: finished tasks, on-time, challenges, a workout and helping others.
    static func today(_ s: ProgressStats) -> Int {
        let ch = Challenges.today().filter { $0.done(s) }.count
        var v = min(s.tasksToday, 3) * 15 + min(s.onTimeToday, 1) * 10 + ch * 10
        v += s.workoutsToday > 0 ? 10 : 0
        v += (s.groupMsgsToday > 0 || s.postsToday > 0) ? 5 : 0
        return min(100, v)
    }
}

struct MyProgressView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.modelContext) private var context
    @Environment(\.look) private var look
    @Query private var conversations: [Conversation]
    @State private var s = ProgressStats()
    @AppStorage("progress.nudges") private var nudges = true

    var body: some View {
        let score = ProductivityScore.today(s)
        List {
            Section {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(look.accent.opacity(0.2), lineWidth: 12)
                        Circle().trim(from: 0, to: CGFloat(score) / 100).stroke(look.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 0) { Text("\(score)").font(.title.bold().monospacedDigit()); Text("today").font(.caption2) }
                    }
                    .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(s.streak)-day streak", systemImage: "flame.fill").foregroundStyle(.orange).font(.headline)
                        Text("\(s.tasksToday) tasks done today · \(s.tasksWeek) this week").font(.subheadline)
                        Text(score >= 80 ? "Brilliant day! 🌟" : score >= 50 ? "Good going — one more challenge?" : "Small steps count. Try a challenge below.")
                            .font(.caption).foregroundStyle(look.textSecondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Today's challenges") {
                ForEach(Challenges.today()) { c in
                    let p = c.progress(s)
                    HStack {
                        Image(systemName: c.done(s) ? "checkmark.circle.fill" : c.icon).foregroundStyle(c.done(s) ? .green : look.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.title).strikethrough(c.done(s))
                            ProgressView(value: Double(min(p.0, p.1)), total: Double(p.1))
                        }
                    }
                }
            }
            Section {
                row("Tasks finished", s.tasksWeek, s.tasksLastWeek)
                LabeledContent("On time", value: s.tasksWeek == 0 ? "—" : "\(s.onTimeWeek * 100 / max(s.tasksWeek, 1))%")
                LabeledContent("Group messages", value: "\(s.groupMsgsWeek)")
                LabeledContent("Views posts", value: "\(s.postsWeek)")
                LabeledContent("Workouts", value: "\(s.workoutsWeek)")
                if let b = s.bestDay { LabeledContent("Best day", value: "\(b.0.formatted(.dateTime.weekday(.wide))) · \(b.1) tasks") }
                ShareMenu(title: "My week in iTeam", text: { weekText })
            } header: { Text("This week") }
            Section {
                LabeledContent("Messages in groups", value: "\(s.groupMsgsAll)")
                LabeledContent("Posts shared", value: "\(s.postsAll)")
            } header: { Text("Community") } footer: { Text("Helping in groups and sharing on Views count towards your score.") }
            Section("Badges") {
                ForEach(Badges.all) { b in
                    let v = b.value(s); let got = v.0 >= v.1
                    HStack {
                        Image(systemName: b.icon).font(.title3).foregroundStyle(got ? .yellow : .secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(b.title).font(.body.weight(got ? .semibold : .regular))
                            Text(got ? "Earned ✓" : b.detail).font(.caption).foregroundStyle(look.textSecondary)
                            if !got { ProgressView(value: Double(min(v.0, v.1)), total: Double(v.1)) }
                        }
                    }
                }
            }
            if let next = Badges.all.first(where: { let v = $0.value(s); return v.0 < v.1 }) {
                Section("Next milestone") {
                    let v = next.value(s)
                    Label("\(next.title): \(v.0) / \(v.1)", systemImage: next.icon)
                }
            }
            Section {
                Toggle("Morning challenges & Sunday summary reminders", isOn: $nudges)
            }
        }
        .lookScreen()
        .navigationTitle("My Progress")
        .onAppear(perform: load)
        .refreshable { await engine.sync(); load() }
        .onChange(of: nudges) { _, _ in Reminders.shared.reschedule(context: context, me: engine.me) }
    }

    private func row(_ t: String, _ now: Int, _ before: Int) -> some View {
        LabeledContent(t) {
            HStack(spacing: 6) {
                Text("\(now)").bold()
                if before > 0 || now > 0 {
                    let up = now >= before
                    Label("\(abs(now - before)) vs last week", systemImage: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption).foregroundStyle(up ? .green : .orange)
                }
            }
        }
    }

    private var weekText: String {
        "📊 My week in iTeam\n✅ \(s.tasksWeek) tasks finished (\(s.tasksWeek == 0 ? 0 : s.onTimeWeek * 100 / max(s.tasksWeek, 1))% on time)\n💬 \(s.groupMsgsWeek) group messages · 📢 \(s.postsWeek) posts · 🏋️ \(s.workoutsWeek) workouts\n🔥 \(s.streak)-day streak"
    }

    private func load() { s = ProgressStats.compute(me: engine.me, context: context, conversations: conversations) }
}

/// The card at the top of the Modules hub.
struct ProgressCard: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.modelContext) private var context
    @Environment(\.look) private var look
    @Query private var conversations: [Conversation]
    @State private var s = ProgressStats()

    var body: some View {
        let done = Challenges.today().filter { $0.done(s) }.count
        HStack(spacing: 14) {
            Text("\(ProductivityScore.today(s))").font(.title2.bold().monospacedDigit())
                .frame(width: 54, height: 54).background(look.accent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("My Progress").font(.headline)
                Text("🔥 \(s.streak)-day streak · challenges \(done)/3").font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(look.textSecondary)
        }
        .padding(12)
        .lookCard()
        .onAppear { s = ProgressStats.compute(me: engine.me, context: context, conversations: conversations) }
    }
}
