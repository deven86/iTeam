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
        let schema = Schema(ITeamSchema.models)
        // The local store is never mirrored to iCloud by SwiftData; CloudKit only carries encrypted events.
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // A damaged store must not brick the app: start a fresh one next to it.
            let url = URL.applicationSupportDirectory.appendingPathComponent("iTeam-recovered.store")
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        }
        MainActor.assumeIsolated {
            SyncEngine.shared.attach(container)
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
                Task {
                    await lock.unlock()
                    await engine.sync()
                }
            case .background:
                engine.setForeground(false)
                lock.lock()
                AppDelegate.scheduleRefresh()
                Reminders.shared.updateBadge(totalUnread(engine))
            default:
                break
            }
        }
    }

    private func totalUnread(_ engine: SyncEngine) -> Int {
        let convs = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        return convs.filter { !$0.muted }.reduce(0) { $0 + $1.unread }
    }
}

/// Deep links from notifications and invite links.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    enum TabID: Hashable { case chats, tasks, care, activity, settings }

    @Published var tab: TabID = .chats
    @Published var openConversation: String?
    @Published var openTask: String?
    @Published var openCare: String?
    @Published var pendingInvite: SyncEngine.Invite?

    func handle(_ url: URL) {
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
        tab = .care
        openCare = care
    }

    func show(task: String) {
        tab = .tasks
        openTask = task
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshID = "com.jondhale.iteam.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            Reminders.shared.registerCategories()
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
