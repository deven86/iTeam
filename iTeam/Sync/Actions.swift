import Foundation
import SwiftData
import CryptoKit
import CloudKit

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

    /// Disappearing messages for a chat — applies to everyone in it.
    func setTimer(_ conv: Conversation, _ seconds: Int) {
        guard !conv.isDemo else { conv.timer = seconds; save(); return }
        send(.chatTimer(seconds: seconds), in: conv, loud: false)
    }

    /// Sends my About line to everyone I chat with ("" when hidden).
    func updateAbout() {
        let text = MyDetails.aboutContacts ? MyDetails.about : ""
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.kind == "direct" && !$0.left }))) ?? []
        for c in convs where !c.isDemo && c.peerID != me { send(.about(text), in: c, loud: false) }
    }

    /// Last seen: published on my public profile only when set to Everyone.
    func touchLastSeen() async {
        guard MyDetails.lastSeenEveryone else { return }
        let key = "lastSeen.pushed"
        if Date.now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: key) < 120 { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: key)
        await cloud.touchSeen(userID: me, at: .now)
    }

    func clearLastSeen() async { await cloud.touchSeen(userID: me, at: nil) }

    func setBlocked(_ c: Contact, _ blocked: Bool) {
        c.blocked = blocked
        if blocked { c.isRequest = false }
        save()
        // Take my photo and FaceTime away from a blocked person; give them back on unblock.
        if let conv = conversation(Self.directID(me, c.userID)), !conv.isDemo {
            if MyDetails.photoContactsOnly {
                send(.photo(blocked ? nil : myAvatar.map { ImageShrink.jpeg($0) ?? $0 }), in: conv, loud: false)
            }
            if MyDetails.shareFaceTime { send(.facetime(handle: blocked ? "" : MyDetails.facetime), in: conv, loud: false) }
        }
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
        if MyDetails.shareFaceTime && !MyDetails.facetime.isEmpty && !c.blocked {
            send(.facetime(handle: MyDetails.facetime), in: conv, loud: false)
        }
        if MyDetails.photoContactsOnly, let pic = myAvatar, !c.blocked {
            send(.photo(ImageShrink.jpeg(pic) ?? pic), in: conv, loud: false)
        }
        if MyDetails.aboutContacts, !MyDetails.about.isEmpty, !c.blocked { send(.about(MyDetails.about), in: conv, loud: false) }
        if MyDetails.defaultTimer > 0 { send(.chatTimer(seconds: MyDetails.defaultTimer), in: conv, loud: false) }
        return conv
    }

    /// Shares (or stops sharing) my FaceTime handle with every contact I have a direct chat with.
    func updateFaceTimeSharing() {
        let handle = MyDetails.shareFaceTime ? MyDetails.facetime : ""
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.kind == "direct" && !$0.left }))) ?? []
        for c in convs where !c.isDemo { send(.facetime(handle: handle), in: c, loud: false) }
    }

    /// Profile photo privacy: the public profile carries the photo only when it's for everyone;
    /// otherwise it goes end-to-end encrypted to each contact I chat with (blocked people get nothing).
    func updatePhotoSharing() async {
        let publicPic = MyDetails.photoContactsOnly ? nil : myAvatar
        try? await cloud.saveProfile(userID: me, name: myName, publicKey: myPublicKey, avatar: publicPic)
        let pic = myAvatar.map { ImageShrink.jpeg($0) ?? $0 }
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.kind == "direct" && !$0.left }))) ?? []
        for c in convs where !c.isDemo {
            guard let peer = c.peerID, peer != me, let contact = contact(peer), !contact.blocked else { continue }
            send(.photo(MyDetails.photoContactsOnly ? pic : nil), in: c, loud: false)
        }
    }

    /// Report someone for abuse: blocks them and files a report the app owner can review.
    func report(_ c: Contact, reason: String) {
        setBlocked(c, true)
        let rec = CKRecord(recordType: "RoomReport")
        rec["room"] = "chat"; rec["sndr"] = c.userID; rec["msg"] = ""; rec["reason"] = reason
        Task { _ = try? await cloud.db.save(rec) }
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

    func sendText(_ text: String, in conv: Conversation, replyTo: String? = nil, attachments: [AttachmentRef] = [],
                  uploads: [String: String] = [:], forwarded: Bool = false, showAt: Date? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !conv.left else { return }
        let magic = showAt.flatMap { $0 > .now ? $0 : nil }
        let p = MessagePayload(id: UUID().uuidString, text: trimmed, replyTo: replyTo, attachments: attachments, fwd: forwarded ? true : nil,
                               at: magic, ttl: conv.timer > 0 ? conv.timer : nil)
        let kind = attachments.first?.kind
        let preview = trimmed.isEmpty ? (kind == "image" ? "📷 Photo" : kind == "audio" ? "🎤 Voice note" : kind == "video" ? "🎬 Video" : "📎 File") : trimmed
        // A magic moment travels silently; the recipient's phone reveals it (and notifies) at the chosen time.
        send(.message(p), in: conv, loud: magic == nil, preview: magic == nil ? preview : nil, uploads: uploads)
        if !forwarded { conv.draft = "" }
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
        var repeatRule = "none"
        /// Shared with everyone in the chat (starts at once) rather than assigned to specific people (they accept first).
        var everyone = false
    }

    @discardableResult
    func createTask(_ d: TaskDraft, in conv: Conversation?) -> String {
        let id = UUID().uuidString
        let now = Date.now
        var stamps: [String: Date] = [:]
        for f in TaskItem.sharedFields { stamps[f] = now }
        let p = TaskPayload(id: id, sourceMessageID: d.sourceMessageID, title: d.title, notes: d.notes, status: .open,
                            priority: d.priority, dueAt: d.dueAt, policy: d.policy, assignees: d.assignees,
                            createdBy: me, createdAt: now, completedAt: nil, completedBy: nil, stamps: stamps, change: nil,
                            repeatRule: d.repeatRule,
                            needsAcceptance: d.assignees.contains { $0 != me } && !d.everyone ? true : nil)
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

    /// The assignee's answer to a task assigned to them.
    func respondToTask(_ t: TaskItem, accept: Bool, note: String = "") {
        let body: Event.Body = .taskAccept(taskID: t.id, accept: accept, note: note)
        if let convID = t.convID, let conv = conversation(convID) { send(body, in: conv, loud: true, preview: "\(accept ? "🤝 Accepted" : "✋ Declined"): \(t.title)") }
        save()
        Reminders.shared.reschedule(context: context, me: me)
    }

    func setStatus(_ t: TaskItem, _ status: TaskStatus) {
        let wasDone = t.isDone
        updateTask(t, fields: ["status"], change: status == .done ? "completed" : "moved to \(status.title)", loud: status == .done) {
            $0.status = status
            $0.completedAt = status == .done ? .now : nil
            $0.completedBy = status == .done ? self.me : nil
        }
        if status == .done && !wasDone && t.repeatRule != "none" { spawnNextOccurrence(t) }
    }

    /// Recurring tasks (Pro): when one is finished, the person who finished it creates the next one.
    func spawnNextOccurrence(_ t: TaskItem) {
        let cal = Calendar.current
        let component: Calendar.Component
        switch t.repeatRule {
        case "daily": component = .day
        case "weekly": component = .weekOfYear
        case "monthly": component = .month
        default: return
        }
        let base = t.dueAt ?? .now
        var next = cal.date(byAdding: component, value: 1, to: base) ?? base
        while next < .now { next = cal.date(byAdding: component, value: 1, to: next) ?? .now.addingTimeInterval(86400) }
        let items = ((try? context.fetch(FetchDescriptor<ChecklistItem>())) ?? []).filter { $0.taskID == t.id && !$0.deleted }
            .sorted { $0.position < $1.position }.map(\.title)
        var d = TaskDraft()
        d.title = t.title
        d.notes = t.notes
        d.dueAt = t.dueAt == nil ? nil : next
        d.priority = t.priority
        d.policy = t.policy
        d.assignees = t.assignees
        d.checklist = items
        d.reminderOffset = t.reminderOffset
        d.repeatRule = t.repeatRule
        createTask(d, in: t.convID.flatMap { conversation($0) })
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

    private func send(_ body: Event.Body, taskConv t: TaskItem, loud: Bool, preview: String? = nil, uploads: [String: String] = [:]) {
        if let convID = t.convID, let conv = conversation(convID) {
            send(body, in: conv, loud: loud, preview: preview, uploads: uploads)
        } else {
            send(body, convID: selfConversationID, recipients: [], keyVersion: 0, loud: false, uploads: uploads)
        }
    }

    // MARK: - Task attachments

    func addTaskFile(_ t: TaskItem, kind: String, title: String, attachment: AttachmentRef? = nil, url: String? = nil, uploads: [String: String] = [:]) {
        let f = TaskFilePayload(id: UUID().uuidString, taskID: t.id, kind: kind, attachment: attachment, url: url, title: title, deleted: false)
        send(.taskFile(f), taskConv: t, loud: false, uploads: uploads)
    }

    func removeTaskFile(_ file: TaskFile) {
        guard let t = task(file.taskID) else { return }
        let f = TaskFilePayload(id: file.id, taskID: file.taskID, kind: file.kind, attachment: file.attachment, url: file.url, title: file.title, deleted: true)
        send(.taskFile(f), taskConv: t, loud: false)
    }

    // MARK: - Approvals

    func requestApproval(in conv: Conversation, title: String, details: String, amount: Double?, approvers: [String],
                         taskID: String? = nil, attachments: [AttachmentRef] = [], uploads: [String: String] = [:]) {
        let p = ApprovalPayload(id: UUID().uuidString, messageID: UUID().uuidString, taskID: taskID, title: title, details: details,
                                amount: amount, approvers: approvers, attachments: attachments)
        var preview = "🟡 Approval needed: \(title)"
        if let amount { preview += " · \(Money.format(amount))" }
        send(.approval(p), in: conv, loud: true, preview: preview, uploads: uploads)
    }

    func decide(_ a: Approval, approved: Bool, note: String, amount: Double?) {
        guard let conv = conversation(a.convID) else { return }
        let d = DecisionPayload(approvalID: a.id, approved: approved, note: note.trimmingCharacters(in: .whitespacesAndNewlines), amount: amount)
        var preview = "\(approved ? "✅ Approved" : "❌ Rejected"): \(a.title)"
        if let amount { preview += " · \(Money.format(amount))" }
        if !d.note.isEmpty { preview += " — \(d.note)" }
        send(.decision(d), in: conv, loud: true, preview: preview)
    }

    // MARK: - Expenses

    func saveExpense(_ t: TaskItem, id: String? = nil, title: String, amount: Double, date: Date, paidBy: String,
                     category: String, receipts: [AttachmentRef], uploads: [String: String] = [:]) {
        let x = ExpensePayload(id: id ?? UUID().uuidString, taskID: t.id, title: title, amount: amount, date: date, paidBy: paidBy,
                               category: category, receipts: receipts, deleted: false, at: .now)
        send(.expense(x), taskConv: t, loud: id == nil, preview: "🧾 \(Money.format(amount)) · \(title) (\(t.title))", uploads: uploads)
    }

    func deleteExpense(_ x: Expense) {
        guard let t = task(x.taskID) else { return }
        let p = ExpensePayload(id: x.id, taskID: x.taskID, title: x.title, amount: x.amount, date: x.date, paidBy: x.paidBy,
                               category: x.category, receipts: x.receipts, deleted: true, at: .now)
        send(.expense(p), taskConv: t, loud: false)
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

// MARK: - Polls & iLife Care

extension SyncEngine {

    func createPoll(in conv: Conversation, question: String, options: [String], multiple: Bool) {
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { PollOption(id: UUID().uuidString, text: $0) }
        guard opts.count >= 2 else { return }
        let p = PollPayload(id: UUID().uuidString, messageID: UUID().uuidString, question: question, options: opts, multiple: multiple)
        send(.poll(p), in: conv, loud: true, preview: "📊 \(question)")
    }

    func vote(_ poll: Poll, options: [String]) {
        guard let conv = conversation(poll.convID) else { return }
        send(.vote(VotePayload(pollID: poll.id, optionIDs: options)), in: conv, loud: false)
    }

    // MARK: - Views

    func post(_ id: String) -> Post? {
        try? context.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.id == id })).first
    }

    /// Shares a post or status into each chat of the audience. Files upload once and are reused.
    func publishPost(kind: PostKind, text: String, media: [AttachmentRef], uploads: [String: String], status: Bool, to convs: [Conversation]) {
        guard !convs.isEmpty else { return }
        let p = PostPayload(id: UUID().uuidString, kind: kind.rawValue, text: text, media: media, status: status,
                            expires: status ? Date(timeIntervalSinceNow: 24 * 3600) : nil, deleted: false, at: .now)
        for (i, conv) in convs.enumerated() where !conv.left {
            send(.post(p), in: conv, loud: false, uploads: i == 0 ? uploads : [:])
        }
        if let mine = post(p.id) { mine.convIDs = convs.map(\.id) }
        save()
    }

    func deletePost(_ p: Post) {
        guard p.author == me else { return }
        let payload = PostPayload(id: p.id, kind: p.kind, text: p.text, media: [], status: p.isStatus, expires: p.expiresAt, deleted: true, at: .now)
        for id in p.convIDs { if let c = conversation(id) { send(.post(payload), in: c, loud: false) } }
    }

    /// The chat a reaction or comment goes back through: the one the post arrived in.
    private func replyConvs(_ p: Post) -> [Conversation] {
        let ids = p.author == me ? p.convIDs : Array(p.convIDs.prefix(1))
        return ids.compactMap { conversation($0) }.filter { !$0.left }
    }

    func reactToPost(_ p: Post, emoji: String?) {
        for c in replyConvs(p) { send(.postReact(postID: p.id, emoji: emoji), in: c, loud: false) }
    }

    func commentOnPost(_ p: Post, text: String) {
        let c = PostCommentPayload(id: UUID().uuidString, postID: p.id, text: text, deleted: false)
        for conv in replyConvs(p) { send(.postComment(c), in: conv, loud: p.author != me, preview: "💬 Comment on a post") }
    }

    func markSeen(_ p: Post) {
        guard p.author != me else { return }
        let sid = p.id + "|" + me
        if (try? context.fetch(FetchDescriptor<PostSeen>(predicate: #Predicate { $0.id == sid })).first) != nil { return }
        for c in replyConvs(p) { send(.postSeen(postID: p.id), in: c, loud: false) }
    }

    // MARK: - Gym & Training

    func gymMember(_ id: String) -> GymMember? {
        try? context.fetch(FetchDescriptor<GymMember>(predicate: #Predicate { $0.id == id })).first
    }

    @discardableResult
    func saveGymMember(in conv: Conversation, id: String? = nil, name: String, relation: String, phone: String, goal: String,
                       trainer: String, fee: Double, avatar: Data?, deleted: Bool = false) -> String {
        let gid = id ?? "g_" + UUID().uuidString
        let p = GymMemberPayload(id: gid, name: name, relation: relation, phone: phone, goal: goal, trainer: trainer, fee: fee,
                                 avatar: avatar, deleted: deleted, at: .now)
        send(.gymMember(p), in: conv, loud: id == nil, preview: "🏋️ Gym & Training: \(name)")
        return gid
    }

    func saveGymPlan(_ m: GymMember, id: String? = nil, gymName: String, branch: String, planName: String, start: Date, end: Date,
                     fee: Double, notes: String, deleted: Bool = false) {
        guard let conv = conversation(m.convID) else { return }
        let p = GymPlanPayload(id: id ?? UUID().uuidString, memberID: m.id, gymName: gymName, branch: branch, planName: planName,
                               start: start, end: end, fee: fee, notes: notes, deleted: deleted, at: .now)
        send(.gymPlan(p), in: conv, loud: id == nil, preview: "🏢 \(m.name): \(gymName)")
    }

    func saveGymSession(_ m: GymMember, id: String? = nil, date: Date, trainer: String, workout: String, notes: String, deleted: Bool = false) {
        guard let conv = conversation(m.convID) else { return }
        let p = GymSessionPayload(id: id ?? UUID().uuidString, memberID: m.id, date: date, trainer: trainer, workout: workout,
                                  notes: notes, deleted: deleted, at: .now)
        send(.gymSession(p), in: conv, loud: id == nil, preview: "💪 \(m.name): training session")
    }

    func saveGymPayment(_ m: GymMember, id: String? = nil, kind: GymPaymentKind, amount: Double, date: Date, method: String,
                        sessions: Int, notes: String, receipts: [AttachmentRef], uploads: [String: String] = [:], deleted: Bool = false) {
        guard let conv = conversation(m.convID) else { return }
        let p = GymPaymentPayload(id: id ?? UUID().uuidString, memberID: m.id, kind: kind.rawValue, amount: amount, date: date,
                                  method: method, sessions: sessions, notes: notes, receipts: receipts, deleted: deleted, at: .now)
        send(.gymPayment(p), in: conv, loud: id == nil, preview: "🧾 \(m.name): \(Money.format(amount))", uploads: uploads)
    }

    func careProfile(_ id: String) -> CareProfile? {
        try? context.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { $0.id == id })).first
    }

    private func careConv(_ profileConvID: String) -> Conversation? { conversation(profileConvID) }

    @discardableResult
    func saveCareProfile(in conv: Conversation, id: String? = nil, name: String, relation: String, bloodGroup: String,
                         allergies: String, conditions: String, emergencyContact: String, notes: String, avatar: Data?, deleted: Bool = false) -> String {
        let pid = id ?? "c_" + UUID().uuidString
        let p = CareProfilePayload(id: pid, name: name, relation: relation, bloodGroup: bloodGroup, allergies: allergies,
                                   conditions: conditions, emergencyContact: emergencyContact, notes: notes, avatar: avatar,
                                   deleted: deleted, at: .now)
        send(.care(p), in: conv, loud: id == nil, preview: "❤️ Care profile for \(name)")
        return pid
    }

    func saveMedicine(_ profile: CareProfile, id: String? = nil, name: String, dose: String, form: String, times: [Int],
                      instructions: String, startDate: Date, endDate: Date?, stock: Int?, active: Bool = true, deleted: Bool = false) {
        guard let conv = careConv(profile.convID) else { return }
        let m = MedicinePayload(id: id ?? UUID().uuidString, profileID: profile.id, name: name, dose: dose, form: form, times: times,
                                instructions: instructions, startDate: startDate, endDate: endDate, stock: stock,
                                active: active, deleted: deleted, at: .now)
        send(.medicine(m), in: conv, loud: id == nil, preview: "💊 \(profile.name): \(name) \(dose)")
        Reminders.shared.reschedule(context: context, me: me)
    }

    func logDose(_ med: Medicine, profile: CareProfile, scheduled: Date, taken: Bool, note: String = "") {
        guard let conv = careConv(profile.convID) else { return }
        let d = DosePayload(id: DoseLog.key(med.id, scheduled), medicineID: med.id, profileID: profile.id, scheduled: scheduled,
                            status: taken ? "taken" : "skipped", note: note)
        let time = scheduled.formatted(date: .omitted, time: .shortened)
        send(.dose(d), in: conv, loud: !taken,
             preview: taken ? nil : "⚠️ \(profile.name)'s \(time) \(med.name) was skipped\(note.isEmpty ? "" : ": " + note)")
        if taken, let stock = med.stock, stock > 0 { med.stock = stock - 1 }
        Reminders.shared.reschedule(context: context, me: me)
    }

    func saveHealthEvent(_ profile: CareProfile, existing: HealthEvent? = nil, kind: String, title: String, details: String, date: Date,
                         severity: Int, status: String, recovery: Int, update: String? = nil,
                         attachments: [AttachmentRef] = [], uploads: [String: String] = [:], deleted: Bool = false) {
        guard let conv = careConv(profile.convID) else { return }
        let h = HealthEventPayload(id: existing?.id ?? UUID().uuidString, profileID: profile.id, kind: kind, title: title, details: details,
                                   date: date, severity: severity, status: status, recovery: recovery, update: update,
                                   attachments: attachments, deleted: deleted, at: .now)
        let label = HealthEventKind(rawValue: kind)?.title ?? "Health"
        let preview = existing == nil ? "🚑 \(label) for \(profile.name): \(title)"
            : "\(profile.name) — \(title): \(status == "recovered" ? "recovered ✅" : "\(recovery)% recovered")\(update.map { " · " + $0 } ?? "")"
        send(.healthEvent(h), in: conv, loud: !deleted, preview: preview, uploads: uploads)
    }

    func addVaultItem(_ profile: CareProfile, title: String, category: String, date: Date, attachment: AttachmentRef, uploads: [String: String]) {
        guard let conv = careConv(profile.convID) else { return }
        let v = VaultPayload(id: UUID().uuidString, profileID: profile.id, title: title, category: category, date: date,
                             attachment: attachment, deleted: false)
        send(.vault(v), in: conv, loud: true, preview: "📁 \(profile.name): \(title)", uploads: uploads)
    }

    func removeVaultItem(_ item: VaultItem) {
        guard let profile = careProfile(item.profileID), let conv = careConv(profile.convID) else { return }
        let v = VaultPayload(id: item.id, profileID: item.profileID, title: item.title, category: item.category, date: item.date,
                             attachment: item.attachment, deleted: true)
        send(.vault(v), in: conv, loud: false)
    }
}
