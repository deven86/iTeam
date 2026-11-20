import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// What the widgets show. The app writes it to the App Group after every sync; widgets only read it.
struct WidgetSnapshot: Codable {
    struct TaskLine: Codable, Hashable { var title: String; var due: Date?; var overdue: Bool; var chat: String; var id: String }
    var updated = Date.now
    var name = ""
    var unreadChats = 0
    var dueToday = 0
    var overdue = 0
    var awaitingMe = 0
    var tasks: [TaskLine] = []
    var doneToday = 0
    // Care
    var nextDoseName: String?
    var nextDosePerson: String?
    var nextDoseAt: Date?
    var dosesLeftToday = 0
    // Gym
    var gymName: String?
    var gymDaysLeft: Int?
    var trainedToday = false
    var trainingDaysMonth = 0
    // Mind
    var mindMinutesToday = 0
    var mindStreak = 0
    // Which modules this person has
    var hasCare = false
    var hasGym = false
    var hasMind = false
    // Meetings, events, trips, kids' school events — the next few things on the calendar.
    struct Upcoming: Codable, Hashable { var title: String; var detail: String; var at: Date; var icon: String; var tab: String }
    var upcoming: [Upcoming] = []

    static let key = "widget.snapshot"

    static func load() -> WidgetSnapshot {
        guard let d = AppGroup.defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: d) else { return WidgetSnapshot() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: Self.key) }
    }
}

#if canImport(ActivityKit)
/// One Live Activity shape for every module: a title, a line of detail, an icon and a countdown.
struct ITeamActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var end: Date
        var progressStart: Date
    }
    /// "task", "mind", "training", "dose"…
    var kind: String
    var icon: String
    var tint: String   // hex like "28BEE6"
}
#endif
