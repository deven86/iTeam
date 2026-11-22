import Foundation
import SwiftData

// Everything lives on this device in SwiftData (no iCloud mirroring of the store itself).
// Other devices and other people get changes as encrypted events through CloudKit (see SyncEngine).

enum ITeamSchema {
    static let models: [any PersistentModel.Type] = [
        Contact.self, Conversation.self, Message.self, TaskItem.self, ChecklistItem.self, TaskComment.self,
        ActivityItem.self, OutboxItem.self, PendingEnvelope.self, SentRecord.self,
        TaskFile.self, Approval.self, Expense.self, Poll.self,
        CareProfile.self, Medicine.self, DoseLog.self, HealthEvent.self, VaultItem.self,
        GymMember.self, GymPlan.self, GymSession.self, GymPayment.self,
        Post.self, PostReaction.self, PostComment.self, PostSeen.self,
        MeditationLog.self, CustomMeditation.self,
        FoodEntry.self, WaterEntry.self, WorkoutLog.self, ExerciseSet.self, WorkoutPlan.self, PlanExercise.self,
        EmergencyContact.self, HealthProfile.self, ProgressPhoto.self, LibraryPhoto.self, CustomFood.self, CustomExercise.self,
        Trainer.self, BodyMeasurement.self, Supplement.self, SupplementDose.self, ExerciseMedia.self,
        WalletDoc.self, Prescription.self, CheckIn.self, BizRecord.self, InviteEvent.self, Meeting.self, AttRecord.self, GameMatch.self, FinRecord.self, AlbumItem.self
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
    /// Phone or email they chose to share for FaceTime ("" = not shared).
    var facetime: String = ""
    /// Their "About" line, sent to contacts only.
    var about: String = ""
    /// "Song — Artist" they're listening to, if they share it.
    var nowPlaying: String = ""
    var nowPlayingAt: Date? = nil
    /// iTeam Plus supporter badge.
    var plus: Bool = false
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
    /// Disappearing messages: seconds after sending (0 = off). Set by either person, applies to both.
    var timer: Int = 0
    /// Chat lock: hidden in "Locked chats", opens with Face ID.
    var locked: Bool = false
    /// Someone outside my contacts added me to this group; waits for Join / Leave.
    var pendingInvite: Bool = false

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
    /// Seconds, for voice notes and videos.
    var duration: Double? = nil
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
    /// View-once photo/video, and whether I've opened it.
    var viewOnce: Bool = false
    var openedOnce: Bool = false
    /// This message is an approval request card.
    var approvalID: String? = nil
    /// This message is a poll card.
    var pollID: String? = nil
    /// Forwarded from another chat.
    var forwarded: Bool = false
    /// Magic moment: hidden from the recipient until this time.
    var showAt: Date? = nil
    /// Disappearing message: removed from both phones after this time.
    var expiresAt: Date? = nil
    /// Magic moment not yet revealed in the chat list / unread count.
    var magicPending: Bool = false

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
        if approvalID != nil { return "🟡 Approval: \(text)" }
        if pollID != nil { return "📊 Poll: \(text)" }
        if !text.isEmpty { return text }
        if let a = attachments.first {
            switch a.kind {
            case "image": return "📷 Photo"
            case "audio": return "🎤 Voice note (\(Clock.mmss(a.duration ?? 0)))"
            case "video": return "🎬 Video"
            default: return "📎 \(a.name)"
            }
        }
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
    /// Who deleted it and when — deleted tasks stay visible as "Deleted".
    var deletedBy: String? = nil
    var deletedAt: Date? = nil
    /// "none", "daily", "weekly", "monthly" (Business Tasks Pro)
    var repeatRule: String = "none"
    /// Follow-up schedule (Business Tasks Pro): JSON of FollowUp, "" = off.
    var followUpRaw: String = ""
    /// Assigned to specific people: each must accept before it starts.
    var needsAcceptance: Bool = false
    /// userID → "accepted" / "declined" (+ optional note after "|").
    var acceptanceData: Data?

    var acceptance: [String: String] {
        get { Packed.decode([String: String].self, acceptanceData) ?? [:] }
        set { acceptanceData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }
    /// Assignees (other than the creator) who still have to accept.
    var pendingAcceptance: [String] {
        guard needsAcceptance else { return [] }
        return assignees.filter { $0 != createdBy && acceptance[$0] == nil }
    }
    var declinedBy: [String] {
        acceptance.filter { $0.value.hasPrefix("declined") }.map(\.key)
    }
    func awaitsMe(_ me: String) -> Bool { pendingAcceptance.contains(me) }

    var followUp: FollowUp? {
        get { followUpRaw.isEmpty ? nil : (try? JSONDecoder().decode(FollowUp.self, from: Data(followUpRaw.utf8))) }
        set { followUpRaw = newValue.flatMap { (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) } } ?? "" }
    }

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
    case mention, taskAssigned, taskUpdated, taskCompleted, taskComment, group, sync, contact, approval, expense, care, gym, views
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
        case .approval: "checkmark.seal"
        case .expense: "indianrupeesign.circle"
        case .care: "heart.text.square"
        case .gym: "dumbbell.fill"
        case .views: "play.rectangle.on.rectangle.fill"
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
    /// Where tapping it goes (the exact task, case, meeting…); "" = the chat.
    var link: String = ""

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


// MARK: - Task files, approvals, expenses

@Model final class TaskFile {
    @Attribute(.unique) var id: String
    var taskID: String
    /// "image", "file" or "link"
    var kind: String
    var attachmentData: Data?
    var url: String?
    var title: String
    var addedBy: String
    var addedAt: Date
    var deleted: Bool

    init(id: String, taskID: String, kind: String, title: String, addedBy: String) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.addedBy = addedBy
        self.addedAt = .now
        self.deleted = false
    }

    var attachment: AttachmentRef? {
        get { Packed.decode(AttachmentRef.self, attachmentData) }
        set { attachmentData = newValue.map { Packed.encode($0) } }
    }
}

struct ApprovalDecision: Codable, Hashable {
    var approved: Bool
    var note: String
    var amount: Double?
    var at: Date
}

enum ApprovalStatus {
    case pending, approved, rejected
    var title: String {
        switch self {
        case .pending: "Waiting for approval"
        case .approved: "Approved"
        case .rejected: "Rejected"
        }
    }
    var icon: String {
        switch self {
        case .pending: "hourglass"
        case .approved: "checkmark.seal.fill"
        case .rejected: "xmark.octagon.fill"
        }
    }
}

@Model final class Approval {
    @Attribute(.unique) var id: String
    var convID: String
    var messageID: String
    var taskID: String?
    var title: String
    var details: String
    var amount: Double?
    var approversData: Data
    var requestedBy: String
    var createdAt: Date
    var decisionsData: Data?
    var attachmentsData: Data?

