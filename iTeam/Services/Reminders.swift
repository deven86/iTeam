import Foundation
import SwiftData
import UserNotifications

/// Task deadline reminders: local notifications, so they work offline and with no server.
/// iOS keeps at most 64 pending notifications per app, so only the nearest 60 are scheduled
/// and the list is topped up every time iTeam syncs, opens or refreshes in the background.
@MainActor
final class Reminders {
    static let shared = Reminders()
    private let center = UNUserNotificationCenter.current()
    private let prefix = "task."
    static let categoryID = "TASK_DUE"
    static let doneAction = "TASK_DONE"
    static let snoozeAction = "TASK_SNOOZE"
    private let limit = 60

    func registerCategories() {
        let done = UNNotificationAction(identifier: Self.doneAction, title: "Mark done", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Remind me in 1 hour", options: [])
        let cat = UNNotificationCategory(identifier: Self.categoryID, actions: [done, snooze], intentIdentifiers: [], options: [])
        let taken = UNNotificationAction(identifier: Self.takenAction, title: "Taken ✓", options: [])
        let skip = UNNotificationAction(identifier: Self.skipAction, title: "Skip", options: [.destructive])
        let dose = UNNotificationCategory(identifier: Self.doseCategoryID, actions: [taken, skip], intentIdentifiers: [], options: [])
        center.setNotificationCategories([cat, dose])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static let doseCategoryID = "DOSE_DUE"
    static let takenAction = "DOSE_TAKEN"
    static let skipAction = "DOSE_SKIP"

    /// Task deadlines + medicine doses, nearest first, at most `limit` (iOS keeps 64 per app).
    func reschedule(context: ModelContext, me: String) {
        guard !me.isEmpty else { return }
        let now = Date.now
        struct Plan { let id: String; let fire: Date; let title: String; let body: String; let category: String; let info: [String: String] }
        var plans: [Plan] = []
        let convTitles = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).map { ($0.id, $0.title) })

        // Tasks
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted && $0.dueAt != nil }))) ?? []
        let snoozed = UserDefaults.standard.dictionary(forKey: "reminders.snoozed") as? [String: Date] ?? [:]
        for t in tasks where !t.isDone && t.involves(me) {
            guard let due = t.dueAt else { continue }
            var body = t.title
            if let conv = t.convID, let title = convTitles[conv] { body += " · \(title)" }
            let info = ["task": t.id]
            if let s = snoozed[t.id], s > now {
                plans.append(Plan(id: prefix + t.id + ".snooze", fire: s, title: "⏰ Task reminder", body: body, category: Self.categoryID, info: info))
                continue
            }
            if due > now { plans.append(Plan(id: prefix + t.id + ".due", fire: due, title: "⏰ Task due now", body: body, category: Self.categoryID, info: info)) }
            if t.reminderOffset > 0 {
                let early = due.addingTimeInterval(-Double(t.reminderOffset) * 60)
                if early > now { plans.append(Plan(id: prefix + t.id + ".early", fire: early, title: "⏰ Due \(Fmt.due(due))", body: body, category: Self.categoryID, info: info)) }
            }
        }

        // Medicine doses (today and tomorrow), unless this person turned reminders off for that profile
        let off = Set(UserDefaults.standard.stringArray(forKey: "care.remindOff") ?? [])
        let profiles = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { !$0.deleted }))) ?? []).map { ($0.id, $0) })
        let meds = (try? context.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { $0.active && !$0.deleted }))) ?? []
        let since = now.addingTimeInterval(-86400)
        let logged = Set(((try? context.fetch(FetchDescriptor<DoseLog>(predicate: #Predicate { $0.scheduled > since }))) ?? []).map(\.id))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        for med in meds {
            guard let profile = profiles[med.profileID], !off.contains(profile.id) else { continue }
            for time in med.schedule(on: now) + med.schedule(on: tomorrow) where time > now {
                let key = DoseLog.key(med.id, time)
                guard !logged.contains(key) else { continue }
                var body = "\(med.name) \(med.dose)".trimmingCharacters(in: .whitespaces)
                if !med.instructions.isEmpty { body += " · \(med.instructions)" }
                plans.append(Plan(id: "dose." + key, fire: time, title: "💊 \(profile.name): time for medicine", body: body,
                                  category: Self.doseCategoryID,
                                  info: ["dose": key, "med": med.id, "profile": profile.id, "at": String(time.timeIntervalSince1970)]))
            }
        }

        plans.sort { $0.fire < $1.fire }
        let chosen = Array(plans.prefix(limit))

        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) || $0.hasPrefix("dose.") }
            let wanted = Set(chosen.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { !wanted.contains($0) })
            for p in chosen {
                let content = UNMutableNotificationContent()
                content.title = p.title
                content.body = p.body
                content.sound = .default
                content.categoryIdentifier = p.category
                content.threadIdentifier = p.category == Self.doseCategoryID ? "care" : "tasks"
                content.userInfo = p.info
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: p.fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: p.id, content: content, trigger: trigger))
            }
        }
    }

    func snooze(taskID: String, context: ModelContext, me: String) {
        var snoozed = UserDefaults.standard.dictionary(forKey: "reminders.snoozed") as? [String: Date] ?? [:]
        snoozed[taskID] = Date(timeIntervalSinceNow: 3600)
        UserDefaults.standard.set(snoozed, forKey: "reminders.snoozed")
        reschedule(context: context, me: me)
    }

    /// The badge on the app icon: unread chats + overdue tasks.
    func updateBadge(_ count: Int) {
        Task { try? await center.setBadgeCount(count) }
    }
}
