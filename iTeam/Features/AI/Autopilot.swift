import SwiftUI
import SwiftData

// MARK: - 🤖 Business Autopilot
//
// When the owner switches it on, questions in chats linked to professional modules (Legal, CRM, Gym, Society,
// Builder, Clinic desk, Tuition, Property, Khata, Pet care) are answered by AI from that module's own records,
// and follow-ups go out (CRM follow-up dates, dues to linked clients).
// • Every reply is clearly marked as the owner's automatic assistant — it never pretends to be a person.
// • It answers only from the records of that chat; anything needing the owner's judgement is passed to the owner.
// • No server: it runs while iTeam is open (an "Autopilot station" iPhone/iPad can stay awake on a charger),
//   when a push wakes iTeam in the background, and on background refreshes iOS allows.

@MainActor
final class Autopilot: ObservableObject {
    static let shared = Autopilot()
    private let d = UserDefaults.standard

    static let modules: [(id: String, title: String, icon: String)] = [
        ("legal", "Legal Matters", "building.columns.fill"), ("crm", "CRM", "person.crop.circle.badge.checkmark"),
        ("gym", "Gym & Training", "dumbbell.fill"), ("society", "Society", "building.2.crop.circle.fill"),
        ("build", "Builder & Infra", "building.columns"), ("clinic", "Clinic Desk (non-medical only)", "cross.case.fill"),
        ("tuition", "Tuition & Classes", "graduationcap.fill"), ("rent", "Property & Rent", "house.and.flag.fill"),
        ("khata", "Shop & Khata", "indianrupeesign.circle.fill"), ("petcare", "Pet Care", "pawprint.fill"),
    ]

    @Published var on: Bool { didSet { d.set(on, forKey: "ap.on"); if on && !oldValue { d.set(Date.now, forKey: "ap.since") }; applyStation() } }
    @Published var moduleOn: Set<String> { didSet { d.set(Array(moduleOn), forKey: "ap.modules") } }
    /// Companies switched OFF (new companies start on).
    @Published var companyOff: Set<String> { didSet { d.set(Array(companyOff), forKey: "ap.companiesOff") } }
    @Published var followUps: Bool { didSet { d.set(followUps, forKey: "ap.followups") } }
    @Published var station: Bool { didSet { d.set(station, forKey: "ap.station"); applyStation() } }
    @Published var log: [LogLine] = []
    @Published private(set) var lastRun: Date?
    private var running = false

    struct LogLine: Codable, Identifiable {
        var id = UUID().uuidString
        var at = Date.now
        var chat: String
        var asked: String
        var answer: String
        var module: String
    }

    private init() {
        on = d.bool(forKey: "ap.on")
        moduleOn = Set(d.stringArray(forKey: "ap.modules") ?? Self.modules.map(\.id))
        companyOff = Set(d.stringArray(forKey: "ap.companiesOff") ?? [])
        followUps = d.object(forKey: "ap.followups") as? Bool ?? true
        station = d.bool(forKey: "ap.station")
        if let data = d.data(forKey: "ap.log"), let l = try? JSONDecoder().decode([LogLine].self, from: data) { log = l }
    }

    var since: Date { d.object(forKey: "ap.since") as? Date ?? .now }

    func applyStation() { UIApplication.shared.isIdleTimerDisabled = on && station }

    private func remember(_ l: LogLine) {
        log.insert(l, at: 0)
        if log.count > 80 { log.removeLast(log.count - 80) }
        d.set(try? JSONEncoder().encode(log), forKey: "ap.log")
    }

    private var handled: Set<String> {
        get { Set(d.stringArray(forKey: "ap.handled") ?? []) }
        set { d.set(Array(newValue.suffix(3000)), forKey: "ap.handled") }
    }

    // MARK: Run

    func run(_ engine: SyncEngine) async {
        guard on, !running, AISettings.shared.enabled, AISettings.shared.ready, let ctx = engine.context, !engine.me.isEmpty else { return }
        running = true
        defer { running = false; lastRun = .now }
        applyStation()
        var sent = 0
        sent += await answer(engine, ctx)
        if followUps {
            sent += followUpRun(engine, ctx)
            sent += await crmFollowUps(engine, ctx)
        }
        if sent > 0 { await engine.sync() }
    }

