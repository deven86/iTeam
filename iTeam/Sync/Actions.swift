import Foundation
import SwiftData
import CryptoKit

/// Everything the user can do. Each action saves locally first, then queues encrypted events.
extension SyncEngine {

    // MARK: - Contacts

    struct Invite {
        var userID: String
        var publicKey: String
        var name: String

        var url: URL {
            var c = URLComponents()
            c.scheme = "iteam"
            c.host = "add"
            c.queryItems = [URLQueryItem(name: "u", value: userID),
                            URLQueryItem(name: "k", value: Invite.toURLSafe(publicKey)),
                            URLQueryItem(name: "n", value: name)]
            return c.url ?? URL(string: "iteam://add")!
        }

        /// Accepts the iteam:// link or the whole "Add me on iTeam: …" text.
        init?(text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let r = trimmed.range(of: "iteam://add?") else { return nil }
            let link = String(trimmed[r.lowerBound...]).split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
            guard let items = URLComponents(string: link)?.queryItems else { return nil }
            func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
            guard let u = v("u"), let k = v("k"), !u.isEmpty, !k.isEmpty else { return nil }
            userID = u
            publicKey = Invite.fromURLSafe(k)
            name = v("n") ?? "iTeam user"
        }

        init(userID: String, publicKey: String, name: String) {
            self.userID = userID
            self.publicKey = publicKey
            self.name = name
        }

        static func toURLSafe(_ b64: String) -> String {
            b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }

        static func fromURLSafe(_ s: String) -> String {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return b
        }
    }

    var myInvite: Invite { Invite(userID: me, publicKey: myPublicKey, name: myName) }

    enum ContactError: LocalizedError {
        case isMe, keyMismatch
        var errorDescription: String? {
            switch self {
            case .isMe: "That's your own code."
            case .keyMismatch: "This code doesn't match the person's current iTeam key. Ask them to show their QR code again."
            }
        }
    }

    /// Adds a contact from a scanned or pasted invite. The key in the invite must match their iCloud profile.
    @discardableResult
    func addContact(_ invite: Invite) async throws -> Contact {
        guard invite.userID != me else { throw ContactError.isMe }
        guard let p = try await cloud.fetchProfile(invite.userID) else { throw SyncError.unknownUser }
        guard p.publicKey == invite.publicKey else { throw ContactError.keyMismatch }
        let c: Contact
        if let existing = contact(invite.userID) {
            c = existing
            c.name = p.name
            c.publicKey = p.publicKey
            c.avatar = p.avatar
        } else {
            c = Contact(userID: p.userID, name: p.name, publicKey: p.publicKey, avatar: p.avatar, saved: true)
            context.insert(c)
        }
        c.saved = true
        c.isRequest = false
        c.verified = true
        c.blocked = false
        if let conv = conversation(Self.directID(me, c.userID)) { conv.title = c.name }
        save()
        return c
    }

    func acceptRequest(_ c: Contact) {
        c.saved = true
        c.isRequest = false
        save()
    }

    func setBlocked(_ c: Contact, _ blocked: Bool) {
        c.blocked = blocked
        if blocked { c.isRequest = false }
        save()
    }

    // MARK: - Conversations

    func directConversation(with c: Contact) -> Conversation {
        let id = Self.directID(me, c.userID)
        if let conv = conversation(id) { return conv }
        let conv = Conversation(id: id, kind: "direct", title: c.name, ownerID: me, peerID: c.userID,
                                members: [MemberInfo(id: me, name: myName, role: .member),
                                          MemberInfo(id: c.userID, name: c.name, role: .member)])
        context.insert(conv)
        save()
        return conv
    }

    func createGroup(title: String, members: [Contact], avatar: Data?) -> Conversation {
        let id = "g_" + UUID().uuidString
        let key = E2E.newConversationKey()
        E2E.storeConversationKey(key, conv: id, version: 1)
        let infos = [MemberInfo(id: me, name: myName, role: .owner)] + members.map { MemberInfo(id: $0.userID, name: $0.name, role: .member) }
        shareKey(key, conv: id, version: 1, with: infos.map(\.id))
        let payload = GroupPayload(title: title, members: infos, avatar: avatar, keyVersion: 1)
        let hint = NotificationHint(n: myName, t: title, b: "\(myName) added you to “\(title)”")
        send(.group(payload), convID: id, recipients: infos.map(\.id), keyVersion: 1, loud: true, hint: hint)
        return conversation(id) ?? Conversation(id: id, kind: "group", title: title, ownerID: me, members: infos)
    }

