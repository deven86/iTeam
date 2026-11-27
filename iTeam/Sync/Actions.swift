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
        /// The owner's current QR code (changes when they reset it); "" = none.
        var code: String = ""
        /// True when it came from a scanned or pasted link (then the code must still be current).
        var fromLink = false
        /// Shared by a friend as a recommendation (not the owner's own QR).
        var recommended = false

        var url: URL {
            var c = URLComponents()
            c.scheme = "iteam"
            c.host = "add"
            c.queryItems = [URLQueryItem(name: "u", value: userID),
                            URLQueryItem(name: "k", value: Invite.toURLSafe(publicKey)),
                            URLQueryItem(name: "n", value: name)] + (code.isEmpty ? [] : [URLQueryItem(name: "c", value: code)])
                + (recommended ? [URLQueryItem(name: "r", value: "1")] : [])
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
            code = v("c") ?? ""
            recommended = v("r") == "1"
            fromLink = !recommended
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

    var myInvite: Invite {
        var i = Invite(userID: me, publicKey: myPublicKey, name: myName)
        i.code = UserDefaults.standard.string(forKey: "qr.code") ?? ""
        return i
    }

    /// Shares a contact in a chat, and tells that person they were recommended.
    func recommend(_ c: Contact, in conv: Conversation) {
        var inv = Invite(userID: c.userID, publicKey: c.publicKey, name: c.name)
        inv.recommended = true
        sendText("👤 I recommend \(c.name) — tap to add: \(inv.url.absoluteString)", in: conv)
        sendText("📣 I recommended you to \(conv.title)", in: directConversation(with: c))
    }

    /// Makes old copies of my QR code stop working (e.g. after it was shared too widely).
    func resetMyQRCode() async {
        let code = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(code, forKey: "qr.code")
        await cloud.setQRCode(userID: me, code)
    }

    enum ContactError: LocalizedError {
        case isMe, keyMismatch, qrChanged
        var errorDescription: String? {
            switch self {
            case .isMe: "That's your own code."
            case .keyMismatch: "This code doesn't match the person's current iTeam key. Ask them to show their QR code again."
            case .qrChanged: "This QR code is no longer valid — its owner changed it. Ask them for their new code."
            }
        }
    }

    /// Adds a contact from a scanned or pasted invite. The key in the invite must match their iCloud profile.
    @discardableResult
    func addContact(_ invite: Invite) async throws -> Contact {
        guard invite.userID != me else { throw ContactError.isMe }
        guard let p = try await cloud.fetchProfile(invite.userID) else { throw SyncError.unknownUser }
        guard p.publicKey == invite.publicKey else { throw ContactError.keyMismatch }
        if invite.fromLink, !p.qrCode.isEmpty, p.qrCode != invite.code, contact(invite.userID)?.saved != true { throw ContactError.qrChanged }
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
        // Show the new contact at the top of Chats straight away ("recently added").
        let conv = directConversation(with: c)
        conv.title = c.name
        if conv.lastPreview.isEmpty {
            context.insert(Message(id: UUID().uuidString, convID: conv.id, senderID: "", text: "👋 You added \(c.name) — say hi!", createdAt: .now, status: .sent, isSystem: true))
            conv.lastPreview = "👋 New contact — say hi!"
        }
        conv.lastActivity = .now
        save()
        return c
    }

    func acceptRequest(_ c: Contact) {
        c.saved = true
        c.isRequest = false
        fixDirectTitle(c)
        save()
        Task { await refreshProfile(c) }
    }

    // MARK: - Doctor & Patient

    func sendPrescription(_ p: PrescriptionPayload, in conv: Conversation) {
        send(.prescription(p), in: conv, loud: true, preview: "🩺 New prescription: \(p.items.map(\.name).joined(separator: ", "))")
    }

    /// Patient's answer. Accepting copies each medicine into the chosen Care profile (with reminders).
    func answerPrescription(_ rx: Prescription, accept: Bool, note: String, into profile: CareProfile?) {
        guard let conv = conversation(rx.convID) else { return }
        if accept, let profile {
            for item in rx.items {
                let end = item.days > 0 ? Calendar.current.date(byAdding: .day, value: item.days, to: .now) : nil
                let doc = name(of: rx.doctorID)
                saveMedicine(profile, name: item.name, dose: item.dose, form: item.form, times: item.times,
                             instructions: [item.instructions, "Prescribed by Dr. \(doc)"].filter { !$0.isEmpty }.joined(separator: " · "),
                             startDate: .now, endDate: end, stock: nil)
            }
            rx.careProfileID = profile.id
        }
        send(.rxAnswer(id: rx.id, accept: accept, note: note), in: conv, loud: true,
             preview: accept ? "✅ Prescription accepted" : "✋ Prescription declined")
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
        if Date.now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: key) < 60 { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: key)
        await cloud.touchSeen(userID: me, at: .now)
    }

    func clearLastSeen() async { await cloud.touchSeen(userID: me, at: nil) }

    /// Who is online / last seen, for everyone I have a direct chat with (refreshed at most every 45 s).
    /// Like WhatsApp: you see others' last seen only while you share your own.
    func refreshPresence(force: Bool = false) async {
        guard MyDetails.lastSeenEveryone else { return }
        let key = "presence.fetched"
        if !force && Date.now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: key) < 45 { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: key)
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.kind == "direct" && !$0.left }))) ?? []
        let peers = Array(Set(convs.compactMap(\.peerID).filter { $0 != me && !$0.hasPrefix("demo_") }))
        let seen = await cloud.fetchSeen(Array(peers.prefix(300)))
        for (id, date) in seen { if let c = contact(id), !c.blocked { c.lastSeen = date } }
        save()
    }

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

    /// Every message is encrypted and posted once per member, so groups are capped to keep sending fast and within iCloud's limits.
    static let maxGroupSize = 256

    func createGroup(title: String, members: [Contact], avatar: Data?) -> Conversation {
        let members = Array(members.prefix(Self.maxGroupSize - 1))
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
        let room = max(0, Self.maxGroupSize - conv.members.count)
        let new = Array(people.filter { !conv.isMember($0.userID) }.prefix(room))
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
                  uploads: [String: String] = [:], forwarded: Bool = false, showAt: Date? = nil, viewOnce: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !conv.left else { return }
        // Replying to someone who messaged me first = accepting them as a contact (so they can be added to groups).
        if !conv.isGroup, let peer = Self.peer(inDirect: conv.id, me: me), let c = contact(peer), !c.saved, !c.blocked { acceptRequest(c) }
        let magic = showAt.flatMap { $0 > .now ? $0 : nil }
        let p = MessagePayload(id: UUID().uuidString, text: trimmed, replyTo: replyTo, attachments: attachments, fwd: forwarded ? true : nil,
                               at: magic, ttl: conv.timer > 0 ? conv.timer : nil, once: viewOnce && !attachments.isEmpty ? true : nil)
        let kind = attachments.first?.kind
        let preview = viewOnce ? "👁 View-once \(kind == "video" ? "video" : "photo")" : trimmed.isEmpty ? (kind == "image" ? "📷 Photo" : kind == "audio" ? "🎤 Voice note" : kind == "video" ? "🎬 Video" : "📎 File") : trimmed
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
        /// People not on iTeam ("personID|Name" per line).
        var peopleRaw = ""
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
                            needsAcceptance: d.assignees.contains { $0 != me } && !d.everyone ? true : nil,
                            people: d.peopleRaw.isEmpty ? nil : d.peopleRaw)
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
        case "yearly": component = .year
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
    /// Deletes my iTeam account: public profile, Nearby listing and room memberships in iCloud,
    /// then everything on this device. Messages already delivered stay on the other person's phone.
    func deleteAccount() async {
        let id = me
        try? await cloud.delete(["P" + id])
        await Nearby.shared.remove(userID: id)
        for (roomID, _) in Rooms.shared.joined { if let r = Rooms.shared.room(roomID) { await Rooms.shared.leave(r) } }
        eraseLocalData()
        try? context.delete(model: DocItem.self)
        try? FileManager.default.removeItem(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CaseFiles"))
        for key in ["me.id", "me.name", "me.avatar"] { UserDefaults.standard.removeObject(forKey: key) }
        me = ""; myName = ""; myAvatar = nil
    }

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
                       trainer: String, fee: Double, avatar: Data?, deleted: Bool = false, trainerID: String? = nil) -> String {
        let gid = id ?? "g_" + UUID().uuidString
        let p = GymMemberPayload(id: gid, name: name, relation: relation, phone: phone, goal: goal, trainer: trainer, fee: fee,
                                 avatar: avatar, deleted: deleted, at: .now, trainerID: trainerID)
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

    /// Re-shares a gym record and all its history into another chat (e.g. Notes to self → chat with my trainer).
    func gymMove(_ m: GymMember, to conv: Conversation) {
        let mid = m.id
        send(.gymMember(GymMemberPayload(id: m.id, name: m.name, relation: m.relation, phone: m.phone, goal: m.goal, trainer: m.trainer,
                                         fee: m.feePerSession, avatar: m.avatar, deleted: false, at: .now)), in: conv, loud: false)
        for p in (try? context.fetch(FetchDescriptor<GymPlan>(predicate: #Predicate { $0.memberID == mid && !$0.deleted }))) ?? [] {
            send(.gymPlan(GymPlanPayload(id: p.id, memberID: mid, gymName: p.gymName, branch: p.branch, planName: p.planName, start: p.startDate,
                                         end: p.endDate, fee: p.fee, notes: p.notes, deleted: false, at: .now)), in: conv, loud: false)
        }
        for s in (try? context.fetch(FetchDescriptor<GymSession>(predicate: #Predicate { $0.memberID == mid && !$0.deleted }))) ?? [] {
            send(.gymSession(GymSessionPayload(id: s.id, memberID: mid, date: s.date, trainer: s.trainer, workout: s.workout, notes: s.notes,
                                               deleted: false, at: .now)), in: conv, loud: false)
        }
        for p in (try? context.fetch(FetchDescriptor<GymPayment>(predicate: #Predicate { $0.memberID == mid && !$0.deleted }))) ?? [] {
            send(.gymPayment(GymPaymentPayload(id: p.id, memberID: mid, kind: p.kind, amount: p.amount, date: p.date, method: p.method,
                                               sessions: p.sessions, notes: p.notes, receipts: p.receipts, deleted: false, at: .now)), in: conv, loud: false)
        }
        for ph in (try? context.fetch(FetchDescriptor<GymPhoto>(predicate: #Predicate { $0.memberID == mid && !$0.deleted }))) ?? [] {
            guard let ref = ph.photo else { continue }
            send(.gymPhoto(GymPhotoPayload(id: ph.id, memberID: mid, pose: ph.pose, date: ph.date, photo: ref, note: ph.note, weight: ph.weight,
                                           deleted: false, at: .now)), in: conv, loud: false)
        }
    }

    /// The trainer someone picked accepts or declines.
    func answerTrainer(_ m: GymMember, accept: Bool, note: String) {
        guard let conv = conversation(m.convID) else { return }
        send(.gymTrainerAnswer(memberID: m.id, accept: accept, note: note), in: conv, loud: true,
             preview: accept ? "✅ \(myName) will train \(m.name)" : "✋ \(myName) declined to train \(m.name)")
    }

    func saveGymPhoto(_ m: GymMember, id: String? = nil, pose: String, date: Date, photo: AttachmentRef, note: String, weight: Double,
                      uploads: [String: String] = [:], deleted: Bool = false) {
        guard let conv = conversation(m.convID) else { return }
        let p = GymPhotoPayload(id: id ?? UUID().uuidString, memberID: m.id, pose: pose, date: date, photo: photo, note: note,
                                weight: weight, deleted: deleted, at: .now)
        send(.gymPhoto(p), in: conv, loud: id == nil && !deleted, preview: "📸 \(m.name): \(pose.lowercased()) progress photo", uploads: uploads)
    }

    func careProfile(_ id: String) -> CareProfile? {
        try? context.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { $0.id == id })).first
    }

    private func careConv(_ profileConvID: String) -> Conversation? { conversation(profileConvID) }

    @discardableResult
    func saveCareProfile(in conv: Conversation, id: String? = nil, name: String, relation: String, bloodGroup: String,
                         allergies: String, conditions: String, emergencyContact: String, notes: String, avatar: Data?,
                         linkedUserID: String? = nil, deleted: Bool = false) -> String {
        let pid = id ?? "c_" + UUID().uuidString
        let p = CareProfilePayload(id: pid, name: name, relation: relation, bloodGroup: bloodGroup, allergies: allergies,
                                   conditions: conditions, emergencyContact: emergencyContact, notes: notes, avatar: avatar,
                                   deleted: deleted, at: .now, linkedUserID: linkedUserID)
        send(.care(p), in: conv, loud: id == nil, preview: "❤️ Care profile for \(name)")
        return pid
    }

    /// Moves a care profile (with its medicines, injuries and events) into another chat, e.g. when it gets linked to an iTeam user.
    func moveCareProfile(_ p: CareProfile, to conv: Conversation) {
        guard p.convID != conv.id, p.createdBy == me else { return }
        p.convID = conv.id
        let pid = p.id
        saveCareProfile(in: conv, id: p.id, name: p.name, relation: p.relation, bloodGroup: p.bloodGroup, allergies: p.allergies,
                        conditions: p.conditions, emergencyContact: p.emergencyContact, notes: p.notes, avatar: p.avatar)
        for m in (try? context.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { $0.profileID == pid && !$0.deleted }))) ?? [] {
            saveMedicine(p, id: m.id, name: m.name, dose: m.dose, form: m.form, times: m.times, instructions: m.instructions,
                         startDate: m.startDate, endDate: m.endDate, stock: m.stock, active: m.active, extra: m.extra)
        }
        for e in (try? context.fetch(FetchDescriptor<HealthEvent>(predicate: #Predicate { $0.profileID == pid && !$0.deleted }))) ?? [] {
            saveHealthEvent(p, existing: e, kind: e.kind, title: e.title, details: e.details, date: e.date, severity: e.severity,
                            status: e.status, recovery: e.recovery, attachments: e.attachments, extra: e.extra)
        }
    }

    func saveMedicine(_ profile: CareProfile, id: String? = nil, name: String, dose: String, form: String, times: [Int],
                      instructions: String, startDate: Date, endDate: Date?, stock: Int?, active: Bool = true, deleted: Bool = false,
                      extra: MedExtra? = nil) {
        guard let conv = careConv(profile.convID) else { return }
        let m = MedicinePayload(id: id ?? UUID().uuidString, profileID: profile.id, name: name, dose: dose, form: form, times: times,
                                instructions: instructions, startDate: startDate, endDate: endDate, stock: stock,
                                active: active, deleted: deleted, at: .now, medExtra: extra)
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

    func saveHealthEvent(_ profile: CareProfile, existing: HealthEvent? = nil, id: String? = nil, kind: String, title: String, details: String, date: Date,
                         severity: Int, status: String, recovery: Int, update: String? = nil,
                         attachments: [AttachmentRef] = [], uploads: [String: String] = [:], deleted: Bool = false,
                         extra: HealthExtra? = nil) {
        guard let conv = careConv(profile.convID) else { return }
        let h = HealthEventPayload(id: existing?.id ?? id ?? UUID().uuidString, profileID: profile.id, kind: kind, title: title, details: details,
                                   date: date, severity: severity, status: status, recovery: recovery, update: update,
                                   attachments: attachments, deleted: deleted, at: .now, extra: extra)
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
