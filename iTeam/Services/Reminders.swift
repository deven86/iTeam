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
        WidgetSync.update(context: context, me: me)
        let now = Date.now
        struct Plan { let id: String; let fire: Date; let title: String; let body: String; let category: String; let info: [String: String] }
        var plans: [Plan] = []
        let convTitles = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).map { ($0.id, $0.title) })

        // Tasks
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted && $0.dueAt != nil }))) ?? []
        let snoozed = UserDefaults.standard.dictionary(forKey: "reminders.snoozed") as? [String: Date] ?? [:]
        for t in tasks where !t.isDone && t.involves(me) && !t.awaitsMe(me) && !t.declinedBy.contains(me) {
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
            for r in t.remindersRaw.split(separator: ",").map(String.init) {
                if r == "D" {
                    // Every day after the due date until done — schedule the next 7 (renewed on each refresh).
                    for k in 1...7 {
                        let f = due.addingTimeInterval(Double(k) * 86400)
                        if f > now { plans.append(Plan(id: prefix + t.id + ".d\(k)", fire: f, title: "🔁 Still pending — \(Fmt.due(due))", body: body, category: Self.categoryID, info: info)) }
                    }
                } else if let m = Int(r) {
                    let f = due.addingTimeInterval(-Double(m) * 60)
                    let title = m > 0 ? "⏰ Due \(Fmt.due(due))" : "⚠️ Overdue since \(Fmt.due(due))"
                    if f > now { plans.append(Plan(id: prefix + t.id + ".x\(r)", fire: f, title: title, body: body, category: Self.categoryID, info: info)) }
                }
            }
        }

        // Follow-ups (Business Tasks Pro): the next 3 days, until the task is done or the end date passes.
        let followTasks = ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted && $0.followUpRaw != "" }))) ?? [])
        let convMembers = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).map { ($0.id, Set($0.members.map(\.id))) })
        let cal = Calendar.current
        for t in followTasks where !t.isDone && !t.declinedBy.contains(me) {
            guard let fu = t.followUp else { continue }
            let inGroup = t.convID.flatMap { convMembers[$0]?.contains(me) } ?? false
            guard t.involves(me) || (fu.wholeGroup && inGroup) else { continue }
            var body = t.title
            if let conv = t.convID, let title = convTitles[conv] { body += " · \(title)" }
            if let due = t.dueAt { body += " · due \(Fmt.due(due))" }
            for dayOffset in 0..<3 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)),
                      fu.weekdays.contains(cal.component(.weekday, from: day)) else { continue }
                for minutes in fu.times {
                    let fire = day.addingTimeInterval(Double(minutes) * 60)
                    guard fire > now else { continue }
                    if let until = fu.until, fire > cal.date(bySettingHour: 23, minute: 59, second: 0, of: until) ?? until { continue }
                    plans.append(Plan(id: prefix + t.id + ".fu.\(Int(fire.timeIntervalSince1970))", fire: fire, title: "🔔 Follow-up",
                                      body: body + " — is it done?", category: Self.categoryID, info: ["task": t.id]))
                }
            }
        }

        // My Day: morning brief and end-of-day review.
        if MyDaySettings.enabled {
            for (kind, minutes, title, text) in [("morning", MyDaySettings.morning, "☀️ Your day", "Your brief and suggestions for today are ready."),
                                                 ("evening", MyDaySettings.evening, "🌙 How was your day?", "See what got done and move what's left.")] {
                for dayOffset in 0..<2 {
                    guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { continue }
                    let fire = day.addingTimeInterval(Double(minutes) * 60)
                    guard fire > now else { continue }
                    plans.append(Plan(id: "myday.\(kind).\(dayOffset == 0 ? "today" : "next")", fire: fire, title: title, body: text,
                                      category: "MYDAY", info: ["myday": kind]))
                }
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

        // My Progress: today's challenges at 9:30, weekly summary on Sunday 19:00.
        if UserDefaults.standard.object(forKey: "progress.nudges") as? Bool ?? true {
            let cal = Calendar.current
            for day in [now, tomorrow] {
                let s = cal.startOfDay(for: day)
                let morning = s.addingTimeInterval(9.5 * 3600)
                if morning > now {
                    plans.append(Plan(id: "dose.prog.day.\(Int(s.timeIntervalSince1970))", fire: morning, title: "🔥 Today's challenges",
                                      body: "Three small wins are waiting — keep your streak going in My Progress.", category: "PROG", info: ["open": "hub"]))
                }
                if cal.component(.weekday, from: s) == 1 {
                    let eve = s.addingTimeInterval(19 * 3600)
                    if eve > now { plans.append(Plan(id: "dose.prog.week.\(Int(s.timeIntervalSince1970))", fire: eve, title: "📊 Your week in iTeam",
                                                     body: "Tasks, streak and badges from this week — take a look.", category: "PROG", info: ["open": "hub"])) }
                }
            }
        }

        // Gym: morning planner and night review nudges (local only).
        if UserDefaults.standard.object(forKey: "fit.planner.on") as? Bool ?? false {
            let cal = Calendar.current
            for day in [now, tomorrow] {
                let s = cal.startOfDay(for: day)
                for (h, m, id, title, body) in [(7, 0, "plan", "☀️ Plan your day", "Today's workout, meals, water and supplements — open Gym → Plan my day."),
                                                (21, 30, "review", "🌙 Night review", "How did today go? Two minutes in Gym → Night review.")] {
                    let fire = s.addingTimeInterval(Double(h * 3600 + m * 60))
                    if fire > now { plans.append(Plan(id: "dose.fit.\(id).\(Int(s.timeIntervalSince1970))", fire: fire, title: title, body: body, category: "FIT", info: ["open": "gym"])) }
                }
            }
        }

        // Daily "I'm OK" check-ins (Care): a nudge on the person's phone, an alert on family phones if none came.
        let okRemind = CareOK.remind, okWatch = CareOK.watch
        if !okRemind.isEmpty || !okWatch.isEmpty {
            let cal = Calendar.current
            for day in [now, tomorrow] {
                let start = cal.startOfDay(for: day)
                for (pid, minutes) in okRemind {
                    guard let p = profiles[pid] else { continue }
                    let fire = start.addingTimeInterval(Double(minutes) * 60)
                    guard fire > now, !CareOK.checkedIn(p, on: day, by: me, context: context) else { continue }
                    plans.append(Plan(id: "dose.ok.me.\(pid).\(Int(start.timeIntervalSince1970))", fire: fire, title: "✅ Daily check-in",
                                      body: "Tap “I'm OK” in Care so your family knows you're fine.", category: "CAREOK", info: ["conv": p.convID]))
                }
                for (pid, minutes) in okWatch {
                    guard let p = profiles[pid] else { continue }
                    let fire = start.addingTimeInterval(Double(minutes) * 60)
                    guard fire > now, !CareOK.checkedIn(p, on: day, by: nil, context: context) else { continue }
                    plans.append(Plan(id: "dose.ok.watch.\(pid).\(Int(start.timeIntervalSince1970))", fire: fire, title: "⚠️ No check-in from \(p.name) yet",
                                      body: "\(p.name) hasn't tapped “I'm OK” today. Give them a call.", category: "CAREOK", info: ["conv": p.convID]))
                }
            }
        }

        plans.sort { $0.fire < $1.fire }
        let chosen = Array(plans.prefix(limit))

        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) || $0.hasPrefix("dose.") || $0.hasPrefix("myday.") }
            let wanted = Set(chosen.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { !wanted.contains($0) })
            for p in chosen {
                let content = UNMutableNotificationContent()
                content.title = p.title
                content.body = p.body
                content.sound = .default
                content.categoryIdentifier = p.category
                content.threadIdentifier = p.category == Self.doseCategoryID ? "care" : p.category == "MYDAY" ? "myday" : "tasks"
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

    /// The badge on the app icon: unread chats + tasks waiting for my answer + my overdue tasks.
    func updateBadge(_ count: Int) {
        AppGroup.badge = count
        Task { try? await center.setBadgeCount(count) }
    }
}
