import Foundation

/// Everything that changes shared data travels as one of these events, encrypted end-to-end.
/// Messages are append-only; edits, deletes, reactions and task changes are separate events.
struct Event: Codable {
    var id: String
    var conv: String
    /// Sender. On receipt this is overwritten with the CloudKit-authenticated creator of the record.
    var from: String
    var at: Date
    var body: Body

    enum Body: Codable {
        case message(MessagePayload)
        case edit(id: String, text: String)
        case unsend(id: String)
        case react(id: String, emoji: String?)
        case group(GroupPayload)
        case leave
        case task(TaskPayload)
        case taskDelete(id: String)
        case checklist(ChecklistPayload)
        case comment(CommentPayload)
        case taskPart(taskID: String, done: Bool)
        case receipt(delivered: Date?, read: Date?)
        case taskFile(TaskFilePayload)
        case approval(ApprovalPayload)
        case decision(DecisionPayload)
        case expense(ExpensePayload)
    }
}

struct MessagePayload: Codable {
    var id: String
    var text: String
    var replyTo: String?
    var attachments: [AttachmentRef]
}

struct GroupPayload: Codable {
    var title: String
    var members: [MemberInfo]
    var avatar: Data?
    /// Current key version (bumped when someone is removed).
    var keyVersion: Int
}

/// A task with a change time per field; receivers keep the newest value of each field.
struct TaskPayload: Codable {
    var id: String
    var sourceMessageID: String?
    var title: String
    var notes: String
    var status: TaskStatus
    var priority: WorkPriority
    var dueAt: Date?
    var policy: CompletionPolicy
    var assignees: [String]
    var createdBy: String
    var createdAt: Date
    var completedAt: Date?
    var completedBy: String?
    var stamps: [String: Date]
    /// Short note for the activity feed ("changed the due date").
    var change: String?
}

struct ChecklistPayload: Codable {
    var id: String
    var taskID: String
    var title: String
    var done: Bool
    var position: Double
    var deleted: Bool
    var at: Date
}

struct CommentPayload: Codable {
    var id: String
    var taskID: String
    var body: String
}

/// A photo, document or link attached to a task.
struct TaskFilePayload: Codable {
    var id: String
    var taskID: String
    /// "image", "file" or "link"
    var kind: String
    var attachment: AttachmentRef?
    var url: String?
    var title: String
    var deleted: Bool
}

/// A request for someone's approval: shown as a card in the chat, optionally linked to a task.
struct ApprovalPayload: Codable {
    var id: String
    var messageID: String
    var taskID: String?
    var title: String
    var details: String
    var amount: Double?
    var approvers: [String]
    var attachments: [AttachmentRef]
}

/// An approver's answer, with a note ("for 3 days only") and an approved amount ("only 200").
struct DecisionPayload: Codable {
    var approvalID: String
    var approved: Bool
    var note: String
    var amount: Double?
}

/// Money spent on a task, with bills / vouchers attached. Last change wins.
struct ExpensePayload: Codable {
    var id: String
    var taskID: String
    var title: String
    var amount: Double
    var date: Date
    var paidBy: String
    var category: String
    var receipts: [AttachmentRef]
    var deleted: Bool
    var at: Date
}

/// A group key, sent to one member, encrypted with a key only the two of us can compute.
struct KeyShare: Codable {
    var conv: String
    var version: Int
    var key: Data
}

extension TaskItem {
    /// Shared fields that take part in last-writer-wins merging.
    static let sharedFields = ["title", "notes", "status", "priority", "dueAt", "policy", "assignees"]

    var payload: TaskPayload {
        TaskPayload(id: id, sourceMessageID: sourceMessageID, title: title, notes: notes, status: status, priority: priority,
                    dueAt: dueAt, policy: policy, assignees: assignees, createdBy: createdBy, createdAt: createdAt,
                    completedAt: completedAt, completedBy: completedBy, stamps: stamps, change: nil)
    }

    /// Takes each field from `p` when its stamp is newer than ours. Returns the names of fields that changed.
    @discardableResult
    func merge(_ p: TaskPayload) -> [String] {
        var mine = stamps
        var changed: [String] = []
        for f in Self.sharedFields {
            let theirs = p.stamps[f] ?? p.createdAt
            let ours = mine[f] ?? .distantPast
            guard theirs > ours else { continue }
            mine[f] = theirs
            switch f {
            case "title": if title != p.title { title = p.title; changed.append(f) }
            case "notes": if notes != p.notes { notes = p.notes; changed.append(f) }
            case "status":
                if status != p.status { status = p.status; changed.append(f) }
                completedAt = p.completedAt
                completedBy = p.completedBy
            case "priority": if priority != p.priority { priority = p.priority; changed.append(f) }
            case "dueAt": if dueAt != p.dueAt { dueAt = p.dueAt; changed.append(f) }
            case "policy": if policy != p.policy { policy = p.policy; changed.append(f) }
            case "assignees": if assignees != p.assignees { assignees = p.assignees; changed.append(f) }
            default: break
            }
        }
        stamps = mine
        if !changed.isEmpty { updatedAt = .now }
        return changed
    }
}
