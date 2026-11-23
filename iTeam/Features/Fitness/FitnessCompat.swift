import UserNotifications
import SwiftUI
import SwiftData
import UIKit

// Glue that lets the Fitness & Nutrition module (ported from iLife) run inside iTeam.

/// iLife had family profiles; in iTeam every record belongs to you (sharing goes through chats).
enum Member {
    static var current: String { "" }
    static func prefix(_ uid: String) -> String { "" }
}


@MainActor
final class Celebration {
    static let shared = Celebration()
    func fire(_ title: String, subtitle: String = "", icon: String = "trophy.fill") { Haptics.success() }
    func fireOncePerDay(key: String, _ title: String, subtitle: String = "", icon: String = "trophy.fill") { Haptics.success() }
}

enum NotificationService {
    static func requestAuthorization() async { _ = await Reminders.shared.requestAuthorization() }
    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// AI tips inside Fitness and Nutrition, using the AI chosen in Settings → AI.
struct AITipCard: View {
    enum Area { case fitness, nutrition, supplements }
    let area: Area
    @Environment(\.modelContext) private var context
    @ObservedObject private var ai = AISettings.shared

    var body: some View {
        if ai.allows(.gym) {
            AIButton(title: area == .fitness ? "AI training tip" : area == .nutrition ? "AI nutrition tip" : "AI supplement check",
                     feature: .gym,
                     instructions: area == .fitness
                        ? "From these workouts, give 3 short, specific training suggestions for this week (volume, rest, balance). No medical advice."
                        : area == .nutrition
                            ? "From today's food log, give 3 short, practical suggestions (protein, calories, Indian food swaps). No medical advice."
                            : "Review this supplement list for timing and obvious overlaps. Suggest asking a doctor about anything uncertain. No dosing advice.",
                     context: { contextText })
                .lookCard()
        }
    }

    private var contextText: String {
        let cal = Calendar.current
        switch area {
        case .fitness:
            let logs = (try? context.fetch(FetchDescriptor<WorkoutLog>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
            return logs.prefix(20).map { "\($0.start.formatted(date: .abbreviated, time: .omitted)) \($0.name) \(Int($0.durationMinutes)) min" }.joined(separator: "\n")
        case .nutrition:
            let foods = ((try? context.fetch(FetchDescriptor<FoodEntry>())) ?? []).filter { cal.isDateInToday($0.date) }
            return foods.map { "\($0.name): \(Int($0.calories)) kcal, P \(Int($0.protein)) g" }.joined(separator: "\n")
        case .supplements:
            let s = (try? context.fetch(FetchDescriptor<Supplement>())) ?? []
            return s.map { "\($0.name) \($0.dose)" }.joined(separator: "\n")
        }
    }
}

// MARK: - Module home

/// Fitness tab: workouts and plans, nutrition (meals, water, supplements), and body transformation.
struct FitnessHomeView: View {
    @StateObject private var session = WorkoutSessionController.shared
    @StateObject private var health = HealthKitManager.shared
    @State private var section = 0
    @State private var showSession = false

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case 0: FitnessView()
                case 1: NutritionView()
                default: TransformationView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    Picker("Section", selection: $section) {
                        Text("Workouts").tag(0); Text("Nutrition").tag(1); Text("Body").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.vertical, 6)
                    .lookFloating(in: Capsule())
                    if section == 0 { HealthStrip(health: health) }
                }
                .padding(.horizontal)
            }
        }
        .environmentObject(session)
        .environmentObject(health)
        .environmentObject(MusicController.shared)
        // The workout screen needs the music controller too — without it iOS crashed the moment a workout started.
        .fullScreenCover(isPresented: $showSession) {
            ActiveWorkoutView().environmentObject(session).environmentObject(health).environmentObject(MusicController.shared)
        }
        .onChange(of: session.isActive) { _, active in if active { showSession = true } }
    }
}

/// Today's numbers from Apple Health (Apple Watch, iPhone and any app that writes to Health).
struct HealthStrip: View {
    @ObservedObject var health: HealthKitManager
    @Environment(\.modelContext) private var context
    @AppStorage("health.connected") private var connected = false

    var body: some View {
        Group {
            if connected {
                HStack {
                    item("figure.walk", "\(Int(health.steps))", "steps")
                    item("flame.fill", "\(Int(health.activeCalories))", "kcal")
                    item("bed.double.fill", String(format: "%.1f", health.sleepHours), "h sleep")
                    item("heart.fill", health.restingHeartRate > 0 ? "\(Int(health.restingHeartRate))" : "–", "rest bpm")
                }
            } else {
                Button {
                    Task { await health.requestAuthorization(); connected = true; await refresh() }
                } label: { Label("Connect Apple Health", systemImage: "heart.text.square.fill").font(.subheadline.weight(.semibold)) }
                .buttonStyle(.glass)
            }
        }
        .padding(8)
        .lookFloating(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { if connected { await refresh() } }
    }

    private func refresh() async {
        await health.refreshToday()
        await health.importWorkouts(into: context, notify: false)
    }

    private func item(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: icon).font(.caption).foregroundStyle(.pink)
            Text(value).font(.subheadline.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DayValue: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

/// Runs once, the first time the view appears (not again after a camera or picker closes).
private struct FirstAppear: ViewModifier {
    @State private var done = false
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onAppear {
            guard !done else { return }
            done = true
            action()
        }
    }
}

extension View {
    func onFirstAppear(perform action: @escaping () -> Void) -> some View { modifier(FirstAppear(action: action)) }
}
struct ExerciseHistory {
    var lastSummary: String?
    var bestKg: Double = 0
    var best1RM: Double = 0

    /// `sets` = every set ever logged; `excluding` = the workout being edited.
    static func make(for exercise: String, sets: [ExerciseSet], excluding: WorkoutLog?) -> ExerciseHistory {
        let mine = sets.filter { $0.exercise.caseInsensitiveCompare(exercise) == .orderedSame && $0.log != nil && $0.log?.persistentModelID != excluding?.persistentModelID }
        guard !mine.isEmpty else { return ExerciseHistory() }
        var h = ExerciseHistory()
        h.bestKg = mine.map(\.weightKg).max() ?? 0
        h.best1RM = mine.map { $0.weightKg * (1 + Double($0.reps) / 30) }.max() ?? 0
        if let lastLog = mine.compactMap(\.log).max(by: { $0.start < $1.start }) {
            let lastSets = mine.filter { $0.log?.persistentModelID == lastLog.persistentModelID }.sorted { $0.order < $1.order }
            if let cardio = lastSets.first, cardio.durationMinutes > 0 {
                h.lastSummary = "\(Int(cardio.durationMinutes)) min" + (cardio.distanceKm > 0 ? " · \(cardio.distanceKm.clean) km" : "")
            } else {
                let parts = lastSets.filter { $0.reps > 0 }.map { $0.weightKg > 0 ? "\($0.reps)×\($0.weightKg.clean)" : "\($0.reps)" }
                if !parts.isEmpty { h.lastSummary = parts.prefix(5).joined(separator: ", ") + (parts.contains { $0.contains("×") } ? " kg" : " reps") }
            }
        }
        return h
    }
}
