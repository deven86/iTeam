import Foundation
import SwiftData

// Everything lives on this device in SwiftData (no iCloud mirroring of the store itself).
// Other devices and other people get changes as encrypted events through CloudKit (see SyncEngine).

enum ITeamSchema {
    static let models: [any PersistentModel.Type] = [
        Contact.self, Conversation.self, Message.self, TaskItem.self, ChecklistItem.self, TaskComment.self,
        ActivityItem.self, OutboxItem.self, PendingEnvelope.self, SentRecord.self
    ]
}

/// JSON helpers for small arrays/dictionaries stored as Data.
enum Packed {
    static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - People

@Model final class Contact {
    @Attribute(.unique) var userID: String
    var name: String
    var publicKey: String
    var avatar: Data?
    var addedAt: Date
    /// In my contact list (false = only known as a group member).
    var saved: Bool
    /// Wrote to me before I added them.
    var isRequest: Bool
    /// Added by scanning their QR code (key checked against iCloud).
    var verified: Bool
    var blocked: Bool

    init(userID: String, name: String, publicKey: String, avatar: Data? = nil, saved: Bool, isRequest: Bool = false, verified: Bool = false) {
        self.userID = userID
        self.name = name
        self.publicKey = publicKey
        self.avatar = avatar
        self.addedAt = .now
        self.saved = saved
        self.isRequest = isRequest
        self.verified = verified
        self.blocked = false
    }
}

// MARK: - Conversations

enum Role: String, Codable, CaseIterable {
    case owner, admin, member
    var title: String { rawValue.capitalized }
    var canManage: Bool { self != .member }
}

struct MemberInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var role: Role
}

/// Per-member delivery/read marks (sender-clock times of the newest message they have).
struct ReceiptMark: Codable, Hashable {
    var delivered: Date?
    var read: Date?
}

@Model final class Conversation {
    @Attribute(.unique) var id: String
    /// "direct" or "group"
    var kind: String
    var title: String
    var ownerID: String
    var peerID: String?
    var createdAt: Date
    var lastActivity: Date
    var lastPreview: String
    var unread: Int
    var pinned: Bool
    var muted: Bool
    var archived: Bool
    /// "vivid:<theme>", "skin:<skin>", "photo" or nil (follow the app look)
    var wallpaper: String?
    var avatar: Data?
    /// I left or was removed.
    var left: Bool
    var keyVersion: Int
    var membersData: Data
    var receiptsData: Data?
    var draft: String
    /// A local practice chat with simulated people (never leaves this device).
    var isDemo: Bool = false

    init(id: String, kind: String, title: String, ownerID: String, peerID: String? = nil, members: [MemberInfo]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.ownerID = ownerID
        self.peerID = peerID
        self.createdAt = .now
        self.lastActivity = .now
        self.lastPreview = ""
        self.unread = 0
        self.pinned = false
        self.muted = false
        self.archived = false
        self.left = false
        self.keyVersion = 0
        self.membersData = Packed.encode(members)
        self.draft = ""
    }

    var isGroup: Bool { kind == "group" }

    var members: [MemberInfo] {
        get { Packed.decode([MemberInfo].self, membersData) ?? [] }
        set { membersData = Packed.encode(newValue) }
    }

    var receipts: [String: ReceiptMark] {
        get { Packed.decode([String: ReceiptMark].self, receiptsData) ?? [:] }
        set { receiptsData = Packed.encode(newValue) }
    }

    func role(of user: String) -> Role? { members.first { $0.id == user }?.role }
    func isMember(_ user: String) -> Bool { members.contains { $0.id == user } }
}

// MARK: - Messages

struct AttachmentRef: Codable, Hashable, Identifiable {
    var id: String
    /// CloudKit Blob record name (nil until uploaded / for local-only).
    var blob: String
    /// Base64 file key (the file is encrypted before upload).
    var key: String
    var name: String
    var mime: String
    var size: Int
    /// "image" or "file"
    var kind: String
    var width: Double?
    var height: Double?
    /// Small JPEG preview (inside the encrypted event).
    var thumb: Data?
}

enum MessageStatus: Int {
    case queued = 0, sent = 1, failed = 3
}

@Model final class Message {
    @Attribute(.unique) var id: String
    var convID: String
    var senderID: String
    var text: String
    var createdAt: Date
    var editedAt: Date?
    var deleted: Bool
    var replyToID: String?
    var reactionsData: Data?
    var attachmentsData: Data?
    var statusRaw: Int
    var taskID: String?
    var isSystem: Bool