    init(id: String, convID: String, messageID: String, title: String, requestedBy: String, approvers: [String]) {
        self.id = id
        self.convID = convID
        self.messageID = messageID
        self.title = title
        self.details = ""
        self.requestedBy = requestedBy
        self.createdAt = .now
        self.approversData = Packed.encode(approvers)
    }

    var approvers: [String] {
        get { Packed.decode([String].self, approversData) ?? [] }
        set { approversData = Packed.encode(newValue) }
    }
    var decisions: [String: ApprovalDecision] {
        get { Packed.decode([String: ApprovalDecision].self, decisionsData) ?? [:] }
        set { decisionsData = Packed.encode(newValue) }
    }
    var attachments: [AttachmentRef] {
        get { Packed.decode([AttachmentRef].self, attachmentsData) ?? [] }
        set { attachmentsData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }

    /// Rejected if any approver rejected; approved when every approver approved.
    var status: ApprovalStatus {
        let d = decisions
        if approvers.contains(where: { d[$0]?.approved == false }) { return .rejected }
        if !approvers.isEmpty && approvers.allSatisfy({ d[$0]?.approved == true }) { return .approved }
        return .pending
    }

    /// The smallest amount any approver allowed (nil = as requested or no amount).
    var approvedAmount: Double? {
        let amounts = decisions.values.filter(\.approved).compactMap(\.amount)
        return amounts.min() ?? (status == .approved ? amount : nil)
    }
}

enum ExpenseCategory: String, CaseIterable {
    case travel = "Travel", food = "Food", fees = "Fees", supplies = "Supplies", printing = "Printing", other = "Other"
    var icon: String {
        switch self {
        case .travel: "car.fill"
        case .food: "fork.knife"
        case .fees: "building.columns.fill"
        case .supplies: "shippingbox.fill"
        case .printing: "printer.fill"
        case .other: "indianrupeesign.circle.fill"
        }
    }
}

@Model final class Expense {
    @Attribute(.unique) var id: String
    var taskID: String
    var title: String
    var amount: Double
    var date: Date
    var paidBy: String
    var category: String
    var receiptsData: Data?
    var addedBy: String
    var deleted: Bool
    var updatedAt: Date

