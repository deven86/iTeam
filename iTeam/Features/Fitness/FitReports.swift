import SwiftUI
import SwiftData
import HealthKit

// MARK: - Night review (saved on this phone)

@Model final class FitReview {
    var memberUID: String = ""
    var day: Date = Date.now            // start of the day reviewed
    var energy: Int = 3                 // 1…5
    var mood: Int = 3                   // 1…5
    var wentWell: String = ""
    var improve: String = ""
    var tomorrow: String = ""
    var aiText: String = ""
    var createdAt: Date = Date.now
    init(day: Date) { self.day = Calendar.current.startOfDay(for: day) }
}

// MARK: - One day's numbers (for the planner, the night review and the daily report)

struct FitDay {
    var day: Date
    var steps = 0.0, active = 0.0, sleep = 0.0
    var kcal = 0.0, protein = 0.0, waterL = 0.0
    var foods: [FoodEntry] = []
    var workouts: [WorkoutLog] = []
    var mindful = 0.0
    var supplements: [(name: String, taken: Int, planned: Int)] = []
    var planned: [WorkoutPlan] = []
    var goals = (kcal: 2200.0, protein: 120.0, steps: 10_000.0)
    var review: FitReview?

    var workoutMinutes: Double { workouts.reduce(0) { $0 + $1.durationMinutes } }

    var text: String {
        var t = "iTeam day report — \(day.formatted(date: .complete, time: .omitted))\n"
        t += "Steps \(Int(steps)) / \(Int(goals.steps)) · Active \(Int(active)) kcal · Sleep \(String(format: "%.1f", sleep)) h\n"
        t += "Food \(Int(kcal)) / \(Int(goals.kcal)) kcal · Protein \(Int(protein)) / \(Int(goals.protein)) g · Water \(String(format: "%.1f", waterL)) L\n"
        t += "Workouts: " + (workouts.isEmpty ? "none" : workouts.map { "\($0.name) \(Int($0.durationMinutes)) min" }.joined(separator: ", ")) + "\n"
        if !planned.isEmpty { t += "Planned: " + planned.map(\.name).joined(separator: ", ") + "\n" }
        if !supplements.isEmpty { t += "Supplements: " + supplements.map { "\($0.name) \($0.taken)/\($0.planned)" }.joined(separator: ", ") + "\n" }
        if mindful > 0 { t += "Mindful \(Int(mindful)) min\n" }
        if let r = review {
            t += "Energy \(r.energy)/5 · Mood \(r.mood)/5\n"
            if !r.wentWell.isEmpty { t += "Went well: \(r.wentWell)\n" }
            if !r.improve.isEmpty { t += "Improve: \(r.improve)\n" }
            if !r.tomorrow.isEmpty { t += "Tomorrow: \(r.tomorrow)\n" }
        }
        return t
    }
}

