import SwiftUI
import SwiftData
import Charts

private func dayPoints(_ values: [Double], end: Date) -> [DayValue] {
    let cal = Calendar.current
    return values.enumerated().map { i, v in DayValue(date: cal.date(byAdding: .day, value: i - (values.count - 1), to: end) ?? end, value: v) }
}

/// "8×60kg", "20 min · 3 km", "12 reps" or "done".
func setSummary(_ s: ExerciseSet) -> String {
    if s.durationMinutes > 0 {
        let km = s.distanceKm > 0 ? " · \(s.distanceKm.clean) km" : ""
        return "\(Int(s.durationMinutes)) min" + km
    }
    if s.weightKg > 0 { return "\(s.reps)×\(s.weightKg.clean)kg" }
    return s.reps > 0 ? "\(s.reps) reps" : "done"
}

private func hm(_ hours: Double) -> String {
    guard hours > 0 else { return "–" }
    let h = Int(hours), m = Int((hours - Double(h)) * 60)
    return "\(h)h \(m)m"
}

// MARK: - Daily report

struct NutritionSummaryBlock: View {
    let foods: [FoodEntry]
    let kcalGoal: Double
    let proteinGoal: Double

    var body: some View {
        let k = foods.reduce(0) { $0 + $1.calories }, p = foods.reduce(0) { $0 + $1.protein }
        let c = foods.reduce(0) { $0 + $1.carbs }, f = foods.reduce(0) { $0 + $1.fat }
        let macro = max(p * 4 + c * 4 + f * 9, 1)
        let parts: [(String, Double, Color)] = [("Protein", p * 4 / macro, .cyan), ("Carbs", c * 4 / macro, .yellow), ("Fat", f * 9 / macro, .pink)]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Nutrition").font(.headline)
            HStack(spacing: 16) {
                ZStack {
                    if k > 0 {
                        Chart(parts, id: \.0) { SectorMark(angle: .value("Share", $0.1), innerRadius: .ratio(0.65), angularInset: 2).foregroundStyle($0.2).cornerRadius(3) }
                    } else { Circle().stroke(.white.opacity(0.2), lineWidth: 10) }
                    VStack(spacing: 0) { Text("\(Int(k))").font(.headline); Text("kcal").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(k)) / \(Int(kcalGoal)) kcal").font(.subheadline.bold())
                    Text("Protein \(Int(p)) / \(Int(proteinGoal)) g").font(.caption).foregroundStyle(.cyan)
                    Text("Carbs \(Int(c)) g").font(.caption).foregroundStyle(.yellow)
                    Text("Fat \(Int(f)) g").font(.caption).foregroundStyle(.pink)
                }
            }
            ForEach(MealType.allCases) { meal in
                let items = foods.filter { $0.meal == meal }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(meal.title) · \(Int(items.reduce(0) { $0 + $1.calories })) kcal").font(.caption.bold())
                        ForEach(items) { e in
                            Text("\(e.name)\(e.quantity.isEmpty ? "" : " (\(e.quantity))") — \(Int(e.calories)) kcal, P \(Int(e.protein))g")
                                .font(.caption2).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
        }
        .shareBox()
    }
}

// MARK: - Single items

struct NutritionDayShareCard: View {
    let day: Date
    let foods: [FoodEntry]
    let kcalGoal: Double
    let proteinGoal: Double
    let waterL: Double
    var body: some View {
        ShareFrame(title: "Nutrition", subtitle: day.formatted(date: .complete, time: .omitted)) {
            NutritionSummaryBlock(foods: foods, kcalGoal: kcalGoal, proteinGoal: proteinGoal)
            Label(String(format: "Water %.1f L", waterL), systemImage: "drop.fill").font(.subheadline).shareBox()
        }
    }
}

struct FoodEntryShareCard: View {
    let entry: FoodEntry
    var body: some View {
        ShareFrame(title: entry.name, subtitle: "\(entry.meal.title) · \(entry.date.formatted(date: .abbreviated, time: .shortened))") {
            if let d = entry.photo ?? MediaStore.shared.photo("food", entry.name), let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFill().frame(height: 220).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            HStack {
                ShareStat(value: "\(Int(entry.calories))", label: "kcal", color: .orange)
                ShareStat(value: "\(Int(entry.protein)) g", label: "protein", color: .cyan)
                ShareStat(value: "\(Int(entry.carbs)) g", label: "carbs", color: .yellow)
                ShareStat(value: "\(Int(entry.fat)) g", label: "fat", color: .pink)
            }
            .shareBox()
            if !entry.quantity.isEmpty { Text(entry.quantity).font(.caption).foregroundStyle(.white.opacity(0.7)) }
        }
    }
}

struct WorkoutShareCard: View {
    let log: WorkoutLog
    var trainerName: String?