    init(id: String, convID: String, senderID: String, text: String, createdAt: Date, replyToID: String? = nil,
         attachments: [AttachmentRef] = [], status: MessageStatus, isSystem: Bool = false) {
        self.id = id
        self.convID = convID
        self.senderID = senderID
        self.text = text
        self.createdAt = createdAt
        self.deleted = false
        self.replyToID = replyToID
        self.attachmentsData = attachments.isEmpty ? nil : Packed.encode(attachments)
        self.statusRaw = status.rawValue
        self.isSystem = isSystem
    }

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    /// userID → emoji
    var reactions: [String: String] {
        get { Packed.decode([String: String].self, reactionsData) ?? [:] }
        set { reactionsData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }

    var attachments: [AttachmentRef] {
        get { Packed.decode([AttachmentRef].self, attachmentsData) ?? [] }
        set { attachmentsData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }

    var preview: String {
        if deleted { return "Message deleted" }
        if !text.isEmpty { return text }
        if let a = attachments.first { return a.kind == "image" ? "📷 Photo" : "📎 \(a.name)" }
        return ""
    }
}

// MARK: - Business Tasks

enum TaskStatus: String, Codable, CaseIterable {
    case open, inProgress, done
    var title: String {
        switch self {
        case .open: "To do"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
    var icon: String {
        switch self {
        case .open: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

enum CompletionPolicy: String, Codable, CaseIterable {
    /// Any participant can complete the whole task.
    case any
    /// Every assignee marks their part; the task completes when all have.
    case all
    var title: String {
        switch self {
        case .any: "Anyone can complete"
        case .all: "Everyone must finish their part"
        }
    }
}

enum WorkPriority: Int, Codable, CaseIterable {
    case low = 0, normal = 1, high = 2, urgent = 3
    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }
    var icon: String {
        switch self {
        case .low: "arrow.down"
        case .normal: "minus"
        case .high: "arrow.up"
        case .urgent: "exclamationmark.2"
        }
    }
}

@Model final class TaskItem {
    @Attribute(.unique) var id: String
    /// nil = personal task (never leaves this device, except as an echo to your own devices)
    var convID: String?
    var sourceMessageID: String?
    var title: String
    var notes: String
    var statusRaw: String
    var priorityRaw: Int
    var dueAt: Date?
    var policyRaw: String
    var createdBy: String
    var createdAt: Date
    var completedAt: Date?
    var completedBy: String?
    var assigneesData: Data
    /// participant → when they finished their part
    var doneByData: Data?
    /// field → last change time (last-writer-wins per field)
    var stampsData: Data?
    /// Minutes before the due time for my reminder (-1 = only at due time). Personal, not shared.
    var reminderOffset: Int
    var deleted: Bool
    var updatedAt: Date

    init(id: String = UUID().uuidString, convID: String?, title: String, createdBy: String) {
        self.id = id
        self.convID = convID
        self.title = title
        self.notes = ""
        self.statusRaw = TaskStatus.open.rawValue
        self.priorityRaw = WorkPriority.normal.rawValue
        self.policyRaw = CompletionPolicy.any.rawValue
        self.createdBy = createdBy
        self.createdAt = .now
        self.assigneesData = Packed.encode([String]())
        self.reminderOffset = 60
        self.deleted = false
        self.updatedAt = .now
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }
    var priority: WorkPriority {
        get { WorkPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }
    var policy: CompletionPolicy {
        get { CompletionPolicy(rawValue: policyRaw) ?? .any }
        set { policyRaw = newValue.rawValue }
    }
    var assignees: [String] {
        get { Packed.decode([String].self, assigneesData) ?? [] }
        set { assigneesData = Packed.encode(newValue) }
    }
    var doneBy: [String: Date] {
        get { Packed.decode([String: Date].self, doneByData) ?? [:] }
        set { doneByData = Packed.encode(newValue) }
    }
    var stamps: [String: Date] {
        get { Packed.decode([String: Date].self, stampsData) ?? [:] }
        set { stampsData = Packed.encode(newValue) }
    }

    var isDone: Bool { status == .done }
    var isOverdue: Bool { !isDone && (dueAt.map { $0 < .now } ?? false) }

    /// Share of assignees who finished their part (or 0/1 for "anyone" tasks).
    var groupProgress: Double {
        if isDone { return 1 }
        let people = assignees
        guard policy == .all, !people.isEmpty else { return status == .inProgress ? 0.5 : 0 }
        let done = doneBy.keys.filter { people.contains($0) }.count
        return Double(done) / Double(people.count)
    }

    func involves(_ user: String) -> Bool {
        createdBy == user || assignees.contains(user) || (convID != nil && assignees.isEmpty)
    }
}

@Model final class ChecklistItem {
    @Attribute(.unique) var id: String
    var taskID: String
    var title: String
    var done: Bool
    var position: Double
    var updatedAt: Date
    var updatedBy: String
    var deleted: Bool

    init(id: String = UUID().uuidString, taskID: String, title: String, position: Double, by: String) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.done = false
        self.position = position
        self.updatedAt = .now
        self.updatedBy = by
        self.deleted = false
    }
}

@Model final class TaskComment {
    @Attribute(.unique) var id: String
    var taskID: String
    var authorID: String
    var body: String
    var createdAt: Date

    init(id: String = UUID().uuidString, taskID: String, authorID: String, body: String, createdAt: Date = .now) {
        self.id = id
        self.taskID = taskID
        self.authorID = authorID
        self.body = body
        self.createdAt = createdAt
    }
}

// MARK: - Activity

enum ActivityKind: String {
    case mention, taskAssigned, taskUpdated, taskCompleted, taskComment, group, sync, contact
    var icon: String {
        switch self {
        case .mention: "at"
        case .taskAssigned: "person.crop.circle.badge.checkmark"
        case .taskUpdated: "square.and.pencil"
        case .taskCompleted: "checkmark.seal.fill"
        case .taskComment: "text.bubble"
        case .group: "person.3"
        case .sync: "arrow.triangle.2.circlepath"
        case .contact: "person.badge.plus"
        }
    }
}

@Model final class ActivityItem {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var text: String
    var convID: String?
    var taskID: String?
    var actorID: String
    var date: Date
    var read: Bool

    init(kind: ActivityKind, text: String, convID: String? = nil, taskID: String? = nil, actorID: String, date: Date = .now) {
        self.id = UUID().uuidString
        self.kindRaw = kind.rawValue
        self.text = text
        self.convID = convID
        self.taskID = taskID
        self.actorID = actorID
        self.date = date
        self.read = false
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .sync }
}

// MARK: - Sync bookkeeping

/// An event (or key share) waiting to be uploaded. Never discarded silently.
@Model final class OutboxItem {
    @Attribute(.unique) var id: String
    var convID: String
    var recipientsData: Data
    /// Encoded `Event` (for kind "event") or raw key bytes (for kind "key").
    var payload: Data
    /// "event" or "key"
    var kind: String
    var keyVersion: Int
    var loud: Bool
    var hintData: Data?
    /// attachment blob ID → local encrypted file name (uploaded before the event)
    var uploadsData: Data?
    var createdAt: Date
    var attempts: Int
    var lastError: String?

    init(id: String, convID: String, recipients: [String], payload: Data, kind: String, keyVersion: Int, loud: Bool, hint: NotificationHint?) {
        self.id = id
        self.convID = convID
        self.recipientsData = Packed.encode(recipients)
        self.payload = payload
        self.kind = kind
        self.keyVersion = keyVersion
        self.loud = loud
        self.hintData = hint.map { Packed.encode($0) }
        self.createdAt = .now
        self.attempts = 0
    }

    var recipients: [String] { Packed.decode([String].self, recipientsData) ?? [] }
    var uploads: [String: String] {
        get { Packed.decode([String: String].self, uploadsData) ?? [:] }
        set { uploadsData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }
}

/// An envelope that arrived before its key (or its group) did. Retried after every sync.
@Model final class PendingEnvelope {
    @Attribute(.unique) var recordName: String
    var conv: String
    var from: String
    var kind: Int
    var body: Data
    var receivedAt: Date
    var tries: Int

    init(recordName: String, conv: String, from: String, kind: Int, body: Data) {
        self.recordName = recordName
        self.conv = conv
        self.from = from
        self.kind = kind
        self.body = body
        self.receivedAt = .now
        self.tries = 0
    }
}

/// Records I uploaded to the public database, so I can delete them after the retention period.
@Model final class SentRecord {
    @Attribute(.unique) var recordName: String
    var sentAt: Date

    init(recordName: String) {
        self.recordName = recordName
        self.sentAt = .now
    }
}
