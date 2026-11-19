import SwiftUI
import SwiftData

// MARK: - Templates (Business Tasks Pro)

struct TaskTemplate: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var title: String
    var notes: String
    var checklist: [String]
    var priority: Int
    var policy: String
    var repeatRule: String
    var reminderOffset: Int
}

@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()
    @Published private(set) var templates: [TaskTemplate]

    private init() {
        templates = Packed.decode([TaskTemplate].self, UserDefaults.standard.data(forKey: "pro.templates")) ?? []
    }

    private func persist() { UserDefaults.standard.set(Packed.encode(templates), forKey: "pro.templates") }

    func save(from t: TaskItem, name: String, context: ModelContext) {
        let tid = t.id
        let items = ((try? context.fetch(FetchDescriptor<ChecklistItem>(predicate: #Predicate { $0.taskID == tid && !$0.deleted }))) ?? [])
            .sorted { $0.position < $1.position }.map(\.title)
        templates.append(TaskTemplate(name: name, title: t.title, notes: t.notes, checklist: items, priority: t.priorityRaw,
                                      policy: t.policyRaw, repeatRule: t.repeatRule, reminderOffset: t.reminderOffset))
        persist()
    }

    func delete(_ t: TaskTemplate) {
        templates.removeAll { $0.id == t.id }
        persist()
    }
}

/// Shown instead of a Pro feature when Pro isn't active: tapping opens the module page.
struct ProLockRow: View {
    let text: String
    @State private var show = false
    @Environment(\.look) private var look
    var body: some View {
        Button { show = true } label: {
            HStack {
                Label(text, systemImage: "lock.fill")
                Spacer()
                Text("Pro").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(look.accent.opacity(0.2), in: Capsule()).foregroundStyle(look.accent)
            }
        }
        .sheet(isPresented: $show) {
            NavigationStack {
                ModuleDetailView(module: ModuleRegistry.businessPro)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { show = false } } }
            }
        }
    }
}

enum RepeatRule: String, CaseIterable {
    case none, daily, weekly, monthly
    var title: String {
        switch self {
        case .none: "Never"
        case .daily: "Every day"
        case .weekly: "Every week"
        case .monthly: "Every month"
        }
    }
}

// MARK: - Reports (Business Tasks Pro)

struct TaskReportsView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(filter: #Predicate<TaskItem> { !$0.deleted }) private var tasks: [TaskItem]
    @Query(filter: #Predicate<Expense> { !$0.deleted }) private var expenses: [Expense]
    @Query private var conversations: [Conversation]

    enum Period: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", quarter = "90 days", all = "All"
        var id: String { rawValue }
        var start: Date {
            switch self {
            case .week: Date(timeIntervalSinceNow: -7 * 86400)
            case .month: Date(timeIntervalSinceNow: -30 * 86400)
            case .quarter: Date(timeIntervalSinceNow: -90 * 86400)
            case .all: .distantPast
            }
        }
    }

    @State private var period: Period = .month
    @State private var chatID = ""
    @State private var exportURL: URL?

    private var scoped: [TaskItem] {
        tasks.filter { chatID.isEmpty || $0.convID == chatID }.filter { $0.createdAt >= period.start || !$0.isDone || ($0.completedAt ?? .distantPast) >= period.start }
    }

    struct PersonRow: Identifiable { let id: String; let done: Int; let open: Int; let overdue: Int }

    private var people: [PersonRow] {
        var ids = Set<String>()
        for t in scoped { ids.formUnion(t.assignees.isEmpty ? [t.createdBy] : t.assignees) }
        return ids.map { id in
            let mine = scoped.filter { ($0.assignees.isEmpty ? [$0.createdBy] : $0.assignees).contains(id) }
            let done = mine.filter { $0.isDone && ($0.completedAt ?? .distantPast) >= period.start }.count
            return PersonRow(id: id, done: done, open: mine.filter { !$0.isDone }.count, overdue: mine.filter(\.isOverdue).count)
        }
        .sorted { $0.done > $1.done }
    }

    private var scopedExpenses: [Expense] {
        let taskIDs = Set(scoped.map(\.id))
        return expenses.filter { taskIDs.contains($0.taskID) && $0.date >= period.start }
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                Picker("Chat", selection: $chatID) {
                    Text("All chats").tag("")
                    ForEach(conversations.filter { $0.isGroup || $0.kind == "direct" }) { Text($0.title).tag($0.id) }
                }
            }
            .lookRows()

            let done = scoped.filter { $0.isDone && ($0.completedAt ?? .distantPast) >= period.start }.count
            let open = scoped.filter { !$0.isDone }.count
            let overdue = scoped.filter(\.isOverdue).count
            Section("Summary") {
                HStack {
                    stat("Done", done, look.success)
                    stat("Open", open, look.accent)
                    stat("Overdue", overdue, look.danger)
                }
            }
            .lookRows()

            Section("By person") {
                let best = max(people.map(\.done).max() ?? 1, 1)
                ForEach(people) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            AvatarView(name: engine.name(of: p.id), imageData: p.id == engine.me ? engine.myAvatar : engine.contact(p.id)?.avatar, size: 26)
                            Text(engine.name(of: p.id)).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(p.done) done · \(p.open) open").font(.caption).foregroundStyle(look.textSecondary)
                            if p.overdue > 0 { Chip(text: "\(p.overdue) late", color: look.danger) }
                        }
                        ProgressView(value: Double(p.done), total: Double(best)).tint(look.accent)
                    }
                }
                if people.isEmpty { Text("No tasks in this period.").foregroundStyle(look.textSecondary) }
            }
            .lookRows()

            Section("Expenses") {
                let total = scopedExpenses.reduce(0) { $0 + $1.amount }
                LabeledContent("Total", value: Money.format(total)).font(.headline)
                ForEach(ExpenseCategory.allCases, id: \.self) { c in
                    let sum = scopedExpenses.filter { $0.category == c.rawValue }.reduce(0) { $0 + $1.amount }
                    if sum > 0 { LabeledContent { Text(Money.format(sum)) } label: { Label(c.rawValue, systemImage: c.icon) } }
                }
            }
            .lookRows()

            Section {
                Button { exportURL = makeCSV() } label: { Label("Create Excel file (CSV)", systemImage: "tablecells") }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text("Opens in Excel, Numbers or Google Sheets: tasks with status, people and due dates, plus every expense.")
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Reports")
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold()).foregroundStyle(color).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(look.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func makeCSV() -> URL? {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        var lines = ["Type,Title,Chat,Status,Priority,Assignees,Due,Completed,Amount,Category,Paid by"]
        for t in scoped {
            lines.append([csv("Task"), csv(t.title), csv(t.convID.flatMap { engine.conversation($0)?.title } ?? "Personal"),
                          csv(t.status.title), csv(t.priority.title), csv(t.assignees.map { engine.name(of: $0) }.joined(separator: "; ")),
                          csv(t.dueAt.map { df.string(from: $0) } ?? ""), csv(t.completedAt.map { df.string(from: $0) } ?? ""),
                          "", "", ""].joined(separator: ","))
        }
        for x in scopedExpenses {
            let task = engine.task(x.taskID)?.title ?? ""
            lines.append([csv("Expense"), csv("\(x.title) (\(task))"), "", "", "", "", csv(df.string(from: x.date)), "",
                          String(format: "%.2f", x.amount), csv(x.category), csv(engine.name(of: x.paidBy))].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iTeam-report-\(df.string(from: .now)).csv")
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}