    func updateGroup(_ conv: Conversation, title: String? = nil, avatar: Data? = nil, members: [MemberInfo]? = nil, note: String? = nil) {
        let payload = GroupPayload(title: title ?? conv.title, members: members ?? conv.members, avatar: avatar ?? conv.avatar, keyVersion: conv.keyVersion)
        let everyone = Array(Set(conv.members.map(\.id) + (members ?? []).map(\.id)))
        let hint = note.map { NotificationHint(n: myName, t: payload.title, b: $0) }
        send(.group(payload), convID: conv.id, recipients: everyone, keyVersion: conv.keyVersion, loud: note != nil, hint: hint)
    }

    func addMembers(_ conv: Conversation, _ people: [Contact]) {
        let new = people.filter { !conv.isMember($0.userID) }
        guard !new.isEmpty, let key = E2E.conversationKey(conv: conv.id, version: conv.keyVersion) else { return }
        shareKey(key, conv: conv.id, version: conv.keyVersion, with: new.map(\.userID))
        let members = conv.members + new.map { MemberInfo(id: $0.userID, name: $0.name, role: .member) }
        updateGroup(conv, members: members, note: "\(myName) added \(new.map(\.name).joined(separator: ", "))")
    }

    /// Removes someone and rotates the group key, so they can't read anything sent afterwards.
    func removeMember(_ conv: Conversation, _ userID: String) {
        guard userID != conv.ownerID else { return }
        let oldVersion = conv.keyVersion
        let oldMembers = conv.members
        let remaining = oldMembers.filter { $0.id != userID }
        let newVersion = oldVersion + 1
        let key = E2E.newConversationKey()
        E2E.storeConversationKey(key, conv: conv.id, version: newVersion)
        shareKey(key, conv: conv.id, version: newVersion, with: remaining.map(\.id))
        let payload = GroupPayload(title: conv.title, members: remaining, avatar: conv.avatar, keyVersion: newVersion)
        // Sent with the old key so the removed person also learns they were removed.
        send(.group(payload), convID: conv.id, recipients: oldMembers.map(\.id), keyVersion: oldVersion, loud: false)
    }

    func setRole(_ conv: Conversation, _ userID: String, _ role: Role) {
        guard userID != conv.ownerID, role != .owner else { return }
        let members = conv.members.map { m -> MemberInfo in
            var m = m
            if m.id == userID { m.role = role }
            return m
        }
        updateGroup(conv, members: members)
    }

    func leave(_ conv: Conversation) {
        guard conv.isGroup, !conv.left else { return }
        send(.leave, in: conv, loud: false)
        conv.left = true
        save()
    }

    func setMuted(_ conv: Conversation, _ muted: Bool) {
        conv.muted = muted
        var set = AppGroup.mutedConversations
        if muted { set.insert(conv.id) } else { set.remove(conv.id) }
        AppGroup.mutedConversations = set
        save()
    }

