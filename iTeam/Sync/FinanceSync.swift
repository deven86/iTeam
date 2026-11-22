import Foundation
import SwiftData
import UserNotifications

extension FinItem {
    init(_ r: FinRecord) {
        id = r.id; kind = r.kind; book = r.book; date = r.date; amount = r.amount; direction = r.direction
        status = r.status; category = r.category; deleted = r.deleted; at = r.updatedAt; data = r.data
    }
}

extension EventApplier {
    /// Personal books: only my own devices. Company books: the owner and admins of that company.
    /// Approvals and decisions on a company's payments: only the owner.
    func applyFinance(_ p: FinPayload, _ e: Event, conv: Conversation?, personal: Bool) -> Result {
        var n = 0
        for it in p.items {
            let id = it.id
            let ex = try? ctx.fetch(FetchDescriptor<FinRecord>(predicate: #Predicate { $0.id == id })).first
            if let ex, it.at < ex.updatedAt { continue }
            if it.book == "personal" {
                guard e.from == me else { continue }
            } else {
                let cid = it.book
                guard let comp = try? ctx.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.id == cid })).first?.company,
                      comp.isStaff(e.from) else { continue }
                // Only the owner decides on an approval, and only the owner deletes.
                if let ex, ex.status == "pending", it.status != "pending", e.from != comp.ownerID { continue }
                if it.deleted, e.from != comp.ownerID, ex?.by != e.from { continue }
            }
            let r = ex ?? { let x = FinRecord(id: it.id); x.createdAt = e.at; x.by = e.from; ctx.insert(x); return x }()
            let wasPending = r.status == "pending"
            r.kind = it.kind; r.book = it.book; r.date = it.date; r.amount = it.amount; r.direction = it.direction
            r.status = it.status; r.category = it.category; r.data = it.data; r.updatedAt = it.at
            if it.deleted && !r.deleted { r.deleted = true; r.deletedBy = e.from }
            n += 1
            if let conv, !personal, it.book != "personal" {
                let who = e.from == me ? "You" : engine.name(of: e.from)
                let what = "\(Fin.money(it.amount)) \(r.isIn ? "income" : "expense") — \(r.d.title.isEmpty ? r.category : r.d.title)"
                let line: String
                if r.deleted { line = "🗑 \(who) deleted \(what)" }
                else if it.status == "pending" { line = "💸 \(who) asked approval for \(what)" }
                else if wasPending && it.status == "paid" || wasPending && it.status == "due" { line = "✅ \(who) approved \(what)" }
                else if it.status == "rejected" { line = "❌ \(who) rejected \(what)" }
                else { line = ex == nil ? "💰 \(who) added \(what)" : "💰 \(who) updated \(what)" }
                system(conv, line, at: e.at)
                if e.from != me && it.status == "pending" {
                    ctx.insert(ActivityItem(kind: .approval, text: line, convID: conv.id, actorID: e.from, date: e.at))
                }
            }
        }
        if n > 0 { FinReminders.update(engine) }
        return n > 0 ? .applied : .ignored
    }
}

