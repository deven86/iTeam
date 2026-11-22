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
        case poll(PollPayload)
        case vote(VotePayload)
        case care(CareProfilePayload)
        case medicine(MedicinePayload)
        case dose(DosePayload)
        case healthEvent(HealthEventPayload)
        case vault(VaultPayload)
        case gymMember(GymMemberPayload)
        case gymPlan(GymPlanPayload)
        case gymSession(GymSessionPayload)
        case gymPayment(GymPaymentPayload)
        case post(PostPayload)
        case postReact(postID: String, emoji: String?)
        case postComment(PostCommentPayload)
        case postSeen(postID: String)
        /// My FaceTime phone or email for this contact ("" = stop sharing).
        case facetime(handle: String)
        /// An assignee accepts or declines a task assigned to them.
        case taskAccept(taskID: String, accept: Bool, note: String)
        /// My profile picture, sent only to contacts when my photo is set to "My contacts".
        case photo(Data?)
        /// Disappearing-messages timer for this chat (0 = off).
        case chatTimer(seconds: Int)
        /// My "About" line ("" = hidden).
        case about(String)
        /// Doctor → patient prescription (create / update / delete).
        case prescription(PrescriptionPayload)
        /// Patient accepts or declines a prescription.
        case rxAnswer(id: String, accept: Bool, note: String)
        /// Check In: started, arrived, extended or ended.
        case checkIn(CheckInPayload)
        /// What I'm listening to on Apple Music ("" = nothing / hidden).
        case nowPlaying(String)
        /// A record in a business module (Khata, Tuition, Rent, Legal, Clinic, Bills).
        case biz(BizPayload)
        /// An invitation in a chat, and the answers to it.
        case invite(InviteEventPayload)
        case rsvp(eventID: String, answer: String)
        /// Meetings: details (admins), a vote, or "I'm attending".
        case meeting(MeetingPayload)
        case meetingVote(meetingID: String, pollID: String, option: Int)
        case meetingAttend(meetingID: String)
        /// Attendance: company, members, punches, leaves, holidays and change requests (a batch).
        case attendance(AttPayload)
        /// A two-player game (X and O) in a chat.
        case game(GamePayload)
        /// Finance: income, expenses, cheques, approvals (a batch).
        case finance(FinPayload)
    }
}

struct MessagePayload: Codable {
    var id: String
    var text: String
    var replyTo: String?
    var attachments: [AttachmentRef]
    /// Forwarded from another chat.
    var fwd: Bool?
    /// Magic moment: show at this time.
    var at: Date? = nil
    /// Disappearing: seconds to keep.
    var ttl: Int? = nil
    /// View once: the photo/video can be opened one time.
    var once: Bool? = nil
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
    /// Recurrence (Business Tasks Pro). nil from older versions = "none".
    var repeatRule: String? = nil
    /// Follow-up schedule (Business Tasks Pro), JSON of FollowUp. "" = off.
    var followUp: String? = nil
    /// Set at creation: assigned to specific people, who must accept.
    var needsAcceptance: Bool? = nil
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

// MARK: Polls

struct PollOption: Codable, Hashable, Identifiable {
    var id: String
    var text: String
}

struct PollPayload: Codable {
    var id: String
    var messageID: String
    var question: String
    var options: [PollOption]
    var multiple: Bool
}

/// A voter's full current choice (empty = vote withdrawn). Newest wins.
struct VotePayload: Codable {
    var pollID: String
    var optionIDs: [String]
}

// MARK: iLife Care

/// The person being cared for, shared in one chat (family or team).
struct CareProfilePayload: Codable {
    var id: String
    var name: String
    var relation: String
    var bloodGroup: String
    var allergies: String
    var conditions: String
    var emergencyContact: String
    var notes: String
    var avatar: Data?
    var deleted: Bool
    var at: Date
}

struct MedicinePayload: Codable {
    var id: String
    var profileID: String
    var name: String
    var dose: String
    var form: String
    /// Minutes after midnight, e.g. 540 = 9:00
    var times: [Int]
    var instructions: String
    var startDate: Date
    var endDate: Date?
    var stock: Int?
    var active: Bool
    var deleted: Bool
    var at: Date
}

struct DosePayload: Codable {
    var id: String
    var medicineID: String
    var profileID: String
    var scheduled: Date
    /// "taken" or "skipped"
    var status: String
    var note: String
}

struct HealthEventPayload: Codable {
    var id: String
    var profileID: String
    /// injury, illness, surgery, hospital, emergency, checkup, other
    var kind: String
    var title: String
    var details: String
    var date: Date
    /// 1 mild … 3 severe
    var severity: Int
    /// ongoing, recovering, recovered
    var status: String
    var recovery: Int
    var update: String?
    var attachments: [AttachmentRef]
    var deleted: Bool
    var at: Date
}

struct VaultPayload: Codable {
    var id: String
    var profileID: String
    var title: String
    /// report, prescription, scan, insurance, bill, other
    var category: String
    var date: Date
    var attachment: AttachmentRef?
    var deleted: Bool
}

/// A group key, sent to one member, encrypted with a key only the two of us can compute.
struct KeyShare: Codable {
    var conv: String
    var version: Int
    var key: Data
}

extension TaskItem {
    /// Shared fields that take part in last-writer-wins merging.
    static let sharedFields = ["title", "notes", "status", "priority", "dueAt", "policy", "assignees", "repeat", "followUp"]

