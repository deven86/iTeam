import Foundation
import SwiftData
import CloudKit
import CryptoKit
import Network
import UIKit

/// Moves encrypted events between this device and CloudKit.
///
/// 1. Every action is saved locally first (the UI never waits for the network).
/// 2. It becomes an `OutboxItem` and is uploaded as one encrypted envelope per recipient
///    (plus one to myself, so my iPad gets it too).
/// 3. Recipients fetch envelopes addressed to them, decrypt, and apply the event.
/// Nothing in the outbox is ever discarded silently.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    enum Status: Equatable {
        case idle, syncing, offline, noAccount
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Synced"
            case .syncing: "Syncing…"
            case .offline: "Offline — changes are saved on this device"
            case .noAccount: "Sign in to iCloud to sync"
            case .failed(let m): "Sync failed — \(m)"
            }
        }
    }

    enum SyncError: LocalizedError {
        case noKey, notSetUp, unknownUser
        var errorDescription: String? {
            switch self {
            case .noKey: "The encryption key for this chat isn't on this device yet"
            case .notSetUp: "Finish setting up iTeam first"
            case .unknownUser: "That person isn't on iTeam (no profile found)"
            }
        }
    }

    @Published var status: Status = .idle
    /// Set when a professional module is read-only after the free year (shows the subscribe alert).
    @Published var lockedModule: ModuleInfo?
    @Published var lastSync: Date? = UserDefaults.standard.object(forKey: "sync.lastSuccess") as? Date
    @Published var pendingUploads = 0
    /// Why background message notifications aren't set up (nil = working).
    @Published var pushProblem: String?
    @Published var failedUploads = 0
    @Published private(set) var isOnline = true
    @Published var me: String = UserDefaults.standard.string(forKey: "me.id") ?? ""
    @Published var myName: String = UserDefaults.standard.string(forKey: "me.name") ?? ""
    @Published var myAvatar: Data? = UserDefaults.standard.data(forKey: "me.avatar")
    /// The chat open on screen (no unread count, no banner for it).
    @Published var openConversation: String? {
        didSet { AppGroup.defaults.set(openConversation, forKey: AppGroup.openConversationKey) }
    }

    private(set) var context: ModelContext!
    let cloud = CloudService.shared
    private let monitor = NWPathMonitor()
    private var running = false
    private var again = false
    private var pendingReceipts: [String: (delivered: Date?, read: Date?)] = [:]
    private var timer: Timer?
    private var subscriptionsChecked = false
    private var profileChecked = false

    /// Envelopes and files are deleted from iCloud after this many days.
    static let retentionDays = 45

    var isSetUp: Bool { !me.isEmpty && E2E.identity != nil && !myName.isEmpty }
    var myPublicKey: String { E2E.identity.map(E2E.publicKeyString) ?? "" }

    private init() {}

    func attach(_ container: ModelContainer) {
        context = container.mainContext
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                if !online { self.status = .offline }
                if online && wasOffline { await self.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "iteam.network"))
        refreshCounts()
    }

    /// Fetch every 20 s while the app is open, so chats feel live even if a push is late.
    func setForeground(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in await SyncEngine.shared.sync() }
        }
    }

    func saveIdentity(id: String, name: String, avatar: Data?) {
        me = id
        myName = name
        myAvatar = avatar
        UserDefaults.standard.set(id, forKey: "me.id")
        UserDefaults.standard.set(name, forKey: "me.name")
        UserDefaults.standard.set(avatar, forKey: "me.avatar")
    }

    // MARK: - Sync loop

    func sync() async {
        guard isSetUp, context != nil, !ScreenshotMode.on else { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        prunePunchPhotos()
        repeat {
            again = false
            status = .syncing
            do {
                if !profileChecked {
                    // Make sure my public profile exists in this iCloud environment (e.g. after switching environments).
                    let remote = try await cloud.fetchProfile(me)
                    if remote == nil || remote?.publicKey != myPublicKey || remote?.name != myName {
                        try await cloud.saveProfile(userID: me, name: myName, publicKey: myPublicKey, avatar: MyDetails.photoContactsOnly ? nil : myAvatar)
                    }
                    profileChecked = true
                }
                // Contacts' names and photos, refreshed from their iCloud profiles twice a day.
                let lastPics = UserDefaults.standard.double(forKey: "contacts.refreshedAt")
                if Date.now.timeIntervalSince1970 - lastPics > 12 * 3600, let ctx = context {
                    UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "contacts.refreshedAt")
                    let saved = (try? ctx.fetch(FetchDescriptor<Contact>(predicate: #Predicate { $0.saved || $0.isRequest }))) ?? []
                    for c in saved.prefix(100) where !c.userID.hasPrefix("demo_") { await refreshProfile(c) }
                }
                await repairNamelessChats()
                if !UserDefaults.standard.bool(forKey: "photoShare.v1") {
                    UserDefaults.standard.set(true, forKey: "photoShare.v1")
                    await updatePhotoSharing()
                }
                if !subscriptionsChecked {
                    // Push setup must never block syncing: messages still flow without it.
                    do {
                        try await cloud.ensureSubscriptions(for: me)
                        subscriptionsChecked = true
                        pushProblem = nil
                    } catch {
                        pushProblem = error.cloudMessage
                    }
                }
                // New messages first, so a big upload (a video) never holds back what others sent me.
                try await receive()
                try await flush()
                try await receive()
                try await sendReceipts()
                await cleanupIfDue()
                MagicMoments.tick(self)
                await touchLastSeen()
                let plus = Store.shared.hasPlus
                if UserDefaults.standard.object(forKey: "plus.published") as? Bool != plus {
                    await cloud.setPlus(userID: me, plus)
                    UserDefaults.standard.set(plus, forKey: "plus.published")
                }
                status = .idle
                lastSync = .now
                UserDefaults.standard.set(lastSync, forKey: "sync.lastSuccess")
            } catch {
                if let ck = error as? CKError, ck.code == .notAuthenticated {
                    status = .noAccount
                } else if !isOnline || (error as? CKError)?.code == .networkUnavailable {
                    status = .offline
                } else {
                    status = .failed(error.cloudMessage)
                }
            }
        } while again
        save()
        refreshCounts()
        Reminders.shared.reschedule(context: context, me: me)
        // Business Autopilot answers new client questions while iTeam is open.
        if timer != nil && Autopilot.shared.on { Task { await Autopilot.shared.run(self) } }
    }

    /// A direct chat always shows the person's current name (never the "Chat" placeholder).
    func fixDirectTitle(_ c: Contact) {
        guard !c.name.isEmpty, let conv = conversation(Self.directID(me, c.userID)) else { return }
        if conv.title != c.name { conv.title = c.name }
        var ms = conv.members
        if let i = ms.firstIndex(where: { $0.id == c.userID }), ms[i].name != c.name { ms[i].name = c.name; conv.members = ms }
    }

    /// Chats still named "Chat" (the sender's name wasn't known yet): fetch the profile and fix them.
    func repairNamelessChats() async {
        guard let ctx = context else { return }
        let convs = (try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.kind == "direct" }))) ?? []
        for conv in convs where conv.title == "Chat" || conv.title.isEmpty {
            guard let peer = Self.peer(inDirect: conv.id, me: me), peer != me else { continue }
            if let c = try? await ensureContact(peer, asRequest: true) { await refreshProfile(c) }
        }
        save()
    }

    func refreshCounts() {
        guard let context else { return }
        let items = (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
        pendingUploads = items.count
        failedUploads = items.filter { $0.attempts >= 5 }.count
    }

    func save() { try? context?.save() }

    // MARK: - Sending

    /// Saves an event locally, applies it, and queues it for upload.
    @discardableResult
    func send(_ body: Event.Body, convID: String, recipients: [String], keyVersion: Int, loud: Bool,
              hint: NotificationHint? = nil, uploads: [String: String] = [:]) -> Event {
        let event = Event(id: UUID().uuidString, conv: convID, from: me, at: .now, body: body)
        _ = EventApplier(engine: self).apply(event, local: true)
        var to = recipients.filter { $0 != me }
        to.append(me)   // echo to my other devices
        let item = OutboxItem(id: event.id, convID: convID, recipients: to, payload: Packed.encode(event),
                              kind: "event", keyVersion: keyVersion, loud: loud, hint: hint)
        item.uploads = uploads
        context.insert(item)
        save()
        refreshCounts()
        // Fast path: upload this right away (in parallel), without waiting for the full sync round (inbox, profiles…).
        Task { await quickFlush(); await sync() }
        return event
    }

    /// Outbox items being uploaded right now (so the normal flush never sends one twice).
    private var inFlight = Set<String>()

    /// Sends what's waiting in the outbox immediately, up to 4 at a time.
    func quickFlush() async {
        guard isSetUp, context != nil, !ScreenshotMode.on else { return }
        let items = ((try? context.fetch(FetchDescriptor<OutboxItem>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { $0.attempts == 0 && !inFlight.contains($0.id) }
        guard !items.isEmpty else { return }
        for batch in stride(from: 0, to: items.count, by: 4).map({ Array(items[$0..<min($0 + 4, items.count)]) }) {
            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    let id = item.id
                    inFlight.insert(id)
                    group.addTask { @MainActor in
                        defer { self.inFlight.remove(id) }
                        guard let live = try? self.context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })).first else { return }
                        do {
                            try await self.upload(live)
                            self.markSent(live)
                            self.context.delete(live)
                        } catch {
                            live.attempts += 1
                            live.lastError = error.cloudMessage
                        }
                    }
                }
            }
            save()
        }
        refreshCounts()
    }

    /// Sends an event to everyone in a conversation.
    @discardableResult
    func send(_ body: Event.Body, in conv: Conversation, loud: Bool, preview: String? = nil, uploads: [String: String] = [:]) -> Event {
        // Free year over and not subscribed: keep the data readable, but don't create or change professional records.
        // Personal use (Notes to self) is never locked.
        if conv.id != selfConversationID, !conv.isDemo, let locked = paidLock(body) {
            lockedModule = locked
            return Event(id: UUID().uuidString, conv: conv.id, from: me, at: .now, body: body)
        }
        if loud { Haptics.big() }
        if conv.isDemo { return DemoChats.localSend(body, in: conv, engine: self) }
        let route = NotifyRoute.of(body)
        let hint = preview.map { NotificationHint(n: myName, t: conv.isGroup ? conv.title : nil, b: String($0.prefix(160)), k: route.0, l: route.1) }
        return send(body, convID: conv.id, recipients: conv.members.map(\.id), keyVersion: conv.keyVersion,
                    loud: loud, hint: hint, uploads: uploads)
    }

    /// Personal data (tasks without a chat): only echoed to my own devices.
    @discardableResult
    func sendPersonal(_ body: Event.Body) -> Event {
        send(body, convID: selfConversationID, recipients: [], keyVersion: 0, loud: false)
    }

    var selfConversationID: String { "s_" + me }

    /// Queues a group key for the given members (and my other devices).
    func shareKey(_ key: SymmetricKey, conv: String, version: Int, with members: [String]) {
        var to = members.filter { $0 != me }
        to.append(me)
        let item = OutboxItem(id: UUID().uuidString, convID: conv, recipients: to, payload: E2E.keyData(key),
                              kind: "key", keyVersion: version, loud: false, hint: nil)
        context.insert(item)
    }

    func retryFailed() {
        let items = (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
        for i in items { i.attempts = 0 }
        save()
        Task { await sync() }
    }

    private func flush() async throws {
        let items = try context.fetch(FetchDescriptor<OutboxItem>(sortBy: [SortDescriptor(\.createdAt)]))
        for item in items where item.attempts < 5 && !inFlight.contains(item.id) {
            // A chat whose key never arrived (deleted/unknown chat): drop it after a day so it can't sit in the queue forever.
            if item.lastError == SyncError.noKey.errorDescription, item.createdAt < .now.addingTimeInterval(-86400), conversation(item.convID) == nil {
                context.delete(item); save(); continue
            }
            inFlight.insert(item.id)
            defer { inFlight.remove(item.id) }
            do {
                try await upload(item)
                markSent(item)
                context.delete(item)
                save()
            } catch {
                item.attempts += 1
                item.lastError = error.cloudMessage
                save()
                if error.isTransientCloudError { throw error }
                if item.attempts >= 5 { markFailed(item) }
            }
        }
    }

    private func upload(_ item: OutboxItem) async throws {
        var records: [CKRecord] = []
        for (blobID, file) in item.uploads {
            let url = Attachments.outgoingURL(file)
            if FileManager.default.fileExists(atPath: url.path) {
                records.append(cloud.makeBlob(id: blobID, fileURL: url))
            }
        }
        if item.kind == "event" {
            guard let key = try await key(for: item.convID, version: item.keyVersion, sender: me) else { throw SyncError.noKey }
            let body = try E2E.sealVersioned(item.payload, key: key, version: item.keyVersion)
            var hint: String?
            if item.loud, let h = item.hintData {
                hint = try E2E.sealVersioned(h, key: key, version: item.keyVersion).base64EncodedString()
            }
            for r in item.recipients {
                let toMe = r == me
                records.append(cloud.makeEnvelope(to: r, from: me, conv: item.convID, kind: 0,
                                                  loud: item.loud && !toMe, body: body, hint: toMe ? nil : hint))
            }
        } else {
            let share = KeyShare(conv: item.convID, version: item.keyVersion, key: item.payload)
            let plain = Packed.encode(share)
            for r in item.recipients {
                let pub: String
                if r == me { pub = myPublicKey } else { pub = try await ensureContact(r, asRequest: false).publicKey }
                let pk = try E2E.pairwiseKey(theirPublicKey: pub, context: "key:" + item.convID)
                let body = try E2E.sealVersioned(plain, key: pk, version: 0)
                records.append(cloud.makeEnvelope(to: r, from: me, conv: item.convID, kind: 1, loud: false, body: body, hint: nil))
            }
        }
        // Speed: deliver the message (with its small preview) first, then the full file.
        // The other person sees it instantly; the full photo/document downloads when they tap it.
        // (Android contacts get both together, because their files travel through the relay.)
        let blobs = records.filter { $0.recordType == "Blob" }
        let split = !blobs.isEmpty && !item.recipients.contains(where: RelayClient.isRelayID)
        let first = split ? records.filter { $0.recordType != "Blob" } : records
        let failed = try await cloud.save(first)
        if let e = failed.values.first { throw e }
        for r in first { context.insert(SentRecord(recordName: r.recordID.recordName)) }
        if split {
            let bf = try await cloud.save(blobs)
            if let e = bf.values.first { throw e }
        }
        for (_, file) in item.uploads { try? FileManager.default.removeItem(at: Attachments.outgoingURL(file)) }
    }

    private func messageID(of item: OutboxItem) -> String? {
        guard item.kind == "event", let ev = Packed.decode(Event.self, item.payload) else { return nil }
        if case .message(let p) = ev.body { return p.id }
        if case .approval(let p) = ev.body { return p.messageID }
        if case .poll(let p) = ev.body { return p.messageID }
        return nil
    }

    private func markSent(_ item: OutboxItem) {
        guard let id = messageID(of: item), let m = message(id) else { return }
        m.status = .sent
    }

    private func markFailed(_ item: OutboxItem) {
        guard let id = messageID(of: item), let m = message(id) else { return }
        m.status = .failed
    }

    // MARK: - Receiving

    private var lastFetch: Date {
        get { UserDefaults.standard.object(forKey: "sync.lastFetch") as? Date ?? Date(timeIntervalSinceNow: -Double(Self.retentionDays) * 86400) }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastFetch") }
    }

    private var processed: [String] {
        get { UserDefaults.standard.stringArray(forKey: "sync.processed") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(3000)), forKey: "sync.processed") }
    }

    private func receive() async throws {
        let incoming = try await cloud.inbox(for: me, since: lastFetch.addingTimeInterval(-10))
        var seen = Set(processed)
        var newlySeen: [String] = []
        // Key shares first, so messages in the same batch can be read.
        let ordered = incoming.filter { $0.kind == 1 } + incoming.filter { $0.kind != 1 }
        for inc in ordered where !seen.contains(inc.recordName) {
            await handle(inc)
            seen.insert(inc.recordName)
            newlySeen.append(inc.recordName)
        }
        if !newlySeen.isEmpty { processed = processed + newlySeen }
        if let newest = incoming.map(\.created).max(), newest > lastFetch { lastFetch = newest }
        await retryPending()
        save()
    }

    private func handle(_ inc: CloudService.Incoming) async {
        // CloudKit tells us who really created the record; a forged "from" is dropped.
        guard !inc.creator.isEmpty, inc.creator == inc.from else { return }
        if inc.from != me, let c = contact(inc.from), c.blocked { return }
        let ok = await process(conv: inc.conv, from: inc.from, kind: inc.kind, body: inc.body)
        if !ok { park(inc) }
    }

    /// Returns false when the envelope can't be used yet (missing key or conversation).
    private func process(conv: String, from: String, kind: Int, body: Data) async -> Bool {
        guard let parts = E2E.splitVersioned(body) else { return true }
        if kind == 1 {
            do {
                let pub: String
                if from == me { pub = myPublicKey } else { pub = try await ensureContact(from, asRequest: false).publicKey }
                let pk = try E2E.pairwiseKey(theirPublicKey: pub, context: "key:" + conv)
                let share = try JSONDecoder().decode(KeyShare.self, from: E2E.open(parts.1, key: pk))
                guard share.conv == conv else { return true }
                E2E.storeConversationKey(SymmetricKey(data: share.key), conv: conv, version: share.version)
                if let c = conversation(conv), share.version > c.keyVersion { c.keyVersion = share.version }
                return true
            } catch {
                return !(error.isTransientCloudError)
            }
        }
        do {
            guard let key = try await key(for: conv, version: parts.0, sender: from) else { return false }
            guard let plain = try? E2E.open(parts.1, key: key) else { return false }
            guard var event = try? JSONDecoder().decode(Event.self, from: plain) else { return true }
            event.from = from
            event.conv = conv
            switch EventApplier(engine: self).apply(event, local: false) {
            case .needsConversation: return false
            case .applied, .ignored: break
            }
            if from != me, case .message = event.body {
                var r = pendingReceipts[conv] ?? (delivered: nil, read: nil)
                r.delivered = max(r.delivered ?? .distantPast, event.at)
                if openConversation == conv { r.read = max(r.read ?? .distantPast, event.at) }
                pendingReceipts[conv] = r
            }
            return true
        } catch {
            return false
        }
    }

    private func park(_ inc: CloudService.Incoming) {
        let name = inc.recordName
        let existing = (try? context.fetch(FetchDescriptor<PendingEnvelope>(predicate: #Predicate { $0.recordName == name }))) ?? []
        guard existing.isEmpty else { return }
        context.insert(PendingEnvelope(recordName: name, conv: inc.conv, from: inc.from, kind: inc.kind, body: inc.body))
    }

    private func retryPending() async {
        let items = (try? context.fetch(FetchDescriptor<PendingEnvelope>(sortBy: [SortDescriptor(\.receivedAt)]))) ?? []
        guard !items.isEmpty else { return }
        // Keys first, then the rest, twice (a key may unlock a group event that creates the conversation).
        for _ in 0..<2 {
            for p in items.sorted(by: { $0.kind > $1.kind }) where !p.isDeleted {
                if await process(conv: p.conv, from: p.from, kind: p.kind, body: p.body) {
                    context.delete(p)
                } else {
                    p.tries += 1
                }
            }
        }
    }

    // MARK: - Receipts

    func markRead(_ conv: Conversation) {
        let incoming = messages(in: conv.id).filter { $0.senderID != me && !$0.isSystem }
        conv.unread = 0
        guard let newest = incoming.map(\.createdAt).max() else { return }
        var r = pendingReceipts[conv.id] ?? (delivered: nil, read: nil)
        r.read = max(r.read ?? .distantPast, newest)
        r.delivered = max(r.delivered ?? .distantPast, newest)
        pendingReceipts[conv.id] = r
        save()
        Task { await sync() }
    }

    private func sendReceipts() async throws {
        guard !pendingReceipts.isEmpty else { return }
        let all = pendingReceipts
        pendingReceipts = [:]
        for (convID, r) in all {
            guard let conv = conversation(convID), !conv.left, conv.members.count <= 21 else { continue }
            send(.receipt(delivered: r.delivered, read: MyDetails.readReceipts ? r.read : nil), in: conv, loud: false)
        }
        try await flush()
    }

    // MARK: - Keys

    /// The key for a conversation/version. Direct and self chats derive it from the two identity keys;
    /// group keys arrive as key shares.
    func key(for conv: String, version: Int, sender: String) async throws -> SymmetricKey? {
        if conv.hasPrefix("g_") { return E2E.conversationKey(conv: conv, version: version) }
        if let k = E2E.conversationKey(conv: conv, version: 0) { return k }
        let peer: String
        if conv.hasPrefix("s_") {
            peer = me
        } else if let p = Self.peer(inDirect: conv, me: me) {
            peer = p
        } else {
            return nil
        }
        let pub: String
        if peer == me { pub = myPublicKey } else { pub = try await ensureContact(peer, asRequest: sender == peer).publicKey }
        let k = try E2E.pairwiseKey(theirPublicKey: pub, context: conv)
        E2E.storeConversationKey(k, conv: conv, version: 0)
        return k
    }

    static func directID(_ a: String, _ b: String) -> String { "d_" + [a, b].sorted().joined(separator: "|") }

    static func peer(inDirect conv: String, me: String) -> String? {
        guard conv.hasPrefix("d_") else { return nil }
        let ids = conv.dropFirst(2).split(separator: "|").map(String.init)
        guard ids.count == 2 else { return nil }
        return ids[0] == me ? ids[1] : ids[0]
    }

    // MARK: - Contacts

    /// Returns the contact, fetching their public profile from iCloud if I don't know them yet.
    @discardableResult
    func ensureContact(_ userID: String, asRequest: Bool) async throws -> Contact {
        if let c = contact(userID) {
            if asRequest && !c.saved && !c.isRequest { c.isRequest = true }
            return c
        }
        guard let p = try await cloud.fetchProfile(userID) else { throw SyncError.unknownUser }
        if let c = contact(userID) { return c }
        let c = Contact(userID: userID, name: p.name, publicKey: p.publicKey, avatar: p.avatar, saved: false, isRequest: asRequest)
        context.insert(c)
        if asRequest {
            context.insert(ActivityItem(kind: .contact, text: "\(p.name) sent you a message. Add them to your contacts?", actorID: userID))
        }
        return c
    }

    /// Re-reads a contact's public profile (name, photo). Warns if their key changed.
    func refreshProfile(_ c: Contact) async {
        guard let p = try? await cloud.fetchProfile(c.userID) else { return }
        c.name = p.name
        if let pic = p.avatar { c.avatar = pic }
        c.plus = p.plus
        fixDirectTitle(c)
        if p.publicKey != c.publicKey {
            c.publicKey = p.publicKey
            c.verified = false
            Keychain.delete("conv.\(Self.directID(me, c.userID)).0")
            context.insert(ActivityItem(kind: .contact, text: "\(c.name)'s security key changed (new device or reinstall). Verify it with them.", actorID: c.userID))
        }
        save()
    }

    // MARK: - Housekeeping

    private func cleanupIfDue() async {
        let key = "sync.lastCleanup"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date.now.timeIntervalSince(last) < 86400 { return }
        let cutoff = Date(timeIntervalSinceNow: -Double(Self.retentionDays) * 86400)
        let old = (try? context.fetch(FetchDescriptor<SentRecord>(predicate: #Predicate { $0.sentAt < cutoff }))) ?? []
        if !old.isEmpty {
            do {
                try await cloud.delete(old.map(\.recordName))
                for r in old { context.delete(r) }
            } catch {
                return
            }
        }
        let pendingCutoff = Date(timeIntervalSinceNow: -30 * 86400)
        for p in (try? context.fetch(FetchDescriptor<PendingEnvelope>(predicate: #Predicate { $0.receivedAt < pendingCutoff }))) ?? [] {
            context.delete(p)
        }
        let activityCutoff = Date(timeIntervalSinceNow: -90 * 86400)
        for a in (try? context.fetch(FetchDescriptor<ActivityItem>(predicate: #Predicate { $0.date < activityCutoff }))) ?? [] {
            context.delete(a)
        }
        UserDefaults.standard.set(Date.now, forKey: key)
        save()
    }

    // MARK: - Lookups

    func contact(_ id: String) -> Contact? {
        try? context.fetch(FetchDescriptor<Contact>(predicate: #Predicate { $0.userID == id })).first
    }

    func conversation(_ id: String) -> Conversation? {
        try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
    }

    func message(_ id: String) -> Message? {
        try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })).first
    }

    func task(_ id: String) -> TaskItem? {
        try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
    }

    func approval(_ id: String) -> Approval? {
        try? context.fetch(FetchDescriptor<Approval>(predicate: #Predicate { $0.id == id })).first
    }

    func messages(in conv: String) -> [Message] {
        (try? context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.convID == conv },
                                                       sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// Display name for a user ID ("You" for me).
    func name(of user: String) -> String {
        if user == me { return "You" }
        return contact(user)?.name ?? "Someone"
    }
}