    /// Answers the newest unanswered message per chat.
    private func answer(_ engine: SyncEngine, _ ctx: ModelContext) async -> Int {
        let me = engine.me
        let start = max(since, Date.now.addingTimeInterval(-48 * 3600))
        let msgs = (try? ctx.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.createdAt > start && !$0.deleted && !$0.isSystem },
                                                             sortBy: [SortDescriptor(\Message.createdAt)]))) ?? []
        var done = handled
        let byConv = Dictionary(grouping: msgs, by: \.convID)
        var sent = 0
        for (cid, list) in byConv {
            guard sent < 8, let conv = engine.conversation(cid), !conv.left, let last = list.last else { continue }
            // Someone (me or my assistant) already spoke after their message → nothing to do.
            guard last.senderID != me, !done.contains(last.id), !last.text.hasPrefix("🤖") else { continue }
            let fresh = list.filter { $0.senderID == last.senderID && !done.contains($0.id) && !$0.text.isEmpty }
            for m in list { done.insert(m.id) }
            guard !fresh.isEmpty, repliesToday(cid) < 12 else { continue }
            guard let c = context(for: conv, sender: last.senderID, engine: engine, ctx: ctx), moduleOn.contains(c.module), !companyOff.contains(c.company) else { continue }
            let history = list.suffix(10).map { "\($0.senderID == me ? engine.myName : engine.name(of: $0.senderID)): \($0.text)" }.joined(separator: "\n")
            let asker = engine.name(of: last.senderID)
            let rules = """
            You are the automatic assistant of \(engine.myName) for \(c.title). You reply in chat to \(asker) on \(engine.myName)'s behalf.
            Answer the newest message using ONLY the records below. Be brief (under 80 words), polite and in the same language as the message.
            If the answer is not in the records, or it needs \(engine.myName)'s own judgement (legal or medical advice, prices or promises not in the records, complaints, disputes), say you have passed it to \(engine.myName), who will reply personally soon.
            Never invent dates, amounts or facts. Never share information about other clients or people.
            \(conv.isGroup ? "This is a group chat: reply only if the message is a question or request for \(engine.myName) or about these records; otherwise output exactly SKIP." : "")
            If the message needs no reply (thanks, ok, emoji, a greeting already answered), output exactly SKIP.
            \(c.extraRules)
            """
            let prompt = "RECORDS (\(c.title)):\n\(c.text)\n\nRECENT CHAT:\n\(history)\n\nNEWEST MESSAGE from \(asker):\n" + fresh.map(\.text).joined(separator: "\n")
            guard let out = try? await AIService.complete(prompt, instructions: rules) else { continue }
            let reply = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty, reply.uppercased() != "SKIP", !reply.uppercased().hasPrefix("SKIP") else { continue }
            engine.sendText("🤖 \(engine.myName)'s assistant: \(reply)", in: conv, replyTo: last.id)
            countReply(cid)
            remember(LogLine(chat: conv.title, asked: fresh.map(\.text).joined(separator: " / "), answer: reply, module: c.title))
            sent += 1
        }
        handled = done
        return sent
    }

    private func repliesToday(_ cid: String) -> Int {
        let k = "ap.count.\(cid).\(HolidayCheck.dayKey(.now))"
        return d.integer(forKey: k)
    }
    private func countReply(_ cid: String) {
        let k = "ap.count.\(cid).\(HolidayCheck.dayKey(.now))"
        d.set(d.integer(forKey: k) + 1, forKey: k)
    }

    // MARK: Which records belong to this chat

    struct ChatContext { let module: String; let company: String; let title: String; let text: String; var extraRules = "" }

    func context(for conv: Conversation, sender: String, engine: SyncEngine, ctx: ModelContext) -> ChatContext? {
        let me = engine.me, cid = conv.id

        // BizRecord modules (Legal, Clinic, Tuition, Property, Khata, Pet care): records kept in this chat.
        let biz = ((try? ctx.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.convID == cid && !$0.deleted && $0.parentID == "" }))) ?? [])
            .filter { $0.ownerID == me || conv.isGroup }
        if let first = biz.first, let spec = BizSpecs.spec(first.module) {
            let tops = biz.filter { $0.module == first.module }.prefix(5)
            var text = ""
            for r in tops {
                let rid = r.id
                let kids = (try? ctx.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.parentID == rid && !$0.deleted }))) ?? []
                text += Self.bizText(r, kids, spec) + "\n\n"
            }
            let extra: String = switch first.module {
            case "legal": "For case questions give the facts from the records: next hearing date, stage, last update, fees due. Never give legal opinions or predict outcomes."
            case "clinic": "Only appointments, timings and bills. Never answer medical questions, symptoms or medicines — pass those to the doctor."
            default: ""
            }
            return ChatContext(module: first.module, company: "personal", title: spec.title, text: text, extraRules: extra)
        }

        // CRM: the lead's team group, or the client's direct chat.
        let leads = ((try? ctx.fetch(FetchDescriptor<CRMLead>(predicate: #Predicate { !$0.deleted }))) ?? []).filter { l in
            l.groupConvID == cid || (!conv.isGroup && !l.clientID.isEmpty && l.clientID == sender && (l.ownerID == me || l.assignees.contains(me)))
        }
        if let l = leads.first {
            let lid = l.id
            let acts = (try? ctx.fetch(FetchDescriptor<CRMActivity>(predicate: #Predicate { $0.leadID == lid }))) ?? []
            return ChatContext(module: "crm", company: l.companyID.isEmpty ? "personal" : l.companyID, title: "CRM",
                               text: CRMShare.leadText(l, activities: acts, engine: engine),
                               extraRules: "Share quotes, stage and next steps from the records only. Don't offer discounts or new prices.")
        }

        // Gym: the member's chat (I'm the owner or the accepted trainer).
        if let m = ((try? ctx.fetch(FetchDescriptor<GymMember>(predicate: #Predicate { $0.convID == cid && !$0.deleted }))) ?? [])
            .first(where: { $0.createdBy == me || ($0.trainerID == me && $0.trainerStatus == "accepted") }) {
            let mid = m.id
            let plans = (try? ctx.fetch(FetchDescriptor<GymPlan>(predicate: #Predicate { $0.memberID == mid }))) ?? []
            let sessions = (try? ctx.fetch(FetchDescriptor<GymSession>(predicate: #Predicate { $0.memberID == mid }, sortBy: [SortDescriptor(\GymSession.date, order: .reverse)]))) ?? []
            let pays = (try? ctx.fetch(FetchDescriptor<GymPayment>(predicate: #Predicate { $0.memberID == mid }))) ?? []
            return ChatContext(module: "gym", company: "personal", title: "Gym & Training",
                               text: ShareText.gym(m, plans: plans, sessions: Array(sessions.prefix(30)), payments: pays, engine: engine),
                               extraRules: "Sessions, timings, plan and payments only. No medical advice.")
        }

        // Builder: the project's team chat, or a buyer / partner asking about their own records.
        let builds = (try? ctx.fetch(FetchDescriptor<BuildRecord>(predicate: #Predicate { !$0.deleted }))) ?? []
        if let p = builds.first(where: { $0.kind == "project" && $0.d.convID == cid }) {
            let pid = p.id
            return ChatContext(module: "build", company: p.companyID.isEmpty ? "personal" : p.companyID, title: "Builder · \(p.title)",
                               text: BuildShare.projectText(p, recs: builds.filter { $0.projectID == pid }, engine: engine))
        }
        if !conv.isGroup {
            let theirs = builds.filter { $0.d.subjectID == sender && $0.ownerID == me }
            if let any = theirs.first {
                let text = theirs.prefix(20).map { r in
                    "[\(r.kind)] \(r.title) · \(r.status) · " + r.d.f.filter { !$0.value.isEmpty && !$0.key.hasPrefix("_") }.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
                }.joined(separator: "\n")
                return ChatContext(module: "build", company: any.companyID.isEmpty ? "personal" : any.companyID, title: "Builder", text: text,
                                   extraRules: "Answer only about this buyer's / partner's own unit, schedule and payments. Dates stored as numbers are seconds since 1970.")
            }
        }

        // Society: a flat owner asking the committee in a direct chat.
        if !conv.isGroup {
            let soc = (try? ctx.fetch(FetchDescriptor<SocietyRecord>(predicate: #Predicate { !$0.deleted }))) ?? []
            if let unit = soc.first(where: { $0.kind == "unit" && $0.unit.ownerUserID == sender }),
               let s = soc.first(where: { $0.kind == "society" && $0.id == unit.societyID }), s.society.isCommittee(me) {
                let bills = soc.filter { $0.kind == "bill" && $0.unitID == unit.id }.sorted { $0.bill.due > $1.bill.due }.prefix(6)
                let comps = soc.filter { $0.kind == "complaint" && $0.by == sender }.prefix(6)
                let notes = soc.filter { $0.kind == "notice" && $0.societyID == s.id }.sorted { $0.createdAt > $1.createdAt }.prefix(5)
                var t = "Society: \(s.society.name)\nFlat: \(unit.unit.wing) \(unit.unit.flat)\nBills:\n"
                t += bills.map { "- \($0.bill.title) \($0.bill.month) ₹\(Int($0.bill.amount)) due \($0.bill.due.formatted(date: .abbreviated, time: .omitted)) · \($0.status)" }.joined(separator: "\n")
                t += "\nTheir complaints:\n" + comps.map { "- \($0.complaint.title) · \($0.status)\($0.complaint.reply.isEmpty ? "" : " · reply: \($0.complaint.reply)")" }.joined(separator: "\n")
                t += "\nRecent notices:\n" + notes.map { "- \($0.notice.title): \(String($0.notice.body.prefix(200)))" }.joined(separator: "\n")
                return ChatContext(module: "society", company: "personal", title: "Society · \(s.society.name)", text: t)
            }
        }
        return nil
    }

    static func bizText(_ r: BizRecord, _ kids: [BizRecord], _ spec: BizSpec) -> String {
        func line(_ x: BizRecord) -> String {
            var bits = ["[\(spec.kind(x.kind)?.label ?? x.kind)] \(x.title)"]
            if !x.subtitle.isEmpty { bits.append(x.subtitle) }
            if x.amount != 0 { bits.append(BizSpecs.money(x.amount)) }
            if let dt = x.date { bits.append("date " + dt.formatted(date: .abbreviated, time: .shortened)) }
            if let dt = x.due { bits.append("due " + dt.formatted(date: .abbreviated, time: .omitted)) }
            if !x.status.isEmpty { bits.append(x.status) }
            if !x.notes.isEmpty { bits.append("notes: " + String(x.notes.prefix(400))) }
            return bits.joined(separator: " · ")
        }
        let sorted = kids.sorted { ($0.date ?? $0.due ?? $0.createdAt) < ($1.date ?? $1.due ?? $1.createdAt) }.suffix(30)
        return "Today: \(Date.now.formatted(date: .complete, time: .omitted))\n" + line(r) + "\n" + sorted.map { "  " + line($0) }.joined(separator: "\n")
    }

    // MARK: Follow-ups

    /// Dues to linked clients (fees, rent, bills): a polite reminder in their chat every 3 days while due.
    private func followUpRun(_ engine: SyncEngine, _ ctx: ModelContext) -> Int {
        let me = engine.me
        let soon = Date.now.addingTimeInterval(86400)
        let all = (try? ctx.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { !$0.deleted && $0.ownerID == me }))) ?? []
        let parents = Dictionary(uniqueKeysWithValues: all.filter { $0.parentID.isEmpty }.map { ($0.id, $0) })
        var sent = 0
        let bucket = Int(Date.now.timeIntervalSince1970 / (3 * 86400))
        for r in all where sent < 10 {
            guard moduleOn.contains(r.module), let spec = BizSpecs.spec(r.module), let k = spec.kind(r.kind), let when = k.countWhen,
                  r.status == when, let due = r.due, due < soon, let p = parents[r.parentID], !p.subjectID.isEmpty,
                  let conv = engine.conversation(p.convID), !conv.left else { continue }
            let key = "ap.fu.\(r.id).\(bucket)"
            guard !d.bool(forKey: key) else { continue }
            d.set(true, forKey: key)
            let late = due < Date.now
            let text = "🤖 \(engine.myName)'s assistant: A gentle reminder — \(r.title.isEmpty ? k.label : r.title) of \(BizSpecs.money(r.amount)) \(late ? "was due on" : "is due on") \(due.formatted(date: .abbreviated, time: .omitted)). Please ignore if already paid. 🙏"
            engine.sendText(text, in: conv)
            remember(LogLine(chat: conv.title, asked: "(follow-up)", answer: text, module: spec.title))
            sent += 1
        }
        return sent
    }

    /// CRM leads whose follow-up date has come: an AI-written follow-up to the client, once per follow-up date.
    private func crmFollowUps(_ engine: SyncEngine, _ ctx: ModelContext) async -> Int {
        guard moduleOn.contains("crm") else { return 0 }
        let me = engine.me
        let leads = ((try? ctx.fetch(FetchDescriptor<CRMLead>(predicate: #Predicate { !$0.deleted }))) ?? [])
            .filter { $0.followUpDue && !$0.clientID.isEmpty && ($0.ownerID == me || $0.assignees.contains(me)) && !companyOff.contains($0.companyID.isEmpty ? "personal" : $0.companyID) }
        var sent = 0
        for l in leads.prefix(5) {
            let key = "ap.crm.\(l.id).\(Int((l.nextFollowUp ?? .now).timeIntervalSince1970))"
            guard !d.bool(forKey: key), let conv = engine.conversation(SyncEngine.directID(me, l.clientID)), !conv.left else { continue }
            d.set(true, forKey: key)
            let lid = l.id
            let acts = (try? ctx.fetch(FetchDescriptor<CRMActivity>(predicate: #Predicate { $0.leadID == lid }))) ?? []
            guard let out = try? await AIService.complete(CRMShare.leadText(l, activities: acts, engine: engine),
                                                          instructions: "Write one short, warm follow-up message (under 60 words) from \(engine.myName)'s assistant to this client, based on the stage and last activity. No new prices, discounts or promises. Same language as earlier messages if known."),
                  !out.isEmpty else { continue }
            let text = "🤖 \(engine.myName)'s assistant: " + out.trimmingCharacters(in: .whitespacesAndNewlines)
            engine.sendText(text, in: conv)
            remember(LogLine(chat: conv.title, asked: "(CRM follow-up)", answer: text, module: "CRM"))
            sent += 1
        }
        return sent
    }
}

// MARK: - Settings → AI → Autopilot

struct AutopilotSettingsView: View {
    @EnvironmentObject var engine: SyncEngine
    @ObservedObject private var ap = Autopilot.shared
    @ObservedObject private var ai = AISettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $ap.on) { Label("Autopilot", systemImage: "airplane.circle.fill") }
                if !ai.enabled || !ai.ready {
                    Label("Turn on AI above first (Apple Intelligence or your own key).", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let t = ap.lastRun { LabeledContent("Last check", value: t.formatted(date: .omitted, time: .shortened)) }
            } footer: {
                Text("Clients' questions in chats linked to the modules below are answered from that module's records, and follow-ups go out. Every reply starts with “🤖 \(engine.myName)'s assistant” so people always know it's automatic. Anything that needs you (advice, prices, complaints) is passed to you.")
            }
            Section {
                ForEach(Autopilot.modules, id: \.id) { m in
                    Toggle(isOn: Binding(get: { ap.moduleOn.contains(m.id) }, set: { on in if on { ap.moduleOn.insert(m.id) } else { ap.moduleOn.remove(m.id) } })) {
                        Label(m.title, systemImage: m.icon)
                    }
                }
            } header: { Text("Modules on autopilot") } footer: { Text("Core modules (chats, tasks, care, attendance, finance) are never answered automatically.") }
            Section {
                ForEach(engine.finBooks, id: \.id) { b in
                    Toggle(isOn: Binding(get: { !ap.companyOff.contains(b.id) }, set: { on in if on { ap.companyOff.remove(b.id) } else { ap.companyOff.insert(b.id) } })) {
                        Label(b.id == "personal" ? "Personal / not linked to a company" : b.name, systemImage: b.id == "personal" ? "person" : "building.2")
                    }
                }
            } header: { Text("Companies") } footer: { Text("CRM leads and builder projects follow their company's switch.") }
            Section {
                Toggle("Send follow-ups", isOn: $ap.followUps)
            } footer: { Text("CRM: a written follow-up to the client when the follow-up date arrives. Fees, rent and bills: a polite reminder to the linked client every 3 days while due.") }
            Section {
                Toggle("Keep this device awake as the Autopilot station", isOn: $ap.station)
            } header: { Text("When does it answer?") } footer: {
                Text("Instantly while iTeam is open. When it's closed, only when iOS wakes iTeam for a new message or a background refresh — often within minutes, sometimes later. For instant answers all day, keep a spare iPhone or iPad signed in to your iTeam on a charger with iTeam open and this switch on.")
            }
            Section("Recent automatic replies") {
                if ap.log.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(ap.log.prefix(30)) { l in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(l.chat) · \(l.module) · \(l.at.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        Text("Q: \(l.asked)").font(.caption)
                        Text(l.answer).font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Autopilot")
        .task { await Autopilot.shared.run(engine) }
    }
}
