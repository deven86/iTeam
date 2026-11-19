import Foundation
import CloudKit
import CryptoKit
import UIKit

/// Chat rooms (free): public rooms anyone can find and join under a room name ("alias"),
/// gender and optional picture. Room chat is public to the room; private chats between two
/// room members are end-to-end encrypted with per-room keys and show only alias, gender and picture.
/// When BOTH people tap "Reveal", each receives the other's iTeam invite and can add them as a contact.
@MainActor
final class Rooms: ObservableObject {
    static let shared = Rooms()

    // MARK: Types

    struct Room: Identifiable, Codable, Hashable {
        let id: String
        var name: String
        var about: String
        var owner: String          // owner's persona id in this room
        var photo: Data?
        var updated: Date
    }

    struct Persona: Codable, Hashable {
        let id: String
        var alias: String
        var gender: String
        var photo: Data?
    }

    struct Member: Codable, Hashable {
        let id: String             // persona id
        var room: String
        var alias: String
        var gender: String
        var photo: Data?
        var key: String
    }

    enum Kind: Int, Codable { case text = 0, reveal = 1, hide = 2 }

    struct Message: Identifiable, Codable, Hashable {
        let id: String
        let room: String
        let sndr: String
        let rcpt: String           // "all" = room chat, else a persona id
        let kind: Kind
        let text: String
        let date: Date
    }

    struct Thread: Identifiable, Hashable {
        var id: String { room + "|" + other }
        let room: String
        let other: String
    }

    private struct Saved: Codable {
        var joined: [String: Persona] = [:]          // room id → my persona
        var rooms: [String: Room] = [:]              // rooms I joined (for offline display)
        var members: [String: Member] = [:]
        var dms: [String: [Message]] = [:]           // thread id → messages
        var revealed: Set<String> = []               // threads where I revealed
        var theirReveal: [String: String] = [:]      // thread id → their invite link
        var blocked: Set<String> = []
        var unread: [String: Int] = [:]
        var lastDM: Date = .distantPast
    }

    static let genders = ["Male", "Female", "Other", "Prefer not to say"]
    static func symbol(_ gender: String) -> String {
        switch gender { case "Male": "♂"; case "Female": "♀"; case "Other": "⚧"; default: "•" }
    }

    // MARK: State

    @Published private(set) var discover: [Room] = []
    @Published private(set) var roomMessages: [String: [Message]] = [:]
    @Published private var saved = Saved()
    @Published var error: String?

    var joined: [String: Persona] { saved.joined }
    var myRooms: [Room] { saved.rooms.values.filter { saved.joined[$0.id] != nil }.sorted { $0.name < $1.name } }
    var threads: [Thread] {
        saved.dms.keys.compactMap { k -> Thread? in
            let p = k.split(separator: "|").map(String.init)
            return p.count == 2 && !saved.blocked.contains(p[1]) ? Thread(room: p[0], other: p[1]) : nil
        }.sorted { (saved.dms[$0.id]?.last?.date ?? .distantPast) > (saved.dms[$1.id]?.last?.date ?? .distantPast) }
    }
    var unreadTotal: Int { saved.unread.values.reduce(0, +) }
    func unread(_ t: Thread) -> Int { saved.unread[t.id] ?? 0 }
    func member(_ id: String) -> Member? { saved.members[id] }
    func room(_ id: String) -> Room? { saved.rooms[id] ?? discover.first { $0.id == id } }
    func dms(_ t: Thread) -> [Message] { saved.dms[t.id] ?? [] }
    func isBlocked(_ persona: String) -> Bool { saved.blocked.contains(persona) }
    func iRevealed(_ t: Thread) -> Bool { saved.revealed.contains(t.id) }
    func theyRevealed(_ t: Thread) -> Bool { saved.theirReveal[t.id] != nil }
    /// Their invite — only handed out once BOTH sides revealed.
    func revealedInvite(_ t: Thread) -> SyncEngine.Invite? {
        guard iRevealed(t), let link = saved.theirReveal[t.id] else { return nil }
        return SyncEngine.Invite(text: link)
    }
    func markRead(_ t: Thread) { saved.unread[t.id] = nil; persist() }

