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
        let bizDue = ((try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { !$0.deleted }))) ?? []).filter { r in
            guard r.ownerID == me || r.subjectID == me, let d = r.due ?? r.date, d < end,
                  let k = BizSpecs.spec(r.module)?.kind(r.kind), !k.doneStatuses.contains(r.status), !(k.statuses.isEmpty && k.fields.contains { $0.key == .date }) else { return false }
            return d >= start || r.due != nil
        }
        s.dueToday += bizDue.count
        s.tasks += bizDue.prefix(4).map { r in
            .init(title: r.title.isEmpty ? (BizSpecs.spec(r.module)?.kind(r.kind)?.label ?? "") : r.title, due: r.due ?? r.date,
                  overdue: (r.due ?? r.date ?? .now) < start, chat: BizSpecs.spec(r.module)?.title ?? "", id: r.id)
        }

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
        let logs = ((try? context.fetch(FetchDescriptor<MeditationLog>())) ?? []).filter { !$0.deleted }
        s.mindMinutesToday = Int(logs.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.minutes })
        s.mindStreak = MindStats.streak(logs.map(\.date))
        s.hasMind = ModuleRegistry.shared.isOn(ModuleRegistry.mindfulness)

        attendance(&s, context: context, me: me)
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
        // Upcoming: meetings, events, trips and other dated module items.
        var up: [WidgetSnapshot.Upcoming] = []
        let convIDs = Set(((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).filter { !$0.left }.map(\.id))
        for m in ((try? context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { !$0.deleted && $0.status == "scheduled" }))) ?? [])
        where m.end > .now && (m.isAdmin(me) || m.expected.contains(me)) {
            up.append(.init(title: m.title, detail: m.online ? "Online meeting" : (m.place.isEmpty ? "Meeting" : m.place), at: m.start, icon: m.online ? "video.fill" : "person.3.fill", tab: "meetings"))
        }
        for ev in ((try? context.fetch(FetchDescriptor<InviteEvent>(predicate: #Predicate { !$0.deleted }))) ?? [])
        where ev.end > .now && convIDs.contains(ev.convID) && ev.rsvps[me] != "no" {
            up.append(.init(title: ev.title, detail: ev.place.isEmpty ? "Event" : ev.place, at: ev.start, icon: "party.popper.fill", tab: "events"))
        }
        let bizAll = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { !$0.deleted }))) ?? []
        for r in bizAll where (r.ownerID == me || r.subjectID == me || !r.convID.isEmpty) {
            guard let spec = BizSpecs.spec(r.module), let k = spec.kind(r.kind), let d = r.date, d > .now, d < .now.addingTimeInterval(14 * 86400) else { continue }
            if k.doneStatuses.contains(r.status) { continue }
            if !(k.id == "trip" || !k.statuses.isEmpty) { continue }
            let parent = bizAll.first { $0.id == r.parentID }?.title ?? ""
            up.append(.init(title: r.title.isEmpty ? k.label : r.title, detail: [spec.title, parent].filter { !$0.isEmpty }.joined(separator: " · "), at: d, icon: k.icon, tab: spec.tab.rawValue))
        }
        s.upcoming = Array(up.sorted { $0.at < $1.at }.prefix(8))

        // Business modules: hearing / appointment in the next hour → Live Activity.
        let biz = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { !$0.deleted }))) ?? []
        let soonBiz = biz.filter { r in
            guard r.ownerID == me || r.subjectID == me, let d = r.date, d > .now, d < .now.addingTimeInterval(3600),
                  let k = BizSpecs.spec(r.module)?.kind(r.kind), !k.statuses.isEmpty, !k.doneStatuses.contains(r.status) else { return false }
            return true
        }.min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        if let b = soonBiz, let d = b.date, let spec = BizSpecs.spec(b.module) {
            let parent = biz.first { $0.id == b.parentID }?.title ?? ""
            LiveActivities.start(kind: "biz", icon: spec.kind(b.kind)?.icon ?? "calendar", tint: String(format: "%06X", spec.colors[0]),
                                 title: [spec.kind(b.kind)?.label ?? "", parent].filter { !$0.isEmpty }.joined(separator: " · "),
                                 detail: b.title.isEmpty ? spec.title : b.title, end: d)
        } else {
            LiveActivities.end(kind: "biz")
        }
        // Live Activity: the next medicine within 30 minutes.
        if let at = s.nextDoseAt, at > .now, at < .now.addingTimeInterval(1800), let name = s.nextDoseName {
            LiveActivities.start(kind: "dose", icon: "pills.fill", tint: "FF8A5B", title: name, detail: "For \(s.nextDosePerson ?? "")", end: at)
        } else {
            LiveActivities.end(kind: "dose")
        }
    }

    /// Attendance: my open shift (Live Activity until punch-out), or today's head count for the owner/admin.
    private static func attendance(_ s: inout WidgetSnapshot, context: ModelContext, me: String) {
        let all = (try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { !$0.deleted && ($0.kind == "company" || $0.kind == "member") }))) ?? []
        let today = Att.key(.now)
        let current = UserDefaults.standard.string(forKey: "att.current") ?? ""
        let companies = all.filter { $0.kind == "company" }
        if let mine = all.first(where: { $0.kind == "member" && $0.member.userID == me && $0.member.accepted == true }),
           let comp = companies.first(where: { $0.id == mine.companyID }) {
            let mid = mine.id
            let e = (try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.kind == "entry" && $0.memberID == mid && $0.day == today && !$0.deleted })))?.first?.entry
            s.attCompany = comp.company.name; s.attIn = e?.inAt; s.attOut = e?.outAt
            s.attDutyEnd = Att.at(Att.dutyEnd(mine.member, comp.company), on: .now)
            if let i = e?.inAt, e?.outAt == nil, let end = s.attDutyEnd, end > .now {
                LiveActivities.start(kind: "shift", icon: "person.badge.clock.fill", tint: "11998E", title: "On duty · \(comp.company.name)",
                                     detail: "In since \(i.formatted(date: .omitted, time: .shortened))", end: end)
            } else {
                LiveActivities.end(kind: "shift")
            }
        } else {
            LiveActivities.end(kind: "shift")
        }
        if let comp = companies.first(where: { $0.id == current && $0.company.isStaff(me) }) ?? companies.first(where: { $0.company.isStaff(me) }) {
            let cid = comp.id
            let members = all.filter { $0.kind == "member" && $0.companyID == cid && $0.member.active }
            let ins = Set(((try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.kind == "entry" && $0.companyID == cid && $0.day == today && !$0.deleted }))) ?? [])
                .filter { $0.entry.inAt != nil }.map(\.memberID))
            s.attPresent = members.filter { ins.contains($0.id) }.count
            s.attTotal = members.count
            if s.attCompany == nil { s.attCompany = comp.company.name }
        }
    }
}

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