@MainActor
extension SyncEngine {
    /// Companies (from Attendance) where I'm the owner or an admin — they become Finance books.
    var finBooks: [(id: String, name: String)] {
        let all = (try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.kind == "company" && !$0.deleted }))) ?? []
        return [("personal", "Personal")] + all.filter { $0.company.isStaff(me) }.map { ($0.id, $0.company.name) }
    }

    func finSend(_ items: [FinItem], book: String, loud: Bool = false, preview: String? = nil, uploads: [String: String] = [:]) {
        let body = Event.Body.finance(FinPayload(items: items))
        if book != "personal", let comp = attRecord(book)?.company, let g = conversation(comp.adminConvID), !g.left {
            send(body, in: g, loud: loud, preview: preview, uploads: uploads)
        } else {
            sendPersonal(body)
        }
    }

    func finSave(_ r: FinRecord?, id: String? = nil, kind: String = "entry", book: String, date: Date, amount: Double, direction: String,
                 status: String, category: String, data: FinData, deleted: Bool = false, uploads: [String: String] = [:]) {
        let item = FinItem(id: r?.id ?? id ?? "fin_" + UUID().uuidString, kind: kind, book: book, date: date, amount: amount, direction: direction,
                           status: status, category: category, deleted: deleted, at: .now, data: (try? JSONEncoder().encode(data)) ?? Data())
        let ask = status == "pending" && r?.status != "pending"
        finSend([item], book: book, loud: ask, preview: ask ? "💸 Approval needed: \(Fin.money(amount)) — \(data.title.isEmpty ? category : data.title)" : nil, uploads: uploads)
    }

    func finDelete(_ r: FinRecord) {
        finSave(r, book: r.book, date: r.date, amount: r.amount, direction: r.direction, status: r.status, category: r.category, data: r.d, deleted: true)
    }

    func finDecide(_ r: FinRecord, approve: Bool, note: String) {
        var d = r.d; d.decidedBy = me; d.decisionNote = note
        finSave(r, book: r.book, date: r.date, amount: r.amount, direction: r.direction,
                status: approve ? (r.date > .now ? "due" : "paid") : "rejected", category: r.category, data: d)
    }

    /// Paying a due / recurring item: records the payment, and moves a recurring item to its next date.
    func finMarkPaid(_ r: FinRecord) {
        let d = r.d
        if d.repeatRule != "none" {
            var paid = d; paid.repeatRule = "none"
            finSave(nil, book: r.book, date: .now, amount: r.amount, direction: r.direction, status: "paid", category: r.category, data: paid)
            finSave(r, book: r.book, date: Fin.next(r.date, d.repeatRule), amount: r.amount, direction: r.direction, status: "due", category: r.category, data: d)
        } else {
            finSave(r, book: r.book, date: .now, amount: r.amount, direction: r.direction, status: "paid", category: r.category, data: d)
        }
    }

    /// Money recorded in other modules, shown in Finance without copying it (always up to date).
    func finModuleLines() -> [FinLine] {
        var out: [FinLine] = []
        let me = self.me
        let biz = (try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { !$0.deleted && $0.amount != 0 }))) ?? []
        for r in biz where r.ownerID == me && !r.parentID.isEmpty || (r.ownerID == me && r.module == "bills") {
            guard let spec = BizSpecs.spec(r.module) else { continue }
            let paid = r.status == "Paid"
            let parent = r.parentID.isEmpty ? nil : biz.first { $0.id == r.parentID }
            var isIn: Bool?, status = paid ? "paid" : "due"
            switch (r.module, r.kind) {
            case ("khata", "got"), ("rent", "payment"): isIn = true; status = "paid"
            case ("khata", "gave"): isIn = true; status = "due"
            case ("tuition", "fee"), ("legal", "fee"), ("clinic", "bill"): isIn = true
            case ("rent", "charge"): if !paid { isIn = true; status = "due" }
            case ("bills", "bill"), ("kids", "fee"): isIn = false
            case ("travel", "booking"), ("travel", "expense"): isIn = false; status = "paid"
            default: isIn = nil
            }
            guard let isIn else { continue }
            let link = "iteam://item/biz/\(r.module)/\(r.parentID.isEmpty ? r.id : r.parentID)"
            out.append(FinLine(id: "biz_" + r.id, date: r.date ?? r.due ?? r.createdAt, amount: abs(r.amount), isIn: isIn, status: status,
                               category: spec.title, title: r.title, party: parent?.title ?? r.subtitle, source: spec.title, link: link, record: nil))
        }
        let exps = (try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { !$0.deleted }))) ?? []
        for x in exps where x.paidBy == me || x.addedBy == me {
            out.append(FinLine(id: "exp_" + x.id, date: x.date, amount: x.amount, isIn: false, status: "paid", category: x.category.isEmpty ? "Task expense" : x.category,
                               title: x.title, party: task(x.taskID)?.title ?? "", source: "Tasks", link: "iteam://task/\(x.taskID)", record: nil))
        }
        return out
    }
}

@MainActor
enum FinReminders {
    static func update(_ engine: SyncEngine) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix("fin.") }
            center.removePendingNotificationRequests(withIdentifiers: old)
        }
        let due = ((try? engine.context.fetch(FetchDescriptor<FinRecord>(predicate: #Predicate { !$0.deleted && $0.status == "due" }))) ?? [])
            .filter { $0.date > .now.addingTimeInterval(-86400) }.sorted { $0.date < $1.date }.prefix(8)
        for r in due {
            let c = UNMutableNotificationContent()
            c.title = r.isIn ? "Money to receive today" : "Payment due today"
            c.body = "\(Fin.money(r.amount)) — \(r.d.title.isEmpty ? r.category : r.d.title)"
            c.sound = .default
            c.userInfo = ["tab": "finance"]
            var dc = Calendar.current.dateComponents([.year, .month, .day], from: r.date); dc.hour = 9; dc.minute = 30
            center.add(UNNotificationRequest(identifier: "fin.\(r.id)", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
        }
        // Bounced cheques: a daily nudge until they're resolved.
        let bounced = ((try? engine.context.fetch(FetchDescriptor<FinRecord>(predicate: #Predicate { !$0.deleted }))) ?? []).filter { $0.d.chequeStatus == "bounced" }.prefix(3)
        for r in bounced {
            let c = UNMutableNotificationContent()
            c.title = "Bounced cheque — follow up"
            c.body = "\(Fin.money(r.amount)) · cheque \(r.d.chequeNo) · \(r.d.party)"
            c.userInfo = ["tab": "finance"]
            var dc = DateComponents(); dc.hour = 11; dc.minute = 0
            center.add(UNNotificationRequest(identifier: "fin.b.\(r.id)", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
        }
    }
}
