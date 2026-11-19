import Foundation
import SwiftData

/// Runs an in-app workout session: timer, Lock Screen Live Activity, Apple Music, heart rate, logging.
@MainActor
final class WorkoutSessionController: ObservableObject {
    static let shared = WorkoutSessionController()

    @Published var isActive = false
    @Published var isPaused = false
    @Published var name = ""
    @Published var category = "Strength"
    @Published var exercises: [String] = []
    @Published var exercisePhotos: [Data?] = []
    @Published var exerciseEquipment: [String] = []
    @Published var exerciseIndex = 0
    @Published var elapsed: TimeInterval = 0
    @Published var heartRate = 0
    @Published var calories: Double = 0

    private(set) var startDate = Date.now
    private var pausedAccum: TimeInterval = 0
    private var pauseStart: Date?
    private var timer: Timer?
    private var tick = 0

    var currentExercise: String { exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : name }
    var currentPhoto: Data? { exercisePhotos.indices.contains(exerciseIndex) ? exercisePhotos[exerciseIndex] : nil }
    var currentEquipment: String { exerciseEquipment.indices.contains(exerciseIndex) ? exerciseEquipment[exerciseIndex] : "" }

    private var met: Double {
        switch category {
        case "HIIT": 8
        case "Cardio", "Running": 7.5
        case "Cycling": 7
        case "Yoga", "Mind & Body": 3
        case "Walking": 3.5
        default: 5
        }
    }

    func start(name: String, category: String, exercises: [String], photos: [Data?] = [], equipment: [String] = []) {
        guard !isActive else { return }
        self.name = name; self.category = category; self.exercises = exercises
        self.exercisePhotos = photos; self.exerciseEquipment = equipment
        exerciseIndex = 0; elapsed = 0; calories = 0; heartRate = 0; pausedAccum = 0; isPaused = false
        startDate = .now; isActive = true

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.onTick() }
        }
        startLiveActivity()
        Task { await MusicController.shared.startWorkoutMusic(); updateLiveActivity() }
    }

    private func onTick() async {
        guard isActive, !isPaused else { return }
        elapsed = Date.now.timeIntervalSince(startDate) - pausedAccum
        let weight = HealthKitManager.shared.weightKg > 0 ? HealthKitManager.shared.weightKg : 70
        calories = met * weight * (elapsed / 3600)
        tick += 1
        if tick % 10 == 0 {
            MusicController.shared.refreshNowPlaying()
            updateLiveActivity()
        }
    }

    func togglePause() {
        if isPaused, let p = pauseStart { pausedAccum += Date.now.timeIntervalSince(p); pauseStart = nil }
        else { pauseStart = .now }
        isPaused.toggle()
        updateLiveActivity()
    }

    func nextExercise() {
        if exerciseIndex < exercises.count - 1 { exerciseIndex += 1; updateLiveActivity() }
    }

    func finish(context: ModelContext, save: Bool) async {
        timer?.invalidate(); timer = nil
        if isPaused, let p = pauseStart { pausedAccum += Date.now.timeIntervalSince(p) }
        let duration = (Date.now.timeIntervalSince(startDate) - pausedAccum) / 60
        isActive = false
        MusicController.shared.stop()
        await endLiveActivity()
        guard save, duration >= 1 else { return }
        let log = WorkoutLog(name: name, category: category, start: startDate, durationMinutes: duration,
                             calories: calories, avgHeartRate: Double(heartRate), source: "iTeam")
        context.insert(log)
        // Record which exercises were done so they show in the workout's detail (edit to add reps/kg).
        for (i, ex) in exercises.prefix(exerciseIndex + 1).enumerated() {
            let s = ExerciseSet(exercise: ex, reps: 0, weightKg: 0, order: i)
            s.log = log
            context.insert(s)
        }
        try? context.save()
    }

    // MARK: Live Activity (Lock Screen + Dynamic Island) — the shared iTeam activity, counting up

    private func startLiveActivity() { updateLiveActivity() }

    private func updateLiveActivity() {
        let detail = isPaused ? "Paused" : "\(currentExercise) · \(Int(calories)) kcal"
        // Counts toward the planned hour; the Dynamic Island shows the time left in the hour.
        LiveActivities.start(kind: "workout", icon: "figure.strengthtraining.traditional", tint: "4FD1C5",
                             title: name, detail: detail, end: startDate.addingTimeInterval(pausedAccum + 3600))
    }

    private func endLiveActivity() async {
        LiveActivities.end(kind: "workout")
    }
}
