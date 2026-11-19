import SwiftUI

/// Paid modules can be added later without touching the chat core.
/// Each module has an ID, a version and an entitlement state. Today every module is free;
/// a StoreKit 2 purchase (verified on the device, no server) can later flip `entitled`.
/// If a paid module ever lapses, its data stays readable and exportable — nothing is locked or deleted.
struct ModuleInfo: Identifiable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let version: Int
    /// Product ID in App Store Connect when the module becomes paid (nil = free).
    let productID: String?
}

@MainActor
final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()

    static let businessTasks = ModuleInfo(id: "business-tasks", title: "Business Tasks",
                                          summary: "Turn messages into tasks, assign them, track group progress and deadlines.",
                                          icon: "checklist", version: 1, productID: nil)

    static let iLifeCare = ModuleInfo(id: "ilife-care", title: "iLife Care",
                                      summary: "Medicines, injuries, health events, recovery and a medical vault — shared with family or team.",
                                      icon: "heart.text.square.fill", version: 1, productID: Store.careProductID)

    static let all: [ModuleInfo] = [businessTasks, iLifeCare]

    /// Modules shown as "coming later" in Settings.
    static let upcoming: [(String, String, String)] = [
        ("Business Tasks Pro", "Recurring tasks, templates and reports", "repeat"),
        ("Team Workspace", "Several workspaces, advanced roles and audit history", "building.2"),
        ("Files & Knowledge", "A structured library for shared documents", "folder"),
        ("AI Assistant", "On-device chat summaries and task extraction", "sparkles")
    ]

    @Published private var enabled: [String: Bool]

    private init() {
        enabled = UserDefaults.standard.dictionary(forKey: "modules.enabled") as? [String: Bool] ?? [:]
    }

    /// The user has the right to use the module: free modules always; paid ones with an active subscription.
    func isEntitled(_ m: ModuleInfo) -> Bool {
        if m.productID == Store.careProductID { return Store.shared.careUnlocked }
        return m.productID == nil
    }

    /// Entitled and switched on in Settings.
    func isOn(_ m: ModuleInfo) -> Bool { isEntitled(m) && (enabled[m.id] ?? true) }

    /// Shown in the app (paid modules show their paywall until subscribed).
    func isVisible(_ m: ModuleInfo) -> Bool { enabled[m.id] ?? true }

    func setOn(_ m: ModuleInfo, _ on: Bool) {
        enabled[m.id] = on
        UserDefaults.standard.set(enabled, forKey: "modules.enabled")
    }
}