    private var db: CKDatabase { CKContainer(identifier: CloudService.containerID).publicCloudDatabase }
    private let file = URL.applicationSupportDirectory.appendingPathComponent("rooms.json")

    private init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) { saved = s }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }

    // MARK: Keys

    private func keyAccount(_ persona: String) -> String { "room.persona." + persona }

    private func privateKey(_ persona: String) -> Curve25519.KeyAgreement.PrivateKey? {
        Keychain.get(keyAccount(persona)).flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
    }

    private func threadKey(room: String, mine: String, theirs: String) throws -> SymmetricKey {
        guard let me = privateKey(mine), let member = saved.members[theirs],
              let raw = Data(base64Encoded: member.key),
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { throw E2E.Failure.badKey }
        return try me.sharedSecretFromKeyAgreement(with: pub)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(room.utf8), sharedInfo: Data("iteam-room-v1".utf8), outputByteCount: 32)
    }

    // MARK: Rooms

    func refreshDiscover() async {
        let q = CKQuery(recordType: "Room", predicate: NSPredicate(value: true))
        q.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
        do {
            let page = try await db.records(matching: q, desiredKeys: ["name", "about", "owner", "photo"], resultsLimit: 150)
            discover = page.matchResults.compactMap { _, r in (try? r.get()).map(Self.room) }
            for r in discover where saved.joined[r.id] != nil { saved.rooms[r.id] = r }
            persist()
        } catch { self.error = error.cloudMessage }
    }

    private static func room(_ r: CKRecord) -> Room {
        Room(id: r.recordID.recordName, name: r["name"] as? String ?? "Room", about: r["about"] as? String ?? "",
             owner: r["owner"] as? String ?? "", photo: r["photo"] as? Data, updated: r.modificationDate ?? .now)
    }

    @discardableResult
    func create(name: String, about: String, photo: Data?, as persona: Persona) async -> Room? {
        let id = "room-" + UUID().uuidString.lowercased()
        let rec = CKRecord(recordType: "Room", recordID: CKRecord.ID(recordName: id))
        rec["name"] = Moderation.clean(name)
        rec["about"] = Moderation.clean(about)
        rec["owner"] = persona.id
        rec["photo"] = photo
        do {
            _ = try await db.save(rec)
            let room = Self.room(rec)
            guard await join(room, as: persona) else { return nil }
            discover.insert(room, at: 0)
            return room
        } catch { self.error = error.cloudMessage; return nil }
    }

    /// A fresh room identity: new id and key pair, so rooms can't be linked to each other.
    static func newPersona(alias: String, gender: String, photo: Data?) -> Persona {
        Persona(id: "p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased(),
                alias: alias, gender: gender, photo: photo)
    }

    func join(_ room: Room, as persona: Persona) async -> Bool {
        let key = Curve25519.KeyAgreement.PrivateKey()
        _ = Keychain.set(key.rawRepresentation, account: keyAccount(persona.id), sync: true)
        let rec = CKRecord(recordType: "RoomMember", recordID: CKRecord.ID(recordName: "rm-" + persona.id))
        rec["room"] = room.id
        rec["alias"] = Moderation.clean(persona.alias)
        rec["gender"] = persona.gender
        rec["photo"] = persona.photo
        rec["key"] = key.publicKey.rawRepresentation.base64EncodedString()
        do {
            _ = try await db.save(rec)
            saved.joined[room.id] = persona
            saved.rooms[room.id] = room
            saved.members[persona.id] = Self.member(rec)
            persist()
            return true
        } catch { self.error = error.cloudMessage; return false }
    }

    func leave(_ room: Room) async {
        guard let p = saved.joined[room.id] else { return }
        _ = try? await db.deleteRecord(withID: CKRecord.ID(recordName: "rm-" + p.id))
        saved.joined[room.id] = nil
        saved.rooms[room.id] = nil
        roomMessages[room.id] = nil
        persist()
    }

    private static func member(_ r: CKRecord) -> Member {
        Member(id: String(r.recordID.recordName.dropFirst(3)), room: r["room"] as? String ?? "",
               alias: r["alias"] as? String ?? "Guest", gender: r["gender"] as? String ?? "",
               photo: r["photo"] as? Data, key: r["key"] as? String ?? "")
    }

    private func loadMembers(_ ids: Set<String>) async {
        let missing = ids.filter { saved.members[$0] == nil }
        guard !missing.isEmpty else { return }
        let res = (try? await db.records(for: missing.map { CKRecord.ID(recordName: "rm-" + $0) })) ?? [:]
        for (_, r) in res { if let rec = try? r.get() { let m = Self.member(rec); saved.members[m.id] = m } }
        persist()
    }

    // MARK: Room chat

    func refresh(room: Room) async {
        let since = roomMessages[room.id]?.last?.date ?? Date(timeIntervalSinceNow: -3 * 86400)
        let q = CKQuery(recordType: "RoomMsg", predicate: NSPredicate(format: "room == %@ AND rcpt == %@ AND creationDate > %@",
                                                                      room.id, "all", since.addingTimeInterval(-2) as NSDate))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        guard let page = try? await db.records(matching: q, desiredKeys: ["sndr", "kind", "body"], resultsLimit: 200) else { return }
        var list = roomMessages[room.id] ?? []
        let known = Set(list.map(\.id))
        for (_, r) in page.matchResults {
            guard let rec = try? r.get(), !known.contains(rec.recordID.recordName) else { continue }
            let text = (rec["body"] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            list.append(Message(id: rec.recordID.recordName, room: room.id, sndr: rec["sndr"] as? String ?? "", rcpt: "all",
                                kind: Kind(rawValue: rec["kind"] as? Int ?? 0) ?? .text, text: text, date: rec.creationDate ?? .now))
        }
        // Only the room owner can remove messages.
        let hidden = Set(list.filter { $0.kind == .hide && $0.sndr == room.owner }.map(\.text))
        list = list.filter { !hidden.contains($0.id) && !($0.kind == .hide && $0.sndr != room.owner) }
        roomMessages[room.id] = Array(list.suffix(300))
        await loadMembers(Set(list.map(\.sndr)))
    }

    func send(_ text: String, in room: Room, kind: Kind = .text) async {
        guard let me = saved.joined[room.id] else { return }
        let rec = CKRecord(recordType: "RoomMsg")
        rec["room"] = room.id; rec["rcpt"] = "all"; rec["sndr"] = me.id; rec["kind"] = kind.rawValue
        rec["body"] = Data((kind == .text ? Moderation.clean(text) : text).utf8)
        do { _ = try await db.save(rec); await refresh(room: room) } catch { self.error = error.cloudMessage }
    }

    // MARK: Private chats

    func send(_ text: String, to t: Thread, kind: Kind = .text) async {
        guard let me = saved.joined[t.room] else { return }
        await loadMembers([t.other])
        do {
            let key = try threadKey(room: t.room, mine: me.id, theirs: t.other)
            let body = try E2E.seal(Data((kind == .text ? Moderation.clean(text) : text).utf8), key: key)
            let rec = CKRecord(recordType: "RoomMsg")
            rec["room"] = t.room; rec["rcpt"] = t.other; rec["sndr"] = me.id; rec["kind"] = kind.rawValue; rec["body"] = body
            _ = try await db.save(rec)
            if kind == .reveal { saved.revealed.insert(t.id) }
            saved.dms[t.id, default: []].append(Message(id: rec.recordID.recordName, room: t.room, sndr: me.id, rcpt: t.other,
                                                        kind: kind, text: kind == .reveal ? "" : text, date: .now))
            persist()
        } catch { self.error = (error as? CKError).map { $0.cloudMessage } ?? "Couldn't send. Try again." }
    }

    func reveal(_ t: Thread, invite: SyncEngine.Invite) async {
        await send(invite.url.absoluteString, to: t, kind: .reveal)
    }

    /// Private messages sent to any of my room identities.
    func refreshInbox() async {
        let mine = saved.joined.values.map(\.id)
        guard !mine.isEmpty else { return }
        let q = CKQuery(recordType: "RoomMsg", predicate: NSPredicate(format: "rcpt IN %@ AND creationDate > %@", mine,
                                                                      saved.lastDM.addingTimeInterval(-2) as NSDate))
        q.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        guard let page = try? await db.records(matching: q, desiredKeys: ["room", "sndr", "rcpt", "kind", "body"], resultsLimit: 200) else { return }
        let recs = page.matchResults.compactMap { try? $0.1.get() }
        await loadMembers(Set(recs.compactMap { $0["sndr"] as? String }))
        for rec in recs {
            guard let room = rec["room"] as? String, let from = rec["sndr"] as? String, let to = rec["rcpt"] as? String,
                  let body = rec["body"] as? Data, !saved.blocked.contains(from) else { continue }
            let t = Thread(room: room, other: from)
            if saved.dms[t.id]?.contains(where: { $0.id == rec.recordID.recordName }) == true { continue }
            guard let key = try? threadKey(room: room, mine: to, theirs: from),
                  let plain = try? E2E.open(body, key: key), let text = String(data: plain, encoding: .utf8) else { continue }
            let kind = Kind(rawValue: rec["kind"] as? Int ?? 0) ?? .text
            if kind == .reveal { saved.theirReveal[t.id] = text }
            saved.dms[t.id, default: []].append(Message(id: rec.recordID.recordName, room: room, sndr: from, rcpt: to, kind: kind,
                                                        text: kind == .reveal ? "" : text, date: rec.creationDate ?? .now))
            saved.unread[t.id, default: 0] += 1
            if let d = rec.creationDate, d > saved.lastDM { saved.lastDM = d }
        }
        persist()
    }

    // MARK: Safety

    func block(_ persona: String) {
        saved.blocked.insert(persona)
        for k in saved.dms.keys where k.hasSuffix("|" + persona) { saved.unread[k] = nil }
        persist()
    }

    func unblock(_ persona: String) { saved.blocked.remove(persona); persist() }

    func report(_ m: Message, reason: String) async {
        let rec = CKRecord(recordType: "RoomReport")
        rec["room"] = m.room; rec["msg"] = m.id; rec["sndr"] = m.sndr; rec["reason"] = reason
        _ = try? await db.save(rec)
        block(m.sndr)
    }

    /// Room owners can remove any message from the room.
    func remove(_ m: Message, in room: Room) async { await send(m.id, in: room, kind: .hide) }

    func deleteThread(_ t: Thread) { saved.dms[t.id] = nil; saved.unread[t.id] = nil; persist() }
}

/// Basic word filter for public rooms (App Store guideline 1.2 asks for one).
enum Moderation {
    private static let words: [String] = ["fuck", "fucker", "motherfucker", "bitch", "bastard", "cunt", "dick", "pussy", "slut", "whore",
                                          "nigger", "faggot", "retard", "chutiya", "madarchod", "behenchod", "bhenchod", "bhosdi", "randi", "gandu", "lund"]

    static func clean(_ text: String) -> String {
        var out = text
        for w in words {
            out = out.replacingOccurrences(of: "\\b\(w)\\b", with: String(repeating: "*", count: w.count),
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}

enum ImageShrink {
    /// Square JPEG of at most `side` px, for room and profile pictures.
    static func jpeg(_ data: Data, side: CGFloat = 256) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let s = min(img.size.width, img.size.height)
        let crop = CGRect(x: (img.size.width - s) / 2, y: (img.size.height - s) / 2, width: s, height: s)
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let scale = side / s
            img.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: img.size.width * scale, height: img.size.height * scale))
        }
        return out.jpegData(compressionQuality: 0.7)
    }
}
