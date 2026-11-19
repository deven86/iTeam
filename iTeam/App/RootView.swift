import SwiftUI
import SwiftData

/// Bottom bar on iPhone: Chats · up to two modules · Modules · Settings (five tabs, so iOS never
/// hides any behind “More”). Every other module opens from the Modules hub. On iPad the bar becomes
/// a sidebar with room for everything, so all modules are listed there.
struct RootView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @EnvironmentObject var modules: ModuleRegistry
    @ObservedObject private var store = Store.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var conversations: [Conversation]
    @Query(filter: #Predicate<ActivityItem> { !$0.read }) private var unreadActivity: [ActivityItem]
    @Query(filter: #Predicate<CareProfile> { !$0.deleted }) private var careProfiles: [CareProfile]
    @Query(filter: #Predicate<GymMember> { !$0.deleted }) private var gymMembers: [GymMember]

    private var unreadChats: Int { conversations.filter { !$0.muted && $0.unread > 0 }.count }

    /// Module tabs the user can open right now.
    private var available: [Router.TabID] {
        var a: [Router.TabID] = []
        if modules.isOn(ModuleRegistry.businessTasks) { a.append(.tasks) }
        // Paid modules appear once bought (or unlocked for the owner / TestFlight testing) — or when
        // someone else shared a profile with you, because members use shared profiles free.
        let me = engine.me
        let sharedCare = careProfiles.contains { $0.createdBy != me && !$0.id.hasPrefix("c_demo") }
        let sharedGym = gymMembers.contains { $0.createdBy != me && !$0.id.hasPrefix("g_demo") }
        if modules.isOn(ModuleRegistry.iLifeCare) || (sharedCare && modules.isVisible(ModuleRegistry.iLifeCare)) { a.append(.care) }
        if modules.isOn(ModuleRegistry.gymTraining) || (sharedGym && modules.isVisible(ModuleRegistry.gymTraining)) { a.append(.gym) }
        a.append(.activity)
        return a
    }

    private var inBar: [Router.TabID] {
        sizeClass == .regular ? available : modules.barTabs(available: available)
    }

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
                .hidden(!inBar.contains(.tasks))

                Tab("Care", systemImage: "heart.text.square.fill", value: Router.TabID.care) {
                    CareHomeView()
                }
                .hidden(!inBar.contains(.care))

                Tab("Gym", systemImage: "dumbbell.fill", value: Router.TabID.gym) {
                    GymHomeView()
                }
                .hidden(!inBar.contains(.gym))

                Tab("Activity", systemImage: "bell.fill", value: Router.TabID.activity) {
                    ActivityView()
                }
                .badge(unreadActivity.count)
                .hidden(!inBar.contains(.activity))

                Tab("Modules", systemImage: "square.grid.2x2.fill", value: Router.TabID.hub) {
                    ModulesHubView(available: available, inBar: inBar)
                }
                .badge(inBar.contains(.activity) ? 0 : unreadActivity.count)

                Tab("Settings", systemImage: "gearshape.fill", value: Router.TabID.settings) {
                    SettingsView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .onAppear { router.barTabs = inBar; router.availableTabs = available }
            .onChange(of: available) { _, a in router.availableTabs = a }
            .onChange(of: inBar) { _, bar in
                router.barTabs = bar
                // A tab that just left the bar reopens inside the hub instead of vanishing.
                if [Router.TabID.tasks, .care, .gym, .activity].contains(router.tab), !bar.contains(router.tab) {
                    router.go(router.tab)
                }
            }
            .task {
                engine.setForeground(true)
                await engine.sync()
            }
        }
    }
}

/// The Modules tab: every module you have, as app-style tiles, plus the store and module requests.
struct ModulesHubView: View {
    let available: [Router.TabID]
    let inBar: [Router.TabID]
    @EnvironmentObject var router: Router
    @EnvironmentObject var modules: ModuleRegistry
    @ObservedObject private var store = Store.shared
    @Environment(\.look) private var look
    @Query(filter: #Predicate<ActivityItem> { !$0.read }) private var unreadActivity: [ActivityItem]

    var body: some View {
        if let open = router.hubOpen, available.contains(open) {
            Self.content(open)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Button { withAnimation(.snappy) { router.hubOpen = nil } } label: {
                            Label("All modules", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        Spacer()
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                }
        } else {
            grid
        }
    }

    @ViewBuilder
    static func content(_ t: Router.TabID) -> some View {
        switch t {
        case .tasks: TaskDashboardView()
        case .care: CareHomeView()
        case .gym: GymHomeView()
        default: ActivityView()
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 18)]

    private var grid: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if store.isOwner {
                        Label("Owner — every module is free on your Apple ID", systemImage: "crown.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(look.accent)
                    }
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(available, id: \.self) { t in
                            Button { open(t) } label: { tile(t) }.buttonStyle(PressStyle())
                        }
                    }
                    .lookCard()

                    VStack(spacing: 10) {
                        NavigationLink { ModuleStoreView() } label: {
                            hubRow("bag.fill", "Module Store", "Add more modules to iTeam")
                        }
                        NavigationLink { ModuleRequestView() } label: {
                            hubRow("lightbulb.max.fill", "Request a module", "Tell us what your team needs next")
                        }
                        NavigationLink { BottomBarSettingsView() } label: {
                            hubRow("dock.rectangle", "Bottom bar", "Choose which modules sit in the bar")
                        }
                    }
                    .buttonStyle(PressStyle())
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .lookScreen()
            .navigationTitle("Modules")
        }
    }

    private func open(_ t: Router.TabID) {
        Haptics.tap()
        if inBar.contains(t) { router.tab = t } else { withAnimation(.snappy) { router.hubOpen = t } }
    }

    private func tile(_ t: Router.TabID) -> some View {
        let info = Self.tileInfo(t)
        return VStack(spacing: 8) {
            Image(systemName: info.icon)
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(LinearGradient(colors: info.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if t == .activity, !unreadActivity.isEmpty { CountBadge(count: unreadActivity.count).offset(x: 6, y: -6) }
                }
            Text(info.title).font(.caption.weight(.medium)).foregroundStyle(Color.primary).lineLimit(1)
            if inBar.contains(t) {
                Text("In bar").font(.caption2).foregroundStyle(look.textSecondary)
            }
        }
    }

    static func tileInfo(_ t: Router.TabID) -> (title: String, icon: String, colors: [UInt32]) {
        switch t {
        case .tasks: ("Tasks", ModuleRegistry.businessTasks.icon, ModuleRegistry.businessTasks.colors)
        case .care: ("Care", ModuleRegistry.iLifeCare.icon, ModuleRegistry.iLifeCare.colors)
        case .gym: ("Gym", ModuleRegistry.gymTraining.icon, ModuleRegistry.gymTraining.colors)
        default: ("Activity", "bell.fill", [0xFFB347, 0xFF6F61])
        }
    }

    private func hubRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(look.accent).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Color.primary)
                Text(subtitle).font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(look.textSecondary)
        }
        .lookCard()
    }
}

