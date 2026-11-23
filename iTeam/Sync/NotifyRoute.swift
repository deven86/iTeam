import Foundation

/// Every notification has a type (switchable in Settings → Notifications) and a link to the exact item.
enum NotifyRoute {
    struct Kind: Identifiable { let id: String; let title: String; let icon: String }

    static let kinds: [Kind] = [
        Kind(id: "messages", title: "Messages", icon: "bubble.left.fill"),
        Kind(id: "tasks", title: "Tasks, approvals & expenses", icon: "checklist"),
        Kind(id: "polls", title: "Polls", icon: "chart.bar.fill"),
        Kind(id: "meetings", title: "Meetings", icon: "person.3.fill"),
        Kind(id: "events", title: "Events", icon: "party.popper.fill"),
        Kind(id: "care", title: "iLife Care & Doctor", icon: "heart.text.square.fill"),
        Kind(id: "gym", title: "Gym & Training", icon: "dumbbell.fill"),
        Kind(id: "biz", title: "Legal, Khata, Rent, Tuition, Clinic…", icon: "briefcase.fill"),
        Kind(id: "attendance", title: "Attendance", icon: "person.badge.clock.fill"),
        Kind(id: "finance", title: "Finance (approvals, dues)", icon: "indianrupeesign.circle.fill"),
        Kind(id: "minis", title: "Minis & posts", icon: "play.rectangle.fill"),
        Kind(id: "safety", title: "Check In & safety", icon: "location.circle.fill"),
        Kind(id: "games", title: "Games", icon: "gamecontroller.fill"),
        Kind(id: "surveys", title: "Surveys", icon: "list.clipboard.fill"),
        Kind(id: "crm", title: "CRM leads & quotes", icon: "person.crop.circle.badge.checkmark"),
        Kind(id: "society", title: "Society: visitors, bills, notices", icon: "building.2.crop.circle.fill"),
        Kind(id: "build", title: "Builder & Infra: sales, payments, site", icon: "building.columns.fill"),
        Kind(id: "rooms", title: "Rooms private messages", icon: "bubble.left.and.text.bubble.right.fill"),
        Kind(id: "groups", title: "Groups (added, changes)", icon: "person.2.fill"),
    ]

    /// (type, link) for an event. Link nil = open the chat.
    static func of(_ body: Event.Body) -> (String, String?) {
        switch body {
        case .message, .edit, .unsend, .react, .facetime, .photo, .about, .chatTimer, .nowPlaying, .receipt, .leave:
            return ("messages", nil)
        case .group: return ("groups", nil)
        case .task(let p): return ("tasks", "iteam://task/\(p.id)")
        case .taskDelete(let id): return ("tasks", "iteam://task/\(id)")
        case .checklist(let p): return ("tasks", "iteam://task/\(p.taskID)")
        case .comment(let p): return ("tasks", "iteam://task/\(p.taskID)")
        case .taskPart(let id, _): return ("tasks", "iteam://task/\(id)")
        case .taskFile(let p): return ("tasks", "iteam://task/\(p.taskID)")
        case .approval(let p): return ("tasks", p.taskID.map { "iteam://task/\($0)" })
        case .decision: return ("tasks", nil)
        case .expense(let p): return ("tasks", "iteam://task/\(p.taskID)")
        case .taskAccept(let id, _, _): return ("tasks", "iteam://task/\(id)")
        case .poll, .vote: return ("polls", nil)
        case .care(let p): return ("care", "iteam://item/care/\(p.id)")
        case .medicine(let p): return ("care", "iteam://item/care/\(p.profileID)")
        case .dose(let p): return ("care", "iteam://item/care/\(p.profileID)")
        case .healthEvent(let p): return ("care", "iteam://item/care/\(p.profileID)")
        case .vault: return ("care", "iteam://open/care")
        case .prescription, .rxAnswer: return ("care", "iteam://open/care")
        case .gymMember(let p): return ("gym", "iteam://item/gym/\(p.id)")
        case .gymPlan(let p): return ("gym", "iteam://item/gym/\(p.memberID)")
        case .gymSession(let p): return ("gym", "iteam://item/gym/\(p.memberID)")
        case .gymPayment(let p): return ("gym", "iteam://item/gym/\(p.memberID)")
        case .society: return ("society", "iteam://open/society")
        case .build: return ("build", "iteam://open/build")
        case .crmGroup: return ("crm", "iteam://open/crm")
        case .crmLead(let p): return ("crm", "iteam://item/crm/\(p.id)")
        case .crmActivity(let p): return ("crm", "iteam://item/crm/\(p.leadID)")
        case .crmQuoteAnswer(_, let lead, _, _): return ("crm", "iteam://item/crm/\(lead)")
        case .gymPhoto(let p): return ("gym", "iteam://item/gym/\(p.memberID)")
        case .gymTrainerAnswer(let id, _, _): return ("gym", "iteam://item/gym/\(id)")
        case .post, .postReact, .postComment, .postSeen: return ("minis", "iteam://open/views")
        case .checkIn: return ("safety", nil)
        case .biz(let p): return ("biz", "iteam://item/biz/\(p.module)/\(p.parentID.isEmpty ? p.id : p.parentID)")
        case .invite, .rsvp: return ("events", "iteam://open/events")
        case .meeting(let p): return ("meetings", "iteam://item/meeting/\(p.id)")
        case .meetingVote(let id, _, _), .meetingAttend(let id): return ("meetings", "iteam://item/meeting/\(id)")
        case .attendance: return ("attendance", "iteam://open/attendance")
        case .game(let p): return ("games", "iteam://item/game/\(p.id)")
        case .finance: return ("finance", "iteam://open/finance")
        case .album: return ("events", nil)
        case .survey: return ("surveys", "iteam://open/survey")
        case .doc: return ("documents", nil)
        }
    }
}
