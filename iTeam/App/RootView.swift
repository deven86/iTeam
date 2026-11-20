import SwiftUI
import SwiftData

/// Bottom bar on iPhone: Chats · three modules you pick · Settings (five tabs, so iOS never hides any
/// behind “More”). Every other module opens from Settings → Modules. On iPad the bar becomes
/// a sidebar with room for everything, so all modules are listed there.
struct RootView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @EnvironmentObject var modules: ModuleRegistry
    @ObservedObject private var store = Store.shared
    @ObservedObject private var rooms = Rooms.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var conversations: [Conversation]
    @Query(filter: #Predicate<ActivityItem> { !$0.read }) private var unreadActivity: [ActivityItem]
    @Query(filter: #Predicate<CareProfile> { !$0.deleted }) private var careProfiles: [CareProfile]
    @Query(filter: #Predicate<GymMember> { !$0.deleted }) private var gymMembers: [GymMember]

    @Query(filter: #Predicate<Post> { !$0.deleted && !$0.isStatus }) private var allPosts: [Post]
    @Query(filter: #Predicate<Prescription> { !$0.deleted && $0.status == "waiting" }) private var waitingRx: [Prescription]
    @Query(filter: #Predicate<BizRecord> { !$0.deleted && $0.parentID == "" }) private var bizRecords: [BizRecord]
    private var rxToReview: [Prescription] { waitingRx.filter { $0.patientID == engine.me } }
    @Query(filter: #Predicate<InviteEvent> { !$0.deleted }) private var invites: [InviteEvent]
    private var invitedToEvents: Bool { invites.contains { $0.hostID != engine.me && $0.end > .now } }
    @AppStorage("views.lastVisit") private var viewsLastVisit: Double = 0
    private var newPosts: Int {
        let since = Date(timeIntervalSince1970: viewsLastVisit)
        return allPosts.filter { $0.createdAt > since && $0.author != engine.me }.count
    }

    private var unreadChats: Int { conversations.filter { !$0.muted && $0.unread > 0 }.count }

    /// Module tabs the user can open right now.
    private var available: [Router.TabID] {
        var a: [Router.TabID] = [.views]
        let sharedBiz = Set(bizRecords.filter { $0.ownerID != engine.me && ($0.subjectID == engine.me || ($0.subjectID.isEmpty && !$0.convID.isEmpty)) }.map(\.module))
        // Free extras: added from the Module Store — or shown automatically when someone shares something with you.
        if modules.isOn(ModuleRegistry.events) || invitedToEvents { a.append(.events) }
        if modules.isOn(ModuleRegistry.travel) || sharedBiz.contains("travel") { a.append(.travel) }
        if modules.isOn(ModuleRegistry.rooms) { a.append(.rooms) }
        if modules.isOn(ModuleRegistry.doctorPatient) || !rxToReview.isEmpty { a.append(.doctor) }
        if modules.isOn(ModuleRegistry.safety) { a.append(.safety) }
        if modules.isOn(ModuleRegistry.bills) { a.append(.bills) }
        if modules.isOn(ModuleRegistry.kids) || sharedBiz.contains("kids") { a.append(.kids) }
        for (info, spec) in [(ModuleRegistry.khata, BizSpecs.khata), (ModuleRegistry.tuition, BizSpecs.tuition), (ModuleRegistry.rent, BizSpecs.rent),
                             (ModuleRegistry.legal, BizSpecs.legal), (ModuleRegistry.clinic, BizSpecs.clinic)] {
            if modules.isOn(info) || (sharedBiz.contains(spec.module) && modules.isVisible(info)) { a.append(spec.tab) }
        }
        if modules.isOn(ModuleRegistry.businessTasks) { a.append(.tasks); a.append(.meetings) }
        // Paid modules appear once bought (or unlocked for the owner / TestFlight testing) — or when
        // someone else shared a profile with you, because members use shared profiles free.
        let me = engine.me
        let sharedCare = careProfiles.contains { $0.createdBy != me && !$0.id.hasPrefix("c_demo") }
        let sharedGym = gymMembers.contains { $0.createdBy != me && !$0.id.hasPrefix("g_demo") }
        if modules.isOn(ModuleRegistry.iLifeCare) || (sharedCare && modules.isVisible(ModuleRegistry.iLifeCare)) { a.append(.care) }
        if modules.isOn(ModuleRegistry.gymTraining) || (sharedGym && modules.isVisible(ModuleRegistry.gymTraining)) { a.append(.gym) }
        if modules.isOn(ModuleRegistry.mindfulness) { a.append(.mind) }
        a.append(.activity)
        return a
    }

    private var inBar: [Router.TabID] {
        sizeClass == .regular ? available : modules.barTabs(available: available)
    }

    @State private var restoreOffer: Backup.Found?

    /// After a fresh install, offer the newest iCloud backup once.
    private func offerRestoreIfFresh() async {
        let key = "backup.restoreOffered"
        guard !UserDefaults.standard.bool(forKey: key), Backup.shared.lastDate == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        if let newest = await Backup.shared.available().first { restoreOffer = newest }
    }

    var body: some View {
        if !engine.isSetUp {
            OnboardingView()
        } else {
            decorated(tabView)
        }
    }

    private var tabView: some View {
        TabView(selection: $router.tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: Router.TabID.chats) {
                ChatListView()
            }
            .badge(unreadChats)

            moduleTabs
            moduleTabs2

            Tab("Settings", systemImage: "gearshape.fill", value: Router.TabID.settings) {
                SettingsView()
            }
            .badge(inBar.contains(.activity) ? 0 : unreadActivity.count)
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    @TabContentBuilder<Router.TabID>
    private var moduleTabs: some TabContent<Router.TabID> {
        Tab("Views", systemImage: "play.rectangle.on.rectangle.fill", value: Router.TabID.views) {
            ViewsHomeView()
        }
        .badge(newPosts)
        .hidden(!inBar.contains(.views))

        Tab("Rooms", systemImage: "person.3.sequence.fill", value: Router.TabID.rooms) {
            RoomsHomeView()
        }
        .badge(rooms.unreadTotal)
        .hidden(!inBar.contains(.rooms))

        Tab("Events", systemImage: "party.popper.fill", value: Router.TabID.events) {
            EventsHomeView()
        }
        .hidden(!inBar.contains(.events))

        Tab("Safety", systemImage: "sos.circle.fill", value: Router.TabID.safety) {
            SafetyView()
        }
        .hidden(!inBar.contains(.safety))

        Tab("Doctor", systemImage: "stethoscope", value: Router.TabID.doctor) {
            DoctorHomeView()
        }
        .badge(rxToReview.count)
        .hidden(!inBar.contains(.doctor))

        ForEach(BizSpecs.all, id: \.module) { spec in
            Tab(spec.title, systemImage: spec.icon, value: spec.tab) {
                BizHomeView(spec: spec)
            }
            .hidden(!inBar.contains(spec.tab))
        }

    }

    @TabContentBuilder<Router.TabID>
    private var moduleTabs2: some TabContent<Router.TabID> {
        Tab("Meetings", systemImage: "person.3.fill", value: Router.TabID.meetings) {
            MeetingsHomeView()
        }
        .hidden(!inBar.contains(.meetings))

        Tab("Tasks", systemImage: "checklist", value: Router.TabID.tasks) {
            TaskDashboardView()
        }
        .hidden(!inBar.contains(.tasks))

        Tab("Care", systemImage: "heart.text.square.fill", value: Router.TabID.care) {
            CareHomeView()
        }
        .hidden(!inBar.contains(.care))

        Tab("Gym", systemImage: "dumbbell.fill", value: Router.TabID.gym) {
            GymModuleView()
        }
        .hidden(!inBar.contains(.gym))

        Tab("Mind", systemImage: "leaf.fill", value: Router.TabID.mind) {
            MindHomeView()
        }
        .hidden(!inBar.contains(.mind))

        Tab("Activity", systemImage: "bell.fill", value: Router.TabID.activity) {
            ActivityView()
        }
        .badge(unreadActivity.count)
        .hidden(!inBar.contains(.activity))
    }

    private func decorated<V: View>(_ v: V) -> some View {
        v
            .onAppear { router.barTabs = inBar; router.availableTabs = available }
            .onChange(of: available) { _, a in router.availableTabs = a }
            .onChange(of: inBar) { _, bar in
                router.barTabs = bar
                // A tab that just left the bar reopens inside the hub instead of vanishing.
                if [Router.TabID.views, .events, .rooms, .doctor, .safety, .khata, .tuition, .rent, .legal, .clinic, .bills, .kids, .travel, .meetings, .tasks, .care, .gym, .mind, .activity].contains(router.tab), !bar.contains(router.tab) {
                    router.tab = .chats
                }
            }
            .sheet(item: $router.moduleSheet) { t in
                ModulesHubView.content(t).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: Binding(get: { router.openMyDay != nil }, set: { if !$0 { router.openMyDay = nil } })) {
                NavigationStack { MyDayView(evening: router.openMyDay == "evening") }
            }
            .sheet(item: $restoreOffer) { f in RestoreOfferView(found: f) }
            .task {
                engine.setForeground(true)
                await offerRestoreIfFresh()
                await engine.sync()
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
        case .views: ViewsHomeView()
        case .rooms: RoomsHomeView()
        case .doctor: DoctorHomeView()
        case .safety: SafetyView()
        case .events: EventsHomeView()
        case .khata: BizHomeView(spec: BizSpecs.khata)
        case .tuition: BizHomeView(spec: BizSpecs.tuition)
        case .rent: BizHomeView(spec: BizSpecs.rent)
        case .legal: BizHomeView(spec: BizSpecs.legal)
        case .clinic: BizHomeView(spec: BizSpecs.clinic)
        case .bills: BizHomeView(spec: BizSpecs.bills)
        case .kids: BizHomeView(spec: BizSpecs.kids)
        case .travel: BizHomeView(spec: BizSpecs.travel)
        case .meetings: MeetingsHomeView()
        case .tasks: TaskDashboardView()
        case .care: CareHomeView()
        case .gym: GymModuleView()
        case .mind: MindHomeView()
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
                        Button {
                            router.openMyDay = Calendar.current.component(.hour, from: .now) >= 17 ? "evening" : "morning"
                        } label: {
                            hubRow("sun.max.fill", "My Day", "Today's brief, or how the day went")
                        }
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
        case .views: ("Views", "play.rectangle.on.rectangle.fill", [0xFF5F6D, 0xFFC371])
        case .rooms: ("Rooms", "person.3.sequence.fill", [0x7F7FD5, 0x86A8E7])
        case .doctor: ("Doctor", "stethoscope", [0x36D1DC, 0x5B86E5])
        case .safety: ("Safety", "sos.circle.fill", [0xFF416C, 0xB31217])
        case .events: ("Events", "party.popper.fill", [0xF953C6, 0xB91D73])
        case .meetings: ("Meetings", "person.3.fill", [0x4568DC, 0xB06AB3])
        case .khata, .tuition, .rent, .legal, .clinic, .bills, .kids, .travel:
            BizSpecs.all.first { $0.tab == t }.map { ($0.title, $0.icon, $0.colors) } ?? ("", "square", [0, 0])
        case .tasks: ("Tasks", ModuleRegistry.businessTasks.icon, ModuleRegistry.businessTasks.colors)
        case .care: ("Care", ModuleRegistry.iLifeCare.icon, ModuleRegistry.iLifeCare.colors)
        case .gym: ("Gym", ModuleRegistry.gymTraining.icon, ModuleRegistry.gymTraining.colors)
        case .mind: ("Mind", ModuleRegistry.mindfulness.icon, ModuleRegistry.mindfulness.colors)
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
                Text("iPhone shows five tabs: Chats, three modules you pick, and Settings. Every other module opens from Settings → Modules, so adding more modules never crowds the bar. On iPad every module is listed in the sidebar.")
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

/// Settings → Modules: every module you can open, as app-style tiles, plus My Day, store and requests.
struct ModuleTilesSection: View {
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Query(filter: #Predicate<ActivityItem> { !$0.read }) private var unreadActivity: [ActivityItem]
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(router.availableTabs, id: \.self) { t in
                let info = ModulesHubView.tileInfo(t)
                Button {
                    Haptics.tap()
                    if router.barTabs.contains(t) { router.tab = t } else { router.moduleSheet = t }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: info.icon)
                            .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(LinearGradient(colors: info.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if t == .activity, !unreadActivity.isEmpty { CountBadge(count: unreadActivity.count).offset(x: 6, y: -6) }
                            }
                        Text(info.title).font(.caption.weight(.medium)).foregroundStyle(Color.primary).lineLimit(1)
                        if router.barTabs.contains(t) { Text("In bar").font(.caption2).foregroundStyle(look.textSecondary) }
                    }
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.vertical, 6)
    }
}
