import Foundation
import SwiftData
import UserNotifications

extension AttItem {
    init(id: String, kind: String, companyID: String, memberID: String = "", day: String = "", status: String = "",
         deleted: Bool = false, data: Data, by: String) {
        self.id = id; self.kind = kind; self.companyID = companyID; self.memberID = memberID; self.day = day
        self.status = status; self.deleted = deleted; self.at = .now; self.data = data; self.by = by
    }
    static func enc<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data() }
}

// MARK: - Applying (who may change what)

extension EventApplier {
    private func attFetch(_ id: String) -> AttRecord? {
        try? ctx.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func applyAttendance(_ p: AttPayload, _ e: Event, conv: Conversation?, personal: Bool) -> Result {
        let from = e.from
        var count = 0
        var toGroup: [AttItem] = []
        var toUser: [String: [AttItem]] = [:]
        var invites: [String] = []
        var relayCompany: AttCompanyData?
        for it in p.items {
            let existing = attFetch(it.id)
            if let existing, existing.kind != it.kind || it.at < existing.updatedAt { continue }
            let oldStatus = existing?.status
            let oldEntry = existing?.kind == "entry" ? existing?.entry : nil
            let wasDeleted = existing?.deleted ?? false
            guard let r = attWrite(it, existing: existing, from: from, eventAt: e.at) else { continue }
            count += 1
            let comp = it.kind == "company" ? r.company : (attFetch(it.companyID)?.company ?? AttCompanyData())
            if p.bulk != true, let conv, !personal {
                let line = attLine(r, isNew: existing == nil, oldStatus: oldStatus, oldEntry: oldEntry, wasDeleted: wasDeleted, from: from, company: comp)
                if !line.isEmpty {
                    system(conv, line, at: e.at)
                    attActivity(r, line: line, from: from, company: comp, conv: conv, at: e.at, isNew: existing == nil)
                }
            }
            // The owner's phone passes things on, so nobody depends on having everyone as a contact:
            // employees' punches and requests → the admins' group; admins' changes → the employee.
            if from != me, comp.ownerID == me, p.bulk != true {
                relayCompany = comp
                let user = r.kind == "member" ? r.member.userID : (attFetch(r.memberID)?.member.userID ?? "")
                if !comp.isStaff(from), !comp.adminConvID.isEmpty, conv?.id != comp.adminConvID { toGroup.append(AttItem(r)) }
                if comp.admins.contains(from) {
                    if r.kind == "member", existing == nil, r.member.isUser { invites.append(r.id) }
                    else if !user.isEmpty, !comp.isStaff(user), ["entry", "leave", "member"].contains(r.kind) { toUser[user, default: []].append(AttItem(r)) }
                }
            }
        }
        if p.bulk == true, count > 0, let conv, !personal {
            system(conv, "📋 Attendance records shared with \(from == me ? "them" : "you") (\(count))", at: e.at)
        }
        if let c = relayCompany, !(toGroup.isEmpty && toUser.isEmpty && invites.isEmpty) {
            let eng = engine
            Task { @MainActor in
                if !toGroup.isEmpty, let g = eng.conversation(c.adminConvID), !g.left { eng.send(.attendance(AttPayload(items: toGroup)), in: g, loud: false) }
                for (user, items) in toUser {
                    guard let ct = eng.contact(user), !ct.blocked else { continue }
                    eng.send(.attendance(AttPayload(items: SyncEngine.attForEmployee(items))), in: eng.directConversation(with: ct), loud: false)
                }
                for id in invites {
                    if let m = eng.attRecord(id), let comp = eng.attRecord(m.companyID) { eng.attSendInvite(company: comp, member: m) }
                }
            }
        }
        if count > 0 { AttReminders.update(engine) }
        return count > 0 ? .applied : .ignored
    }

    /// Checks the sender's right to make this change, then stores it. Returns nil when refused.
    private func attWrite(_ it: AttItem, existing: AttRecord?, from: String, eventAt: Date) -> AttRecord? {
        let companyRec = it.kind == "company" ? existing : attFetch(it.companyID)
        let c = companyRec?.company
        var data = it.data
        var status = it.status
        var deleted = it.deleted

        switch it.kind {
        case "company":
            guard var inc = try? JSONDecoder().decode(AttCompanyData.self, from: it.data) else { return nil }
            if let existing { guard existing.company.ownerID == from, inc.ownerID == from else { return nil } }
            else { guard inc.ownerID == from else { return nil } }
            if inc.qrSecret.isEmpty, let existing { inc.qrSecret = existing.company.qrSecret }
            if !inc.isStaff(me) { inc.qrSecret = "" }
            data = AttItem.enc(inc)

        case "member":
            guard let c, let inc = try? JSONDecoder().decode(AttMemberData.self, from: it.data) else { return nil }
            if from == c.ownerID {
                // fine
            } else if c.admins.contains(from) {
                guard status == "employee", existing == nil || existing?.status == "employee" else { return nil }
            } else if let existing, existing.member.userID == from, !existing.member.userID.isEmpty {
                // The person only answers the invitation.
                var d = existing.member
                d.accepted = inc.accepted
                data = AttItem.enc(d); status = existing.status; deleted = existing.deleted
            } else { return nil }

        case "entry":
            guard let c, let m = attFetch(it.memberID), let inc = try? JSONDecoder().decode(AttEntryData.self, from: it.data) else { return nil }
            if from == c.ownerID { break }
            let isSelf = m.member.userID == from && !from.isEmpty
            guard c.admins.contains(from) || (isSelf && m.member.canPunch) else { return nil }
            guard !it.deleted else { return nil }   // only the owner deletes
            if !c.admins.contains(from) {
                // Own punches only for today (±1 day for time zones), and no status override.
                let near = [-1, 0, 1].compactMap { Calendar.current.date(byAdding: .day, value: $0, to: eventAt) }.map(Att.key)
                guard near.contains(it.day), it.status.isEmpty else { return nil }
            }
            if let existing {
                // Admins and employees may only add the punch-out; any other edit needs the owner.
                let old = existing.entry
                guard !existing.deleted, old.outAt == nil, old.inAt == inc.inAt, existing.status == it.status else { return nil }
            }

        case "leave":
            guard let c, let m = attFetch(it.memberID) else { return nil }
            if c.isStaff(from) { break }
            guard m.member.userID == from, !from.isEmpty else { return nil }
            if let existing { guard existing.status == "pending", it.status == "pending" else { return nil } }
            else { guard it.status == "pending", !it.deleted else { return nil } }

        case "holiday":
            guard let c else { return nil }
            if from == c.ownerID { break }
            guard c.admins.contains(from), !it.deleted else { return nil }
            if let existing { guard existing.status == "pending" else { return nil } }
            status = "pending"

        case "change":
            guard let c else { return nil }
            if from == c.ownerID { break }
            guard c.admins.contains(from), existing == nil, it.status == "pending" else { return nil }

        default:
            return nil
        }

        let r: AttRecord
        if let existing { r = existing } else {
            r = AttRecord(id: it.id, kind: it.kind)
            r.createdAt = eventAt
            ctx.insert(r)
        }
        defer { if existing == nil && (it.kind == "company" || it.kind == "member") { try? ctx.save() } }
        r.companyID = it.kind == "company" ? it.id : it.companyID
        r.memberID = it.memberID; r.day = it.day; r.status = status; r.data = data
        r.updatedAt = it.at; r.by = it.by ?? from
        if deleted && !r.deleted { r.deleted = true; r.deletedBy = from }
        return r
    }

    private func attName(_ memberID: String) -> String {
        guard let m = attFetch(memberID) else { return "someone" }
        let d = m.member
        if !d.name.isEmpty { return d.name }
        return d.isUser ? engine.name(of: d.userID) : "someone"
    }

    private func attLine(_ r: AttRecord, isNew: Bool, oldStatus: String?, oldEntry: AttEntryData?, wasDeleted: Bool,
                         from: String, company c: AttCompanyData) -> String {
        let who = from == me ? "You" : engine.name(of: from)
        let dayText = Att.date(r.day).formatted(.dateTime.day().month(.abbreviated))
        if r.deleted && !wasDeleted {
            switch r.kind {
            case "company": return "🏢 \(who) closed attendance for “\(c.name)”"
            case "member": return "👤 \(who) removed \(attName(r.id)) from “\(c.name)” attendance"
            case "entry": return "🗑 \(who) deleted \(attName(r.memberID))'s attendance for \(dayText)"
            case "leave": return "🌴 \(who) cancelled \(attName(r.memberID))'s leave request"
            case "holiday": return "🎌 \(who) removed the holiday “\(r.holiday.name)”"
            default: return ""
            }
        }
        switch r.kind {
        case "company":
            return isNew ? "🏢 \(who) set up attendance for “\(c.name)”" : "🏢 \(who) updated the attendance settings of “\(c.name)”"
        case "member":
            let m = r.member
            if !isNew && oldStatus == r.status, m.isUser, m.userID == from {
                return m.accepted == true ? "✅ \(attName(r.id)) joined “\(c.name)” attendance" : "❌ \(attName(r.id)) declined “\(c.name)” attendance"
            }
            if !isNew && oldStatus != r.status && r.status == "admin" { return "⭐ \(who) made \(attName(r.id)) an attendance admin of “\(c.name)”" }
            if !isNew && oldStatus == "admin" && r.status == "employee" { return "👤 \(attName(r.id)) is no longer an attendance admin" }
            return isNew ? "👤 \(who) added \(attName(r.id)) to “\(c.name)” attendance\(m.isUser ? " — waiting for them to accept" : "")"
                         : "👤 \(who) updated \(attName(r.id))'s attendance profile"
        case "entry":
            let e = r.entry
            let name = attName(r.memberID)
            let via = e.method == "manual" || e.method == "edit" ? "" : " · via \(e.method == "qr" ? "QR" : e.method)"
            if oldEntry?.inAt == nil, let i = e.inAt, e.outAt == nil || isNew {
                let m = attFetch(r.memberID)?.member ?? AttMemberData()
                let st = r.status.isEmpty ? Att.auto(inAt: i, start: Att.dutyStart(m, c), company: c) : r.status
                return "🕘 \(name) punched in \(i.formatted(date: .omitted, time: .shortened)) · \(Att.label(st))\(via)"
            }
            if oldEntry?.outAt == nil, let o = e.outAt, let i = e.inAt, oldEntry?.inAt == e.inAt {
                let mins = Int(o.timeIntervalSince(i) / 60)
                return "🕕 \(name) punched out \(o.formatted(date: .omitted, time: .shortened)) · \(mins / 60) h \(mins % 60) m"
            }
            return "✏️ \(who) changed \(name)'s attendance for \(dayText)\(r.status.isEmpty ? "" : " — " + Att.label(r.status))"
        case "leave":
            let l = r.leave
            let span = l.halfDay ? "half day" : "\(l.days.formatted()) day\(l.days == 1 ? "" : "s")"
            let dates = l.from.formatted(.dateTime.day().month(.abbreviated)) + (l.days > 1 ? "–" + l.to.formatted(.dateTime.day().month(.abbreviated)) : "")
            switch r.status {
            case "approved":
                return isNew || oldStatus == "approved" ? "🌴 \(who) recorded \(span) \(l.paid ? "paid" : "unpaid") leave for \(attName(r.memberID)) (\(dates))"
                                                        : "✅ \(who) approved \(attName(r.memberID))'s leave (\(dates), \(l.paid ? "paid" : "unpaid"))"
            case "rejected": return "❌ \(who) rejected \(attName(r.memberID))'s leave (\(dates))\(l.note.isEmpty ? "" : " — " + l.note)"
            default: return "🌴 \(attName(r.memberID)) applied for \(span) \(l.type) leave (\(dates))"
            }
        case "holiday":
            let h = r.holiday
            if r.status == "pending" { return "🎌 \(who) proposed the holiday “\(h.name)” on \(dayText) — waiting for the owner" }
            if r.status == "rejected" { return "🎌 \(who) rejected the holiday “\(h.name)”" }
            return oldStatus == "pending" ? "🎌 \(who) approved the holiday “\(h.name)” on \(dayText)" : "🎌 \(who) set \(dayText) as a holiday — “\(h.name)”"
        case "change":
            let name = attName(r.memberID)
            switch r.status {
            case "approved": return "✅ \(who) approved the change to \(name)'s attendance for \(dayText)"
            case "rejected": return "❌ \(who) rejected the change to \(name)'s attendance for \(dayText)"
            default: return "✏️ \(who) asked to change \(name)'s attendance for \(dayText) — waiting for the owner"
            }
        default: return ""
        }
    }

    private func attActivity(_ r: AttRecord, line: String, from: String, company c: AttCompanyData, conv: Conversation, at: Date, isNew: Bool) {
        guard from != me else { return }
        let mineUser = attFetch(r.kind == "member" ? r.id : r.memberID)?.member.userID == me
        var kind: ActivityKind?
        switch r.kind {
        case "leave": kind = r.status == "pending" ? (c.isStaff(me) ? .approval : nil) : (mineUser ? .taskUpdated : nil)
        case "change", "holiday": kind = r.status == "pending" && c.ownerID == me ? .approval : nil
        case "member": kind = mineUser && isNew ? .taskAssigned : nil
        case "entry": kind = mineUser && c.isStaff(from) ? .taskUpdated : nil
        default: kind = nil
        }
        if let kind { ctx.insert(ActivityItem(kind: kind, text: line, convID: conv.id, actorID: from, date: at)) }
    }
}

// MARK: - Actions

@MainActor
extension SyncEngine {
    func attAll(_ kind: String, company: String) -> [AttRecord] {
        (try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.kind == kind && $0.companyID == company }))) ?? []
    }
    func attRecord(_ id: String) -> AttRecord? {
        try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// Sends attendance changes to the right people only:
    /// owner/admin → the admins' group (+ the employee's direct chat for their own records, without secrets);
    /// employee → direct chats with the owner and admins.
    func attSend(_ items: [AttItem], company c: AttCompanyData, about user: String = "", loud: Bool = false,
                 preview: String? = nil, uploads: [String: String] = [:]) {
        let body = Event.Body.attendance(AttPayload(items: items))
        if c.isStaff(me) {
            if let g = conversation(c.adminConvID), !g.left {
                send(body, in: g, loud: loud, preview: preview, uploads: uploads)
            } else {
                sendPersonal(body)
            }
            if !user.isEmpty, user != me, !c.isStaff(user), let ct = contact(user), !ct.blocked {
                send(.attendance(AttPayload(items: Self.attForEmployee(items))), in: directConversation(with: ct), loud: loud, preview: preview,
                     uploads: conversation(c.adminConvID) == nil ? uploads : [:])
            }
        } else {
            var sent = false
            for staff in [c.ownerID] + c.admins where staff != me {
                guard let ct = contact(staff), !ct.blocked else { continue }
                send(body, in: directConversation(with: ct), loud: loud, preview: preview, uploads: sent ? [:] : uploads)
                sent = true
            }
            if !sent { sendPersonal(body) }
        }
    }

    /// Strips the QR secret from company records going to an employee.
    static func attForEmployee(_ items: [AttItem]) -> [AttItem] {
        items.map { it in
            guard it.kind == "company", var d = try? JSONDecoder().decode(AttCompanyData.self, from: it.data) else { return it }
            d.qrSecret = ""
            var x = it; x.data = AttItem.enc(d); return x
        }
    }

    @discardableResult
    func attCreateCompany(name: String) -> String {
        var d = AttCompanyData()
        d.name = name; d.ownerID = me; d.qrSecret = Att.newSecret()
        let id = "attc_" + UUID().uuidString
        attSend([AttItem(id: id, kind: "company", companyID: id, data: AttItem.enc(d), by: me)], company: d)
        return id
    }

    /// Owner only. Employees on iTeam get the settings too (without the QR secret).
    func attSaveCompany(_ rec: AttRecord, _ d: AttCompanyData, deleted: Bool = false) {
        let item = AttItem(id: rec.id, kind: "company", companyID: rec.id, deleted: deleted, data: AttItem.enc(d), by: me)
        attSend([item], company: d)
        for m in attAll("member", company: rec.id) where !m.deleted && m.member.isUser && !d.isStaff(m.member.userID) {
            guard let ct = contact(m.member.userID), !ct.blocked else { continue }
            send(.attendance(AttPayload(items: Self.attForEmployee([item]))), in: directConversation(with: ct), loud: false)
        }
    }

    func attSaveMember(company: AttRecord, existing: AttRecord?, _ d: AttMemberData) {
        let c = company.company
        let id = existing?.id ?? "attm_" + UUID().uuidString
        var d = d
        if existing == nil { d.joined = d.joined ?? .now; if d.isUser && d.userID != me { d.accepted = nil } else { d.accepted = true } }
        let item = AttItem(id: id, kind: "member", companyID: company.id, status: existing?.status ?? "employee", data: AttItem.enc(d), by: me)
        if existing == nil, d.isUser, d.userID != me {
            attSend([item], company: c)
            // The owner's phone sends the invitation (company without secrets, profile, holidays).
            if c.ownerID == me, let rec = attRecord(id) { attSendInvite(company: company, member: rec) }
        } else {
            attSend([item], company: c, about: d.userID)
        }
    }

    func attSendInvite(company: AttRecord, member m: AttRecord) {
        let c = company.company
        guard c.ownerID == me, let ct = contact(m.member.userID), !ct.blocked else { return }
        let holidays = attAll("holiday", company: company.id).filter { $0.status == "approved" && !$0.deleted }.map(AttItem.init)
        let bundle = Self.attForEmployee([AttItem(company)]) + [AttItem(m)] + holidays
        send(.attendance(AttPayload(items: bundle)), in: directConversation(with: ct), loud: true,
             preview: "🏢 \(myName) added you to “\(c.name)” attendance — tap to accept")
    }

    func attRemoveMember(company: AttRecord, _ m: AttRecord) {
        var c = company.company
        if c.admins.contains(m.member.userID) { attSetAdmin(company: company, m, on: false); c = attRecord(company.id)?.company ?? c }
        let item = AttItem(id: m.id, kind: "member", companyID: company.id, status: m.status, deleted: true, data: m.data, by: me)
        attSend([item], company: c, about: m.member.userID)
    }

    /// Owner only. Admins share a group chat with the owner, where all attendance travels.
    func attSetAdmin(company: AttRecord, _ m: AttRecord, on: Bool) {
        var c = company.company
        let user = m.member.userID
        guard c.ownerID == me, !user.isEmpty, let ct = contact(user) else { return }
        if on {
            if !c.admins.contains(user) { c.admins.append(user) }
            if let g = conversation(c.adminConvID), !g.left { addMembers(g, [ct]) }
            else { c.adminConvID = createGroup(title: "\(c.name) · Attendance", members: [ct], avatar: nil).id }
        } else {
            c.admins.removeAll { $0 == user }
            if let g = conversation(c.adminConvID), !g.left { removeMember(g, user) }
        }
        let compItem = AttItem(id: company.id, kind: "company", companyID: company.id, data: AttItem.enc(c), by: me)
        let memItem = AttItem(id: m.id, kind: "member", companyID: company.id, status: on ? "admin" : "employee", data: m.data, by: me)
        // Everyone (employees too, without the secret) learns who the admins are.
        attSaveCompany(company, c)
        attSend([memItem], company: c)
        let dc = directConversation(with: ct)
        if on {
            // Catch the new admin up with everything, in batches.
            let cid = company.id
            let all = ((try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.companyID == cid }))) ?? [])
                .filter { $0.kind != "company" }.map(AttItem.init)
            let ordered = [compItem] + all.filter { $0.kind == "member" } + all.filter { $0.kind != "member" }
            for i in stride(from: 0, to: ordered.count, by: 150) {
                send(.attendance(AttPayload(items: Array(ordered[i..<min(i + 150, ordered.count)]), bulk: true)), in: dc, loud: false)
            }
        } else {
            send(.attendance(AttPayload(items: Self.attForEmployee([compItem, memItem]))), in: dc, loud: false)
        }
    }

    func attAnswerInvite(_ m: AttRecord, accept: Bool) {
        guard let comp = attRecord(m.companyID) else { return }
        var d = m.member
        d.accepted = accept
        attSend([AttItem(id: m.id, kind: "member", companyID: m.companyID, status: m.status, data: AttItem.enc(d), by: me)],
                company: comp.company, loud: true, preview: accept ? "✅ \(myName) joined “\(comp.company.name)” attendance" : nil)
    }

    func attTodayEntry(_ member: AttRecord, day: Date = .now) -> AttRecord? {
        let key = Att.key(day), mid = member.id
        return (try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.kind == "entry" && $0.memberID == mid && $0.day == key && !$0.deleted })))?.first
    }

    /// Punch in, or punch out if already in. Returns what happened for the confirmation.
    @discardableResult
    func attPunch(_ member: AttRecord, company: AttRecord, method: String, photo: Data? = nil,
                  lat: Double? = nil, lon: Double? = nil, distance: Double? = nil, qr: String = "") -> String {
        let c = company.company
        let day = Att.key(.now)
        let existing = attTodayEntry(member)
        var d = existing?.entry ?? AttEntryData()
        var what: String
        if d.inAt == nil {
            d.inAt = .now; d.method = method; d.photoIn = photo; d.qrIn = qr; d.markedBy = me
            what = "in"
        } else if d.outAt == nil {
            d.outAt = .now; d.photoOut = photo; d.qrOut = qr
            what = "out"
        } else { return "done" }
        if let lat, let lon { d.lat = lat; d.lon = lon; d.distance = distance }
        let id = existing?.id ?? "atte_\(member.id)_\(day)_\(UUID().uuidString.prefix(6))"
        let item = AttItem(id: id, kind: "entry", companyID: company.id, memberID: member.id, day: day,
                           status: existing?.status ?? "", data: AttItem.enc(d), by: me)
        attSend([item], company: c, about: member.member.userID)
        return what
    }

    /// Owner: saves straight away. Admin: becomes a change request for the owner.
    func attSaveEntry(company: AttRecord, member: AttRecord, existing: AttRecord?, day: Date, data: AttEntryData,
                      status: String, delete: Bool = false, reason: String = "") {
        let c = company.company
        let key = Att.key(day)
        if c.ownerID == me {
            var d = data; d.markedBy = d.markedBy.isEmpty ? me : d.markedBy
            if existing == nil && d.method.isEmpty { d.method = "edit" }
            let id = existing?.id ?? "atte_\(member.id)_\(key)_\(UUID().uuidString.prefix(6))"
            attSend([AttItem(id: id, kind: "entry", companyID: company.id, memberID: member.id, day: key, status: status,
                             deleted: delete, data: AttItem.enc(d), by: me)], company: c, about: member.member.userID)
        } else if existing == nil && !delete {
            // A new entry needs no approval.
            var d = data; d.markedBy = me; d.method = "manual"
            attSend([AttItem(id: "atte_\(member.id)_\(key)_\(UUID().uuidString.prefix(6))", kind: "entry", companyID: company.id,
                             memberID: member.id, day: key, status: status, data: AttItem.enc(d), by: me)], company: c, about: member.member.userID)
        } else {
            var ch = AttChangeData()
            ch.entryID = existing?.id ?? ""; ch.proposed = data; ch.proposedStatus = status; ch.reason = reason; ch.deleteEntry = delete
            attSend([AttItem(id: "attx_" + UUID().uuidString, kind: "change", companyID: company.id, memberID: member.id, day: key,
                             status: "pending", data: AttItem.enc(ch), by: me)], company: c, loud: true,
                    preview: "✏️ Change request for \(member.member.name) — \(day.formatted(date: .abbreviated, time: .omitted))")
        }
    }

    func attDecideChange(_ x: AttRecord, approve: Bool, note: String) {
        guard let company = attRecord(x.companyID), let member = attRecord(x.memberID) else { return }
        var ch = x.change
        ch.decidedBy = me; ch.note = note
        attSend([AttItem(id: x.id, kind: "change", companyID: x.companyID, memberID: x.memberID, day: x.day,
                         status: approve ? "approved" : "rejected", data: AttItem.enc(ch), by: me)], company: company.company)
        if approve {
            attSaveEntry(company: company, member: member, existing: ch.entryID.isEmpty ? nil : attRecord(ch.entryID),
                         day: Att.date(x.day), data: ch.proposed, status: ch.proposedStatus, delete: ch.deleteEntry)
        }
    }

    /// Employees apply (pending); the owner or an admin can record a leave straight away.
    func attSaveLeave(company: AttRecord, member: AttRecord, existing: AttRecord?, _ d: AttLeaveData, status: String,
                      deleted: Bool = false, uploads: [String: String] = [:]) {
        let id = existing?.id ?? "attl_" + UUID().uuidString
        let item = AttItem(id: id, kind: "leave", companyID: company.id, memberID: member.id, day: Att.key(d.from),
                           status: status, deleted: deleted, data: AttItem.enc(d), by: me)
        let isRequest = status == "pending" && existing == nil
        attSend([item], company: company.company, about: member.member.userID, loud: isRequest || (existing?.status == "pending" && status != "pending"),
                preview: isRequest ? "🌴 \(member.member.name.isEmpty ? myName : member.member.name) applied for leave" : nil, uploads: uploads)
    }

    func attDecideLeave(_ l: AttRecord, approve: Bool, note: String, paid: Bool) {
        guard let company = attRecord(l.companyID), let member = attRecord(l.memberID) else { return }
        var d = l.leave
        d.decidedBy = me; d.note = note; d.paid = paid
        attSaveLeave(company: company, member: member, existing: l, d, status: approve ? "approved" : "rejected")
    }

    /// Owner: approved at once. Admin: waits for the owner.
    func attSaveHoliday(company: AttRecord, existing: AttRecord? = nil, date: Date, name: String, type: String,
                        status: String? = nil, deleted: Bool = false) {
        let c = company.company
        let st = status ?? (c.ownerID == me ? "approved" : "pending")
        let item = AttItem(id: existing?.id ?? "atth_" + UUID().uuidString, kind: "holiday", companyID: company.id, day: Att.key(date),
                           status: st, deleted: deleted, data: AttItem.enc(AttHolidayData(name: name, type: type)), by: me)
        attSend([item], company: c, loud: st == "pending", preview: st == "pending" ? "🎌 Holiday “\(name)” needs your approval" : nil)
        // Approved holidays go to every employee on iTeam.
        if st == "approved" || deleted {
            for m in attAll("member", company: company.id) where !m.deleted && m.member.isUser && !c.isStaff(m.member.userID) {
                guard let ct = contact(m.member.userID), !ct.blocked else { continue }
                send(.attendance(AttPayload(items: [item])), in: directConversation(with: ct), loud: false)
            }
        }
    }

    /// Only the owner deletes; the record stays in the archive.
    func attDelete(_ r: AttRecord) {
        guard let company = attRecord(r.companyID) else { return }
        let user = r.kind == "member" ? r.member.userID : (attRecord(r.memberID)?.member.userID ?? "")
        attSend([AttItem(id: r.id, kind: r.kind, companyID: r.companyID, memberID: r.memberID, day: r.day, status: r.status,
                         deleted: true, data: r.data, by: me)], company: company.company, about: user)
    }
}

