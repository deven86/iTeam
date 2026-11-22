import Foundation
import SwiftData
import UserNotifications

// MARK: - Apply (receiving side)

extension EventApplier {
    private func crmLeadRec(_ id: String) -> CRMLead? {
        try? ctx.fetch(FetchDescriptor<CRMLead>(predicate: #Predicate { $0.id == id })).first
    }
    private func crmActRec(_ id: String) -> CRMActivity? {
        try? ctx.fetch(FetchDescriptor<CRMActivity>(predicate: #Predicate { $0.id == id })).first
    }

    func applyCRMGroup(_ p: CRMGroupPayload, _ e: Event, conv: Conversation?, local: Bool) -> Result {
        guard let conv else { return .needsConversation }
        let gid = p.id
        let existing = try? ctx.fetch(FetchDescriptor<CRMGroup>(predicate: #Predicate { $0.id == gid })).first
        if let existing, p.at <= existing.updatedAt { return .ignored }
        if let existing, e.from != existing.createdBy, p.deleted { return .ignored }
        let g = existing ?? CRMGroup(id: p.id)
        if existing == nil {
            g.createdBy = e.from; g.createdAt = e.at; ctx.insert(g)
            system(conv, "💼 \(e.from == me ? "You" : engine.name(of: e.from)) made this a CRM team group: “\(p.name)”", at: e.at)
        }
        g.companyID = p.companyID; g.convID = conv.id; g.name = p.name; g.memberIDs = p.memberIDs
        g.deleted = p.deleted; g.updatedAt = p.at
        return .applied
    }

    func applyCRMLead(_ p: CRMLeadPayload, _ e: Event, conv: Conversation?, local: Bool) -> Result {
        guard let conv else { return .needsConversation }
        let existing = crmLeadRec(p.id)
        if let existing, p.at <= existing.updatedAt { return .ignored }
        let isClientCopy = p.clientCopy == true
        if let existing {
            // The linked client never edits the lead; only the owner deletes it.
            if e.from == existing.clientID && e.from != existing.ownerID { return .ignored }
            if p.deleted && !existing.deleted && e.from != existing.ownerID { return .ignored }
            if !existing.clientCopy && isClientCopy { return .ignored }
        } else if !isClientCopy && e.from != p.ownerID && !p.assignees.contains(e.from) && !conv.members.contains(where: { $0.id == e.from }) {
            return .ignored
        }
        let l = existing ?? CRMLead(id: p.id)
        let who = e.from == me ? "You" : engine.name(of: e.from)
        let oldStage = existing?.stage
        let oldAssignees = existing?.assignees ?? []
        if existing == nil {
            l.createdAt = e.at; l.clientCopy = isClientCopy
            ctx.insert(l)
        }
        l.companyID = p.companyID; l.groupConvID = isClientCopy ? conv.id : p.groupConvID; l.ownerID = p.ownerID
        l.assignees = p.assignees; l.clientID = p.clientID; l.name = p.name; l.company = p.company; l.phone = p.phone
        l.email = p.email; l.source = p.source; l.stage = p.stage; l.dealValue = p.dealValue; l.probability = p.probability
        l.nextFollowUp = p.nextFollowUp; l.notes = p.notes; l.updatedAt = p.at
        if p.deleted && !l.deleted { l.deletedBy = e.from }
        l.deleted = p.deleted

        // Change log in the chat + activity for others' changes that concern me.
        var line: String?
        if existing == nil {
            line = isClientCopy ? "💼 \(who) shared “\(p.name)” with you in CRM" : "💼 \(who) added lead “\(p.name)”\(p.dealValue > 0 ? " · \(Money.format(p.dealValue))" : "")"
        } else if p.deleted {
            line = "🗑️ \(who) deleted lead “\(p.name)”"
        } else if let oldStage, oldStage != p.stage {
            line = "💼 \(who) moved “\(p.name)” to \(CRMStage.of(p.stage).title)"
        } else if !isClientCopy {
            line = "💼 \(who) updated “\(p.name)”"
        }
        if let line, !(isClientCopy && existing != nil) { system(conv, line, at: e.at) }
        let newlyAssigned = p.assignees.contains(me) && !oldAssignees.contains(me)
        if !local && e.from != me && (newlyAssigned || existing == nil) {
            ctx.insert(ActivityItem(kind: newlyAssigned ? .taskAssigned : .mention,
                                    text: newlyAssigned ? "💼 \(engine.name(of: e.from)) assigned you lead “\(p.name)”" : (line ?? p.name),
                                    convID: conv.id, actorID: e.from, date: e.at))
        }
        Task { @MainActor in CRMReminders.reschedule(engine) }
        return .applied
    }

    func applyCRMActivity(_ p: CRMActivityPayload, _ e: Event, conv: Conversation?, local: Bool) -> Result {
        guard let conv else { return .needsConversation }
        let existing = crmActRec(p.id)
        if let existing, p.at <= existing.updatedAt { return .ignored }
        if let existing, e.from != existing.authorID { return .ignored }
        let a = existing ?? CRMActivity(id: p.id)
        if existing == nil { a.authorID = e.from; ctx.insert(a) }
        a.leadID = p.leadID; a.companyID = p.companyID; a.kind = p.kind; a.title = p.title; a.detail = p.detail
        a.amount = p.amount; a.at = p.date; a.needsAcceptance = p.needsAcceptance; a.acceptance = p.acceptance
        a.declineReason = p.declineReason; a.files = p.files; a.deleted = p.deleted; a.updatedAt = p.at
        if existing == nil, !p.deleted {
            let who = e.from == me ? "You" : engine.name(of: e.from)
            let leadName = crmLeadRec(p.leadID)?.name ?? "a lead"
            let line: String = switch p.kind {
            case "quote": "🧾 \(who) sent a quote of \(Money.format(p.amount)) for “\(leadName)”\(p.needsAcceptance ? " — waiting for acceptance" : "")"
            case "call": "📞 \(who) logged a call with “\(leadName)”"
            case "meeting", "visit": "📍 \(who) logged a \(p.kind) with “\(leadName)”"
            default: "📝 \(who) added a note to “\(leadName)”"
            }
            system(conv, line, at: e.at)
            if !local && e.from != me {
                ctx.insert(ActivityItem(kind: .mention, text: line, convID: conv.id, actorID: e.from, date: e.at))
            }
        }
        return .applied
    }

    /// A client answers a quote. The quote's author relays the answer to the team.
    func applyCRMQuoteAnswer(activityID: String, leadID: String, accept: Bool, reason: String, _ e: Event, conv: Conversation?, local: Bool) -> Result {
        guard let conv else { return .needsConversation }
        guard let a = crmActRec(activityID), a.kind == "quote", a.acceptance.isEmpty else { return .ignored }
        let lead = crmLeadRec(leadID)
        guard let lead, e.from == lead.clientID else { return .ignored }
        a.acceptance = accept ? "accepted" : "declined"
        a.declineReason = reason
        a.updatedAt = e.at
        let who = e.from == me ? "You" : engine.name(of: e.from)
        let line = accept ? "✅ \(who) accepted the quote of \(Money.format(a.amount)) for “\(lead.name)”"
            : "✋ \(who) declined the quote for “\(lead.name)”\(reason.isEmpty ? "" : " — “\(reason)”")"
        system(conv, line, at: e.at)
        if !local && e.from != me {
            ctx.insert(ActivityItem(kind: .approval, text: line, convID: conv.id, actorID: e.from, date: e.at))
            if a.authorID == me {
                let aid = a.id
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if let act = engine.crmActivity(aid), let l = engine.crmLead(leadID) { engine.crmRelayAnswer(act, lead: l) }
                }
            }
        }
        return .applied
    }
}

// MARK: - Actions (sending side)

@MainActor
extension SyncEngine {
    func crmLead(_ id: String) -> CRMLead? {
        try? context.fetch(FetchDescriptor<CRMLead>(predicate: #Predicate { $0.id == id })).first
    }
    func crmActivity(_ id: String) -> CRMActivity? {
        try? context.fetch(FetchDescriptor<CRMActivity>(predicate: #Predicate { $0.id == id })).first
    }
    func crmGroups(company: String) -> [CRMGroup] {
        ((try? context.fetch(FetchDescriptor<CRMGroup>(predicate: #Predicate { !$0.deleted }))) ?? [])
            .filter { company.isEmpty || $0.companyID == company }
    }

    /// Companies I own or belong to — the same list Attendance uses.
    func crmCompanies() -> [(id: String, name: String)] {
        let all = (try? context.fetch(FetchDescriptor<AttRecord>(predicate: #Predicate { ($0.kind == "company" || $0.kind == "member") && !$0.deleted }))) ?? []
        let companies = all.filter { $0.kind == "company" }
        let mine = Set(all.filter { $0.kind == "member" && $0.member.userID == me && $0.member.accepted != false }.map(\.companyID))
        return companies.filter { $0.company.ownerID == me || $0.company.admins.contains(me) || mine.contains($0.id) }
            .map { ($0.id, $0.company.name) }.sorted { $0.name < $1.name }
    }

    /// iTeam users in a company (owner, admins, accepted members).
    func crmCompanyPeople(_ companyID: String) -> [(id: String, name: String)] {
        guard let c = attRecord(companyID)?.company else { return [] }
        var ids = [c.ownerID] + c.admins
        ids += attAll("member", company: companyID).filter { !$0.deleted && $0.member.isUser && $0.member.accepted == true }.map(\.member.userID)
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { ($0, $0 == me ? "You" : name(of: $0)) }
    }

    @discardableResult
    func crmCreateCompany(name: String) -> String { attCreateCompany(name: name) }

    /// A CRM team pod: a real encrypted group chat tagged with the company.
    @discardableResult
    func crmCreateGroup(name: String, companyID: String, memberIDs: [String]) -> Conversation {
        let people = memberIDs.compactMap { contact($0) }
        let conv = createGroup(title: name, members: people, avatar: nil)
        send(.crmGroup(CRMGroupPayload(id: "crmg_" + UUID().uuidString, companyID: companyID, name: name,
                                       memberIDs: memberIDs + [me], deleted: false, at: .now)),
             in: conv, loud: true, preview: "💼 CRM team group “\(name)”")
        return conv
    }

    /// Internal chats a lead lives in: its team group, else the assignees' one-to-one chats, else Notes to self.
    private func crmHomes(groupConvID: String, assignees: [String]) -> [Conversation] {
        if !groupConvID.isEmpty, let g = conversation(groupConvID), !g.left { return [g] }
        let others = assignees.filter { $0 != me }.compactMap { contact($0) }.filter { !$0.blocked }.map { directConversation(with: $0) }
        return others.isEmpty ? [DemoChats.notesToSelf(self)] : others
    }

    private func crmClientConv(_ clientID: String) -> Conversation? {
        guard !clientID.isEmpty, clientID != me, let c = contact(clientID), !c.blocked else { return nil }
        return directConversation(with: c)
    }

    @discardableResult
    func crmSaveLead(_ p: CRMLeadPayload) -> String {
        var p = p
        p.at = .now
        if p.ownerID.isEmpty { p.ownerID = me }
        let isNew = crmLead(p.id) == nil
        for conv in crmHomes(groupConvID: p.groupConvID, assignees: p.assignees) {
            send(.crmLead(p), in: conv, loud: isNew || p.deleted, preview: isNew ? "💼 New lead: \(p.name)" : nil)
        }
        if let client = crmClientConv(p.clientID) {
            var safe = p
            safe.notes = ""; safe.assignees = []; safe.probability = 0; safe.groupConvID = ""; safe.source = ""; safe.clientCopy = true
            send(.crmLead(safe), in: client, loud: isNew, preview: isNew ? "💼 \(myName) shared “\(p.name)” with you" : nil)
        }
        CRMReminders.reschedule(self)
        return p.id
    }

    func crmPayload(_ l: CRMLead) -> CRMLeadPayload {
        CRMLeadPayload(id: l.id, companyID: l.companyID, groupConvID: l.groupConvID, ownerID: l.ownerID, assignees: l.assignees,
                       clientID: l.clientID, name: l.name, company: l.company, phone: l.phone, email: l.email, source: l.source,
                       stage: l.stage, dealValue: l.dealValue, probability: l.probability, nextFollowUp: l.nextFollowUp,
                       notes: l.notes, deleted: l.deleted, at: .now)
    }

    func crmSetStage(_ l: CRMLead, _ stage: CRMStage) {
        var p = crmPayload(l)
        p.stage = stage.rawValue
        if stage == .won { p.probability = 100 } else if stage == .lost { p.probability = 0 }
        crmSaveLead(p)
    }

    func crmSaveActivity(_ lead: CRMLead, id: String? = nil, kind: String, title: String, detail: String, amount: Double,
                         date: Date, files: [AttachmentRef], uploads: [String: String] = [:], deleted: Bool = false) {
        let p = CRMActivityPayload(id: id ?? "crma_" + UUID().uuidString, leadID: lead.id, companyID: lead.companyID, kind: kind,
                                   title: title, detail: detail, amount: amount, date: date, needsAcceptance: kind == "quote" && !lead.clientID.isEmpty,
                                   acceptance: "", declineReason: "", files: files, deleted: deleted, at: .now)
        var sent = false
        for conv in crmHomes(groupConvID: lead.groupConvID, assignees: lead.assignees) {
            send(.crmActivity(p), in: conv, loud: kind == "quote", preview: kind == "quote" ? "🧾 Quote for \(lead.name)" : nil, uploads: sent ? [:] : uploads)
            sent = true
        }
        if kind == "quote", let client = crmClientConv(lead.clientID) {
            send(.crmActivity(p), in: client, loud: true, preview: "🧾 \(myName) sent you a quote of \(Money.format(amount)) — tap to accept",
                 uploads: sent ? [:] : uploads)
        }
    }

    /// Client side: accept or decline a quote (goes back in the chat it came from).
    func crmAnswerQuote(_ a: CRMActivity, lead: CRMLead, accept: Bool, reason: String) {
        guard let conv = conversation(lead.groupConvID) else { return }
        send(.crmQuoteAnswer(activityID: a.id, leadID: lead.id, accept: accept, reason: reason), in: conv, loud: true,
             preview: accept ? "✅ \(myName) accepted your quote" : "✋ \(myName) declined your quote")
    }

    /// The quote's author passes the client's answer on to the team chat.
    func crmRelayAnswer(_ a: CRMActivity, lead: CRMLead) {
        let p = CRMActivityPayload(id: a.id, leadID: a.leadID, companyID: a.companyID, kind: a.kind, title: a.title, detail: a.detail,
                                   amount: a.amount, date: a.at, needsAcceptance: a.needsAcceptance, acceptance: a.acceptance,
                                   declineReason: a.declineReason, files: a.files, deleted: a.deleted, at: .now)
        for conv in crmHomes(groupConvID: lead.groupConvID, assignees: lead.assignees) {
            send(.crmActivity(p), in: conv, loud: false)
        }
        if a.acceptance == "accepted", lead.stage != CRMStage.won.rawValue { crmSetStage(lead, .won) }
    }
}

// MARK: - Follow-up reminders (local, no server)

@MainActor
enum CRMReminders {
    static func reschedule(_ engine: SyncEngine) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix("crm.") }
            center.removePendingNotificationRequests(withIdentifiers: old)
        }
        let me = engine.me
        let leads = ((try? engine.context.fetch(FetchDescriptor<CRMLead>(predicate: #Predicate { !$0.deleted && !$0.clientCopy }))) ?? [])
            .filter { $0.isOpen && ($0.ownerID == me || $0.assignees.contains(me)) && ($0.nextFollowUp ?? .distantPast) > .now }
            .sorted { ($0.nextFollowUp ?? .distantFuture) < ($1.nextFollowUp ?? .distantFuture) }
            .prefix(10)
        for l in leads {
            guard let due = l.nextFollowUp else { continue }
            let content = UNMutableNotificationContent()
            content.title = "💼 Follow up: \(l.name)"
            content.body = [l.company, l.dealValue > 0 ? Money.format(l.dealValue) : "", CRMStage.of(l.stage).title].filter { !$0.isEmpty }.joined(separator: " · ")
            content.sound = .default
            content.userInfo = ["link": "iteam://item/crm/\(l.id)"]
            let fire = max(due.addingTimeInterval(-3600), Date.now.addingTimeInterval(60))
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            center.add(UNNotificationRequest(identifier: "crm.\(l.id)", content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
}

// MARK: - Demo

@MainActor
enum CRMDemo {
    /// Sample leads in the demo team chat (or Notes to self) so CRM can be tried alone.
    static func create(_ engine: SyncEngine) {
        let team = (try? engine.context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.isDemo })))?.first { $0.isGroup }
        if let team, engine.crmGroups(company: "").first(where: { $0.convID == team.id }) == nil {
            engine.send(.crmGroup(CRMGroupPayload(id: "crmg_demo", companyID: "", name: "Demo Sales Pod",
                                                  memberIDs: team.members.map(\.id), deleted: false, at: .now)), in: team, loud: false)
        }
        let cal = Calendar.current
        let sample: [(String, String, String, Double, Int)] = [
            ("Acme Retail", "Showroom fit-out", "negotiation", 450_000, 0),
            ("Patil Constructions", "Site office interiors", "proposal", 280_000, 1),
            ("Sai Heights Society", "Annual maintenance contract", "contacted", 96_000, 3),
            ("Mehta Clinic", "Reception redesign", "new", 60_000, 5),
        ]
        for (i, s) in sample.enumerated() {
            let p = CRMLeadPayload(id: "crml_demo_\(i)", companyID: "", groupConvID: team?.id ?? "", ownerID: engine.me,
                                   assignees: [], clientID: "", name: s.0, company: s.1, phone: "", email: "", source: "Demo",
                                   stage: s.2, dealValue: s.3, probability: [70, 50, 30, 20][i],
                                   nextFollowUp: cal.date(byAdding: .day, value: s.4, to: cal.startOfDay(for: .now))?.addingTimeInterval(11 * 3600),
                                   notes: "Sample lead", deleted: false, at: .now)
            engine.crmSaveLead(p)
        }
        if let l = engine.crmLead("crml_demo_0") {
            engine.crmSaveActivity(l, kind: "visit", title: "Site visit", detail: "Measured the showroom; client wants a glass facade.", amount: 0, date: .now.addingTimeInterval(-86_400), files: [])
            engine.crmSaveActivity(l, kind: "quote", title: "Fit-out quote v1", detail: "Includes facade, lighting and signage.", amount: 450_000, date: .now, files: [])
        }
    }
}
