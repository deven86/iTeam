import SwiftUI
import SwiftData

/// The separate Business Tasks dashboard.
struct TaskDashboardView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    private var tasks: [TaskItem] { allTasks.filter { !$0.deleted } }
    @Query private var conversations: [Conversation]
    @Query private var approvals: [Approval]

    private var approvalsWaiting: Int {
        approvals.filter { $0.status == .pending && $0.approvers.contains(engine.me) && $0.decisions[engine.me] == nil }.count
    }

    enum Scope: String, CaseIterable, Identifiable {
        case mine = "My Tasks", assigned = "Assigned to me", created = "Created by me", groups = "Group tasks", done = "Completed", deleted = "Deleted"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .mine: "tray.full"
            case .assigned: "person.crop.circle.badge.checkmark"
            case .created: "square.and.pencil"
            case .groups: "person.3"
            case .done: "checkmark.seal"
            case .deleted: "trash"
            }
        }
    }

    @State private var scope: Scope = .mine
    @State private var search = ""
    @State private var showMeetings = false
    @State private var showNew = false
    @State private var path: [String] = []
    @State private var calendarMode = false
    @State private var showApprovals = false
    @State private var showReports = false
    @State private var showProPage = false
    @ObservedObject private var store = Store.shared

    private var me: String { engine.me }
    private var open: [TaskItem] { tasks.filter { !$0.isDone } }

    private func inScope(_ t: TaskItem) -> Bool {
        switch scope {
        case .mine: return !t.isDone && t.involves(me)
        case .assigned: return !t.isDone && t.assignees.contains(me)
        case .created: return !t.isDone && t.createdBy == me
        case .groups: return !t.isDone && t.convID != nil && (conversations.first { $0.id == t.convID }?.isGroup ?? false)
        case .done: return t.isDone
        case .deleted: return t.deleted
        }
    }

    private var visible: [TaskItem] {
        let q = search.lowercased()
        return (scope == .deleted ? allTasks : tasks).filter(inScope).filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.notes.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { summary.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Scope.allCases) { s in
                                Button { withAnimation(.snappy) { scope = s } } label: {
                                    Label(s.rawValue, systemImage: s.icon)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .foregroundStyle(scope == s ? Color.white : Color.primary)
                                        .background(scope == s ? AnyShapeStyle(look.gradient) : AnyShapeStyle(Color.clear), in: Capsule())
                                        .lookFloating(in: Capsule(), interactive: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if visible.isEmpty {
                    Section {
                        EmptyStateView(icon: scope == .done ? "checkmark.seal" : "checklist",
                                       title: scope == .done ? "Nothing completed yet" : "All clear",
                                       message: "Long-press any message in a chat and choose “Create Business Task”, or tap + to add one.")
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                } else if scope == .deleted {
                    taskSection("Deleted", visible.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) })
                } else if scope == .done {
                    taskSection("Completed", visible.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
                } else if scope == .groups {
                    ForEach(groupedByChat, id: \.0) { pair in
                        taskSection(pair.0, pair.1)
                    }
                } else {
                    let overdue = visible.filter(\.isOverdue).sorted(by: dueOrder)
                    let today = visible.filter { !$0.isOverdue && ($0.dueAt.map { Calendar.current.isDateInToday($0) } ?? false) }.sorted(by: dueOrder)
                    let upcoming = visible.filter { t in t.dueAt.map { $0 > .now && !Calendar.current.isDateInToday($0) } ?? false }.sorted(by: dueOrder)
                    let noDate = visible.filter { $0.dueAt == nil }
                    if !overdue.isEmpty { taskSection("Overdue", overdue, tint: look.danger) }
                    if !today.isEmpty { taskSection("Due today", today, tint: look.warning) }
                    if !upcoming.isEmpty { taskSection("Upcoming", upcoming) }
                    if !noDate.isEmpty { taskSection("No due date", noDate) }
                }
            }
            .listStyle(.insetGrouped)
            .lookScreen()
            .searchable(text: $search, prompt: "Search tasks")
            .refreshable { await engine.sync() }
            .navigationTitle("Business Tasks")
            .navigationDestination(for: String.self) { TaskDetailView(taskID: $0) }
            .sheet(isPresented: $showApprovals) {
                NavigationStack {
                    ApprovalsListView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showApprovals = false } } }
                }
            }
            // A sheet, not navigationDestination(isPresented:): mixing that with a path-based stack froze the app.
            .sheet(isPresented: $showReports) {
                NavigationStack {
                    TaskReportsView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showReports = false } } }
                }
            }
            .sheet(isPresented: $showProPage) {
                NavigationStack {
                    ModuleDetailView(module: ModuleRegistry.businessPro)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showProPage = false } } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { if store.proUnlocked { showReports = true } else { showProPage = true } } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel("Reports")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMeetings = true } label: { Image(systemName: "person.3.fill") }.accessibilityLabel("Meetings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("New task")
                }
            }
            .sheet(isPresented: $showNew) { NavigationStack { TaskEditorView(conv: nil, source: nil) } }
            .sheet(isPresented: $showMeetings) { MeetingsHomeView() }
            .onChange(of: router.openTask) { _, id in
                guard let id else { return }
                path = [id]
                router.openTask = nil
            }
            .onAppear {
                if let id = router.openTask { path = [id]; router.openTask = nil }
            }
        }
    }

    private func dueOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        (a.dueAt ?? .distantFuture, -a.priorityRaw) < (b.dueAt ?? .distantFuture, -b.priorityRaw)
    }

    private var groupedByChat: [(String, [TaskItem])] {
        let groups = Dictionary(grouping: visible) { t in conversations.first { $0.id == t.convID }?.title ?? "Chat" }
        return groups.map { ($0.key, $0.value.sorted(by: dueOrder)) }.sorted { $0.0 < $1.0 }
    }

    private func taskSection(_ title: String, _ items: [TaskItem], tint: Color? = nil) -> some View {
        Section {
            ForEach(items) { t in
                NavigationLink(value: t.id) { TaskRow(task: t) }
                    .swipeActions(edge: .leading) {
                        if !t.isDone {
                            Button { complete(t) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                        }
                    }
            }
        } header: {
            HStack {
                Text(title).foregroundStyle(tint ?? look.textSecondary)
                Spacer()
                Text("\(items.count)")
            }
        }
        .lookRows()
    }

    private func complete(_ t: TaskItem) {
        Haptics.success()
        if t.policy == .all && t.assignees.contains(me) { engine.setMyPart(t, done: true) }
        else { engine.setStatus(t, .done) }
    }

    // MARK: Summary tiles (iLife-style)

    private var summary: some View {
        let mine = open.filter { $0.involves(me) }
        let dueToday = mine.filter { $0.dueAt.map { Calendar.current.isDateInToday($0) } ?? false }.count
        let overdue = mine.filter(\.isOverdue).count
        let assigned = mine.filter { $0.assignees.contains(me) }.count
        let weekAgo = Date(timeIntervalSinceNow: -7 * 86400)
        let doneWeek = tasks.filter { $0.isDone && ($0.completedAt ?? .distantPast) > weekAgo && $0.involves(me) }.count
        let total = doneWeek + mine.count
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    ProgressRing(progress: total == 0 ? 0 : Double(doneWeek) / Double(total), color: look.accent, lineWidth: 10)
                    VStack(spacing: 0) {
                        Text("\(doneWeek)").font(.title2.bold()).contentTransition(.numericText())
                        Text("done").font(.caption2).foregroundStyle(look.textSecondary)
                    }
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("This week").font(.headline)
                    Text("\(doneWeek) completed · \(mine.count) open").font(.subheadline).foregroundStyle(look.textSecondary)
                    if overdue > 0 { Chip(text: "\(overdue) overdue", icon: "exclamationmark.triangle.fill", color: look.danger) }
                }
                Spacer(minLength: 0)
            }
            .lookCard()
            .appear(0)
            Button { showApprovals = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(look.warning)
                        .frame(width: 36, height: 36).background(look.warning.opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Approvals").font(.headline)
                        Text(approvalsWaiting == 0 ? "Nothing waiting for you" : "\(approvalsWaiting) waiting for you")
                            .font(.caption).foregroundStyle(approvalsWaiting == 0 ? look.textSecondary : look.warning)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(look.textSecondary)
                }
                .lookCard(cornerRadius: 18, padding: 12)
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 4 : 2), spacing: 12) {
                tile("Due today", dueToday, "calendar", look.warning).appear(1)
                tile("Overdue", overdue, "exclamationmark.triangle", look.danger).appear(2)
                tile("Assigned to me", assigned, "person.crop.circle.badge.checkmark", look.accent).appear(3)
                tile("Open", mine.count, "tray.full", .purple).appear(4)
            }
        }
        .padding(.vertical, 6)
    }

    private func tile(_ title: String, _ value: Int, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
                .frame(width: 36, height: 36).background(color.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(.title3.bold()).contentTransition(.numericText())
                Text(title).font(.caption).foregroundStyle(look.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .lookCard(cornerRadius: 18, padding: 12)
    }
}

struct TaskRow: View {
    let task: TaskItem
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var checklist: [ChecklistItem]
    @Query private var comments: [TaskComment]

    init(task: TaskItem) {
        self.task = task
        let id = task.id
        _checklist = Query(filter: #Predicate<ChecklistItem> { $0.taskID == id && !$0.deleted })
        _comments = Query(filter: #Predicate<TaskComment> { $0.taskID == id })
    }

    private var myPartDone: Bool { task.doneBy[engine.me] != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: task.isDone || (task.policy == .all && myPartDone) ? "checkmark.circle.fill" : task.status.icon)
                    .font(.title2)
                    .foregroundStyle(task.isDone ? look.success : (task.isOverdue ? look.danger : look.accent))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Reopen" : "Mark done")

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(.body.weight(.medium))
                    .strikethrough(task.isDone).foregroundStyle(task.isDone ? look.textSecondary : Color.primary)
                    .lineLimit(2)
                FlowChips(task: task, checklistDone: checklist.filter(\.done).count, checklistTotal: checklist.count, comments: comments.count)
                if task.policy == .all && !task.assignees.isEmpty && !task.isDone {
                    ProgressView(value: task.groupProgress).tint(look.accent)
                }
            }
            Spacer(minLength: 0)
            if !task.assignees.isEmpty {
                HStack(spacing: -10) {
                    ForEach(task.assignees.prefix(3), id: \.self) { id in
                        AvatarView(name: engine.name(of: id), imageData: id == engine.me ? engine.myAvatar : engine.contact(id)?.avatar, size: 26)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func toggle() {
        Haptics.tap()
        if task.isDone {
            engine.reopen(task, reason: "")
        } else if task.policy == .all && task.assignees.contains(engine.me) {
            engine.setMyPart(task, done: !myPartDone)
        } else {
            engine.setStatus(task, .done)
            Haptics.success()
        }
    }
}

struct FlowChips: View {
    let task: TaskItem
    let checklistDone: Int
    let checklistTotal: Int
    let comments: Int
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 6) {
            if task.awaitsMe(engine.me) {
                Chip(text: "Accept?", icon: "hand.raised.fill", color: look.warning)
            } else if !task.pendingAcceptance.isEmpty {
                Chip(text: "Awaiting \(task.pendingAcceptance.map { engine.name(of: $0) }.joined(separator: ", "))", icon: "hourglass", color: look.warning)
            } else if !task.declinedBy.isEmpty {
                Chip(text: "Declined", icon: "xmark.circle", color: look.danger)
            }
            if let due = task.dueAt {
                Chip(text: Fmt.due(due), icon: "calendar", color: task.isOverdue ? look.danger : (Calendar.current.isDateInToday(due) ? look.warning : look.textSecondary))
            }
            if task.priority.rawValue >= WorkPriority.high.rawValue {
                Chip(text: task.priority.title, icon: task.priority.icon, color: task.priority == .urgent ? look.danger : look.warning)
            }
            if let convID = task.convID, let c = engine.conversation(convID) {
                Chip(text: c.title, icon: c.isGroup ? "person.3" : "person", color: look.accent)
            }
            if checklistTotal > 0 { Chip(text: "\(checklistDone)/\(checklistTotal)", icon: "checklist", color: look.textSecondary) }
            if comments > 0 { Chip(text: "\(comments)", icon: "text.bubble", color: look.textSecondary) }
        }
        .lineLimit(1)
    }
}
