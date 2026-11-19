import SwiftUI

/// Every module in the Module Store. New modules are added here; chat itself is always free.
/// Paid modules are monthly StoreKit 2 subscriptions verified on the device. If one lapses,
/// its data stays readable and exportable — nothing is locked away or deleted.
struct ModuleInfo: Identifiable {
    enum Availability { case included, paid, comingSoon }

    /// Screens shown as previews on the module's page.
    enum Preview: Hashable {
        case taskDashboard, taskForm, proForm, careDashboard, medicineForm
        case taskList, approval, expenses, poll
        case recurring, templates, reports
        case careToday, careEvent, careVault
        case workspaces, library, assistant
        case gymDashboard, gymForm, gymSessions
    }

    let id: String
    let title: String
    let tagline: String
    let icon: String
    let colors: [UInt32]
    let availability: Availability
    let productID: String?
    /// Shown before the App Store price loads.
    let fallbackPrice: String
    let problems: [String]
    let benefits: [String]
    let previews: [Preview]
    let note: String
}

@MainActor
final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()

    static let businessTasks = ModuleInfo(
        id: "business-tasks", title: "Business Tasks",
        tagline: "Turn any message into work that gets done.",
        icon: "checklist", colors: [0x28BEE6, 0x3A5BD9], availability: .included, productID: nil, fallbackPrice: "Free",
        problems: ["Work gets lost in long chat threads",
                   "Nobody knows who is doing what, or by when",
                   "Approvals and spending are scattered across calls and slips of paper"],
        benefits: ["Long-press a message → Create Business Task, with the chat linked",
                   "Assign people, set due dates and reminders, track each person's part",
                   "Approval requests with notes and approved amounts",
                   "Expenses with photos of bills and vouchers, against the approved budget",
                   "Polls to decide quickly"],
        previews: [.taskDashboard, .taskForm, .taskList, .approval, .expenses, .poll],
        note: "Included free with iTeam.")

    static let businessPro = ModuleInfo(
        id: "business-pro", title: "Business Tasks Pro",
        tagline: "Repeat work automatically and see how the team is doing.",
        icon: "chart.bar.doc.horizontal.fill", colors: [0x7850F0, 0xC2378C], availability: .paid,
        productID: Store.proProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Recreating the same weekly or monthly tasks by hand",
                   "Typing the same checklist every time a new case, client or job starts",
                   "No clear picture of who finished what, what is overdue and what was spent"],
        benefits: ["Recurring tasks: daily, weekly or monthly — the next one appears when you finish",
                   "Templates: save any task with its checklist and start new ones in one tap",
                   "Reports: done, open and overdue per person; expenses by category and month",
                   "Export reports and expenses to Excel (CSV) to share or file"],
        previews: [.reports, .proForm, .recurring, .templates],
        note: "Only the person who sets up recurring tasks and templates needs Pro; everyone can work on them.")

    static let iLifeCare = ModuleInfo(
        id: "ilife-care", title: "iLife Care",
        tagline: "Look after family health together.",
        icon: "heart.text.square.fill", colors: [0xFF8A5B, 0xE5486B], availability: .paid,
        productID: Store.careProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Missed or double doses when several people look after one person",
                   "Injury and recovery updates lost in family chats",
                   "Reports and prescriptions scattered across phones and paper files"],
        benefits: ["Medicine schedule with reminders on everyone's phone — Taken or Skip",
                   "The whole group is alerted when a dose is skipped or a new event is logged",
                   "Injuries and major health events with severity and recovery progress",
                   "Medical vault for reports, prescriptions, X-rays and insurance",
                   "Blood group, allergies, conditions and emergency contact in one place"],
        previews: [.careDashboard, .medicineForm, .careToday, .careEvent, .careVault],
        note: "Only the person who creates care profiles needs the subscription; family members use them free.")

    static let gymTraining = ModuleInfo(
        id: "gym-training", title: "Gym & Training",
        tagline: "Memberships, trainer sessions and payments — shared with your trainer, clients or family.",
        icon: "dumbbell.fill", colors: [0x4FD1C5, 0x2B6CB0], availability: .paid,
        productID: Store.gymProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Forgetting when the gym membership runs out",
                   "Arguments over how many personal-training sessions are done and how many are paid",
                   "Fees, supplement bills and receipts scattered across UPI apps and paper"],
        benefits: ["Add yourself, family or clients — with relations like Client, or your own custom relation",
                   "Membership with days left, renewal warnings, directions and call buttons",
                   "One-tap “Trained today” — sessions counted per training day, visible to trainer and client",
                   "Training balance: sessions paid vs done, so both sides always agree",
                   "Payments with receipt photos; monthly and yearly spend; PDF statement to share"],
        previews: [.gymDashboard, .gymForm, .gymSessions],
        note: "Only the person who adds members needs the subscription; trainers, clients and family in the chat use it free.")

    static let teamWorkspace = ModuleInfo(
        id: "team-workspace", title: "Team Workspace",
        tagline: "Keep office, trust and family separate.",
        icon: "building.2.fill", colors: [0x4CD38A, 0x1E9A6E], availability: .comingSoon, productID: nil, fallbackPrice: "Coming soon",
        problems: ["Work, trust and family chats and tasks mixed in one list", "No record of who changed what"],
        benefits: ["Separate workspaces with their own chats, tasks and care profiles", "More roles and an audit history"],
        previews: [.workspaces], note: "In development.")

    static let filesKnowledge = ModuleInfo(
        id: "files-knowledge", title: "Files & Knowledge",
        tagline: "Every document your group shares, in one library.",
        icon: "folder.fill", colors: [0xFFC94D, 0xF07B2C], availability: .comingSoon, productID: nil, fallbackPrice: "Coming soon",
        problems: ["Hunting through months of chat for one PDF"],
        benefits: ["Folders and search across chats and tasks", "Pinned important documents"],
        previews: [.library], note: "In development.")

    static let aiAssistant = ModuleInfo(
        id: "ai-assistant", title: "AI Assistant",
        tagline: "Catch up in seconds — privately, on your iPhone.",
        icon: "sparkles", colors: [0xB57CFF, 0x6F5BD6], availability: .comingSoon, productID: nil, fallbackPrice: "Coming soon",
        problems: ["Too many unread messages to read", "Tasks hidden inside conversations"],
        benefits: ["“What did I miss?” summaries", "Suggested tasks from messages", "Runs on-device with Apple Intelligence (iPhone 15 Pro and newer)"],
        previews: [.assistant], note: "In development.")

    static let all: [ModuleInfo] = [businessTasks, businessPro, iLifeCare, gymTraining, teamWorkspace, filesKnowledge, aiAssistant]

    @Published private var enabled: [String: Bool]
    /// Modules the user wants in the iPhone bottom bar, in order (Router.TabID raw values).
    @Published private(set) var pinned: [String]
    /// The iPhone bar holds Chats, up to this many modules, Modules and Settings — five in all,
    /// the most iOS shows before it hides tabs behind “More”.
    static let maxPinned = 3

    private init() {
        enabled = UserDefaults.standard.dictionary(forKey: "modules.enabled") as? [String: Bool] ?? [:]
        pinned = UserDefaults.standard.stringArray(forKey: "modules.pinned2") ?? ["views", "tasks", "activity"]
    }

    /// Which of the available module tabs go in the bar: the user's pins first, then the rest in order.
    func barTabs(available: [Router.TabID]) -> [Router.TabID] {
        let pins = pinned.compactMap(Router.TabID.init(rawValue:)).filter(available.contains)
        let rest = available.filter { !pins.contains($0) }
        return Array((pins + rest).prefix(Self.maxPinned))
    }

    func setPins(_ tabs: [Router.TabID]) {
        pinned = tabs.map(\.rawValue)
        UserDefaults.standard.set(pinned, forKey: "modules.pinned2")
    }

    /// The user has the right to use the module: included ones always; paid ones with an active subscription.
    func isEntitled(_ m: ModuleInfo) -> Bool {
        switch m.availability {
        case .included: true
        case .paid: m.productID.map { Store.shared.isUnlocked($0) } ?? false
        case .comingSoon: false
        }
    }

    /// Entitled and switched on in Settings.
    func isOn(_ m: ModuleInfo) -> Bool { isEntitled(m) && isVisible(m) }

    /// Shown in the app (paid modules show their store page until subscribed).
    func isVisible(_ m: ModuleInfo) -> Bool { enabled[m.id] ?? true }

    func setOn(_ m: ModuleInfo, _ on: Bool) {
        enabled[m.id] = on
        UserDefaults.standard.set(enabled, forKey: "modules.enabled")
    }
}