/// Settings → Bottom bar: pick the two modules that sit next to Chats.
struct BottomBarSettingsView: View {
    @EnvironmentObject var modules: ModuleRegistry
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look

    private var options: [Router.TabID] { router.availableTabs }

    var body: some View {
        let bar = modules.barTabs(available: options)
        List {
            Section {
                ForEach(options, id: \.self) { t in
                    let info = ModulesHubView.tileInfo(t)
                    Button {
                        Haptics.tap()
                        toggle(t, bar: bar)
                    } label: {
                        HStack {
                            Label(info.title, systemImage: info.icon).foregroundStyle(Color.primary)
                            Spacer()
                            if bar.contains(t) { Image(systemName: "checkmark.circle.fill").foregroundStyle(look.accent) }
                            else { Image(systemName: "circle").foregroundStyle(look.textSecondary) }
                        }
                    }
                }
            } header: {
                Text("In the bottom bar (pick \(ModuleRegistry.maxPinned))")
            } footer: {
                Text("iPhone shows five tabs: Chats, two modules, Modules and Settings. Everything else opens from the Modules tab, so adding more modules never crowds the bar. On iPad every module is listed in the sidebar.")
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Bottom bar")
    }

    /// Removing a module from the bar brings the next one in; adding one pushes out the oldest.
    private func toggle(_ t: Router.TabID, bar: [Router.TabID]) {
        var next = bar
        if bar.contains(t) {
            next.removeAll { $0 == t }
            if let fill = options.first(where: { !bar.contains($0) && $0 != t }) { next.append(fill) }
        } else {
            next.append(t)
            if next.count > ModuleRegistry.maxPinned { next.removeFirst() }
        }
        modules.setPins(next)
    }
}
