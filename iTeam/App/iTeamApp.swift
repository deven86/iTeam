import SwiftUI
import SwiftData
import UserNotifications
import BackgroundTasks

@main
struct iTeamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lock = AppLock()
    @StateObject private var router = Router.shared
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer

    init() {
        // A restore downloaded last session replaces the data before the database opens.
        Backup.applyPendingRestore()
        let schema = Schema(ITeamSchema.models)
        // The local store is never mirrored to iCloud by SwiftData; CloudKit only carries encrypted events.
        let config = ScreenshotMode.on ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                                       : ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // A damaged store must not brick the app: start a fresh one next to it.
            let url = URL.applicationSupportDirectory.appendingPathComponent("iTeam-recovered.store")
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        }
        MainActor.assumeIsolated {
            SyncEngine.shared.attach(container)
            ScreenshotMode.prepare(SyncEngine.shared)
        }
    }

    var body: some Scene {
        WindowGroup {
            LookHost {
                ZStack {
                    RootView()
                    if lock.lockEnabled && !lock.isUnlocked {
                        LockScreenView().transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: lock.isUnlocked)
            }
            .environmentObject(lock)
            .environmentObject(router)
            .environmentObject(SyncEngine.shared)
            .environmentObject(LookManager.shared)
            .environmentObject(ModuleRegistry.shared)
            .onOpenURL { url in router.handle(url) }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            let engine = SyncEngine.shared
            switch phase {
            case .active:
                engine.setForeground(true)
                NowPlaying.shared.start()
                Reminders.shared.updateBadge(totalUnread(engine))
                Task {
                    await lock.unlock()
                    await engine.sync()
                }
            case .background:
                engine.setForeground(false)
                lock.lock()
                AppDelegate.scheduleRefresh()
                Reminders.shared.updateBadge(totalUnread(engine))
                Backup.shared.runIfDue()
            default:
                break
            }
        }
    }

    private func totalUnread(_ engine: SyncEngine) -> Int {
        let convs = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        let chats = convs.filter { !$0.muted && !$0.archived }.reduce(0) { $0 + $1.unread }
        let me = engine.me
        let tasks = ((try? container.mainContext.fetch(FetchDescriptor<TaskItem>())) ?? [])
            .filter { $0.deletedAt == nil && ($0.awaitsMe(me) || ($0.isOverdue && $0.assignees.contains(me))) }.count
        return chats + tasks
    }
}