@MainActor
enum FitReportBuilder {
    static func day(_ day: Date, context ctx: ModelContext) async -> FitDay {
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: day), d1 = d0.addingTimeInterval(86400)
        var r = FitDay(day: d0)
        let hk = HealthKitManager.shared
        if UserDefaults.standard.bool(forKey: "health.connected") {
            let back = (cal.dateComponents([.day], from: d0, to: cal.startOfDay(for: .now)).day ?? 0) + 1
            if back <= 60 {
                r.steps = await hk.dailySeries(.stepCount, unit: .count(), days: back).first { cal.isDate($0.date, inSameDayAs: d0) }?.value ?? 0
                r.active = await hk.dailySeries(.activeEnergyBurned, unit: .kilocalorie(), days: back).first { cal.isDate($0.date, inSameDayAs: d0) }?.value ?? 0
                r.sleep = await hk.sleepSeries(days: back).first { cal.isDate($0.date, inSameDayAs: d0) }?.value ?? 0
            }
        }
        r.foods = ((try? ctx.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.date >= d0 && $0.date < d1 }))) ?? []).sorted { $0.date < $1.date }
        r.kcal = r.foods.reduce(0) { $0 + $1.calories }; r.protein = r.foods.reduce(0) { $0 + $1.protein }
        r.waterL = ((try? ctx.fetch(FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.date >= d0 && $0.date < d1 }))) ?? []).reduce(0) { $0 + $1.millilitres } / 1000
        r.workouts = ((try? ctx.fetch(FetchDescriptor<WorkoutLog>(predicate: #Predicate { $0.start >= d0 && $0.start < d1 }))) ?? []).sorted { $0.start < $1.start }
        r.mindful = ((try? ctx.fetch(FetchDescriptor<MeditationLog>(predicate: #Predicate { $0.date >= d0 && $0.date < d1 }))) ?? []).reduce(0) { $0 + $1.minutes }
        let doses = (try? ctx.fetch(FetchDescriptor<SupplementDose>(predicate: #Predicate { $0.day >= d0 && $0.day < d1 }))) ?? []
        r.supplements = ((try? ctx.fetch(FetchDescriptor<Supplement>())) ?? []).filter { $0.isDue(on: d0) }
            .map { s in (s.name, doses.filter { $0.supplementUID == s.uid }.count, s.doseSlots.count) }
        let wd = cal.component(.weekday, from: d0)
        r.planned = ((try? ctx.fetch(FetchDescriptor<WorkoutPlan>())) ?? []).filter { $0.weekdays.contains(wd) }
        if let p = ((try? ctx.fetch(FetchDescriptor<HealthProfile>())) ?? []).first {
            r.goals = (p.calorieIntakeGoal, p.proteinGoal, p.stepGoal)
        }
        r.review = ((try? ctx.fetch(FetchDescriptor<FitReview>(predicate: #Predicate { $0.day == d0 }))) ?? []).max { $0.createdAt < $1.createdAt }
        return r
    }
}

// MARK: - Daily report card (image / PDF)

struct FitDayCard: View {
    let d: FitDay
    var body: some View {
        ShareFrame(title: "Daily Report", subtitle: d.day.formatted(date: .complete, time: .omitted)) {
            VStack(spacing: 10) {
                HStack {
                    ShareStat(value: Int(d.steps).formatted(), label: "steps / \(Int(d.goals.steps / 1000))k", color: .cyan)
                    ShareStat(value: "\(Int(d.active))", label: "active kcal", color: .orange)
                    ShareStat(value: String(format: "%.1f h", d.sleep), label: "sleep", color: .indigo)
                }
                HStack {
                    ShareStat(value: "\(Int(d.kcal))", label: "kcal / \(Int(d.goals.kcal))", color: .red)
                    ShareStat(value: "\(Int(d.protein)) g", label: "protein / \(Int(d.goals.protein))", color: .yellow)
                    ShareStat(value: String(format: "%.1f L", d.waterL), label: "water", color: .blue)
                }
                HStack {
                    ShareStat(value: "\(d.workouts.count)", label: "workouts", color: .green)
                    ShareStat(value: "\(Int(d.workoutMinutes))", label: "training min", color: .green)
                    ShareStat(value: "\(Int(d.mindful))", label: "mindful min", color: .mint)
                }
            }
            .shareBox()
            if !d.workouts.isEmpty || !d.planned.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Training").font(.headline)
                    ForEach(d.workouts) { w in
                        Text("✓ \(w.start.formatted(date: .omitted, time: .shortened)) · \(w.name) · \(Int(w.durationMinutes)) min · \(Int(w.calories)) kcal").font(.caption2)
                    }
                    ForEach(d.planned.filter { p in !d.workouts.contains { $0.name == p.name } }) { p in
                        Text("○ Planned: \(p.name) · \(p.estimatedMinutes) min").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).shareBox()
            }
            if !d.foods.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Food").font(.headline)
                    ForEach(d.foods.prefix(25)) { f in
                        Text("\(f.date.formatted(date: .omitted, time: .shortened)) · \(f.name) · \(Int(f.calories)) kcal · P \(Int(f.protein)) g").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).shareBox()
            }
            if !d.supplements.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Supplements").font(.headline)
                    ForEach(d.supplements.indices, id: \.self) { i in
                        let s = d.supplements[i]
                        Text("\(s.taken >= s.planned ? "✓" : "○") \(s.name) · \(s.taken)/\(s.planned)").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).shareBox()
            }
            if let r = d.review {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Night review · energy \(r.energy)/5 · mood \(r.mood)/5").font(.headline)
                    if !r.wentWell.isEmpty { Text("Went well: \(r.wentWell)").font(.caption2) }
                    if !r.improve.isEmpty { Text("Improve: \(r.improve)").font(.caption2) }
                    if !r.tomorrow.isEmpty { Text("Tomorrow: \(r.tomorrow)").font(.caption2) }
                    if !r.aiText.isEmpty { Text("AI: \(r.aiText)").font(.caption2).foregroundStyle(.white.opacity(0.8)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).shareBox()
            }
        }
    }
}

// MARK: - Period report (PDF / image with charts)

struct FitRange {
    var from: Date, to: Date
    var steps: [DayValue] = [], active: [DayValue] = [], sleep: [DayValue] = []
    var kcal: [DayValue] = [], protein: [DayValue] = [], water: [DayValue] = []
    var workoutMin: [DayValue] = [], mindful: [DayValue] = [], weight: [DayValue] = []
    var energy: [DayValue] = [], mood: [DayValue] = []
    var workouts: [WorkoutLog] = []
    var ptDays = 0
    var doseTaken = 0, dosePlanned = 0
    var goals = (kcal: 2200.0, protein: 120.0, steps: 10_000.0)
}

@MainActor
enum FitRangeBuilder {
    static func build(from: Date, to: Date, context ctx: ModelContext) async -> FitRange {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from), end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!
        var r = FitRange(from: start, to: cal.startOfDay(for: to))
        func clip(_ v: [DayValue]) -> [DayValue] { v.filter { $0.date >= start && $0.date < end } }
        func perDay<T>(_ items: [T], date: (T) -> Date, value: (T) -> Double) -> [DayValue] {
            var sums: [Date: Double] = [:]
            for i in items where date(i) >= start && date(i) < end { sums[cal.startOfDay(for: date(i)), default: 0] += value(i) }
            return sums.map { DayValue(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
        }
        if UserDefaults.standard.bool(forKey: "health.connected") {
            let hk = HealthKitManager.shared
            let back = (cal.dateComponents([.day], from: start, to: cal.startOfDay(for: .now)).day ?? 0) + 1
            r.steps = clip(await hk.dailySeries(.stepCount, unit: .count(), days: back))
            r.active = clip(await hk.dailySeries(.activeEnergyBurned, unit: .kilocalorie(), days: back))
            if back <= 60 { r.sleep = clip(await hk.sleepSeries(days: back)) }
        }
        let foods = (try? ctx.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        r.kcal = perDay(foods, date: { $0.date }, value: { $0.calories })
        r.protein = perDay(foods, date: { $0.date }, value: { $0.protein })
        let water = (try? ctx.fetch(FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        r.water = perDay(water, date: { $0.date }, value: { $0.millilitres / 1000 })
        let logs = ((try? ctx.fetch(FetchDescriptor<WorkoutLog>(predicate: #Predicate { $0.start >= start && $0.start < end }))) ?? []).sorted { $0.start < $1.start }
        r.workouts = logs
        r.workoutMin = perDay(logs, date: { $0.start }, value: { $0.durationMinutes })
        r.ptDays = logs.ptDays().count
        let meds = (try? ctx.fetch(FetchDescriptor<MeditationLog>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        r.mindful = perDay(meds, date: { $0.date }, value: { $0.minutes })
        r.weight = ((try? ctx.fetch(FetchDescriptor<BodyMeasurement>(predicate: #Predicate { $0.date >= start && $0.date < end && $0.weightKg > 0 }))) ?? [])
            .map { DayValue(date: $0.date, value: $0.weightKg) }.sorted { $0.date < $1.date }
        let reviews = (try? ctx.fetch(FetchDescriptor<FitReview>(predicate: #Predicate { $0.day >= start && $0.day < end }))) ?? []
        r.energy = reviews.map { DayValue(date: $0.day, value: Double($0.energy)) }.sorted { $0.date < $1.date }
        r.mood = reviews.map { DayValue(date: $0.day, value: Double($0.mood)) }.sorted { $0.date < $1.date }
        let sups = (try? ctx.fetch(FetchDescriptor<Supplement>())) ?? []
        let days = max(1, cal.dateComponents([.day], from: start, to: end).day ?? 1)
        for o in 0..<days { if let d = cal.date(byAdding: .day, value: o, to: start) { r.dosePlanned += sups.filter { $0.isDue(on: d) }.reduce(0) { $0 + $1.doseSlots.count } } }
        r.doseTaken = ((try? ctx.fetch(FetchDescriptor<SupplementDose>(predicate: #Predicate { $0.day >= start && $0.day < end }))) ?? []).count
        if let p = ((try? ctx.fetch(FetchDescriptor<HealthProfile>())) ?? []).first { r.goals = (p.calorieIntakeGoal, p.proteinGoal, p.stepGoal) }
        return r
    }
}

struct FitRangeCard: View {
    let r: FitRange
    private func avg(_ v: [DayValue]) -> Double { v.isEmpty ? 0 : v.map(\.value).reduce(0, +) / Double(v.count) }

    var body: some View {
        ShareFrame(title: "Fitness Report", subtitle: "\(r.from.formatted(date: .abbreviated, time: .omitted)) – \(r.to.formatted(date: .abbreviated, time: .omitted))") {
            VStack(spacing: 10) {
                HStack {
                    ShareStat(value: Int(avg(r.steps)).formatted(), label: "avg steps", color: .cyan)
                    ShareStat(value: "\(Int(avg(r.active)))", label: "avg active kcal", color: .orange)
                    ShareStat(value: String(format: "%.1f h", avg(r.sleep)), label: "avg sleep", color: .indigo)
                }
                HStack {
                    ShareStat(value: "\(r.workouts.count)", label: "workouts", color: .green)
                    ShareStat(value: "\(Int(r.workouts.reduce(0) { $0 + $1.durationMinutes }))", label: "training min", color: .green)
                    ShareStat(value: "\(r.ptDays)", label: "PT days", color: .orange)
                }
                HStack {
                    ShareStat(value: "\(Int(avg(r.kcal)))", label: "avg kcal eaten", color: .red)
                    ShareStat(value: "\(Int(avg(r.protein))) g", label: "avg protein", color: .yellow)
                    ShareStat(value: String(format: "%.1f L", avg(r.water)), label: "avg water", color: .blue)
                }
                if r.dosePlanned > 0 || r.weight.count >= 2 || !r.energy.isEmpty {
                    HStack {
                        if r.dosePlanned > 0 { ShareStat(value: "\(min(100, r.doseTaken * 100 / max(r.dosePlanned, 1)))%", label: "supplements taken", color: .teal) }
                        if let a = r.weight.first?.value, let b = r.weight.last?.value, r.weight.count >= 2 {
                            ShareStat(value: String(format: "%+.1f kg", b - a), label: "weight change", color: .purple)
                        }
                        if !r.energy.isEmpty { ShareStat(value: String(format: "%.1f/5", avg(r.energy)), label: "avg energy", color: .pink) }
                    }
                }
            }
            .shareBox()
            if r.weight.count >= 2 { ShareChart(title: "Weight (kg)", points: r.weight, color: .purple, line: true) }
            if !r.steps.isEmpty { ShareChart(title: "Steps", points: r.steps, color: .cyan, goal: r.goals.steps) }
            if !r.active.isEmpty { ShareChart(title: "Active energy (kcal)", points: r.active, color: .orange) }
            if !r.sleep.isEmpty { ShareChart(title: "Sleep (h)", points: r.sleep, color: .indigo, goal: 8) }
            if !r.workoutMin.isEmpty { ShareChart(title: "Workout minutes", points: r.workoutMin, color: .green) }
            if !r.kcal.isEmpty { ShareChart(title: "Calories eaten", points: r.kcal, color: .red, goal: r.goals.kcal) }
            if !r.protein.isEmpty { ShareChart(title: "Protein (g)", points: r.protein, color: .yellow, goal: r.goals.protein) }
            if !r.water.isEmpty { ShareChart(title: "Water (L)", points: r.water, color: .blue) }
            if !r.mindful.isEmpty { ShareChart(title: "Mindful minutes", points: r.mindful, color: .mint) }
            if r.energy.count >= 2 { ShareChart(title: "Energy (night reviews)", points: r.energy, color: .pink, line: true) }
            if !r.workouts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workouts").font(.headline)
                    ForEach(r.workouts.prefix(40)) { w in
                        Text("\(w.start.formatted(.dateTime.day().month(.abbreviated))) · \(w.name) · \(Int(w.durationMinutes)) min" + (w.isPT ? " · PT" : "")).font(.caption2)
                    }
                    if r.workouts.count > 40 { Text("…and \(r.workouts.count - 40) more").font(.caption2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).shareBox()
            }
        }
    }
}

// MARK: - Reports screen

struct FitReportsView: View {
    @Environment(\.modelContext) private var context
    @State private var preset = 30
    @State private var from = Calendar.current.date(byAdding: .day, value: -29, to: .now)!
    @State private var to = Date.now
    @State private var day = Date.now
    @State private var working = false
    @State private var items: [Any] = []
    @State private var show = false

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $preset) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365); Text("Custom").tag(0)
                }
                .pickerStyle(.segmented)
                .onChange(of: preset) { _, p in if p > 0 { to = .now; from = Calendar.current.date(byAdding: .day, value: -(p - 1), to: .now)! } }
                if preset == 0 {
                    DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
                }
                Button { Task { await range(pdf: true) } } label: { Label("Fitness report — PDF with charts", systemImage: "doc.richtext.fill") }
                Button { Task { await range(pdf: false) } } label: { Label("Fitness report — image", systemImage: "photo.fill") }
            } header: { Text("Period report") } footer: { Text("Steps, sleep, training, food, protein, water, weight, supplements and your night reviews — ready for WhatsApp, your trainer or doctor.") }
            Section {
                DatePicker("Day", selection: $day, in: ...Date.now, displayedComponents: .date)
                Button { Task { await daily(pdf: true) } } label: { Label("Daily report — PDF", systemImage: "doc.richtext") }
                Button { Task { await daily(pdf: false) } } label: { Label("Daily report — image", systemImage: "photo") }
            } header: { Text("One day") }
            if working { Section { HStack { ProgressView(); Text("Preparing…") } } }
        }
        .navigationTitle("Reports")
        .sheet(isPresented: $show) { ShareSheet(items: items) }
    }

    private func range(pdf: Bool) async {
        working = true; defer { working = false }
        let r = await FitRangeBuilder.build(from: from, to: to, context: context)
        let name = "iTeam fitness \(r.from.formatted(.iso8601.year().month().day())) to \(r.to.formatted(.iso8601.year().month().day()))"
        if pdf, let u = Exporter.pdf(FitRangeCard(r: r), name: name) { items = [u]; show = true }
        if !pdf, let i = Exporter.image(FitRangeCard(r: r)) { items = [i]; show = true }
    }

    private func daily(pdf: Bool) async {
        working = true; defer { working = false }
        let d = await FitReportBuilder.day(day, context: context)
        if pdf, let u = Exporter.pdf(FitDayCard(d: d), name: "iTeam day \(d.day.formatted(.iso8601.year().month().day()))") { items = [u, d.text]; show = true }
        if !pdf, let i = Exporter.image(FitDayCard(d: d)) { items = [i]; show = true }
    }
}

// MARK: - Daily planner (morning)

struct DayPlannerView: View {
    @Environment(\.modelContext) private var context
    @State private var d: FitDay?
    @AppStorage("fit.planner.on") private var remind = false

    var body: some View {
        List {
            if let d {
                Section("Today's goals") {
                    progress("Steps", d.steps, d.goals.steps, "figure.walk")
                    progress("Calories", d.kcal, d.goals.kcal, "flame")
                    progress("Protein (g)", d.protein, d.goals.protein, "fork.knife")
                    progress("Water (L)", d.waterL, 3, "drop")
                }
                Section("Training") {
                    if d.planned.isEmpty { Text("No plan for today. Rest day — or pick a plan in Workouts → Plans.").foregroundStyle(.secondary) }
                    ForEach(d.planned) { p in
                        let done = d.workouts.contains { $0.name == p.name }
                        Label("\(p.name) · \(p.estimatedMinutes) min · \(p.focus)", systemImage: done ? "checkmark.circle.fill" : "circle")
                    }
                    ForEach(d.workouts) { w in Label("Done: \(w.name) · \(Int(w.durationMinutes)) min", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                }
                if !d.supplements.isEmpty {
                    Section("Supplements & medicines") {
                        ForEach(d.supplements.indices, id: \.self) { i in
                            let s = d.supplements[i]
                            Label("\(s.name) · \(s.taken)/\(s.planned)", systemImage: s.taken >= s.planned ? "checkmark.circle.fill" : "pills")
                        }
                    }
                }
                Section {
                    AIButton(title: "Plan my day", feature: .gym,
                             instructions: "You are a friendly fitness coach. From today's plan, goals, supplements and yesterday's numbers, write a short plan for today: when to train, meals with protein targets, water, steps and sleep time. Bullets, under 120 words. Not medical advice.",
                             context: { d.text })
                }
                Section {
                    Toggle("Morning planner & night review reminders", isOn: $remind)
                } footer: { Text("A nudge at 7:00 to plan the day and at 21:30 to review it.") }
            } else { ProgressView() }
        }
        .navigationTitle("Plan my day")
        .task { d = await FitReportBuilder.day(.now, context: context) }
        .onChange(of: remind) { _, _ in Reminders.shared.reschedule(context: context, me: SyncEngine.shared.me) }
    }

    private func progress(_ t: String, _ v: Double, _ goal: Double, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Label(t, systemImage: icon); Spacer(); Text("\(Int(v)) / \(Int(goal))").monospacedDigit().foregroundStyle(.secondary) }
            ProgressView(value: min(v, goal), total: max(goal, 1))
        }
    }
}

// MARK: - Night review

struct NightReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FitReview.day, order: .reverse) private var past: [FitReview]
    @State private var d: FitDay?
    @State private var energy = 3
    @State private var mood = 3
    @State private var wentWell = ""
    @State private var improve = ""
    @State private var tomorrow = ""
    @State private var aiText = ""
    @State private var loadingAI = false

    var body: some View {
        Form {
            if let d {
                Section("Today in numbers") {
                    Text(d.text).font(.caption).textSelection(.enabled)
                }
            }
            Section("How was today?") {
                Stepper("Energy \(String(repeating: "⚡️", count: energy))", value: $energy, in: 1...5)
                Stepper("Mood \(String(repeating: "🙂", count: mood))", value: $mood, in: 1...5)
                TextField("What went well?", text: $wentWell, axis: .vertical)
                TextField("What to improve?", text: $improve, axis: .vertical)
                TextField("Plan for tomorrow", text: $tomorrow, axis: .vertical)
            }
            if AISettings.shared.allows(.gym) {
                Section {
                    Button(loadingAI ? "Thinking…" : "✨ AI coach review", systemImage: "sparkles") { Task { await ai() } }.disabled(loadingAI)
                    if !aiText.isEmpty { Text(aiText).font(.callout) }
                } footer: { Text("Advice only — not medical advice.") }
            }
            Section {
                Button("Save review", systemImage: "moon.stars.fill") { save() }.bold()
            }
            if !past.isEmpty {
                Section("Past reviews") {
                    ForEach(past.prefix(14)) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.day.formatted(date: .abbreviated, time: .omitted) + " · energy \(r.energy)/5 · mood \(r.mood)/5").font(.caption.bold())
                            if !r.wentWell.isEmpty { Text("✓ " + r.wentWell).font(.caption) }
                            if !r.improve.isEmpty { Text("↑ " + r.improve).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Night review")
        .task {
            d = await FitReportBuilder.day(.now, context: context)
            if let r = d?.review { energy = r.energy; mood = r.mood; wentWell = r.wentWell; improve = r.improve; tomorrow = r.tomorrow; aiText = r.aiText }
        }
    }

    private func ai() async {
        loadingAI = true; defer { loadingAI = false }
        let ctx = (d?.text ?? "") + "\nEnergy \(energy)/5, mood \(mood)/5. Went well: \(wentWell). Improve: \(improve)."
        aiText = (try? await AIService.complete(ctx, instructions: "You are a kind fitness coach. Review this day in 3–5 short bullets: what went well, one thing to fix tomorrow, and a sleep tip. Under 90 words. Not medical advice.")) ?? ""
    }

    private func save() {
        let r = d?.review ?? FitReview(day: .now)
        if d?.review == nil { context.insert(r) }
        r.energy = energy; r.mood = mood; r.wentWell = wentWell; r.improve = improve; r.tomorrow = tomorrow; r.aiText = aiText; r.createdAt = .now
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

/// Plan · Review · Reports buttons at the top of My training.
struct FitDailyBar: View {
    @State private var open: String?
    var body: some View {
        HStack(spacing: 8) {
            chip("Plan my day", "sun.max.fill", "plan")
            chip("Night review", "moon.stars.fill", "review")
            chip("Reports", "chart.bar.doc.horizontal", "reports")
        }
        .sheet(item: Binding(get: { open.map { FitSheet(id: $0) } }, set: { open = $0?.id })) { s in
            NavigationStack {
                Group {
                    switch s.id {
                    case "plan": DayPlannerView()
                    case "review": NightReviewView()
                    default: FitReportsView()
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { open = nil } } }
            }
        }
    }

    private func chip(_ t: String, _ icon: String, _ id: String) -> some View {
        Button { open = id } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(t).font(.caption2.weight(.semibold)).lineLimit(1) }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.glass)
    }
}

private struct FitSheet: Identifiable { let id: String }
