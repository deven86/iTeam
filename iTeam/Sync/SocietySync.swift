import Foundation
import SwiftData

// MARK: - Apply

extension EventApplier {
    private func socRec(_ id: String) -> SocietyRecord? {
        try? ctx.fetch(FetchDescriptor<SocietyRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func applySociety(_ p: SocietyPayload, _ e: Event, conv: Conversation?, local: Bool) -> Result {
        guard let conv else { return .needsConversation }
        var changed = false
        // Societies first, so the others can check permissions.
        for it in p.items.sorted(by: { ($0.kind == "society" ? 0 : 1) < ($1.kind == "society" ? 0 : 1) }) {
            let existing = socRec(it.id)
            if let existing, it.at <= existing.updatedAt { continue }
            let soc: SocData? = it.kind == "society" ? (try? JSONDecoder().decode(SocData.self, from: it.data)) : socRec(it.societyID)?.society
            guard let soc else { continue }
            let committee = (existing?.kind == "society" ? existing?.society : nil)?.isCommittee(e.from) ?? soc.isCommittee(e.from)
            // Permissions: society/unit/bill(new)/notice — committee only. Owners may update their own bill (paid),
            // complaint (raise) and visitor (approve/deny) for their own flat.
            let ownerOfUnit: Bool = {
                let uid = it.kind == "unit" ? it.id : it.unitID
                return socRec(uid)?.unit.ownerUserID == e.from
            }()
            switch it.kind {
            case "society":
                if let existing { if !existing.society.isCommittee(e.from) { continue } }
                else if !committee { continue }
            case "unit", "notice": if !committee { continue }
            case "bill", "complaint", "visitor": if !committee && !ownerOfUnit { continue }
            default: continue
            }
            let r = existing ?? SocietyRecord(id: it.id, kind: it.kind)
            let oldStatus = existing?.status
            if existing == nil { r.by = e.from; r.createdAt = e.at; ctx.insert(r) }
            r.societyID = it.societyID; r.unitID = it.unitID; r.status = it.status; r.deleted = it.deleted
            r.data = it.data; r.updatedAt = it.at
            changed = true
            if let line = socLine(r, isNew: existing == nil, oldStatus: oldStatus, from: e.from) {
                system(conv, line, at: e.at)
                if !local && e.from != me {
                    ctx.insert(ActivityItem(kind: r.kind == "visitor" || r.kind == "bill" ? .approval : .mention, text: line,
                                            convID: conv.id, actorID: e.from, date: e.at))
                }
            }
        }
        return changed ? .applied : .ignored
    }

    private func socLine(_ r: SocietyRecord, isNew: Bool, oldStatus: String?, from: String) -> String? {
        let who = from == me ? "You" : engine.name(of: from)
        let flat = socRec(r.unitID)?.unit.label ?? ""
        if r.deleted { return isNew ? nil : "🗑️ \(who) removed a \(r.kind)" }
        switch r.kind {
        case "society": return isNew ? "🏢 \(who) set up society “\(r.society.name)”" : nil
        case "unit": return isNew ? "🏠 \(who) added flat \(r.unit.label) — owner \(r.unit.ownerName)" : nil
        case "bill":
            let b = r.bill
            if isNew { return "🧾 \(b.title) for flat \(flat): \(Money.format(b.amount)), due \(b.due.formatted(date: .abbreviated, time: .omitted))" }
            if oldStatus != r.status {
                switch r.status {
                case "verifying": return "💸 \(who) paid \(Money.format(b.amount)) for flat \(flat) — please verify"
                case "paid": return "✅ \(who) confirmed \(Money.format(b.amount)) received from flat \(flat)"
                default: return "🧾 \(who) marked the bill for flat \(flat) as \(r.status)"
                }
            }
            return nil
        case "complaint":
            if isNew { return "🛠️ \(who) raised a complaint for flat \(flat): \(r.complaint.title)" }
            return oldStatus != r.status ? "🛠️ \(who) marked “\(r.complaint.title)” \(r.status)" : nil
        case "visitor":
            let v = r.visitor
            if isNew { return "🚪 \(v.purpose): \(v.name) at the gate for flat \(flat) — approve or deny" }
            if oldStatus != r.status {
                switch r.status {
                case "approved": return "✅ \(who) let \(v.name) in (flat \(flat))"
                case "denied": return "⛔️ \(who) denied entry to \(v.name) (flat \(flat))"
                case "left": return "👋 \(v.name) left (flat \(flat))"
                default: return nil
                }
            }
            return nil
        case "notice": return isNew ? "📢 Notice: \(r.notice.title)" : nil
        default: return nil
        }
    }
}

// MARK: - Actions

@MainActor
extension SyncEngine {
    func socRecord(_ id: String) -> SocietyRecord? {
        try? context.fetch(FetchDescriptor<SocietyRecord>(predicate: #Predicate { $0.id == id })).first
    }
    func socAll(_ kind: String, society: String) -> [SocietyRecord] {
        (try? context.fetch(FetchDescriptor<SocietyRecord>(predicate: #Predicate { $0.kind == kind && $0.societyID == society && !$0.deleted }))) ?? []
    }

    /// Committee → the committee group (and the flat owner's one-to-one chat for their own records).
    /// Flat owner → one-to-one chats with the committee.
    func socSend(_ items: [SocItem], society s: SocData, ownerOf unitID: String = "", loud: Bool = false, preview: String? = nil,
                 uploads: [String: String] = [:]) {
        let body = Event.Body.society(SocietyPayload(items: items))
        if s.isCommittee(me) {
            if let g = conversation(s.committeeConvID), !g.left { send(body, in: g, loud: loud, preview: preview, uploads: uploads) }
            else { send(body, in: DemoChats.notesToSelf(self), loud: false) }
            if let owner = socRecord(unitID)?.unit.ownerUserID, !owner.isEmpty, owner != me, !s.isCommittee(owner), let ct = contact(owner), !ct.blocked {
                // Owners also get the society record so their tab knows the society.
                var bundle = items
                if let soc = items.first.flatMap({ socRecord($0.societyID) }), !items.contains(where: { $0.kind == "society" }) {
                    bundle.insert(SocItem(id: soc.id, kind: "society", societyID: soc.id, status: soc.status, data: soc.data, at: soc.updatedAt), at: 0)
                }
                send(.society(SocietyPayload(items: bundle)), in: directConversation(with: ct), loud: loud, preview: preview, uploads: uploads)
            }
        } else {
            var sent = false
            for c in [s.ownerID] + s.committee where c != me {
                guard let ct = contact(c), !ct.blocked else { continue }
                send(body, in: directConversation(with: ct), loud: loud, preview: preview, uploads: sent ? [:] : uploads)
                sent = true
            }
            if !sent { send(body, in: DemoChats.notesToSelf(self), loud: false) }
        }
    }

    func socItem(_ r: SocietyRecord, status: String? = nil, deleted: Bool = false) -> SocItem {
        SocItem(id: r.id, kind: r.kind, societyID: r.societyID, unitID: r.unitID, status: status ?? r.status, deleted: deleted, data: r.data, at: .now)
    }

    @discardableResult
    func socCreate(name: String, address: String, committee: [String], maintenance: Double) -> String {
        let id = "soc_" + UUID().uuidString
        var d = SocData()
        d.name = name; d.address = address; d.ownerID = me; d.committee = committee; d.defaultMaintenance = maintenance
        if !committee.isEmpty {
            let conv = createGroup(title: "\(name) · Committee", members: committee.compactMap { contact($0) }, avatar: nil)
            d.committeeConvID = conv.id
        }
        d.attCompanyID = attCreateCompany(name: "\(name) · Staff")
        socSend([SocItem(id: id, kind: "society", societyID: id, data: SocItem.enc(d))], society: d, loud: true, preview: "🏢 Society “\(name)”")
        return id
    }

    func socSaveSociety(_ r: SocietyRecord, _ d: SocData) {
        socSend([SocItem(id: r.id, kind: "society", societyID: r.id, data: SocItem.enc(d))], society: d)
    }

    func socSaveUnit(society: SocietyRecord, existing: SocietyRecord?, _ d: SocUnitData) {
        let id = existing?.id ?? "socu_" + UUID().uuidString
        let item = SocItem(id: id, kind: "unit", societyID: society.id, data: SocItem.enc(d))
        // Send to the committee, then to the owner (bundled with the society so their tab appears).
        let s = society.society
        let body = Event.Body.society(SocietyPayload(items: [item]))
        if let g = conversation(s.committeeConvID), !g.left { send(body, in: g, loud: false) } else { send(body, in: DemoChats.notesToSelf(self), loud: false) }
        if d.ownerUserID != me, !s.isCommittee(d.ownerUserID), let ct = contact(d.ownerUserID), !ct.blocked {
            let soc = SocItem(id: society.id, kind: "society", societyID: society.id, data: society.data, at: society.updatedAt)
            send(.society(SocietyPayload(items: [soc, item])), in: directConversation(with: ct), loud: existing == nil,
                 preview: existing == nil ? "🏠 \(myName) added you as owner of flat \(d.label) in \(s.name)" : nil)
        }
    }

    /// Committee: one maintenance bill per flat for a month.
    func socGenerateBills(society: SocietyRecord, month: Date) {
        let s = society.society
        let cal = Calendar.current
        let monthKey = month.formatted(.dateTime.month(.wide).year())
        let existing = Set(socAll("bill", society: society.id).filter { $0.bill.month == monthKey }.map(\.unitID))
        let start = cal.dateInterval(of: .month, for: month)?.start ?? month
        let due = cal.date(byAdding: .day, value: max(0, s.dueDay - 1), to: start) ?? month
        for u in socAll("unit", society: society.id) where !existing.contains(u.id) {
            var b = SocBillData()
            b.title = "Maintenance \(monthKey)"; b.month = monthKey; b.due = due
            b.amount = u.unit.maintenance > 0 ? u.unit.maintenance : s.defaultMaintenance
            guard b.amount > 0 else { continue }
            socSend([SocItem(id: "socb_" + UUID().uuidString, kind: "bill", societyID: society.id, unitID: u.id, status: "due", data: SocItem.enc(b))],
                    society: s, ownerOf: u.id, loud: true, preview: "🧾 \(s.name): maintenance \(Money.format(b.amount)) due \(due.formatted(date: .abbreviated, time: .omitted))")
        }
    }

    func socPayBill(_ r: SocietyRecord, method: String, reference: String, receipts: [AttachmentRef], uploads: [String: String]) {
        guard let s = socRecord(r.societyID)?.society else { return }
        var b = r.bill
        b.paidOn = .now; b.method = method; b.reference = reference; b.receipts = receipts
        if s.isCommittee(me) { b.verifiedBy = me }
        let item = SocItem(id: r.id, kind: "bill", societyID: r.societyID, unitID: r.unitID, status: s.isCommittee(me) ? "paid" : "verifying", data: SocItem.enc(b))
        socSend([item], society: s, ownerOf: r.unitID, loud: true, preview: s.isCommittee(me) ? "✅ Payment received" : "💸 \(myName) paid \(Money.format(b.amount)) — please verify", uploads: uploads)
    }

    func socVerifyBill(_ r: SocietyRecord, ok: Bool) {
        guard let s = socRecord(r.societyID)?.society else { return }
        var b = r.bill
        if ok { b.verifiedBy = me } else { b.paidOn = nil }
        socSend([SocItem(id: r.id, kind: "bill", societyID: r.societyID, unitID: r.unitID, status: ok ? "paid" : "due", data: SocItem.enc(b))],
                society: s, ownerOf: r.unitID, loud: true, preview: ok ? "✅ \(s.name) confirmed your payment" : "⚠️ \(s.name) couldn't match your payment")
    }

    func socRaiseComplaint(society: SocietyRecord, unitID: String, _ d: SocComplaintData, uploads: [String: String]) {
        socSend([SocItem(id: "socc_" + UUID().uuidString, kind: "complaint", societyID: society.id, unitID: unitID, status: "open", data: SocItem.enc(d))],
                society: society.society, ownerOf: unitID, loud: true, preview: "🛠️ Complaint: \(d.title)", uploads: uploads)
    }

    func socUpdateComplaint(_ r: SocietyRecord, status: String, reply: String) {
        guard let s = socRecord(r.societyID)?.society else { return }
        var c = r.complaint
        c.reply = reply
        socSend([SocItem(id: r.id, kind: "complaint", societyID: r.societyID, unitID: r.unitID, status: status, data: SocItem.enc(c))],
                society: s, ownerOf: r.unitID, loud: true, preview: "🛠️ “\(c.title)”: \(status)")
    }

    /// Gate / reception: ask the flat owner to approve a visitor.
    @discardableResult
    func socLogVisitor(society: SocietyRecord, unitID: String, _ v: SocVisitorData) -> String {
        var v = v
        v.gateBy = me; v.at = .now
        let id = "socv_" + UUID().uuidString
        let flat = socRecord(unitID)?.unit.label ?? ""
        socSend([SocItem(id: id, kind: "visitor", societyID: society.id, unitID: unitID, status: "waiting", data: SocItem.enc(v))],
                society: society.society, ownerOf: unitID, loud: true, preview: "🚪 \(v.purpose): \(v.name) is at the gate for flat \(flat) — approve?")
        return id
    }

    func socAnswerVisitor(_ r: SocietyRecord, status: String, note: String = "") {
        guard let s = socRecord(r.societyID)?.society else { return }
        var v = r.visitor
        v.answeredBy = me; v.answeredAt = .now; v.note = note
        socSend([SocItem(id: r.id, kind: "visitor", societyID: r.societyID, unitID: r.unitID, status: status, data: SocItem.enc(v))],
                society: s, ownerOf: r.unitID, loud: status != "left", preview: status == "approved" ? "✅ \(v.name) approved" : status == "denied" ? "⛔️ \(v.name) denied" : nil)
    }

    /// Notices go to the committee and to every flat owner.
    func socPostNotice(society: SocietyRecord, _ n: SocNoticeData, uploads: [String: String]) {
        let s = society.society
        let item = SocItem(id: "socn_" + UUID().uuidString, kind: "notice", societyID: society.id, data: SocItem.enc(n))
        if let g = conversation(s.committeeConvID), !g.left { send(.society(SocietyPayload(items: [item])), in: g, loud: true, preview: "📢 \(n.title)", uploads: uploads) }
        else { send(.society(SocietyPayload(items: [item])), in: DemoChats.notesToSelf(self), loud: false, uploads: uploads) }
        let soc = SocItem(id: society.id, kind: "society", societyID: society.id, data: society.data, at: society.updatedAt)
        var owners = Set<String>()
        for u in socAll("unit", society: society.id) { owners.insert(u.unit.ownerUserID) }
        for o in owners where !o.isEmpty && o != me && !s.isCommittee(o) {
            guard let ct = contact(o), !ct.blocked else { continue }
            send(.society(SocietyPayload(items: [soc, item])), in: directConversation(with: ct), loud: true, preview: "📢 \(s.name): \(n.title)")
        }
    }

    func socDelete(_ r: SocietyRecord) {
        guard let s = socRecord(r.societyID)?.society else { return }
        socSend([socItem(r, deleted: true)], society: s, ownerOf: r.unitID)
    }
}

// MARK: - Demo

@MainActor
enum SocietyDemo {
    static func create(_ engine: SyncEngine) {
        let sid = engine.socCreate(name: "Sai Heights (demo)", address: "Dombivli East", committee: [], maintenance: 2500)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let soc = engine.socRecord(sid) else { return }
            for (flat, owner) in [("101", "Asha Patil (demo)"), ("102", "Rahul Shinde (demo)"), ("201", "You")] {
                var u = SocUnitData()
                u.wing = "A"; u.flat = flat; u.ownerUserID = owner == "You" ? engine.me : "demo_\(flat)"; u.ownerName = owner; u.maintenance = 2500; u.members = 3
                engine.socSaveUnit(society: soc, existing: nil, u)
            }
            try? await Task.sleep(for: .milliseconds(400))
            engine.socGenerateBills(society: soc, month: .now)
            if let unit = engine.socAll("unit", society: sid).first {
                var v = SocVisitorData(); v.name = "Ramesh (Swiggy)"; v.purpose = "Delivery"; v.vehicle = "MH05 AB 1234"
                engine.socLogVisitor(society: soc, unitID: unit.id, v)
                var c = SocComplaintData(); c.title = "Lift not working"; c.category = "Lift"; c.detail = "Lift B stuck on 3rd floor since morning."
                engine.socRaiseComplaint(society: soc, unitID: unit.id, c, uploads: [:])
            }
            var n = SocNoticeData(); n.title = "Water tank cleaning on Sunday"; n.body = "No water supply from 10 am to 2 pm."
            engine.socPostNotice(society: soc, n, uploads: [:])
        }
    }
}