/// Deep links from notifications and invite links.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    enum TabID: String, Hashable { case chats, views, rooms, doctor, safety, events, khata, tuition, rent, legal, clinic, bills, kids, travel, petcare, survey, crm, meetings, attendance, finance, tasks, care, gym, mind, activity, hub, settings }

    @Published var tab: TabID = .chats
    /// Module tabs currently in the bottom bar (set by RootView). Others open inside the Modules hub.
    @Published var barTabs: [TabID] = [.tasks, .activity]
    /// Every module tab the user can open right now (set by RootView).
    @Published var availableTabs: [TabID] = [.tasks, .activity]
    /// The module shown inside the Modules hub, if any.
    @Published var hubOpen: TabID?
    /// A module that isn't in the bottom bar, opened as a sheet (from Settings → Modules or a notification).
    @Published var moduleSheet: TabID?
    @Published var openConversation: String?
    /// An exact item to open on top of everything (from a notification or Activity).
    @Published var openItem: OpenItem?
    @Published var openModuleStore = false
    struct OpenItem: Identifiable, Equatable { let kind: String; let module: String; let id: String }
    @Published var openTask: String?
    @Published var openCare: String?
    @Published var openGym: String?
    /// "morning" or "evening": open My Day.
    @Published var openMyDay: String?
    @Published var pendingInvite: SyncEngine.Invite?

    func handle(_ url: URL) {
        // Widgets and Live Activities: iteam://open/<tab>, iteam://task/<id>
        if url.scheme == "iteam", url.host == "open" || url.host == "task" {
            let arg = url.pathComponents.dropFirst().first ?? ""
            if url.host == "task" { show(task: arg); return }
            if arg == "myday" { openMyDay = Calendar.current.component(.hour, from: .now) >= 17 ? "evening" : "morning"; return }
            if arg == "training" { go(.gym); return }
            if arg == "dose" { go(.care); return }
            if arg == "task" { go(.tasks); return }
            if let t = TabID(rawValue: arg) { go(t) }
            return
        }
        // Exact items: iteam://item/<kind>/<id> (or iteam://item/biz/<module>/<id>)
        if url.scheme == "iteam", url.host == "item" {
            let parts = Array(url.pathComponents.dropFirst())
            guard let kind = parts.first, parts.count >= 2 else { return }
            switch kind {
            case "care": show(care: parts[1])
            case "gym": show(gym: parts[1])
            case "biz":
                openItem = OpenItem(kind: kind, module: parts[1], id: parts.last ?? "")
            default:
                openItem = OpenItem(kind: kind, module: "", id: parts[1])
            }
            return
        }
        if let invite = SyncEngine.Invite(text: url.absoluteString) {
            pendingInvite = invite
            tab = .chats
        }
    }

    func show(conversation: String) {
        tab = .chats
        openConversation = conversation
    }

    func show(care: String) {
        go(.care)
        openCare = care
    }

    func show(gym: String) {
        go(.gym)
        openGym = gym
    }

    func show(task: String) {
        go(.tasks)
        openTask = task
    }

    /// Opens a tab or module: in the bottom bar when it is there, otherwise inside the Modules hub.
    func go(_ t: TabID) {
        switch t {
        case .chats, .settings, .hub:
            tab = t
        default:
            if barTabs.contains(t) { tab = t } else { moduleSheet = t }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshID = "com.jondhale.iteam.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            Reminders.shared.registerCategories()
            _ = CheckInMonitor.shared
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.scheduleRefresh()
            let work = Task { @MainActor in
                await SyncEngine.shared.sync()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        application.registerForRemoteNotifications()
        return true
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// CloudKit pushes (loud and quiet) land here when iTeam is running or can be woken.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await SyncEngine.shared.sync()
        return .newData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "push.registrationError")
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        UserDefaults.standard.removeObject(forKey: "push.registrationError")
    }

    // Banner while the app is open — except for the chat already on screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let conv = notification.request.content.userInfo["conv"] as? String
            ?? notification.request.content.threadIdentifier
        let open = await MainActor.run { SyncEngine.shared.openConversation }
        Task { @MainActor in await SyncEngine.shared.sync() }
        if let open, open == conv { return [] }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let conv = info["conv"] as? String
        let taskID = info["task"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            let engine = SyncEngine.shared
            if let medID = info["med"] as? String, let profileID = info["profile"] as? String,
               let atText = info["at"] as? String, let at = Double(atText) {
                let scheduled = Date(timeIntervalSince1970: at)
                if let ctx = engine.context,
                   let med = try? ctx.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { $0.id == medID })).first,
                   let profile = engine.careProfile(profileID) {
                    switch action {
                    case Reminders.takenAction: engine.logDose(med, profile: profile, scheduled: scheduled, taken: true)
                    case Reminders.skipAction: engine.logDose(med, profile: profile, scheduled: scheduled, taken: false)
                    default: Router.shared.show(care: profileID)
                    }
                }
            } else if let link = info["link"] as? String, let url = URL(string: link), action == UNNotificationDefaultActionIdentifier {
                Router.shared.handle(url)
            } else if let kind = info["myday"] as? String {
                Router.shared.openMyDay = kind
            } else if let tab = info["tab"] as? String, let t = Router.TabID(rawValue: tab) {
                Router.shared.go(t)
            } else if let taskID {
                switch action {
                case Reminders.doneAction:
                    if let t = engine.task(taskID) {
                        if t.policy == .all && t.assignees.contains(engine.me) { engine.setMyPart(t, done: true) }
                        else { engine.setStatus(t, .done) }
                    }
                case Reminders.snoozeAction:
                    if let ctx = engine.context { Reminders.shared.snooze(taskID: taskID, context: ctx, me: engine.me) }
                default:
                    Router.shared.show(task: taskID)
                }
            } else if let conv {
                Router.shared.show(conversation: conv)
            }
        }
    }
}

extension Router.TabID: Identifiable { var id: String { rawValue } }
