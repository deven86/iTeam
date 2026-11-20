import Foundation

/// The right chart for each module's PDF: pie = shares, bar = volume per item, line = trend over time.
@MainActor
enum PDFCharts {
    private static func monthKey(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated)) }

    /// Last n months as (label, count) for any list of dates.
    static func perMonth(_ dates: [Date], months n: Int = 6, title: String) -> PDFChart {
        let cal = Calendar.current
        let starts = (0..<n).reversed().compactMap { cal.date(byAdding: .month, value: -$0, to: cal.dateInterval(of: .month, for: .now)?.start ?? .now) }
        let values = starts.map { s in Double(dates.filter { cal.isDate($0, equalTo: s, toGranularity: .month) }.count) }
        return PDFChart(kind: .bar, title: title, labels: starts.map(monthKey), values: values)
    }

    static func pie(_ title: String, _ counts: [(String, Double)], colors: [UInt32]? = nil) -> PDFChart {
        let kept = counts.filter { $0.1 > 0 }
        return PDFChart(kind: .pie, title: title, labels: kept.map(\.0), values: kept.map(\.1), colors: colors)
    }

    // MARK: Chats
    static func chat(_ messages: [Message], engine: SyncEngine) -> [PDFChart] {
        let real = messages.filter { !$0.isSystem && !$0.deleted }
        let byPerson = Dictionary(grouping: real, by: \.senderID).map { (engine.name(of: $0.key), Double($0.value.count)) }.sorted { $0.1 > $1.1 }
        let cal = Calendar.current
        let days = (0..<14).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now)) }
        let perDay = days.map { d in Double(real.filter { cal.isDate($0.createdAt, inSameDayAs: d) }.count) }
        return [pie("Messages by person", Array(byPerson.prefix(8))),
                PDFChart(kind: .line, title: "Messages per day (last 14 days)", labels: days.map { $0.formatted(.dateTime.day()) }, values: perDay)]
    }

    // MARK: Events
    static func events(_ evs: [InviteEvent]) -> [PDFChart] {
        let answers = evs.flatMap { $0.rsvps.values }
        let going = evs.prefix(12).map { ev in Double(ev.rsvps.values.filter { $0 == "going" }.count) }
        return [pie("All answers", [("Going", Double(answers.filter { $0 == "going" }.count)), ("Maybe", Double(answers.filter { $0 == "maybe" }.count)),
                                    ("Can't", Double(answers.filter { $0 == "no" }.count))], colors: [0x34C759, 0xFF9500, 0xFF3B30]),
                PDFChart(kind: .bar, title: "Going per event", labels: evs.prefix(12).map(\.title), values: Array(going))]
    }

    // MARK: Meetings
    static func meetings(_ ms: [Meeting]) -> [PDFChart] {
        [pie("Meetings by status", [("Scheduled", Double(ms.filter { $0.status == "scheduled" }.count)), ("Done", Double(ms.filter { $0.status == "done" }.count)),
                                    ("Cancelled", Double(ms.filter { $0.status == "cancelled" }.count))], colors: [0x5B8DEF, 0x34C759, 0xFF3B30]),
         perMonth(ms.map(\.start), title: "Meetings per month")]
    }
    static func minutes(_ m: Meeting) -> [PDFChart] {
        var out = [pie("Attendance", [("Attended", Double(m.attended.count)), ("Expected, absent", Double(m.expected.filter { !m.attended.contains($0) }.count))],
                       colors: [0x34C759, 0xFF3B30])]
        if let poll = m.polls.first {
            let v = m.votes[poll.id] ?? [:]
            out.append(PDFChart(kind: .bar, title: "Vote: \(poll.question)", labels: poll.options,
                                values: poll.options.indices.map { i in Double(v.values.filter { $0 == i }.count) }))
        }
        return out
    }

    // MARK: Doctor
    static func prescriptions(_ rx: [Prescription]) -> [PDFChart] {
        [pie("Prescriptions by answer", [("Waiting", Double(rx.filter { $0.status == "waiting" }.count)), ("Accepted", Double(rx.filter { $0.status == "accepted" }.count)),
                                         ("Declined", Double(rx.filter { $0.status == "declined" }.count))], colors: [0xFF9500, 0x34C759, 0xFF3B30]),
         perMonth(rx.map(\.createdAt), title: "Prescriptions per month")]
    }
    static func prescription(_ rx: Prescription) -> [PDFChart] {
        [PDFChart(kind: .bar, title: "Doses per day", labels: rx.items.map(\.name), values: rx.items.map { Double($0.times.count) })]
    }

    // MARK: Business modules (Khata, Tuition, Rent, Legal, Clinic, Bills, Kids, Travel)
    static func biz(_ spec: BizSpec, records: [BizRecord]) -> [PDFChart] {
        let tops = records.filter { $0.parentID.isEmpty }
        let bal = tops.map { r in (r.title, spec.parent == nil ? BizMath.contribution(r, spec) : BizMath.balance(of: r.id, in: records, spec: spec)) }
            .filter { $0.1 != 0 }.sorted { abs($0.1) > abs($1.1) }
        let entries = records.filter { !$0.parentID.isEmpty || spec.parent == nil }
        let byKind = Dictionary(grouping: entries, by: \.kind).map { (spec.kind($0.key)?.label ?? $0.key, Double($0.value.count)) }
        var out: [PDFChart] = []
        if !bal.isEmpty { out.append(PDFChart(kind: .bar, title: "\(spec.balanceLabel) by \(spec.parent?.label.lowercased() ?? "item")", labels: bal.prefix(12).map(\.0), values: bal.prefix(12).map { abs($0.1) }, unit: "")) }
        out.append(pie("Entries by type", byKind.sorted { $0.1 > $1.1 }))
        out.append(perMonth(entries.map { $0.date ?? $0.due ?? $0.createdAt }, title: "Entries per month"))
        return out
    }
    static func bizStatement(_ spec: BizSpec, children: [BizRecord]) -> [PDFChart] {
        let sorted = children.sorted { ($0.date ?? $0.due ?? $0.createdAt) < ($1.date ?? $1.due ?? $1.createdAt) }
        var running = 0.0
        let points = sorted.map { c -> Double in running += BizMath.contribution(c, spec); return running }
        let byKind = Dictionary(grouping: sorted, by: \.kind).map { (spec.kind($0.key)?.label ?? $0.key, $0.value.reduce(0) { $0 + abs($1.amount) }) }
        var out: [PDFChart] = []
        if points.count > 1 { out.append(PDFChart(kind: .line, title: "\(spec.balanceLabel) over time", labels: sorted.map { ($0.date ?? $0.due ?? $0.createdAt).formatted(.dateTime.day().month(.abbreviated)) }, values: points)) }
        if byKind.contains(where: { $0.1 > 0 }) { out.append(pie("Amount by type", byKind)) }
        return out
    }

    // MARK: Attendance
    static func attendance(_ data: AttData, month: Date, engine: SyncEngine) -> [PDFChart] {
        var total = Att.Summary()
        for m in data.active { for (k, v) in data.summary(m, month: month).counts { total.counts[k, default: 0] += v } }
        let order = ["present", "grace", "late", "halfday", "absent", "leave", "unpaid", "holiday", "off"]
        let days = Att.monthDays(month).filter { $0 <= .now }
        let perDay = days.map { d in Double(data.active.filter { ["present", "grace", "late", "halfday"].contains(data.status($0, d)) }.count) }
        let pay = data.active.prefix(20).map { (data.name($0, engine), data.summary($0, month: month).payable) }
        return [pie("Days by status (everyone)", order.map { (Att.label($0), Double(total.n($0))) }, colors: order.map(Att.color)),
                PDFChart(kind: .line, title: "People present per day", labels: days.map { $0.formatted(.dateTime.day()) }, values: perDay, colors: [0x11998E]),
                PDFChart(kind: .bar, title: "Payable days per person", labels: pay.map(\.0), values: pay.map(\.1))]
    }
    static func attendanceMember(_ data: AttData, _ m: AttRecord, month: Date) -> [PDFChart] {
        let s = data.summary(m, month: month)
        let order = ["present", "grace", "late", "halfday", "absent", "leave", "unpaid", "holiday", "off"]
        let days = Att.monthDays(month).filter { $0 <= .now }
        let hours = days.map { d -> Double in
            guard let e = data.entry(m, d)?.entry, let i = e.inAt, let o = e.outAt else { return 0 }
            return o.timeIntervalSince(i) / 3600
        }
        return [pie("Days by status", order.map { (Att.label($0), Double(s.n($0))) }, colors: order.map(Att.color)),
                PDFChart(kind: .line, title: "Hours worked per day", labels: days.map { $0.formatted(.dateTime.day()) }, values: hours, colors: [0x11998E], unit: " h")]
    }

    // MARK: Care, Gym, Tasks, Mind
    static func care(meds: [Medicine], events: [HealthEvent]) -> [PDFChart] {
        let active = meds.filter { $0.active && !$0.deleted }
        let byKind = Dictionary(grouping: events.filter { !$0.deleted }, by: \.kind).map { ($0.key.capitalized, Double($0.value.count)) }
        return [PDFChart(kind: .bar, title: "Doses per day by medicine", labels: active.map(\.name), values: active.map { Double($0.schedule(on: .now).count) }),
                pie("Health events by kind", byKind)]
    }
    static func gym(payments: [GymPayment], sessions: [GymSession]) -> [PDFChart] {
        let cal = Calendar.current
        let starts = (0..<6).reversed().compactMap { cal.date(byAdding: .month, value: -$0, to: cal.dateInterval(of: .month, for: .now)?.start ?? .now) }
        let spend = starts.map { s in payments.filter { cal.isDate($0.date, equalTo: s, toGranularity: .month) }.reduce(0) { $0 + $1.amount } }
        let byKind = Dictionary(grouping: payments, by: \.kind).map { ($0.key.capitalized, $0.value.reduce(0) { $0 + $1.amount }) }
        return [PDFChart(kind: .bar, title: "Spend per month (₹)", labels: starts.map(monthKey), values: spend),
                pie("Spend by type", byKind), perMonth(sessions.map(\.date), title: "Training sessions per month")]
    }
    static func task(checklist: [ChecklistItem]) -> [PDFChart] {
        checklist.isEmpty ? [] : [pie("Checklist", [("Done", Double(checklist.filter(\.done).count)), ("Open", Double(checklist.filter { !$0.done }.count))], colors: [0x34C759, 0xFF9500])]
    }
    static func mind(_ byDay: [(Date, Double)]) -> [PDFChart] {
        [PDFChart(kind: .line, title: "Mindful minutes per day", labels: byDay.map { $0.0.formatted(.dateTime.day()) }, values: byDay.map(\.1), colors: [0x3B8D99], unit: " min")]
    }
}