// MARK: - Reminders: punch in / punch out on working days

@MainActor
enum AttReminders {
    static func update(_ engine: SyncEngine) {
        let center = UNUserNotificationCenter.current()
        let ids = (1...7).flatMap { ["att.in.\($0)", "att.out.\($0)"] }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard UserDefaults.standard.object(forKey: "att.remind") as? Bool ?? true else { return }
        let me = engine.me
        let mine = ((try? engine.context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { $0.kind == "member" && !$0.deleted }))) ?? [])
            .filter { $0.member.userID == me && $0.member.canPunch }
        guard let m = mine.first, let comp = engine.attRecord(m.companyID), !comp.deleted else { return }
        let c = comp.company
        guard c.selfPunch else { return }
        let start = Att.dutyStart(m.member, c), end = Att.dutyEnd(m.member, c)
        for wd in 1...7 where !c.weeklyOff.contains(wd) {
            for (id, minute, title) in [("att.in.\(wd)", max(start - 5, 0), "Time to punch in"), ("att.out.\(wd)", end, "Punch out before you leave")] {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = "\(c.name) · duty \(Att.clock(start))–\(Att.clock(end))"
                content.sound = .default
                content.userInfo = ["tab": "attendance"]
                var dc = DateComponents(); dc.weekday = wd; dc.hour = minute / 60; dc.minute = minute % 60
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
            }
        }
    }
}
