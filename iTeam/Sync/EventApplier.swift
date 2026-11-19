import Foundation
import SwiftData

/// Applies one decrypted event to the local database. Used for my own actions (local = true)
/// and for events arriving from other people or my other devices. Applying the same event twice is harmless.
@MainActor
struct EventApplier {
    enum Result { case applied, ignored, needsConversation }

    let engine: SyncEngine
    var ctx: ModelContext { engine.context }
    var me: String { engine.me }

    func apply(_ e: Event, local: Bool) -> Result {
        let personal = e.conv.hasPrefix("s_")
        var conv: Conversation? = engine.conversation(e.conv)

        // "Notes to self": created the first time a message arrives for it (e.g. on my iPad).
        if conv == nil, personal, case .message = e.body {
            let c = Conversation(id: e.conv, kind: "direct", title: "Notes to self", ownerID: me, peerID: me,
                                 members: [MemberInfo(id: me, name: engine.myName, role: .owner)])
            ctx.insert(c)
            conv = c
        }

        if conv == nil, e.conv.hasPrefix("d_"), let peer = SyncEngine.peer(inDirect: e.conv, me: me) {
            let c = Conversation(id: e.conv, kind: "direct", title: engine.contact(peer)?.name ?? "Chat", ownerID: peer, peerID: peer,
                                 members: [MemberInfo(id: me, name: engine.myName, role: .member),
                                           MemberInfo(id: peer, name: engine.contact(peer)?.name ?? "", role: .member)])
            ctx.insert(c)
            conv = c
        }

        if case .group(let g) = e.body { return applyGroup(g, e, conv: conv, local: local) }
        if case .receipt(let d, let r) = e.body {
            guard let conv, e.from != me else { return .ignored }
            var all = conv.receipts
            var mark = all[e.from] ?? ReceiptMark()
            if let d { mark.delivered = max(mark.delivered ?? .distantPast, d) }
            if let r { mark.read = max(mark.read ?? .distantPast, r) }
            all[e.from] = mark
            conv.receipts = all
            return .applied
        }

        if !personal {
            guard let conv else { return .needsConversation }
            // Only members may change a group.
            if conv.isGroup && !conv.isMember(e.from) && e.from != me { return .ignored }
        }

        switch e.body {
        case .message(let p):
            guard let conv, engine.message(p.id) == nil else { return .ignored }
            let m = Message(id: p.id, convID: conv.id, senderID: e.from, text: p.text, createdAt: e.at,
                            replyToID: p.replyTo, attachments: p.attachments, status: local ? .queued : .sent)
            ctx.insert(m)
            touch(conv, at: e.at, preview: m.preview, from: e.from)
            if !local && e.from != me {
                if engine.openConversation != conv.id { conv.unread += 1 }
                conv.archived = false
                if mentionsMe(p.text) {
                    ctx.insert(ActivityItem(kind: .mention, text: "\(engine.name(of: e.from)) mentioned you: \(p.text.prefix(120))",
                                            convID: conv.id, actorID: e.from, date: e.at))
                }
            }

        case .edit(let id, let text):
            guard let m = engine.message(id), m.senderID == e.from, !m.deleted else { return .ignored }
            m.text = text
            m.editedAt = e.at

        case .unsend(let id):
            guard let m = engine.message(id), m.senderID == e.from else { return .ignored }
            m.deleted = true
            m.text = ""
            m.attachments = []
            m.reactions = [:]

        case .react(let id, let emoji):
            guard let m = engine.message(id) else { return .ignored }
            var r = m.reactions
            r[e.from] = emoji
            if emoji == nil { r.removeValue(forKey: e.from) }
            m.reactions = r

        case .leave:
            guard let conv, conv.isGroup else { return .ignored }
            conv.members = conv.members.filter { $0.id != e.from }
            if e.from == me { conv.left = true }
            system(conv, "\(engine.name(of: e.from)) left", at: e.at)

        case .task(let p):
            applyTask(p, e, convID: personal ? nil : conv?.id, local: local)

        case .taskDelete(let id):
            guard let t = engine.task(id) else { return .ignored }
            let admin = conv?.role(of: e.from)?.canManage ?? false
            guard t.createdBy == e.from || admin || personal else { return .ignored }
            t.deleted = true
            t.updatedAt = .now

        case .checklist(let c):
            let itemID = c.id
            if let item = try? ctx.fetch(FetchDescriptor<ChecklistItem>(predicate: #Predicate { $0.id == itemID })).first {
                guard c.at >= item.updatedAt else { return .ignored }
                item.title = c.title
                item.done = c.done
                item.position = c.position
                item.deleted = c.deleted
                item.updatedAt = c.at
                item.updatedBy = e.from
            } else {
                let item = ChecklistItem(id: c.id, taskID: c.taskID, title: c.title, position: c.position, by: e.from)
                item.done = c.done
                item.deleted = c.deleted
                item.updatedAt = c.at
                ctx.insert(item)
            }
            engine.task(c.taskID)?.updatedAt = .now

        case .comment(let c):
            let cid = c.id
            let exists = ((try? ctx.fetch(FetchDescriptor<TaskComment>(predicate: #Predicate { $0.id == cid }))) ?? []).isEmpty == false
            guard !exists else { return .ignored }
            ctx.insert(TaskComment(id: c.id, taskID: c.taskID, authorID: e.from, body: c.body, createdAt: e.at))
            if let t = engine.task(c.taskID) {
                t.updatedAt = .now
                if e.from != me && t.involves(me) {
                    ctx.insert(ActivityItem(kind: .taskComment, text: "\(engine.name(of: e.from)) commented on “\(t.title)”: \(c.body.prefix(100))",
                                            convID: t.convID, taskID: t.id, actorID: e.from, date: e.at))
                }
            }

        case .taskPart(let taskID, let done):
            guard let t = engine.task(taskID) else { return .ignored }
            var parts = t.doneBy
            if done { parts[e.from] = e.at } else { parts.removeValue(forKey: e.from) }
            t.doneBy = parts
            t.updatedAt = .now
            if t.policy == .all, !t.assignees.isEmpty {
                let allDone = t.assignees.allSatisfy { parts[$0] != nil }
                var st = t.stamps
                if allDone && !t.isDone {
                    t.status = .done
                    t.completedAt = e.at
                    t.completedBy = e.from
                    st["status"] = e.at
                    if local && t.repeatRule != "none" {
                        let task = t
                        Task { @MainActor in engine.spawnNextOccurrence(task) }
                    }
                    if e.from != me {
                        ctx.insert(ActivityItem(kind: .taskCompleted, text: "Everyone finished “\(t.title)”", convID: t.convID, taskID: t.id, actorID: e.from, date: e.at))
                    }
                } else if !allDone && t.isDone {
                    t.status = .inProgress
                    t.completedAt = nil
                    t.completedBy = nil
                    st["status"] = e.at
                }
                t.stamps = st
            }
            if e.from != me && done {
                ctx.insert(ActivityItem(kind: .taskUpdated, text: "\(engine.name(of: e.from)) finished their part of “\(t.title)”",
                                        convID: t.convID, taskID: t.id, actorID: e.from, date: e.at))
            }

        case .taskFile(let f):
            let fid = f.id
            if let existing = try? ctx.fetch(FetchDescriptor<TaskFile>(predicate: #Predicate { $0.id == fid })).first {
                existing.deleted = f.deleted
                existing.title = f.title
            } else {
                let tf = TaskFile(id: f.id, taskID: f.taskID, kind: f.kind, title: f.title, addedBy: e.from)
                tf.attachment = f.attachment
                tf.url = f.url
                tf.deleted = f.deleted
                tf.addedAt = e.at
                ctx.insert(tf)
                if let t = engine.task(f.taskID), e.from != me, !local, t.involves(me), !f.deleted {
                    ctx.insert(ActivityItem(kind: .taskUpdated, text: "\(engine.name(of: e.from)) attached “\(f.title)” to “\(t.title)”",
                                            convID: t.convID, taskID: t.id, actorID: e.from, date: e.at))
                }
            }
            engine.task(f.taskID)?.updatedAt = .now

        case .approval(let a):
            guard let conv else { return .needsConversation }
            guard engine.approval(a.id) == nil else { return .ignored }
            let ap = Approval(id: a.id, convID: conv.id, messageID: a.messageID, title: a.title, requestedBy: e.from, approvers: a.approvers)
            ap.details = a.details
            ap.amount = a.amount
            ap.taskID = a.taskID
            ap.attachments = a.attachments
            ap.createdAt = e.at
            ctx.insert(ap)
            if engine.message(a.messageID) == nil {
                let m = Message(id: a.messageID, convID: conv.id, senderID: e.from, text: a.title, createdAt: e.at, status: local ? .queued : .sent)
                m.approvalID = a.id
                ctx.insert(m)
                touch(conv, at: e.at, preview: m.preview, from: e.from)
            }
            if !local && e.from != me {
                if engine.openConversation != conv.id { conv.unread += 1 }
                if a.approvers.contains(me) {
                    ctx.insert(ActivityItem(kind: .approval, text: "\(engine.name(of: e.from)) asked for your approval: “\(a.title)”",
                                            convID: conv.id, taskID: a.taskID, actorID: e.from, date: e.at))
                }
            }

        case .decision(let d):
            guard let ap = engine.approval(d.approvalID), ap.approvers.contains(e.from) else { return .ignored }
            var all = ap.decisions
            if let old = all[e.from], old.at > e.at { return .ignored }
            all[e.from] = ApprovalDecision(approved: d.approved, note: d.note, amount: d.amount, at: e.at)
            ap.decisions = all
            if let conv {
                let word = d.approved ? "✅ Approved" : "❌ Rejected"
                touch(conv, at: e.at, preview: "\(word): \(ap.title)", from: e.from)
            }
            if e.from != me && !local && ap.requestedBy == me {
                var text = "\(engine.name(of: e.from)) \(d.approved ? "approved" : "rejected") “\(ap.title)”"
                if let amt = d.amount { text += " · \(Money.format(amt))" }
                if !d.note.isEmpty { text += " — \(d.note)" }
                ctx.insert(ActivityItem(kind: .approval, text: text, convID: ap.convID, taskID: ap.taskID, actorID: e.from, date: e.at))
            }

        case .expense(let x):
            let xid = x.id
            if let ex = try? ctx.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.id == xid })).first {
                guard x.at > ex.updatedAt else { return .ignored }
                ex.title = x.title
                ex.amount = x.amount
                ex.date = x.date
                ex.paidBy = x.paidBy
                ex.category = x.category
                ex.receipts = x.receipts
                ex.deleted = x.deleted
                ex.updatedAt = x.at
            } else {
                let ex = Expense(id: x.id, taskID: x.taskID, title: x.title, amount: x.amount, date: x.date,
                                 paidBy: x.paidBy, category: x.category, addedBy: e.from)
                ex.receipts = x.receipts
                ex.deleted = x.deleted
                ex.updatedAt = x.at
                ctx.insert(ex)
                if let t = engine.task(x.taskID), e.from != me, !local, t.involves(me), !x.deleted {
                    ctx.insert(ActivityItem(kind: .expense, text: "\(engine.name(of: e.from)) added an expense of \(Money.format(x.amount)) to “\(t.title)”",
                                            convID: t.convID, taskID: t.id, actorID: e.from, date: e.at))
                }
            }
            engine.task(x.taskID)?.updatedAt = .now

        case .poll(let p):
            guard let conv else { return .needsConversation }
            let pid = p.id
            guard ((try? ctx.fetch(FetchDescriptor<Poll>(predicate: #Predicate { $0.id == pid }))) ?? []).isEmpty else { return .ignored }
            let poll = Poll(id: p.id, convID: conv.id, messageID: p.messageID, question: p.question, options: p.options,
                            multiple: p.multiple, createdBy: e.from)
            poll.createdAt = e.at
            ctx.insert(poll)
            if engine.message(p.messageID) == nil {
                let m = Message(id: p.messageID, convID: conv.id, senderID: e.from, text: p.question, createdAt: e.at, status: local ? .queued : .sent)
                m.pollID = p.id
                ctx.insert(m)
                touch(conv, at: e.at, preview: m.preview, from: e.from)
                if !local && e.from != me && engine.openConversation != conv.id { conv.unread += 1 }
            }

        case .vote(let v):
            let pid = v.pollID
            guard let poll = try? ctx.fetch(FetchDescriptor<Poll>(predicate: #Predicate { $0.id == pid })).first else { return .ignored }
            var all = poll.votes
            if let old = all[e.from], old.at > e.at { return .ignored }
            var choice = v.optionIDs.filter { id in poll.options.contains { $0.id == id } }
            if !poll.multiple { choice = Array(choice.prefix(1)) }
            all[e.from] = VoteRecord(options: choice, at: e.at)
            poll.votes = all

        case .care(let c):
            guard let conv else { return .needsConversation }
            let cid = c.id
            if let prof = try? ctx.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { $0.id == cid })).first {
                guard c.at > prof.updatedAt else { return .ignored }
                fillProfile(prof, c)
            } else {
                let prof = CareProfile(id: c.id, convID: conv.id, name: c.name, createdBy: e.from)
                prof.createdAt = e.at
                fillProfile(prof, c)
                ctx.insert(prof)
                if !local && e.from != me {
                    careAlert("\(engine.name(of: e.from)) started a care profile for \(c.name) in “\(conv.title)”", conv: conv, from: e.from, at: e.at)
                }
            }

        case .medicine(let m):
            let mid = m.id
            let prof = careProfile(m.profileID)
            if let med = try? ctx.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { $0.id == mid })).first {
                guard m.at > med.updatedAt else { return .ignored }
                fillMedicine(med, m)
            } else {
                let med = Medicine(id: m.id, profileID: m.profileID, name: m.name, addedBy: e.from)
                fillMedicine(med, m)
                ctx.insert(med)
                if !local && e.from != me, let prof {
                    careAlert("💊 \(engine.name(of: e.from)) added \(m.name) \(m.dose) for \(prof.name)", conv: conv, from: e.from, at: e.at)
                }
            }

        case .dose(let d):
            let did = d.id
            if let log = try? ctx.fetch(FetchDescriptor<DoseLog>(predicate: #Predicate { $0.id == did })).first {
                guard e.at >= log.at else { return .ignored }
                log.status = d.status
                log.note = d.note
                log.by = e.from
                log.at = e.at
            } else {
                let log = DoseLog(id: d.id, medicineID: d.medicineID, profileID: d.profileID, scheduled: d.scheduled, status: d.status, by: e.from)
                log.note = d.note
                log.at = e.at
                ctx.insert(log)
            }
            if !local && e.from != me && d.status == "skipped", let prof = careProfile(d.profileID) {
                let med = medicine(d.medicineID)?.name ?? "medicine"
                careAlert("⚠️ \(prof.name)'s \(d.scheduled.formatted(date: .omitted, time: .shortened)) \(med) was skipped (\(engine.name(of: e.from)))\(d.note.isEmpty ? "" : ": " + d.note)",
                          conv: conv, from: e.from, at: e.at)
            }

        case .healthEvent(let h):
            let hid = h.id
            let prof = careProfile(h.profileID)
            if let ev = try? ctx.fetch(FetchDescriptor<HealthEvent>(predicate: #Predicate { $0.id == hid })).first {
                guard h.at > ev.updatedAt else { return .ignored }
                fillEvent(ev, h, from: e.from)
                if !local && e.from != me, let prof {
                    let what = h.deleted ? "removed" : (h.status == "recovered" ? "marked recovered" : "updated (\(h.recovery)% recovered)")
                    careAlert("\(engine.name(of: e.from)) \(what): \(prof.name) — \(h.title)\(h.update.map { ": " + $0 } ?? "")", conv: conv, from: e.from, at: e.at)
                }
            } else {
                let ev = HealthEvent(id: h.id, profileID: h.profileID, kind: h.kind, title: h.title, createdBy: e.from)
                fillEvent(ev, h, from: e.from)
                ctx.insert(ev)
                if !local && e.from != me, let prof {
                    let kind = HealthEventKind(rawValue: h.kind)?.title ?? "Health event"
                    careAlert("🚑 \(kind) for \(prof.name): \(h.title) (logged by \(engine.name(of: e.from)))", conv: conv, from: e.from, at: e.at)
                }
            }

        case .vault(let v):
            let vid = v.id
            if let item = try? ctx.fetch(FetchDescriptor<VaultItem>(predicate: #Predicate { $0.id == vid })).first {
                item.deleted = v.deleted
                item.title = v.title
                item.category = v.category
            } else {
                let item = VaultItem(id: v.id, profileID: v.profileID, title: v.title, category: v.category, date: v.date, addedBy: e.from)
                item.attachment = v.attachment
                item.deleted = v.deleted
                ctx.insert(item)
                if !local && e.from != me, let prof = careProfile(v.profileID) {
                    careAlert("📁 \(engine.name(of: e.from)) added “\(v.title)” to \(prof.name)'s medical vault", conv: conv, from: e.from, at: e.at)
                }
            }

        case .group, .receipt:
            break
        }
        return .applied
    }

    // MARK: - Groups

    private func applyGroup(_ g: GroupPayload, _ e: Event, conv: Conversation?, local: Bool) -> Result {
        guard e.conv.hasPrefix("g_") else { return .ignored }
        guard let conv else {
            // A new group: accept only if I'm in it.
            guard g.members.contains(where: { $0.id == me }) else { return .ignored }
            let owner = g.members.first { $0.role == .owner }?.id ?? e.from
            let c = Conversation(id: e.conv, kind: "group", title: g.title, ownerID: owner, members: g.members)
            c.avatar = g.avatar
            c.keyVersion = g.keyVersion
            c.createdAt = e.at
            ctx.insert(c)
            if e.from == me {
                system(c, "You created “\(g.title)”", at: e.at)
            } else {
                system(c, "\(memberName(e.from, g.members)) added you", at: e.at)
                ctx.insert(ActivityItem(kind: .group, text: "\(memberName(e.from, g.members)) added you to “\(g.title)”", convID: c.id, actorID: e.from, date: e.at))
            }
            return .applied
        }

        // Changes must come from an owner/admin, and the owner can't be removed by someone else.
        guard local || conv.role(of: e.from)?.canManage == true else { return .ignored }
        if !g.members.contains(where: { $0.id == conv.ownerID }) && e.from != conv.ownerID { return .ignored }

        let before = Set(conv.members.map(\.id))
        let after = Set(g.members.map(\.id))
        let actor = memberName(e.from, g.members + conv.members)

        if g.title != conv.title { system(conv, "\(actor) renamed the group to “\(g.title)”", at: e.at) }
        for id in after.subtracting(before) where id != me {
            system(conv, "\(actor) added \(memberName(id, g.members))", at: e.at)
        }
        for id in before.subtracting(after) {
            system(conv, id == me ? "\(actor) removed you" : "\(actor) removed \(memberName(id, conv.members))", at: e.at)
        }
        if !before.contains(me) && after.contains(me) {
            conv.left = false
            system(conv, "\(actor) added you", at: e.at)
        }

        conv.title = g.title
        conv.members = g.members
        if let a = g.avatar { conv.avatar = a }
        conv.keyVersion = max(conv.keyVersion, g.keyVersion)
        if !after.contains(me) { conv.left = true }
        return .applied
    }

    // MARK: - Tasks

    private func applyTask(_ p: TaskPayload, _ e: Event, convID: String?, local: Bool) {
        if let t = engine.task(p.id) {
            let wasDone = t.isDone
            let changed = t.merge(p)
            guard !changed.isEmpty, e.from != me, !local else { return }
            if t.isDone && !wasDone {
                ctx.insert(ActivityItem(kind: .taskCompleted, text: "\(engine.name(of: e.from)) completed “\(t.title)”",
                                        convID: convID, taskID: t.id, actorID: e.from, date: e.at))
            } else if changed.contains("assignees") && t.assignees.contains(me) {
                ctx.insert(ActivityItem(kind: .taskAssigned, text: "\(engine.name(of: e.from)) assigned you “\(t.title)”",
                                        convID: convID, taskID: t.id, actorID: e.from, date: e.at))
            } else if t.involves(me) {
                ctx.insert(ActivityItem(kind: .taskUpdated, text: "\(engine.name(of: e.from)) \(p.change ?? "updated") “\(t.title)”",
                                        convID: convID, taskID: t.id, actorID: e.from, date: e.at))
            }
            return
        }
        let t = TaskItem(id: p.id, convID: convID, title: p.title, createdBy: p.createdBy)
        t.sourceMessageID = p.sourceMessageID
        t.notes = p.notes
        t.status = p.status
        t.priority = p.priority
        t.dueAt = p.dueAt
        t.policy = p.policy
        t.assignees = p.assignees
        t.createdAt = p.createdAt
        t.completedAt = p.completedAt
        t.completedBy = p.completedBy
        t.stamps = p.stamps
        t.repeatRule = p.repeatRule ?? "none"
        ctx.insert(t)
        if let src = p.sourceMessageID, let m = engine.message(src) { m.taskID = t.id }
        if let convID, let conv = engine.conversation(convID) {
            touch(conv, at: e.at, preview: "📋 \(p.title)", from: e.from)
        }
        if e.from != me && !local && t.involves(me) {
            let text = p.assignees.contains(me)
                ? "\(engine.name(of: e.from)) assigned you “\(p.title)”"
                : "\(engine.name(of: e.from)) created a group task “\(p.title)”"
            ctx.insert(ActivityItem(kind: .taskAssigned, text: text, convID: convID, taskID: t.id, actorID: e.from, date: e.at))
        }
    }

    // MARK: - Care helpers

    private func careProfile(_ id: String) -> CareProfile? {
        try? ctx.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { $0.id == id })).first
    }

    private func medicine(_ id: String) -> Medicine? {
        try? ctx.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { $0.id == id })).first
    }

    private func careAlert(_ text: String, conv: Conversation?, from: String, at: Date) {
        ctx.insert(ActivityItem(kind: .care, text: text, convID: conv?.id, actorID: from, date: at))
    }

    private func fillProfile(_ p: CareProfile, _ c: CareProfilePayload) {
        p.name = c.name
        p.relation = c.relation
        p.bloodGroup = c.bloodGroup
        p.allergies = c.allergies
        p.conditions = c.conditions
        p.emergencyContact = c.emergencyContact
        p.notes = c.notes
        if let a = c.avatar { p.avatar = a }
        p.deleted = c.deleted
        p.updatedAt = c.at
    }

    private func fillMedicine(_ med: Medicine, _ m: MedicinePayload) {
        med.name = m.name
        med.dose = m.dose
        med.form = m.form
        med.times = m.times
        med.instructions = m.instructions
        med.startDate = m.startDate
        med.endDate = m.endDate
        med.stock = m.stock
        med.active = m.active
        med.deleted = m.deleted
        med.updatedAt = m.at
    }

    private func fillEvent(_ ev: HealthEvent, _ h: HealthEventPayload, from: String) {
        ev.kind = h.kind
        ev.title = h.title
        ev.details = h.details
        ev.date = h.date
        ev.severity = h.severity
        ev.status = h.status
        ev.recovery = h.recovery
        ev.deleted = h.deleted
        if !h.attachments.isEmpty { ev.attachments = h.attachments }
        if let u = h.update, !u.isEmpty {
            var list = ev.updates
            if !list.contains(where: { $0.at == h.at && $0.by == from }) {
                list.append(HealthUpdate(text: u, by: from, at: h.at, recovery: h.recovery))
            }
            ev.updates = list
        }
        ev.updatedAt = h.at
    }

    // MARK: - Helpers

    private func touch(_ conv: Conversation, at: Date, preview: String, from: String) {
        guard at >= conv.lastActivity.addingTimeInterval(-1) || conv.lastPreview.isEmpty else { return }
        conv.lastActivity = max(conv.lastActivity, at)
        conv.lastPreview = conv.isGroup && from != me ? "\(engine.name(of: from)): \(preview)" : preview
    }

    private func system(_ conv: Conversation, _ text: String, at: Date) {
        let m = Message(id: UUID().uuidString, convID: conv.id, senderID: "", text: text, createdAt: at, status: .sent, isSystem: true)
        ctx.insert(m)
        touch(conv, at: at, preview: text, from: me)
    }

    private func memberName(_ id: String, _ members: [MemberInfo]) -> String {
        if id == me { return "You" }
        if let c = engine.contact(id), c.saved { return c.name }
        return members.first { $0.id == id && !$0.name.isEmpty }?.name ?? engine.name(of: id)
    }

    private func mentionsMe(_ text: String) -> Bool {
        let name = engine.myName.split(separator: " ").first.map(String.init) ?? engine.myName
        guard !name.isEmpty else { return false }
        return text.range(of: "@\(name)", options: .caseInsensitive) != nil
    }
}