    init(id: String, taskID: String, title: String, amount: Double, date: Date, paidBy: String, category: String, addedBy: String) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.amount = amount
        self.date = date
        self.paidBy = paidBy
        self.category = category
        self.addedBy = addedBy
        self.deleted = false
        self.updatedAt = .distantPast
    }

    var receipts: [AttachmentRef] {
        get { Packed.decode([AttachmentRef].self, receiptsData) ?? [] }
        set { receiptsData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }
}

enum Money {
    static var code: String { Locale.current.currency?.identifier ?? "INR" }
    static func format(_ v: Double) -> String { v.formatted(.currency(code: code).precision(.fractionLength(0...2))) }
}


// MARK: - Polls

struct VoteRecord: Codable, Hashable {
    var options: [String]
    var at: Date
}

@Model final class Poll {
    @Attribute(.unique) var id: String
    var convID: String
    var messageID: String
    var question: String
    var optionsData: Data
    var multiple: Bool
    var createdBy: String
    var createdAt: Date
    var votesData: Data?

    init(id: String, convID: String, messageID: String, question: String, options: [PollOption], multiple: Bool, createdBy: String) {
        self.id = id
        self.convID = convID
        self.messageID = messageID
        self.question = question
        self.optionsData = Packed.encode(options)
        self.multiple = multiple
        self.createdBy = createdBy
        self.createdAt = .now
    }

    var options: [PollOption] { Packed.decode([PollOption].self, optionsData) ?? [] }
    var votes: [String: VoteRecord] {
        get { Packed.decode([String: VoteRecord].self, votesData) ?? [:] }
        set { votesData = Packed.encode(newValue) }
    }
    func voters(for option: String) -> [String] { votes.filter { $0.value.options.contains(option) }.map(\.key) }
    var totalVoters: Int { votes.values.filter { !$0.options.isEmpty }.count }
}

// MARK: - iLife Care

@Model final class CareProfile {
    @Attribute(.unique) var id: String
    /// The chat it is shared in (family / team). Members see and update it.
    var convID: String
    var name: String
    var relation: String
    var bloodGroup: String
    var allergies: String
    var conditions: String
    var emergencyContact: String
    var notes: String
    var avatar: Data?
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool

    init(id: String, convID: String, name: String, createdBy: String) {
        self.id = id
        self.convID = convID
        self.name = name
        self.relation = ""
        self.bloodGroup = ""
        self.allergies = ""
        self.conditions = ""
        self.emergencyContact = ""
        self.notes = ""
        self.createdBy = createdBy
        self.createdAt = .now
        self.updatedAt = .distantPast
        self.deleted = false
    }
}

@Model final class Medicine {
    @Attribute(.unique) var id: String
    var profileID: String
    var name: String
    var dose: String
    var form: String
    var timesData: Data
    var instructions: String
    var startDate: Date
    var endDate: Date?
    var stock: Int?
    var active: Bool
    var deleted: Bool
    var updatedAt: Date
    var addedBy: String

    init(id: String, profileID: String, name: String, addedBy: String) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.dose = ""
        self.form = "Tablet"
        self.timesData = Packed.encode([Int]())
        self.instructions = ""
        self.startDate = .now
        self.active = true
        self.deleted = false
        self.updatedAt = .distantPast
        self.addedBy = addedBy
    }

    var times: [Int] {
        get { (Packed.decode([Int].self, timesData) ?? []).sorted() }
        set { timesData = Packed.encode(newValue.sorted()) }
    }

    /// Doses due on a given day.
    func schedule(on day: Date) -> [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard active, !deleted, cal.startOfDay(for: startDate) <= start else { return [] }
        if let endDate, cal.startOfDay(for: endDate) < start { return [] }
        return times.compactMap { cal.date(byAdding: .minute, value: $0, to: start) }
    }

    static func timeLabel(_ minutes: Int) -> String {
        let d = Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return d.formatted(date: .omitted, time: .shortened)
    }
}

@Model final class DoseLog {
    @Attribute(.unique) var id: String
    var medicineID: String
    var profileID: String
    var scheduled: Date
    var status: String
    var note: String
    var by: String
    var at: Date

