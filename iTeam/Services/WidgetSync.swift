import Foundation
import SwiftData
import WidgetKit
import ActivityKit

/// Writes what the widgets show into the App Group and keeps Live Activities (Lock Screen, Dynamic Island) current.
@MainActor
enum WidgetSync {
    static func update(context: ModelContext, me: String) {
        var s = WidgetSnapshot()
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? .now
        s.name = SyncEngine.shared.myName

        let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.deleted }))) ?? []).filter { $0.involves(me) }
        let open = tasks.filter { !$0.isDone && !$0.declinedBy.contains(me) }
        s.overdue = open.filter(\.isOverdue).count
        s.dueToday = open.filter { ($0.dueAt.map { $0 >= start && $0 < end } ?? false) }.count
        s.awaitingMe = open.filter { $0.awaitsMe(me) }.count
        s.doneToday = tasks.filter { $0.isDone && ($0.completedAt.map { $0 >= start } ?? false) }.count
        let titles = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).map { ($0.id, $0.title) })
        s.tasks = open.filter { $0.isOverdue || ($0.dueAt.map { $0 < end } ?? false) }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            .prefix(8)
            .map { .init(title: $0.title, due: $0.dueAt, overdue: $0.isOverdue, chat: $0.convID.flatMap { titles[$0] } ?? "", id: $0.id) }
        s.unreadChats = ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).filter { $0.unread > 0 && !$0.muted }.count

        // Care: next dose today
        let meds = (try? context.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { $0.active && !$0.deleted }))) ?? []
        let profiles = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { !$0.deleted }))) ?? []).map { ($0.id, $0.name) })
        let logged = Set(((try? context.fetch(FetchDescriptor<DoseLog>(predicate: #Predicate { $0.scheduled >= start }))) ?? []).map(\.id))
        let pending = meds.flatMap { m in m.schedule(on: .now).map { (m, $0) } }.filter { !logged.contains(DoseLog.key($0.0.id, $0.1)) }
        s.dosesLeftToday = pending.count
        if let next = pending.filter({ $0.1 >= .now.addingTimeInterval(-3600) }).min(by: { $0.1 < $1.1 }) {
            s.nextDoseName = "\(next.0.name) \(next.0.dose)".trimmingCharacters(in: .whitespaces)
            s.nextDosePerson = profiles[next.0.profileID]
            s.nextDoseAt = next.1
        }
        s.hasCare = !profiles.isEmpty

        // Gym
        let plans = ((try? context.fetch(FetchDescriptor<GymPlan>(predicate: #Predicate { !$0.deleted }))) ?? []).filter(\.isActive)
        if let p = plans.min(by: { $0.daysLeft < $1.daysLeft }) { s.gymName = p.gymName; s.gymDaysLeft = p.daysLeft }
        let monthStart = cal.dateInterval(of: .month, for: .now)?.start ?? start
        let sessions = (try? context.fetch(FetchDescriptor<GymSession>(predicate: #Predicate { !$0.deleted && $0.date >= monthStart }))) ?? []
        s.trainingDaysMonth = Set(sessions.map { "\($0.memberID)|\(cal.startOfDay(for: $0.date).timeIntervalSince1970)" }).count
        s.trainedToday = sessions.contains { cal.isDateInToday($0.date) }
        s.hasGym = !((try? context.fetch(FetchDescriptor<GymMember>(predicate: #Predicate { !$0.deleted }))) ?? []).isEmpty

        // Mind
        let logs = (try? context.fetch(FetchDescriptor<MeditationLog>())) ?? []
        s.mindMinutesToday = Int(logs.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.minutes })
        s.mindStreak = MindStats.streak(logs.map(\.date))
        s.hasMind = ModuleRegistry.shared.isOn(ModuleRegistry.mindfulness)

        s.save()
        WidgetCenter.shared.reloadAllTimelines()

        // Live Activity: the next task due within the hour (accepted, not done).
        if let soon = open.filter({ !$0.awaitsMe(me) }).compactMap({ t in t.dueAt.map { (t, $0) } })
            .filter({ $0.1 > .now && $0.1 < .now.addingTimeInterval(3600) }).min(by: { $0.1 < $1.1 }) {
            LiveActivities.start(kind: "task", icon: "checklist", tint: "28BEE6", title: soon.0.title,
                                 detail: "Due \(soon.1.formatted(date: .omitted, time: .shortened))", end: soon.1)
        } else {
            LiveActivities.end(kind: "task")
        }
        // Live Activity: the next medicine within 30 minutes.
        if let at = s.nextDoseAt, at > .now, at < .now.addingTimeInterval(1800), let name = s.nextDoseName {
            LiveActivities.start(kind: "dose", icon: "pills.fill", tint: "FF8A5B", title: name, detail: "For \(s.nextDosePerson ?? "")", end: at)
        } else {
            LiveActivities.end(kind: "dose")
        }
    }
}

/// Live Activities for every module: Lock Screen banner + Dynamic Island with a countdown.
@MainActor
enum LiveActivities {
    static func start(kind: String, icon: String, tint: String, title: String, detail: String, end: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ITeamActivityAttributes.ContentState(title: title, detail: detail, end: end, progressStart: .now)
        let content = ActivityContent(state: state, staleDate: end.addingTimeInterval(600))
        if let existing = Activity<ITeamActivityAttributes>.activities.first(where: { $0.attributes.kind == kind }) {
            guard existing.content.state.title != title || existing.content.state.end != end else { return }
            Task { await existing.update(ActivityContent(state: ITeamActivityAttributes.ContentState(title: title, detail: detail, end: end,
                                                                                                     progressStart: existing.content.state.progressStart),
                                                         staleDate: end.addingTimeInterval(600))) }
            return
        }
        _ = try? Activity.request(attributes: ITeamActivityAttributes(kind: kind, icon: icon, tint: tint), content: content)
    }

    static func end(kind: String) {
        for a in Activity<ITeamActivityAttributes>.activities where a.attributes.kind == kind {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
