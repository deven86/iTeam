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
        center.setNotificationCategories([cat])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func reschedule(context: ModelContext, me: String) {
        guard !me.isEmpty else { return }
        let now = Date.now
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted && $0.dueAt != nil }))) ?? []
        let snoozed = UserDefaults.standard.dictionary(forKey: "reminders.snoozed") as? [String: Date] ?? [:]

        struct Plan { let id: String; let fire: Date; let task: TaskItem; let early: Bool }
        var plans: [Plan] = []
        for t in tasks where !t.isDone && t.involves(me) {
            guard let due = t.dueAt else { continue }
            if let s = snoozed[t.id], s > now {
                plans.append(Plan(id: prefix + t.id + ".snooze", fire: s, task: t, early: false))
                continue
            }
            if due > now { plans.append(Plan(id: prefix + t.id + ".due", fire: due, task: t, early: false)) }
            if t.reminderOffset > 0 {
                let early = due.addingTimeInterval(-Double(t.reminderOffset) * 60)
                if early > now { plans.append(Plan(id: prefix + t.id + ".early", fire: early, task: t, early: true)) }
            }
        }
        plans.sort { $0.fire < $1.fire }
        let chosen = Array(plans.prefix(limit))
        let convTitles = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).map { ($0.id, $0.title) })

        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            let wanted = Set(chosen.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { !wanted.contains($0) })
            for p in chosen {
                let content = UNMutableNotificationContent()
                content.title = p.early ? "⏰ Due \(Fmt.due(p.task.dueAt ?? p.fire))" : "⏰ Task due now"
                var body = p.task.title
                if let conv = p.task.convID, let title = convTitles[conv] { body += " · \(title)" }
                content.body = body
                content.sound = .default
                content.categoryIdentifier = Self.categoryID
                content.threadIdentifier = "tasks"
                content.userInfo = ["task": p.task.id]
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