    init(id: String, medicineID: String, profileID: String, scheduled: Date, status: String, by: String) {
        self.id = id
        self.medicineID = medicineID
        self.profileID = profileID
        self.scheduled = scheduled
        self.status = status
        self.note = ""
        self.by = by
        self.at = .now
    }

    /// One log per medicine per scheduled time.
    static func key(_ medicineID: String, _ scheduled: Date) -> String {
        "\(medicineID)@\(Int(scheduled.timeIntervalSince1970 / 60))"
    }
}

enum HealthEventKind: String, CaseIterable {
    case injury, illness, surgery, hospital, emergency, checkup, other
    var title: String {
        switch self {
        case .injury: "Injury"
        case .illness: "Illness"
        case .surgery: "Surgery"
        case .hospital: "Hospital stay"
        case .emergency: "Emergency"
        case .checkup: "Check-up"
        case .other: "Other"
        }
    }
    var icon: String {
        switch self {
        case .injury: "bandage.fill"
        case .illness: "thermometer.medium"
        case .surgery: "cross.case.fill"
        case .hospital: "bed.double.fill"
        case .emergency: "light.beacon.max.fill"
        case .checkup: "stethoscope"
        case .other: "heart.text.square.fill"
        }
    }
}

struct HealthUpdate: Codable, Hashable {
    var text: String
    var by: String
    var at: Date
    var recovery: Int
}

@Model final class HealthEvent {
    @Attribute(.unique) var id: String
    var profileID: String
    var kind: String
    var title: String
    var details: String
    var date: Date
    var severity: Int
    var status: String
    var recovery: Int
    var updatesData: Data?
    var attachmentsData: Data?
    var createdBy: String
    var deleted: Bool
    var updatedAt: Date

    init(id: String, profileID: String, kind: String, title: String, createdBy: String) {
        self.id = id
        self.profileID = profileID
        self.kind = kind
        self.title = title
        self.details = ""
        self.date = .now
        self.severity = 1
        self.status = "ongoing"
        self.recovery = 0
        self.createdBy = createdBy
        self.deleted = false
        self.updatedAt = .distantPast
    }

    var updates: [HealthUpdate] {
        get { Packed.decode([HealthUpdate].self, updatesData) ?? [] }
        set { updatesData = Packed.encode(newValue) }
    }
    var attachments: [AttachmentRef] {
        get { Packed.decode([AttachmentRef].self, attachmentsData) ?? [] }
        set { attachmentsData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }
    var kindValue: HealthEventKind { HealthEventKind(rawValue: kind) ?? .other }
}

enum VaultCategory: String, CaseIterable {
    case report, prescription, scan, insurance, bill, other
    var title: String {
        switch self {
        case .report: "Lab report"
        case .prescription: "Prescription"
        case .scan: "X-ray / Scan"
        case .insurance: "Insurance"
        case .bill: "Bill"
        case .other: "Other"
        }
    }
    var icon: String {
        switch self {
        case .report: "doc.text.magnifyingglass"
        case .prescription: "pills.fill"
        case .scan: "xray"
        case .insurance: "shield.lefthalf.filled"
        case .bill: "indianrupeesign.square"
        case .other: "folder.fill"
        }
    }
}

@Model final class VaultItem {
    @Attribute(.unique) var id: String
    var profileID: String
    var title: String
    var category: String
    var date: Date
    var attachmentData: Data?
    var addedBy: String
    var deleted: Bool

    init(id: String, profileID: String, title: String, category: String, date: Date, addedBy: String) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.category = category
        self.date = date
        self.addedBy = addedBy
        self.deleted = false
    }

    var attachment: AttachmentRef? {
        get { Packed.decode(AttachmentRef.self, attachmentData) }
        set { attachmentData = newValue.map { Packed.encode($0) } }
    }
}

/// A task follow-up (Business Tasks Pro): set by the task creator, it keeps nudging everyone on the task —
/// the assignees, or the whole group for a group task — until the work is done or the end date passes.
struct FollowUp: Codable, Hashable {
    /// Times of day, minutes after midnight (1–4 per day).
    var times: [Int] = [600]
    /// Weekdays, Calendar numbering (1 = Sunday … 7 = Saturday).
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    /// nil = until the task is completed.
    var until: Date?
    /// Everyone in the group chat, not only assignees.
    var wholeGroup: Bool = false
}
