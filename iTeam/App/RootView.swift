import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @EnvironmentObject var modules: ModuleRegistry
    @Query private var conversations: [Conversation]
    @Query(filter: #Predicate<ActivityItem> { !$0.read }) private var unreadActivity: [ActivityItem]

    private var unreadChats: Int { conversations.filter { !$0.muted && $0.unread > 0 }.count }
    private var tasksOn: Bool { modules.isOn(ModuleRegistry.businessTasks) }

    var body: some View {
        if !engine.isSetUp {
            OnboardingView()
        } else {
            TabView(selection: $router.tab) {
                Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: Router.TabID.chats) {
                    ChatListView()
                }
                .badge(unreadChats)

                Tab("Tasks", systemImage: "checklist", value: Router.TabID.tasks) {
                    TaskDashboardView()
                }
                .hidden(!tasksOn)

                Tab("Care", systemImage: "heart.text.square.fill", value: Router.TabID.care) {
                    CareHomeView()
                }
                .hidden(!modules.isVisible(ModuleRegistry.iLifeCare))

                Tab("Activity", systemImage: "bell.fill", value: Router.TabID.activity) {
                    ActivityView()
                }
                .badge(unreadActivity.count)

                Tab("Settings", systemImage: "gearshape.fill", value: Router.TabID.settings) {
                    SettingsView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .task {
                engine.setForeground(true)
                await engine.sync()
            }
        }
    }
}