    var payload: TaskPayload {
        TaskPayload(id: id, sourceMessageID: sourceMessageID, title: title, notes: notes, status: status, priority: priority,
                    dueAt: dueAt, policy: policy, assignees: assignees, createdBy: createdBy, createdAt: createdAt,
                    completedAt: completedAt, completedBy: completedBy, stamps: stamps, change: nil, repeatRule: repeatRule,
                    followUp: followUpRaw, needsAcceptance: needsAcceptance ? true : nil)
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
            case "repeat":
                let r = p.repeatRule ?? "none"
                if repeatRule != r { repeatRule = r; changed.append(f) }
            case "followUp":
                // Older versions don't send it; never let their silence switch a follow-up off.
                guard let fu = p.followUp else { break }
                if followUpRaw != fu { followUpRaw = fu; changed.append(f) }
            default: break
            }
        }
        stamps = mine
        if !changed.isEmpty { updatedAt = .now }
        return changed
    }
}

// MARK: Gym & Training

struct GymMemberPayload: Codable {
    var id: String
    var name: String
    var relation: String
    var phone: String
    var goal: String
    var trainer: String
    var fee: Double
    var avatar: Data?
    var deleted: Bool
    var at: Date
}

struct GymPlanPayload: Codable {
    var id: String
    var memberID: String
    var gymName: String
    var branch: String
    var planName: String
    var start: Date
    var end: Date
    var fee: Double
    var notes: String
    var deleted: Bool
    var at: Date
}

struct GymSessionPayload: Codable {
    var id: String
    var memberID: String
    var date: Date
    var trainer: String
    var workout: String
    var notes: String
    var deleted: Bool
    var at: Date
}

struct GymPaymentPayload: Codable {
    var id: String
    var memberID: String
    var kind: String
    var amount: Double
    var date: Date
    var method: String
    var sessions: Int
    var notes: String
    var receipts: [AttachmentRef]
    var deleted: Bool
    var at: Date
}

// MARK: Views

struct PostPayload: Codable {
    var id: String
    var kind: String
    var text: String
    var media: [AttachmentRef]
    var status: Bool
    var expires: Date?
    var deleted: Bool
    var at: Date
}

struct PostCommentPayload: Codable {
    var id: String
    var postID: String
    var text: String
    var deleted: Bool
}


struct PrescriptionPayload: Codable {
    var id: String
    var patientID: String
    var patientName: String
    var diagnosis: String
    var advice: String
    var items: [RxItem]
    var nextVisit: Date?
    var deleted: Bool
    var at: Date
}
