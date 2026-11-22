import Foundation
import SwiftData
import UserNotifications

// MARK: - Apply

extension EventApplier {
    private func bRec(_ id: String) -> BuildRecord? {
        try? ctx.fetch(FetchDescriptor<BuildRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func applyBuild(_ p: BuildPayload, _ e: Event, conv: Conversation?, local: Bool) -> Result {
        guard let conv else { return .needsConversation }
        var changed = false
        // Projects first, so the others can check the team.
        for it in p.items.sorted(by: { ($0.kind == "project" ? 0 : 1) < ($1.kind == "project" ? 0 : 1) }) {
            let existing = bRec(it.id)
            if let existing, it.at <= existing.updatedAt { continue }
            if let existing, !existing.ownerID.isEmpty, existing.ownerID != it.ownerID { continue }
            let incoming = (try? JSONDecoder().decode(BuildData.self, from: it.data)) ?? BuildData()
            let project: BuildData? = it.kind == "project" ? (existing?.d ?? incoming) : bRec(it.projectID)?.d
            let isOwner = e.from == it.ownerID
            let isAdmin = isOwner || (project?.admins.contains(e.from) ?? false)
            let isTeam = isAdmin || (project?.team.contains(e.from) ?? false)
            let allowed: Bool
            if it.kind == "project" { allowed = existing == nil ? isOwner : isAdmin }
            else if it.projectID.isEmpty { allowed = isOwner }
            else { allowed = BuildKinds.adminOnly(it.kind) ? isAdmin : isTeam }
            guard allowed else { continue }

            let r = existing ?? BuildRecord(id: it.id, kind: it.kind)
            let oldStatus = existing?.status
            let wasDeleted = existing?.deleted ?? false
            if existing == nil { r.by = e.from; r.createdAt = e.at; ctx.insert(r) }
            r.companyID = it.companyID; r.projectID = it.projectID; r.parentID = it.parentID
            r.status = it.status; r.ownerID = it.ownerID; r.deleted = it.deleted; r.data = it.data; r.updatedAt = it.at
            changed = true
            if let line = buildLine(r, isNew: existing == nil, oldStatus: oldStatus, wasDeleted: wasDeleted, from: e.from) {
                system(conv, line, at: e.at)
                if !local && e.from != me {
                    ctx.insert(ActivityItem(kind: ["payment", "approval", "test"].contains(r.kind) ? .approval : .mention, text: line,
                                            convID: conv.id, actorID: e.from, date: e.at))
                }
            }
        }
        return changed ? .applied : .ignored
    }

    private func buildLine(_ r: BuildRecord, isNew: Bool, oldStatus: String?, wasDeleted: Bool, from: String) -> String? {
        let who = from == me ? "You" : engine.name(of: from)
        let k = BuildKinds.of(r.kind)
        let t = r.title
        if r.deleted { return wasDeleted ? nil : "🗑️ \(who) deleted \(k.label.lowercased()) “\(t)”" }
        let parent = bRec(r.parentID)
        switch r.kind {
        case "company": return nil
        case "project": return isNew ? "🏗️ \(who) set up project “\(t)”" : (oldStatus != r.status ? "🏗️ “\(t)” is now \(r.status)" : nil)
        case "unit": return isNew ? nil : (oldStatus != r.status ? "🏠 Unit \(t): \(r.status)" : nil)
        case "sale":
            if isNew { return "🤝 \(who) booked unit \(parent?.title ?? "") for \(t)" }
            return oldStatus != r.status ? "🤝 \(t) · unit \(parent?.title ?? ""): \(r.status)" : nil
        case "payment":
            let amt = Money.format(r.num("amount"))
            return isNew ? "💰 \(who) recorded \(amt) from \(parent?.title ?? "") — \(r.f("title"))" : (oldStatus != r.status ? "💰 Payment \(amt) \(r.status.lowercased())" : nil)
        case "demand":
            return isNew ? "🧾 Demand: \(r.f("title")) \(Money.format(r.num("amount"))) for \(parent?.title ?? "")" : (oldStatus != r.status ? "🧾 \(r.f("title")) marked \(r.status)" : nil)
        case "move":
            guard isNew else { return nil }
            let unit = parent?.f("unit") ?? ""
            return "📦 \(who): \(r.f("type")) \(r.f("qty")) \(unit) \(parent?.title ?? "")\(r.f("where").isEmpty ? "" : " → \(r.f("where"))")"
        case "log": return isNew ? "🚜 \(who) logged \(parent?.title ?? ""): \(r.f("title"))" : nil
        case "test":
            if isNew { return "🧪 \(who) added test “\(t)” (\(r.f("where")))" }
            if oldStatus != r.status { return r.status == "Fail" ? "❌ Test failed: \(t) — \(r.f("where"))" : "🧪 \(t): \(r.status)" }
            return nil
        case "approval":
            if isNew { return "📜 \(who) added approval “\(t)” — \(r.status)" }
            return oldStatus != r.status ? (r.status == "Approved" ? "✅ Approved: \(t)" : "📜 \(t): \(r.status)") : nil
        case "progress": return isNew ? "📸 Site report by \(who): \(t)" : nil
        default:
            if isNew { return "\(r.kind == "dispute" ? "⚠️" : "➕") \(who) added \(k.label.lowercased()) “\(t)”" }
            return oldStatus != r.status && !r.status.isEmpty ? "✏️ “\(t)”: \(r.status)" : nil
        }
    }
}

// MARK: - Actions

@MainActor
extension SyncEngine {
    func bRecord(_ id: String) -> BuildRecord? {
        guard !id.isEmpty else { return nil }
        return try? context.fetch(FetchDescriptor<BuildRecord>(predicate: #Predicate { $0.id == id })).first
    }
    func bChildren(_ parent: String, kind: String? = nil) -> [BuildRecord] {
        let all = (try? context.fetch(FetchDescriptor<BuildRecord>(predicate: #Predicate { $0.parentID == parent && !$0.deleted }))) ?? []
        return kind.map { k in all.filter { $0.kind == k } } ?? all
    }

    func bIsAdmin(_ project: BuildRecord?) -> Bool {
        guard let project else { return true }
        return project.ownerID == me || project.d.admins.contains(me)
    }

    /// Stock on hand from stock entries.
    func bStock(_ material: BuildRecord) -> Double {
        bChildren(material.id, kind: "move").reduce(0) { sum, m in
            let q = m.num("qty")
            switch m.f("type") {
            case "Received", "Returned", "Count correction": return sum + q
            default: return sum - q
            }
        }
    }

    private func item(_ id: String, kind: String, company: String, project: String, parent: String, status: String, owner: String,
                      data: BuildData, deleted: Bool = false) -> BuildItem {
        BuildItem(id: id, kind: kind, companyID: company, projectID: project, parentID: parent, status: status, ownerID: owner,
                  deleted: deleted, data: (try? JSONEncoder().encode(data)) ?? Data(), at: .now)
    }
    private func item(_ r: BuildRecord) -> BuildItem {
        BuildItem(id: r.id, kind: r.kind, companyID: r.companyID, projectID: r.projectID, parentID: r.parentID, status: r.status,
                  ownerID: r.ownerID, deleted: r.deleted, data: r.data, at: r.updatedAt)
    }

    /// Who the record is about: itself (sale/party) or its parent sale (payment/demand).
    private func bSubject(_ it: BuildItem, data: BuildData) -> String {
        if !data.subjectID.isEmpty { return data.subjectID }
        if let p = bRecord(it.parentID), ["sale", "party"].contains(p.kind) { return p.d.subjectID }
        return ""
    }

    /// Team chat (or my own devices for private kinds); the buyer / partner / rehab tenant gets their own copy.
    func bSend(_ items: [BuildItem], loud: Bool = false, preview: String? = nil, uploads: [String: String] = [:]) {
        guard let first = items.first else { return }
        let data = (try? JSONDecoder().decode(BuildData.self, from: first.data)) ?? BuildData()
        let project = first.kind == "project" ? data : bRecord(first.projectID)?.d
        let body = Event.Body.build(BuildPayload(items: items))
        if BuildKinds.isPrivate(first.kind, data: data) || project == nil || (project?.convID ?? "").isEmpty {
            send(body, in: DemoChats.notesToSelf(self), loud: false, uploads: uploads)
        } else if let g = conversation(project?.convID ?? ""), !g.left {
            send(body, in: g, loud: loud, preview: preview, uploads: uploads)
        } else {
            send(body, in: DemoChats.notesToSelf(self), loud: false, uploads: uploads)
        }
        // Subject copy (bundled with the project and the unit, so their tab can show it).
        let subject = bSubject(first, data: data)
        guard !subject.isEmpty, subject != me, let ct = contact(subject), !ct.blocked, first.kind != "vault", first.kind != "company" else { return }
        var bundle: [BuildItem] = []
        if let p = bRecord(first.projectID), first.kind != "project" {
            var safe = p.d
            safe.team = []; safe.admins = []; safe.convID = ""; safe.files = []
            safe["budget"] = ""
            bundle.append(item(p.id, kind: "project", company: p.companyID, project: p.id, parent: "", status: p.status, owner: p.ownerID, data: safe))
        }
        var chain = bRecord(first.parentID)
        while let c = chain, bundle.count < 4 {
            bundle.append(item(c))
            chain = bRecord(c.parentID)
        }
        bundle.append(contentsOf: items)
        send(.build(BuildPayload(items: bundle)), in: directConversation(with: ct), loud: loud,
             preview: loud ? (preview ?? "🏗️ \(myName) updated your \(BuildKinds.of(first.kind).label.lowercased())") : nil, uploads: uploads)
    }

    @discardableResult
    func bSave(kind: String, existing: BuildRecord?, company: String, project: String, parent: String = "", status: String, data: BuildData,
               uploads: [String: String] = [:], loud: Bool = false) -> String {
        let id = existing?.id ?? "b\(kind.prefix(3))_" + UUID().uuidString
        let owner = existing?.ownerID ?? bRecord(project)?.ownerID ?? me
        let it = item(id, kind: kind, company: company, project: project, parent: parent, status: status, owner: owner, data: data)
        let isNew = existing == nil
        bSend([it], loud: loud || isNew && ["sale", "payment", "demand", "test", "approval", "dispute", "inspection"].contains(kind),
              preview: isNew ? "🏗️ \(BuildKinds.of(kind).label): \(data.title(kind))" : nil, uploads: uploads)
        bFinanceLink(it, data: data)
        BuildReminders.reschedule(self)
        return id
    }

    func bDelete(_ r: BuildRecord) {
        var it = item(r)
        it.deleted = true; it.at = .now
        bSend([it])
        bFinanceLink(it, data: r.d)
        for c in bChildren(r.id) where ["move", "log", "payment", "demand"].contains(c.kind) { bDelete(c) }
    }

    func bSetStatus(_ r: BuildRecord, _ status: String) {
        bSave(kind: r.kind, existing: r, company: r.companyID, project: r.projectID, parent: r.parentID, status: status, data: r.d)
    }

    /// Money in Build also lands in the company's Finance book (same id, so edits and deletes follow).
    private func bFinanceLink(_ it: BuildItem, data: BuildData) {
        guard !it.companyID.isEmpty, attRecord(it.companyID)?.company.isStaff(me) == true else { return }
        var amount = 0.0, dir = "out", cat = "Purchase", party = "", title = data.title(it.kind)
        let parent = bRecord(it.parentID)
        let project = bRecord(it.projectID)?.title ?? ""
        switch it.kind {
        case "payment":
            amount = BuildData.number(data["amount"])
            guard it.status != "Bounced" else { amount = 0; break }
            if parent?.kind == "sale" {
                dir = "in"; cat = "Sales"; party = parent?.title ?? ""
                title = "Unit \(bRecord(parent?.parentID ?? "")?.title ?? "") · \(data["title"])"
            } else if let p = parent, p.kind == "party" {
                party = p.title
                if BuildKinds.money.contains(p.f("role")) { dir = "in"; cat = "Other income"; title = "Capital from \(p.title)" }
                else { dir = "out"; cat = p.f("role") == "Supplier" ? "Purchase" : "Professional fees"; title = "\(p.f("role")): \(data["title"])" }
            }
        case "move":
            guard data["type"] == "Received", data["paid"] == "Yes" else { break }
            amount = BuildData.number(data["qty"]) * BuildData.number(data["rate"])
            cat = "Purchase"; party = data["party"]; title = "\(data["qty"]) \(parent?.f("unit") ?? "") \(parent?.title ?? "")"
        case "log":
            guard data["paid"] == "Yes" else { break }
            amount = BuildData.number(data["cost"]); cat = "Repairs"; title = "\(parent?.title ?? "Machine"): \(data["title"])"
        case "reward":
            amount = BuildData.number(data["amount"]); cat = "Salary & wages"; party = data["name"]; title = "Reward: \(data["reason"])"
        default: return
        }
        let finID = "fin_b_" + it.id
        let existing = try? context.fetch(FetchDescriptor<FinRecord>(predicate: #Predicate { $0.id == finID })).first
        guard amount > 0 || existing != nil else { return }
        var fd = existing?.d ?? FinData()
        fd.title = project.isEmpty ? title : "\(project): \(title)"
        fd.party = party
        fd.mode = data["mode"].isEmpty ? "Bank" : data["mode"]
        fd.reference = data["ref"].isEmpty ? data["challan"] : data["ref"]
        let date = BuildData.date(data["date"]) ?? .now
        finSave(existing, id: finID, book: it.companyID, date: date, amount: amount, direction: dir, status: "paid", category: cat, data: fd,
                deleted: it.deleted || amount == 0)
    }

    // MARK: Company & project

    @discardableResult
    func bCreateCompany(_ data: BuildData) -> String {
        let cid = attCreateCompany(name: data["name"])
        bSave(kind: "company", existing: nil, company: cid, project: "", status: "", data: data)
        return cid
    }

    @discardableResult
    func bCreateProject(company: String, data: BuildData, team: [String], admins: [String]) -> String {
        var d = data
        d.team = team; d.admins = admins
        if !team.isEmpty {
            let g = createGroup(title: "\(d["name"]) · Project", members: team.compactMap { contact($0) }, avatar: nil)
            d.convID = g.id
        }
        return bSave(kind: "project", existing: nil, company: company, project: "", status: "Planning", data: d, loud: true)
    }

    func bSaveProject(_ r: BuildRecord, data: BuildData, status: String) {
        var d = data
        // New team members join the project chat.
        if let g = conversation(d.convID) {
            let have = Set(g.members.map(\.id))
            let add = d.team.filter { !have.contains($0) }.compactMap { contact($0) }
            if !add.isEmpty { addMembers(g, add) }
        } else if !d.team.isEmpty {
            d.convID = createGroup(title: "\(d["name"]) · Project", members: d.team.compactMap { contact($0) }, avatar: nil).id
        }
        bSave(kind: "project", existing: r, company: r.companyID, project: "", status: status, data: d)
    }

    /// Units for every wing × floor of a building.
    func bGenerateUnits(_ b: BuildRecord, perFloor: Int, type: String, carpet: String, price: String, fromFloor: Int, toFloor: Int) {
        let wings = b.f("wings").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let existing = Set(bChildren(b.id, kind: "unit").map(\.title))
        var items: [BuildItem] = []
        for w in (wings.isEmpty ? [""] : wings) {
            for fl in fromFloor...max(fromFloor, toFloor) {
                for n in 1...max(1, perFloor) {
                    var d = BuildData()
                    d["wing"] = w; d["floor"] = String(fl); d["number"] = fl == 0 ? "G0\(n)" : "\(fl)\(String(format: "%02d", n))"
                    d["type"] = type; d["carpet"] = carpet; d["price"] = price
                    guard !existing.contains(d.title("unit")) else { continue }
                    items.append(item("bun_" + UUID().uuidString, kind: "unit", company: b.companyID, project: b.projectID, parent: b.id,
                                      status: "Available", owner: b.ownerID, data: d))
                }
            }
        }
        // Batches keep each event small.
        for i in stride(from: 0, to: items.count, by: 40) { bSend(Array(items[i..<min(i + 40, items.count)])) }
    }

    /// Instalments for a sale from the payment plan stages.
    func bAddPlan(_ sale: BuildRecord, stages: [(String, Double)]) {
        let value = sale.num("value")
        guard value > 0 else { return }
        let items = stages.map { s -> BuildItem in
            var d = BuildData()
            d["title"] = s.0; d["percent"] = String(s.1); d["amount"] = String(format: "%.0f", value * s.1 / 100)
            return item("bdem_" + UUID().uuidString, kind: "demand", company: sale.companyID, project: sale.projectID, parent: sale.id,
                        status: "Due", owner: sale.ownerID, data: d)
        }
        bSend(items, loud: true, preview: "🧾 Payment schedule for unit \(bRecord(sale.parentID)?.title ?? "")")
    }

    /// Creates a CRM lead for an enquiry on a unit / project.
    func bToCRM(name: String, phone: String, email: String, value: Double, note: String, company: String) -> String {
        crmSaveLead(CRMLeadPayload(id: "crm_" + UUID().uuidString, companyID: company, groupConvID: "", ownerID: me, assignees: [], clientID: "",
                                   name: name, company: "", phone: phone, email: email, source: "Builder", stage: "new", dealValue: value,
                                   probability: 20, nextFollowUp: Calendar.current.date(byAdding: .day, value: 1, to: .now), notes: note,
                                   deleted: false, at: .now))
    }

    /// Opens a Legal Matters case for a dispute.
    func bToLegal(_ dispute: BuildRecord) {
        let r = BizRecord(id: "biz_" + UUID().uuidString)
        r.module = "legal"; r.kind = "case"; r.ownerID = me
        r.title = "\(dispute.title) — \(dispute.f("against"))"
        r.subtitle = [dispute.f("forum"), dispute.f("caseNo")].filter { !$0.isEmpty }.joined(separator: " · ")
        r.status = "Pending"; r.notes = "From project \(bRecord(dispute.projectID)?.title ?? ""): \(dispute.f("notes"))"
        saveBiz(BizPayload(r), convID: "")
    }

    /// A project bill in Bills & Renewals.
    func bToBill(title: String, amount: Double, due: Date) {
        let r = BizRecord(id: "biz_" + UUID().uuidString)
        r.module = "bills"; r.kind = "bill"; r.ownerID = me; r.title = title; r.amount = amount; r.due = due; r.status = "Due"; r.subtitle = "Monthly"
        saveBiz(BizPayload(r), convID: "")
    }
}

// MARK: - Reminders

@MainActor
enum BuildReminders {
    static func reschedule(_ engine: SyncEngine) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix("build.") })
        }
        let me = engine.me
        let all = (try? engine.context.fetch(FetchDescriptor<BuildRecord>(predicate: #Predicate { !$0.deleted }))) ?? []
        var due: [(Date, String, String, String)] = []   // date, id, title, body
        for r in all where r.ownerID == me || r.by == me {
            switch r.kind {
            case "demand" where r.status == "Due":
                if let d = BuildData.date(r.f("due")) { due.append((d, r.id, "🧾 Instalment due: \(r.f("title"))", Money.format(r.num("amount")))) }
            case "approval" where r.status == "Approved":
                if let d = BuildData.date(r.f("expiry")) { due.append((d.addingTimeInterval(-30 * 86400), r.id, "📜 Renew soon: \(r.title)", "Valid until \(d.formatted(date: .abbreviated, time: .omitted))")) }
            case "equipment":
                if let d = BuildData.date(r.f("service")) { due.append((d, r.id, "🚜 Service due: \(r.title)", r.f("type"))) }
                if let d = BuildData.date(r.f("insurance")) { due.append((d.addingTimeInterval(-7 * 86400), r.id + ".ins", "🚜 Insurance / fitness: \(r.title)", "Expires \(d.formatted(date: .abbreviated, time: .omitted))")) }
            case "dispute" where !["Settled", "Closed"].contains(r.status):
                if let d = BuildData.date(r.f("next")) { due.append((d.addingTimeInterval(-86400), r.id, "⚖️ Tomorrow: \(r.title)", r.f("forum"))) }
            case "inspection" where r.status == "Compliance needed":
                if let d = BuildData.date(r.f("comply")) { due.append((d.addingTimeInterval(-86400), r.id, "🔎 Compliance due: \(r.title)", r.f("authority"))) }
            default: break
            }
        }
        for (date, id, title, body) in due.filter({ $0.0 > .now }).sorted(by: { $0.0 < $1.0 }).prefix(10) {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            c.userInfo = ["link": "iteam://open/build"]
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
            comps.hour = 9
            center.add(UNNotificationRequest(identifier: "build.\(id)", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
}

// MARK: - Demo

@MainActor
enum BuildDemo {
    static func create(_ engine: SyncEngine) {
        var co = BuildData()
        co["name"] = "Sai Developers (demo)"; co["legal"] = "Partnership firm"; co["address"] = "Dombivli East, Thane"
        let cid = engine.bCreateCompany(co)
        var p = BuildData()
        p["name"] = "Sai Residency (demo)"; p["type"] = "Residential"; p["city"] = "Dombivli"; p["address"] = "Near station road"
        p["plot"] = "2500"; p["authority"] = "KDMC"; p["survey"] = "S. No. 42/1"
        p["start"] = BuildData.dateString(.now)
        let pid = engine.bCreateProject(company: cid, data: p, team: [], admins: [])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            var b = BuildData()
            b["name"] = "Building 1"; b["use"] = "Residential"; b["wings"] = "A, B"; b["floors"] = "7"; b["structure"] = "RCC frame"
            let bid = engine.bSave(kind: "building", existing: nil, company: cid, project: pid, status: "Superstructure", data: b)
            try? await Task.sleep(for: .milliseconds(400))
            guard let bRec = engine.bRecord(bid) else { return }
            engine.bGenerateUnits(bRec, perFloor: 4, type: "2 BHK", carpet: "650", price: "7500000", fromFloor: 1, toFloor: 7)
            try? await Task.sleep(for: .milliseconds(600))
            if let unit = engine.bChildren(bid, kind: "unit").first(where: { $0.title == "A-101" }) {
                var s = BuildData()
                s["buyer"] = "Rahul Shinde (demo)"; s["phone"] = "+91 90000 00000"; s["value"] = "7500000"; s["plan"] = "Construction linked"
                s["booked"] = BuildData.dateString(.now); s["loan"] = "Sanctioned"; s["bank"] = "SBI"; s["loanAmt"] = "6000000"
                engine.bSetStatus(unit, "Booked")
                let sid = engine.bSave(kind: "sale", existing: nil, company: cid, project: pid, parent: unit.id, status: "Booked", data: s)
                try? await Task.sleep(for: .milliseconds(300))
                var pay = BuildData()
                pay["title"] = "Booking"; pay["amount"] = "750000"; pay["date"] = BuildData.dateString(.now); pay["mode"] = "RTGS / NEFT"
                engine.bSave(kind: "payment", existing: nil, company: cid, project: pid, parent: sid, status: "Received", data: pay)
            }
            for (name, cat, unit, qty) in [("OPC 53 cement", "Cement & binders", "Bag", "800"), ("TMT bar 12 mm", "Steel & metal", "Tonne", "12"), ("M-sand (manufactured)", "Sand & aggregates", "Brass", "30")] {
                var m = BuildData()
                m["name"] = name; m["category"] = cat; m["unit"] = unit; m["reorder"] = unit == "Bag" ? "200" : "3"
                let mid = engine.bSave(kind: "material", existing: nil, company: cid, project: pid, status: "", data: m)
                var mv = BuildData()
                mv["type"] = "Received"; mv["qty"] = qty; mv["date"] = BuildData.dateString(.now); mv["party"] = "Demo supplier"
                engine.bSave(kind: "move", existing: nil, company: cid, project: pid, parent: mid, status: "", data: mv)
            }
            for (name, type, own) in [("JCB 3DX", "Backhoe loader (JCB)", "Rented"), ("Poclain 210", "Excavator (Poclain)", "Owned"), ("Mixer 1", "Concrete mixer (half bag / one bag)", "Owned")] {
                var e = BuildData()
                e["name"] = name; e["type"] = type; e["own"] = own
                engine.bSave(kind: "equipment", existing: nil, company: cid, project: pid, status: "Working", data: e)
            }
            var t = BuildData()
            t["name"] = "Concrete cube test — 28 days"; t["where"] = "Building 1, 3rd slab"; t["required"] = "25 N/mm²"; t["result"] = "27.4 N/mm²"
            engine.bSave(kind: "test", existing: nil, company: cid, project: pid, status: "Pass", data: t)
            var a = BuildData()
            a["name"] = "Commencement certificate (CC)"; a["authority"] = "KDMC"; a["number"] = "KDMC/NRV/BP/123"
            engine.bSave(kind: "approval", existing: nil, company: cid, project: pid, status: "Approved", data: a)
            var oc = BuildData()
            oc["name"] = "Occupancy certificate (OC)"; oc["authority"] = "KDMC"
            engine.bSave(kind: "approval", existing: nil, company: cid, project: pid, status: "Not applied", data: oc)
        }
    }
}
