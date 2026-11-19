import SwiftUI
import SwiftData
import UIKit

// Glue that lets the Fitness & Nutrition module (ported from iLife) run inside iTeam.

/// iLife had family profiles; in iTeam every record belongs to you (sharing goes through chats).
enum Member {
    static var current: String { "" }
    static func prefix(_ uid: String) -> String { "" }
}

/// iTeam doesn't read Apple Health (no HealthKit entitlement); these keep the shared views simple.
@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()
    @Published var weightKg: Double = UserDefaults.standard.double(forKey: "fit.weightKg")
    func importWorkouts(into context: ModelContext, notify: Bool) async -> Int { 0 }
    func saveFood(_ entry: FoodEntry) async {}
    func saveWater(ml: Double) async {}
}

@MainActor
final class Celebration {
    static let shared = Celebration()
    func fire(_ title: String, subtitle: String = "", icon: String = "trophy.fill") { Haptics.success() }
    func fireOncePerDay(key: String, _ title: String, subtitle: String = "", icon: String = "trophy.fill") { Haptics.success() }
}

enum NotificationService {
    static func requestAuthorization() async { _ = await Reminders.shared.requestAuthorization() }
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
                Picker("Section", selection: $section) {
                    Text("Workouts").tag(0); Text("Nutrition").tag(1); Text("Body").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 6)
                .lookFloating(in: Capsule())
                .padding(.horizontal)
            }
        }
        .environmentObject(session)
        .environmentObject(health)
        .fullScreenCover(isPresented: $showSession) { ActiveWorkoutView().environmentObject(session).environmentObject(health) }
        .onChange(of: session.isActive) { _, active in if active { showSession = true } }
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