    var body: some View {
        let volumes: [(String, Double)] = log.exerciseNames.map { ex in
            (ex, log.orderedSets.filter { $0.exercise == ex }.reduce(0) { $0 + Double($1.reps) * $1.weightKg })
        }
        ShareFrame(title: log.name, subtitle: log.start.formatted(date: .complete, time: .shortened), accent: [.orange, .pink]) {
            HStack {
                ShareStat(value: "\(Int(log.durationMinutes))", label: "minutes", color: .green)
                ShareStat(value: "\(Int(log.calories))", label: "kcal", color: .orange)
                ShareStat(value: "\(log.orderedSets.count)", label: "sets", color: .cyan)
                if log.avgHeartRate > 0 { ShareStat(value: "\(Int(log.avgHeartRate))", label: "avg bpm", color: .pink) }
            }
            .shareBox()
            if log.isPT { Label("Personal training\(trainerName.map { " with \($0)" } ?? "")", systemImage: "person.2.fill").font(.caption).shareBox() }
            ForEach(log.exerciseNames, id: \.self) { ex in
                let sets = log.orderedSets.filter { $0.exercise == ex }
                VStack(alignment: .leading, spacing: 4) {
                    Text(ex).font(.subheadline.bold())
                    Text(sets.map(setSummary).joined(separator: "   ")).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .shareBox()
            }
            if volumes.contains(where: { $0.1 > 0 }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Volume by exercise (kg)").font(.caption.bold()).foregroundStyle(.white.opacity(0.8))
                    Chart(volumes.filter { $0.1 > 0 }, id: \.0) { v in
                        BarMark(x: .value("kg", v.1), y: .value("Exercise", v.0))
                            .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)).cornerRadius(3)
                            .annotation(position: .trailing) { Text("\(Int(v.1))").font(.caption2).foregroundStyle(.white.opacity(0.8)) }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white.opacity(0.8)) } }
                    .frame(height: CGFloat(max(1, volumes.filter { $0.1 > 0 }.count)) * 30 + 10)
                }
                .shareBox()
            }
            if !log.notes.isEmpty { Text(log.notes).font(.caption).shareBox() }
        }
    }
}

struct TrendShareCard: View {
    let title: String
    let unit: String
    let data: [DayValue]
    let color: Color
    var goal: Double = 0
    var line = false
    var body: some View {
        let avg = data.isEmpty ? 0 : data.map(\.value).reduce(0, +) / Double(data.count)
        ShareFrame(title: title, subtitle: rangeText) {
            HStack {
                ShareStat(value: line ? (data.last?.value ?? 0).clean : Int(avg.rounded()).formatted(), label: line ? "latest \(unit)" : "daily average \(unit)", color: color)
                ShareStat(value: "\(data.count)", label: "days with data")
            }
            .shareBox()
            ShareChart(title: title, points: data, color: color, goal: goal, line: line)
        }
    }
    private var rangeText: String {
        guard let a = data.first?.date, let b = data.last?.date else { return "" }
        return "\(a.formatted(date: .abbreviated, time: .omitted)) – \(b.formatted(date: .abbreviated, time: .omitted))"
    }
}