    /// Removes the chat from this device only.
    func deleteLocally(_ conv: Conversation) {
        let id = conv.id
        for m in (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.convID == id }))) ?? [] { context.delete(m) }
        context.delete(conv)
        save()
    }

    // MARK: - Messages

    func sendText(_ text: String, in conv: Conversation, replyTo: String? = nil, attachments: [AttachmentRef] = [], uploads: [String: String] = [:]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !conv.left else { return }
        let p = MessagePayload(id: UUID().uuidString, text: trimmed, replyTo: replyTo, attachments: attachments)
        let preview = trimmed.isEmpty ? (attachments.first?.kind == "image" ? "📷 Photo" : "📎 File") : trimmed
        send(.message(p), in: conv, loud: true, preview: preview, uploads: uploads)
        conv.draft = ""
    }

    func edit(_ m: Message, text: String) {
        guard let conv = conversation(m.convID), m.senderID == me else { return }
        send(.edit(id: m.id, text: text), in: conv, loud: false)
    }

    func unsend(_ m: Message) {
        guard let conv = conversation(m.convID), m.senderID == me else { return }
        send(.unsend(id: m.id), in: conv, loud: false)
    }

    func react(_ m: Message, _ emoji: String?) {
        guard let conv = conversation(m.convID) else { return }
        let current = m.reactions[me]
        let value = current == emoji ? nil : emoji
        send(.react(id: m.id, emoji: value), in: conv, loud: false)
    }

    // MARK: - Tasks

    struct TaskDraft {
        var title = ""
        var notes = ""
        var dueAt: Date?
        var priority: WorkPriority = .normal
        var policy: CompletionPolicy = .any
        var assignees: [String] = []
        var checklist: [String] = []
        var sourceMessageID: String?
        var reminderOffset = 60
    }

    @discardableResult
    func createTask(_ d: TaskDraft, in conv: Conversation?) -> String {
        let id = UUID().uuidString
        let now = Date.now
        var stamps: [String: Date] = [:]
        for f in TaskItem.sharedFields { stamps[f] = now }
        let p = TaskPayload(id: id, sourceMessageID: d.sourceMessageID, title: d.title, notes: d.notes, status: .open,
                            priority: d.priority, dueAt: d.dueAt, policy: d.policy, assignees: d.assignees,
                            createdBy: me, createdAt: now, completedAt: nil, completedBy: nil, stamps: stamps, change: nil)
        if let conv {
            let who = d.assignees.isEmpty ? "the group" : d.assignees.map { name(of: $0) }.joined(separator: ", ")
            send(.task(p), in: conv, loud: true, preview: "📋 New task for \(who): \(d.title)")
        } else {
            sendPersonal(.task(p))
        }
        task(id)?.reminderOffset = d.reminderOffset
        for (i, title) in d.checklist.enumerated() where !title.trimmingCharacters(in: .whitespaces).isEmpty {
            addChecklistItem(title, to: id, position: Double(i))
        }
        save()
        return id
    }

    /// Changes shared fields of a task and sends the new values.
    func updateTask(_ t: TaskItem, fields: [String], change: String, loud: Bool = false, _ mutate: (TaskItem) -> Void) {
        mutate(t)
        var st = t.stamps
        let now = Date.now
        for f in fields { st[f] = now }
        t.stamps = st
        t.updatedAt = now
        var p = t.payload
        p.change = change
        if let convID = t.convID, let conv = conversation(convID) {
            send(.task(p), in: conv, loud: loud, preview: loud ? "📋 \(t.title): \(change)" : nil)
        } else {
            sendPersonal(.task(p))
        }
    }

    func setStatus(_ t: TaskItem, _ status: TaskStatus) {
        updateTask(t, fields: ["status"], change: status == .done ? "completed" : "moved to \(status.title)", loud: status == .done) {
            $0.status = status
            $0.completedAt = status == .done ? .now : nil
            $0.completedBy = status == .done ? self.me : nil
        }
    }

    func reopen(_ t: TaskItem, reason: String) {
        updateTask(t, fields: ["status"], change: "reopened", loud: true) {
            $0.status = .open
            $0.completedAt = nil
            $0.completedBy = nil
        }
        if !reason.isEmpty { addComment("Reopened: \(reason)", to: t) }
    }

    /// For "everyone must finish" tasks: mark my own part.
    func setMyPart(_ t: TaskItem, done: Bool) {
        send(.taskPart(taskID: t.id, done: done), taskConv: t, loud: false)
    }

    func deleteTask(_ t: TaskItem) {
        send(.taskDelete(id: t.id), taskConv: t, loud: false)
    }

    func addChecklistItem(_ title: String, to taskID: String, position: Double) {
        guard let t = task(taskID) else { return }
        let c = ChecklistPayload(id: UUID().uuidString, taskID: taskID, title: title, done: false, position: position, deleted: false, at: .now)
        send(.checklist(c), taskConv: t, loud: false)
    }

    func updateChecklistItem(_ item: ChecklistItem, title: String? = nil, done: Bool? = nil, deleted: Bool = false) {
        guard let t = task(item.taskID) else { return }
        let c = ChecklistPayload(id: item.id, taskID: item.taskID, title: title ?? item.title, done: done ?? item.done,
                                 position: item.position, deleted: deleted, at: .now)
        send(.checklist(c), taskConv: t, loud: false)
    }

    func addComment(_ body: String, to t: TaskItem) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let c = CommentPayload(id: UUID().uuidString, taskID: t.id, body: text)
        send(.comment(c), taskConv: t, loud: true, preview: "💬 \(t.title): \(text)")
    }

    private func send(_ body: Event.Body, taskConv t: TaskItem, loud: Bool, preview: String? = nil) {
        if let convID = t.convID, let conv = conversation(convID) {
            send(body, in: conv, loud: loud, preview: preview)
        } else {
            sendPersonal(body)
        }
    }

    // MARK: - Reset

    /// Deletes everything on this device (iCloud copies expire on their own).
    func eraseLocalData() {
        try? context.delete(model: Message.self)
        try? context.delete(model: Conversation.self)
        try? context.delete(model: Contact.self)
        try? context.delete(model: TaskItem.self)
        try? context.delete(model: ChecklistItem.self)
        try? context.delete(model: TaskComment.self)
        try? context.delete(model: ActivityItem.self)
        try? context.delete(model: OutboxItem.self)
        try? context.delete(model: PendingEnvelope.self)
        try? context.delete(model: SentRecord.self)
        save()
        for key in ["sync.lastFetch", "sync.processed", "sync.lastCleanup"] { UserDefaults.standard.removeObject(forKey: key) }
    }
}

extension SyncEngine.Invite: Identifiable {
    var id: String { userID }
}
