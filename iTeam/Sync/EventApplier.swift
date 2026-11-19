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
        var conv: Conversation? = personal ? nil : engine.conversation(e.conv)

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
