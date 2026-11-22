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
        let before = Set(ctx.insertedModelsArray.compactMap { ($0 as? ActivityItem)?.id })
        let r = applyEvent(e, local: local)
        // Activity rows created by this event remember the exact item to open.
        if let link = NotifyRoute.of(e.body).1 {
            for case let a as ActivityItem in ctx.insertedModelsArray where !before.contains(a.id) && a.link.isEmpty { a.link = link }
        }
        return r
    }

    private func applyEvent(_ e: Event, local: Bool) -> Result {
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
            m.forwarded = p.fwd ?? false
            m.viewOnce = p.once ?? false
            if let ttl = p.ttl, ttl > 0 { m.expiresAt = e.at.addingTimeInterval(Double(ttl)) }
            ctx.insert(m)
            // Magic moment: hidden on the recipient's phone until its time.
            if let at = p.at, at > .now, e.from != me {
                m.showAt = at
                m.magicPending = true
                MagicMoments.schedule(m, from: engine.name(of: e.from), group: conv.isGroup ? conv.title : nil, muted: conv.muted)
                return .applied
            }
            if let at = p.at, e.from == me { m.showAt = at }
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
            if m.magicPending { MagicMoments.cancel(m.id); m.magicPending = false }
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
            // Only the person who created a task can delete it.
            guard t.createdBy == e.from || personal else { return .ignored }
            t.deleted = true
            t.deletedBy = e.from
            t.deletedAt = e.at
            t.updatedAt = .now
            if !local && e.from != me {
                ctx.insert(ActivityItem(kind: .taskUpdated, text: "🗑 \(engine.name(of: e.from)) deleted the task “\(t.title)”",
                                        convID: conv?.id, actorID: e.from, date: e.at))
            }

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
                if c.deleted && !prof.deleted && e.from != prof.createdBy { return .ignored }   // only the creator deletes
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
                if m.deleted && !med.deleted && e.from != med.addedBy { return .ignored }
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
                if h.deleted && !ev.deleted && e.from != ev.createdBy { return .ignored }
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
                if v.deleted && !item.deleted && e.from != item.addedBy { return .ignored }
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

        case .gymMember(let g):
            guard let conv else { return .needsConversation }
            let gid = g.id
            let existing = try? ctx.fetch(FetchDescriptor<GymMember>(predicate: #Predicate { $0.id == gid })).first
            if let existing, g.at <= existing.updatedAt { return .ignored }
            if let existing, g.deleted, !existing.deleted, e.from != existing.createdBy { return .ignored }
            let m = existing ?? GymMember(id: g.id, convID: conv.id, name: g.name, createdBy: e.from)
            if existing == nil {
                m.createdAt = e.at
                ctx.insert(m)
                if !local && e.from != me {
                    gymAlert("🏋️ \(engine.name(of: e.from)) added \(g.name) to Gym & Training in “\(conv.title)”", conv: conv, from: e.from, at: e.at)
                }
            }
            m.name = g.name; m.relation = g.relation; m.phone = g.phone; m.goal = g.goal
            m.trainer = g.trainer; m.feePerSession = g.fee; m.deleted = g.deleted; m.updatedAt = g.at
            if let a = g.avatar { m.avatar = a }
            if let t = g.trainerID, t != m.trainerID, e.from == m.createdBy {
                m.trainerID = t
                m.trainerStatus = t.isEmpty ? "" : "waiting"
                m.trainerNote = ""
                if !t.isEmpty {
                    system(conv, "🏋️ \(engine.name(of: e.from)) asked \(t == me ? "you" : engine.name(of: t)) to be \(g.name)'s trainer — waiting for an answer", at: e.at)
                    if t == me && !local {
                        gymAlert("🏋️ \(engine.name(of: e.from)) asked you to be \(g.name)'s trainer. Open Gym & Training to accept or decline.", conv: conv, from: e.from, at: e.at)
                    }
                }
            }

        case .gymTrainerAnswer(let memberID, let accept, let note):
            guard let conv else { return .needsConversation }
            guard let m = gymMember(memberID), e.from == m.trainerID, m.trainerStatus != (accept ? "accepted" : "declined") else { return .ignored }
            m.trainerStatus = accept ? "accepted" : "declined"
            m.trainerNote = note
            if accept, m.trainer.isEmpty || m.trainer != engine.name(of: e.from) { m.trainer = engine.name(of: e.from) }
            let line = accept ? "✅ \(engine.name(of: e.from)) accepted to train \(m.name)" :
                "✋ \(engine.name(of: e.from)) declined to train \(m.name)\(note.isEmpty ? "" : " — “\(note)”")"
            system(conv, line, at: e.at)
            if !local && e.from != me { gymAlert(line, conv: conv, from: e.from, at: e.at) }

        case .gymPhoto(let g):
            let gid = g.id
            let existing = try? ctx.fetch(FetchDescriptor<GymPhoto>(predicate: #Predicate { $0.id == gid })).first
            if let existing, g.at <= existing.updatedAt { return .ignored }
            if let existing, e.from != existing.by, e.from != gymMember(g.memberID)?.createdBy { return .ignored }
            let p = existing ?? GymPhoto(id: g.id, memberID: g.memberID)
            if existing == nil {
                p.by = e.from
                ctx.insert(p)
                if !local && e.from != me, let who = gymMember(g.memberID) {
                    gymAlert("📸 \(engine.name(of: e.from)) added a \(g.pose.lowercased()) progress photo for \(who.name)", conv: conv, from: e.from, at: e.at)
                }
            }
            p.pose = g.pose; p.date = g.date; p.photo = g.photo; p.note = g.note; p.weight = g.weight
            p.deleted = g.deleted; p.updatedAt = g.at

        case .gymPlan(let g):
            let gid = g.id
            let existing = try? ctx.fetch(FetchDescriptor<GymPlan>(predicate: #Predicate { $0.id == gid })).first
            if let existing, g.at <= existing.updatedAt { return .ignored }
            if let existing, g.deleted, !existing.deleted, e.from != gymMember(g.memberID)?.createdBy { return .ignored }
            let p = existing ?? GymPlan(id: g.id, memberID: g.memberID)
            if existing == nil {
                ctx.insert(p)
                if !local && e.from != me, let who = gymMember(g.memberID) {
                    gymAlert("🏢 \(engine.name(of: e.from)) added a \(g.planName.isEmpty ? "membership" : g.planName) at \(g.gymName) for \(who.name)", conv: conv, from: e.from, at: e.at)
                }
            }
            p.gymName = g.gymName; p.branch = g.branch; p.planName = g.planName; p.startDate = g.start; p.endDate = g.end
            p.fee = g.fee; p.notes = g.notes; p.deleted = g.deleted; p.updatedAt = g.at

        case .gymSession(let g):
            let gid = g.id
            let existing = try? ctx.fetch(FetchDescriptor<GymSession>(predicate: #Predicate { $0.id == gid })).first
            if let existing, g.at <= existing.updatedAt { return .ignored }
            if let existing, g.deleted, !existing.deleted, e.from != existing.by, e.from != gymMember(g.memberID)?.createdBy { return .ignored }
            let s = existing ?? GymSession(id: g.id, memberID: g.memberID)
            if existing == nil {
                s.by = e.from
                ctx.insert(s)
                if !local && e.from != me, let who = gymMember(g.memberID) {
                    gymAlert("💪 \(engine.name(of: e.from)) logged a training session for \(who.name)\(g.workout.isEmpty ? "" : ": " + g.workout)", conv: conv, from: e.from, at: e.at)
                }
            }
            s.date = g.date; s.trainer = g.trainer; s.workout = g.workout; s.notes = g.notes; s.deleted = g.deleted; s.updatedAt = g.at

        case .gymPayment(let g):
            let gid = g.id
            let existing = try? ctx.fetch(FetchDescriptor<GymPayment>(predicate: #Predicate { $0.id == gid })).first
            if let existing, g.at <= existing.updatedAt { return .ignored }
            if let existing, g.deleted, !existing.deleted, e.from != existing.by, e.from != gymMember(g.memberID)?.createdBy { return .ignored }
            let p = existing ?? GymPayment(id: g.id, memberID: g.memberID)
            if existing == nil {
                p.by = e.from
                ctx.insert(p)
                if !local && e.from != me, let who = gymMember(g.memberID) {
                    gymAlert("🧾 \(engine.name(of: e.from)) recorded \(Money.format(g.amount)) for \(who.name) — \(GymPaymentKind(rawValue: g.kind)?.title ?? "payment")", conv: conv, from: e.from, at: e.at)
                }
            }
            p.kind = g.kind; p.amount = g.amount; p.date = g.date; p.method = g.method; p.sessions = g.sessions
            p.notes = g.notes; p.receipts = g.receipts; p.deleted = g.deleted; p.updatedAt = g.at

        case .post(let p):
            guard let conv else { return .needsConversation }
            let pid = p.id
            if let post = try? ctx.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.id == pid })).first {
                guard post.author == e.from else { return .ignored }
                if !post.convIDs.contains(conv.id) { post.convIDs.append(conv.id) }
                post.text = p.text
                post.deleted = p.deleted
                if !p.media.isEmpty { post.media = p.media }
            } else {
                let post = Post(id: p.id, author: e.from)
                post.kind = p.kind; post.text = p.text; post.media = p.media
                post.isStatus = p.status; post.expiresAt = p.expires; post.createdAt = e.at
                post.deleted = p.deleted; post.convIDs = [conv.id]
                ctx.insert(post)
                if !local && e.from != me && !p.status && !p.deleted {
                    ctx.insert(ActivityItem(kind: .views, text: "\(engine.name(of: e.from)) shared a \((PostKind(rawValue: p.kind) ?? .moment).title.lowercased()) in Views",
                                            convID: nil, actorID: e.from, date: e.at))
                }
            }

        case .postReact(let postID, let emoji):
            let rid = postID + "|" + e.from
            let existing = try? ctx.fetch(FetchDescriptor<PostReaction>(predicate: #Predicate { $0.id == rid })).first
            if let existing, existing.at > e.at { return .ignored }
            if let emoji {
                if let existing { existing.emoji = emoji; existing.at = e.at }
                else {
                    ctx.insert(PostReaction(postID: postID, user: e.from, emoji: emoji, at: e.at))
                    if !local && e.from != me, let post = try? ctx.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.id == postID })).first, post.author == me {
                        ctx.insert(ActivityItem(kind: .views, text: "\(engine.name(of: e.from)) liked your post \(emoji)", convID: nil, actorID: e.from, date: e.at))
                    }
                }
            } else if let existing {
                ctx.delete(existing)
            }

        case .postComment(let c):
            guard let conv else { return .needsConversation }
            let cid = c.id
            if let existing = try? ctx.fetch(FetchDescriptor<PostComment>(predicate: #Predicate { $0.id == cid })).first {
                guard existing.author == e.from else { return .ignored }
                existing.text = c.text
                existing.deleted = c.deleted
            } else {
                ctx.insert(PostComment(id: c.id, postID: c.postID, author: e.from, text: c.text, createdAt: e.at, convID: conv.id))
                let pid = c.postID
                if !local && e.from != me, let post = try? ctx.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.id == pid })).first, post.author == me {
                    ctx.insert(ActivityItem(kind: .views, text: "\(engine.name(of: e.from)) commented: \(c.text.prefix(80))", convID: nil, actorID: e.from, date: e.at))
                }
            }

        case .postSeen(let postID):
            let sid = postID + "|" + e.from
            if (try? ctx.fetch(FetchDescriptor<PostSeen>(predicate: #Predicate { $0.id == sid })).first) == nil {
                ctx.insert(PostSeen(postID: postID, user: e.from, at: e.at))
            }

        case .taskAccept(let taskID, let accept, let note):
            guard let t = engine.task(taskID), t.assignees.contains(e.from) else { return .ignored }
            var a = t.acceptance
            a[e.from] = (accept ? "accepted" : "declined") + (note.isEmpty ? "" : "|" + note)
            t.acceptance = a
            t.updatedAt = .now
            if !local && e.from != me && t.createdBy == me {
                ctx.insert(ActivityItem(kind: .taskUpdated, text: "\(engine.name(of: e.from)) \(accept ? "accepted" : "declined") “\(t.title)”\(note.isEmpty ? "" : ": " + note)",
                                        convID: conv?.id, taskID: t.id, actorID: e.from, date: e.at))
            }

        case .facetime(let handle):
            if e.from != me, let c = engine.contact(e.from) { c.facetime = handle }

        case .photo(let data):
            if e.from != me, let c = engine.contact(e.from), !c.blocked { c.avatar = data }

        case .about(let text):
            if e.from != me, let c = engine.contact(e.from), !c.blocked { c.about = text }

        case .prescription(let p):
            guard let conv else { return .needsConversation }
            let pid = p.id
            let existing = try? ctx.fetch(FetchDescriptor<Prescription>(predicate: #Predicate { $0.id == pid })).first
            if let rx = existing {
                guard rx.doctorID == e.from, p.at > rx.updatedAt else { return .ignored }
                rx.diagnosis = p.diagnosis; rx.advice = p.advice; rx.items = p.items; rx.nextVisit = p.nextVisit
                rx.updatedAt = p.at
                if p.deleted && !rx.deleted {
                    rx.deleted = true
                    system(conv, "🩺 \(e.from == me ? "You" : engine.name(of: e.from)) cancelled a prescription", at: e.at)
                } else {
                    system(conv, "🩺 \(e.from == me ? "You" : engine.name(of: e.from)) updated the prescription — \(p.diagnosis.isEmpty ? "\(p.items.count) medicine(s)" : p.diagnosis)", at: e.at)
                }
            } else {
                let rx = Prescription(id: p.id)
                rx.convID = conv.id; rx.doctorID = e.from; rx.patientID = p.patientID; rx.patientName = p.patientName
                rx.diagnosis = p.diagnosis; rx.advice = p.advice; rx.items = p.items; rx.nextVisit = p.nextVisit
                rx.createdAt = e.at; rx.updatedAt = p.at; rx.deleted = p.deleted
                ctx.insert(rx)
                let doc = e.from == me ? "You" : "Dr. " + engine.name(of: e.from)
                system(conv, "🩺 \(doc) prescribed \(p.items.map(\.name).joined(separator: ", ")) — waiting for \(p.patientID == me ? "your" : p.patientName + "'s") OK", at: e.at)
                if p.patientID == me && e.from != me {
                    ctx.insert(ActivityItem(kind: .care, text: "Dr. \(engine.name(of: e.from)) sent you a prescription — review and accept", convID: conv.id, actorID: e.from, date: e.at))
                }
            }

        case .rxAnswer(let id, let accept, let note):
            guard let conv else { return .needsConversation }
            guard let rx = try? ctx.fetch(FetchDescriptor<Prescription>(predicate: #Predicate { $0.id == id })).first,
                  rx.patientID == e.from else { return .ignored }
            rx.status = accept ? "accepted" : "declined"
            rx.answerNote = note
            rx.answeredAt = e.at
            let who = e.from == me ? "You" : engine.name(of: e.from)
            system(conv, accept ? "✅ \(who) accepted the prescription — medicines added to Care" : "✋ \(who) declined the prescription\(note.isEmpty ? "" : " — " + note)", at: e.at)
            if rx.doctorID == me && e.from != me {
                ctx.insert(ActivityItem(kind: .care, text: "\(who) \(accept ? "accepted" : "declined") your prescription", convID: conv.id, actorID: e.from, date: e.at))
            }

        case .checkIn(let p):
            guard let conv else { return .needsConversation }
            let cid = p.id
            let ci = (try? ctx.fetch(FetchDescriptor<CheckIn>(predicate: #Predicate { $0.id == cid })).first) ?? {
                let n = CheckIn(id: cid); n.convID = conv.id; n.ownerID = e.from; n.createdAt = e.at; ctx.insert(n); return n
            }()
            guard ci.ownerID == e.from, p.at >= ci.updatedAt else { return .ignored }
            let was = ci.status
            ci.place = p.place; ci.lat = p.lat; ci.lon = p.lon; ci.eta = p.eta; ci.status = p.status; ci.updatedAt = p.at
            let who = e.from == me ? "You" : engine.name(of: e.from)
            switch p.status {
            case "arrived": system(conv, "✅ \(who) arrived at \(p.place)", at: e.at)
            case "ended": system(conv, "📍 \(who) ended the Check In", at: e.at)
            default:
                system(conv, was == "active" && ci.createdAt < e.at ? "📍 \(who) updated the Check In — now by \(p.eta.formatted(date: .omitted, time: .shortened))"
                                                                    : "📍 \(who) started a Check In to \(p.place) — expected by \(p.eta.formatted(date: .omitted, time: .shortened))", at: e.at)
            }
            if e.from != me { CheckInAlerts.update(ci, name: engine.name(of: e.from)) }

        case .biz(let incoming):
            var p = incoming
            let rid = p.id
            let existing = try? ctx.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == rid })).first
            let r: BizRecord
            if let existing {
                guard p.at > existing.updatedAt else { return .ignored }
                let kind = BizSpecs.spec(existing.module)?.kind(existing.kind)
                let pid = existing.parentID
                let parentOwner = pid.isEmpty ? nil : (try? ctx.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == pid })).first)?.ownerID
                let isOwner = existing.ownerID == e.from || parentOwner == e.from
                // A matter/record shared into a group: the whole group works on it as a team (only the creator deletes).
                let team = conv?.isGroup == true && conv?.isMember(e.from) == true && existing.convID == conv?.id && !p.deleted
                // The linked client answers: approvals, e-vakalatnama, homework done, a fee moved back to due.
                let client = !existing.subjectID.isEmpty && existing.subjectID == e.from && !isOwner
                    && (kind?.clientAnswers == true || existing.status == "Reverting")
                guard isOwner || team || client else { return .ignored }
                if client {
                    var keep = BizPayload(existing)
                    keep.status = existing.status == "Reverting" ? (p.status == "Due" ? "Due" : "Paid") : p.status
                    keep.notes = kind?.clientAnswers == true && !p.notes.isEmpty ? p.notes : existing.notes
                    keep.at = p.at
                    p = keep
                }
                // Paid → Due needs approval: by the linked client, or by a group admin when a team works on it.
                if existing.status == "Paid" && p.status == "Due" && !client {
                    let isAdmin = conv?.members.first { $0.id == e.from }.map { $0.role != .member } ?? true
                    if (!existing.subjectID.isEmpty && existing.subjectID != e.from) || (conv?.isGroup == true && !isAdmin) { p.status = "Reverting" }
                }
                // While waiting, only the client (or, with no client, a group admin) can settle it as Due.
                if existing.status == "Reverting" && !client && p.status == "Due" {
                    let isAdmin = conv?.members.first { $0.id == e.from }.map { $0.role != .member } ?? true
                    if !existing.subjectID.isEmpty || (conv?.isGroup == true && !isAdmin) { p.status = "Reverting" }
                }
                r = existing
            } else {
                r = BizRecord(id: p.id)
                r.ownerID = e.from
                r.createdAt = e.at
                r.convID = personal ? "" : (conv?.id ?? "")
                ctx.insert(r)
            }
            if !personal, let conv { r.convID = conv.id }
            let wasDeleted = r.deleted
            r.module = p.module; r.kind = p.kind; r.parentID = p.parentID; r.subjectID = p.subjectID
            r.title = p.title; r.subtitle = p.subtitle; r.phone = p.phone; r.amount = p.amount
            r.date = p.date; r.due = p.due; r.status = p.status; r.notes = p.notes; r.updatedAt = p.at
            if let f = p.files { r.files = f }
            if let x = p.extra { r.extra = x }
            if p.deleted && !wasDeleted { r.deleted = true; r.deletedBy = e.from }
            if let conv, !personal {
                let who = e.from == me ? "You" : engine.name(of: e.from)
                let line = p.status == "Reverting" && existing?.status != "Reverting"
                    ? "↩️ \(who) wants to move “\(p.title)” back to Due — needs approval" : BizSpecs.logLine(p, who: who, isNew: existing == nil)
                system(conv, line, at: e.at)
                if e.from != me && (p.subjectID == me || r.ownerID == me || p.status == "Reverting") {
                    ctx.insert(ActivityItem(kind: .taskUpdated, text: BizSpecs.logLine(p, who: who, isNew: existing == nil), convID: conv.id, actorID: e.from, date: e.at))
                }
            }

        case .invite(let p):
            guard let conv else { return .needsConversation }
            let eid = p.id
            let ev = (try? ctx.fetch(FetchDescriptor<InviteEvent>(predicate: #Predicate { $0.id == eid })).first) ?? {
                let n = InviteEvent(id: eid); n.convID = conv.id; n.hostID = e.from; ctx.insert(n); return n
            }()
            guard ev.hostID == e.from, p.at >= ev.updatedAt else { return .ignored }
            let isNew = ev.title.isEmpty
            ev.title = p.title; ev.place = p.place; ev.start = p.start; ev.end = p.end; ev.notes = p.notes; ev.updatedAt = p.at
            let who = e.from == me ? "You" : engine.name(of: e.from)
            if p.deleted && !ev.deleted {
                ev.deleted = true
                system(conv, "🎉 \(who) cancelled “\(p.title)”", at: e.at)
            } else {
                system(conv, isNew ? "🎉 \(who) invited everyone to “\(p.title)” — \(p.start.formatted(date: .abbreviated, time: .shortened))\(p.place.isEmpty ? "" : " at " + p.place)"
                                   : "🎉 \(who) updated “\(p.title)” — \(p.start.formatted(date: .abbreviated, time: .shortened))", at: e.at)
            }
            EventReminders.update(ev, me: me)

        case .rsvp(let id, let answer):
            guard let conv, let ev = try? ctx.fetch(FetchDescriptor<InviteEvent>(predicate: #Predicate { $0.id == id })).first else { return .ignored }
            var r = ev.rsvps; r[e.from] = answer; ev.rsvps = r
            let who = e.from == me ? "You" : engine.name(of: e.from)
            let word = answer == "going" ? "is going" : answer == "maybe" ? "might come" : "can't come"
            system(conv, "🎉 \(who) \(e.from == me ? (answer == "going" ? "are going" : answer == "maybe" ? "might come" : "can't come") : word) — “\(ev.title)”", at: e.at)
            if e.from == me { EventReminders.update(ev, me: me) }

        case .meeting(let p):
            guard let conv else { return .needsConversation }
            let mid = p.id
            let existing = try? ctx.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == mid })).first
            let m: Meeting
            if let existing {
                guard existing.isAdmin(e.from), p.at >= existing.updatedAt else { return .ignored }
                // Only the creator can cancel / delete a meeting.
                if (p.deleted || p.status == "cancelled") && e.from != existing.createdBy { return .ignored }
                m = existing
            } else {
                m = Meeting(id: p.id); m.convID = conv.id; m.createdBy = e.from; ctx.insert(m)
            }
            let old = (existing?.status, existing?.minutes.isEmpty, existing?.start)
            m.taskID = p.taskID; m.title = p.title; m.online = p.online; m.link = p.link; m.place = p.place
            m.start = p.start; m.end = p.end; m.notes = p.notes; m.minutes = p.minutes; m.status = p.status
            m.agenda = p.agenda; m.expected = p.expected; m.attended = p.attended; m.admins = p.admins
            m.polls = p.polls; m.files = p.files; m.updatedAt = p.at
            let who = e.from == me ? "You" : engine.name(of: e.from)
            var line: String
            if p.deleted && !m.deleted { m.deleted = true; line = "📅 \(who) cancelled the meeting “\(p.title)”" }
            else if existing == nil { line = "📅 \(who) scheduled “\(p.title)” — \(p.start.formatted(date: .abbreviated, time: .shortened)) · \(p.online ? "online" : (p.place.isEmpty ? "in person" : p.place))" }
            else if old.0 != "done" && p.status == "done" { line = "📅 “\(p.title)” marked done by \(who) — \(p.attended.count) attended" }
            else if old.1 == true && !p.minutes.isEmpty { line = "📝 \(who) added the minutes of “\(p.title)”" }
            else if old.2 != p.start { line = "📅 \(who) moved “\(p.title)” to \(p.start.formatted(date: .abbreviated, time: .shortened))" }
            else { line = "📅 \(who) updated the meeting “\(p.title)”" }
            system(conv, line, at: e.at)
            if !p.taskID.isEmpty, let t = engine.task(p.taskID), let tconv = t.convID, tconv != conv.id, let tc = engine.conversation(tconv) {
                system(tc, line, at: e.at)
            }
            MeetingReminders.update(m, me: me)

        case .meetingVote(let mid, let pid, let option):
            guard let conv, let m = try? ctx.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == mid })).first else { return .ignored }
            var v = m.votes; v[pid, default: [:]][e.from] = option; m.votes = v
            if let poll = m.polls.first(where: { $0.id == pid }), option < poll.options.count {
                system(conv, "🗳 \(e.from == me ? "You" : engine.name(of: e.from)) voted “\(poll.options[option])” — \(poll.question)", at: e.at)
            }

        case .meetingAttend(let mid):
            guard let conv, let m = try? ctx.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == mid })).first else { return .ignored }
            if !m.attended.contains(e.from) { m.attended = m.attended + [e.from] }
            system(conv, "✋ \(e.from == me ? "You" : engine.name(of: e.from)) joined “\(m.title)”", at: e.at)

        case .attendance(let p):
            return applyAttendance(p, e, conv: conv, personal: personal)

        case .game(let p):
            return applyGame(p, e, conv: conv)

        case .finance(let p):
            return applyFinance(p, e, conv: conv, personal: personal)

        case .album(let p):
            return applyAlbum(p, e)

        case .survey(let p):
            return applySurvey(p, e, conv: conv, personal: personal)

        case .nowPlaying(let text):
            if e.from != me, let c = engine.contact(e.from), !c.blocked { c.nowPlaying = text; c.nowPlayingAt = e.at }

        case .chatTimer(let seconds):
            guard let conv else { return .ignored }
            conv.timer = seconds
            let who = e.from == me ? "You" : engine.name(of: e.from)
            system(conv, seconds == 0 ? "⏱ \(who) turned off disappearing messages" : "⏱ \(who) turned on disappearing messages — new messages disappear after \(MyDetails.timerName(seconds))", at: e.at)

        case .group, .receipt:
            break
        }
        if !personal { changeLog(e, conv: conv) }
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
            // "Who can add me to groups: My contacts" — strangers' groups wait for Join / Leave.
            if e.from != me, MyDetails.groupsContactsOnly, engine.contact(e.from)?.saved != true {
                c.pendingInvite = true
            }
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
        t.needsAcceptance = p.needsAcceptance ?? false
        if let fu = p.followUp { t.followUpRaw = fu }
        ctx.insert(t)
        if let src = p.sourceMessageID, let m = engine.message(src) { m.taskID = t.id }
        if let convID, let conv = engine.conversation(convID) {
            touch(conv, at: e.at, preview: "📋 \(p.title)", from: e.from)
        }
        if e.from != me && !local && t.involves(me) {
            let text = p.assignees.contains(me)
                ? "\(engine.name(of: e.from)) assigned you “\(p.title)”\(t.needsAcceptance ? " — accept or decline" : "")"
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

    private func gymMember(_ id: String) -> GymMember? {
        try? ctx.fetch(FetchDescriptor<GymMember>(predicate: #Predicate { $0.id == id })).first
    }

    private func gymAlert(_ text: String, conv: Conversation?, from: String, at: Date) {
        ctx.insert(ActivityItem(kind: .gym, text: text, convID: conv?.id, actorID: from, date: at))
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

    // MARK: - Change log
    //
    // Every change to shared work (tasks, approvals' expenses, files, care, gym) is written into the chat it
    // belongs to, so the whole group sees who changed what. When a task is shared between a creator and an
    // assignee, the same line also appears in their one-to-one chat, on both phones.

    private func changeLog(_ e: Event, conv: Conversation?) {
        guard let conv, !conv.id.hasPrefix("s_") else { return }
        let who = e.from == me ? "You" : engine.name(of: e.from)
        var line: String?
        var task: TaskItem?
        switch e.body {
        case .task(let p):
            task = engine.task(p.id)
            line = "📋 \(who) \(p.change ?? "created the task") — “\(p.title)”"
        case .taskDelete(let id):
            task = engine.task(id)
            line = task.map { "🗑 \(who) deleted the task “\($0.title)”" }
        case .checklist(let c):
            task = engine.task(c.taskID)
            // Only ticks are worth a line; adding or renaming steps would flood the chat.
            if !c.deleted && c.done, let t = task { line = "☑︎ \(who) ticked “\(c.title)” in “\(t.title)”" }
        case .taskAccept(let taskID, let accept, let note):
            task = engine.task(taskID)
            if let t = task { line = "\(accept ? "🤝" : "✋") \(who) \(accept ? "accepted" : "declined") the task “\(t.title)”\(note.isEmpty ? "" : " — " + note)" }
        case .comment(let c):
            task = engine.task(c.taskID)
            if let t = task { line = "💬 \(who) on “\(t.title)”: \(c.body.prefix(140))" }
        case .taskPart(let taskID, let done):
            task = engine.task(taskID)
            if let t = task { line = "\(done ? "✅" : "↩︎") \(who) marked their part \(done ? "done" : "not done") — “\(t.title)”" }
        case .taskFile(let f):
            task = engine.task(f.taskID)
            if let t = task { line = f.deleted ? "📎 \(who) removed “\(f.title)” from “\(t.title)”" : "📎 \(who) attached “\(f.title)” to “\(t.title)”" }
        case .expense(let x):
            task = engine.task(x.taskID)
            if let t = task { line = x.deleted ? "🧾 \(who) removed the expense “\(x.title)”" : "🧾 \(who) logged \(Money.format(x.amount)) — \(x.title) (“\(t.title)”)" }
        case .dose(let d):
            if let med = medicine(d.medicineID), let prof = careProfile(d.profileID) {
                line = "💊 \(who) marked \(med.name) \(d.status == "taken" ? "taken" : "skipped") for \(prof.name)"
            }
        case .healthEvent(let h):
            if let prof = careProfile(h.profileID) { line = "🩺 \(who) updated \(prof.name): \(h.title)" }
        case .vault(let v):
            if !v.deleted, let prof = careProfile(v.profileID) { line = "📁 \(who) added “\(v.title)” to \(prof.name)'s vault" }
        case .medicine(let m):
            if let prof = careProfile(m.profileID) { line = "💊 \(who) \(m.deleted ? "removed" : "updated") \(m.name) \(m.dose) for \(prof.name)" }
        case .gymSession(let g):
            if let m = gymMember(g.memberID) { line = "💪 \(who) \(g.deleted ? "removed a session" : "logged a training session") for \(m.name)" }
        case .gymPayment(let g):
            if let m = gymMember(g.memberID) { line = "🧾 \(who) \(g.deleted ? "removed" : "recorded") \(Money.format(g.amount)) for \(m.name)" }
        case .gymPhoto(let g):
            if let m = gymMember(g.memberID) { line = "📸 \(who) \(g.deleted ? "removed a" : "added a") \(g.pose.lowercased()) progress photo for \(m.name)" }
        case .gymPlan(let g):
            if let m = gymMember(g.memberID) { line = "🏢 \(who) \(g.deleted ? "removed" : "updated") \(m.name)'s membership at \(g.gymName)" }
        default:
            break
        }
        guard let line else { return }
        system(conv, line, at: e.at)

        // Mirror task changes into the creator ↔ assignee one-to-one chat (on each phone, for its own side).
        guard let t = task, conv.isGroup else { return }
        let actor = e.from
        let parties: [String] = actor == t.createdBy ? t.assignees : (t.assignees.contains(actor) ? [t.createdBy] : [])
        for p in parties where p != actor {
            let other: String? = me == actor ? p : (me == p ? actor : nil)
            guard let other, let direct = engine.conversation(SyncEngine.directID(me, other)) else { continue }
            system(direct, line + " · in “\(conv.title)”", at: e.at)
        }
    }

    // MARK: - Helpers

    private func touch(_ conv: Conversation, at: Date, preview: String, from: String) {
        guard at >= conv.lastActivity.addingTimeInterval(-1) || conv.lastPreview.isEmpty else { return }
        conv.lastActivity = max(conv.lastActivity, at)
        conv.lastPreview = conv.isGroup && from != me ? "\(engine.name(of: from)): \(preview)" : preview
    }

    func system(_ conv: Conversation, _ text: String, at: Date, gameID: String? = nil) {
        let m = Message(id: UUID().uuidString, convID: conv.id, senderID: "", text: text, createdAt: at, status: .sent, isSystem: true)
        m.gameID = gameID
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
