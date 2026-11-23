import SwiftUI
import SwiftData

// MARK: - Attachments on a task

struct TaskFilesSection: View {
    let task: TaskItem
    let editable: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Environment(\.openURL) private var openURL
    @Query private var files: [TaskFile]
    @State private var pending = PendingAttachments()
    @State private var askLink = false
    @State private var linkText = ""
    @State private var preview: URL?

    init(task: TaskItem, editable: Bool) {
        self.task = task
        self.editable = editable
        let id = task.id
        _files = Query(filter: #Predicate<TaskFile> { $0.taskID == id && !$0.deleted }, sort: \TaskFile.addedAt)
    }

    var body: some View {
        Section {
            ForEach(files) { f in
                Button { open(f) } label: { row(f) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if editable { Button("Remove", role: .destructive) { engine.removeTaskFile(f) } }
                    }
            }
            if editable {
                AttachmentAdder(pending: $pending, title: "Add photo or document")
                Button { askLink = true } label: { Label("Add link", systemImage: "link") }
            }
        } header: {
            Text("Attachments\(files.isEmpty ? "" : " (\(files.count))")")
        }
        .lookRows()
        .onChange(of: pending.refs.count) { _, count in
            guard count > 0 else { return }
            for ref in pending.refs {
                let uploads = pending.uploads.filter { $0.key == ref.blob }
                engine.addTaskFile(task, kind: ref.kind, title: ref.kind == "image" ? "Photo" : ref.name, attachment: ref, uploads: uploads)
            }
            pending = PendingAttachments()
        }
        .alert("Add link", isPresented: $askLink) {
            TextField("https://…", text: $linkText).keyboardType(.URL).textInputAutocapitalization(.never)
            Button("Add") {
                let t = linkText.trimmingCharacters(in: .whitespaces)
                let full = t.hasPrefix("http") ? t : "https://" + t
                if !t.isEmpty, let url = URL(string: full) {
                    engine.addTaskFile(task, kind: "link", title: url.host() ?? full, url: full)
                }
                linkText = ""
            }
            Button("Cancel", role: .cancel) { linkText = "" }
        }
        .sheet(item: Binding(get: { preview.map(PreviewItem.init) }, set: { preview = $0?.url })) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
    }

    private func row(_ f: TaskFile) -> some View {
        HStack(spacing: 12) {
            if let ref = f.attachment {
                AttachmentThumb(ref: ref, size: 44).allowsHitTesting(false)
            } else {
                Image(systemName: "link").frame(width: 44, height: 44).background(look.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(f.kind == "link" ? (f.url ?? f.title) : f.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(engine.name(of: f.addedBy)) · \(Fmt.chatTime(f.addedAt))").font(.caption2).foregroundStyle(look.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func open(_ f: TaskFile) {
        if let s = f.url, let url = URL(string: s) { openURL(url); return }
        guard let ref = f.attachment else { return }
        Task { if let url = try? await Attachments.load(ref) { preview = url } }
    }
}

// MARK: - Expenses on a task

struct TaskExpensesSection: View {
    let task: TaskItem
    let editable: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var expenses: [Expense]
    @Query private var approvals: [Approval]
    @State private var editing: Expense?
    @State private var adding = false

    init(task: TaskItem, editable: Bool) {
        self.task = task
        self.editable = editable
        let id = task.id
        let oid: String? = id
        _expenses = Query(filter: #Predicate<Expense> { $0.taskID == id && !$0.deleted }, sort: \Expense.date, order: .reverse)
        _approvals = Query(filter: #Predicate<Approval> { $0.taskID == oid })
    }

    private var total: Double { expenses.reduce(0) { $0 + $1.amount } }
    private var budget: Double? {
        let approved = approvals.filter { $0.status == .approved }.compactMap(\.approvedAmount)
        return approved.isEmpty ? nil : approved.reduce(0, +)
    }

    var body: some View {
        Section {
            if !expenses.isEmpty || budget != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Spent").font(.caption).foregroundStyle(look.textSecondary)
                        Text(Money.format(total)).font(.title3.bold())
                        Spacer()
                        if let budget {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("Approved budget").font(.caption2).foregroundStyle(look.textSecondary)
                                Text(Money.format(budget)).font(.subheadline.bold())
                            }
                        }
                    }
                    if let budget, budget > 0 {
                        ProgressView(value: min(total / budget, 1)).tint(total > budget ? look.danger : look.success)
                        Text(total > budget ? "Over budget by \(Money.format(total - budget))" : "\(Money.format(budget - total)) left")
                            .font(.caption).foregroundStyle(total > budget ? look.danger : look.textSecondary)
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(expenses) { x in
                Button { if editable { editing = x } } label: { row(x) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if editable { Button("Delete", role: .destructive) { engine.deleteExpense(x) } }
                    }
            }
            if editable {
                Button { adding = true } label: { Label("Add expense", systemImage: "plus.circle") }
            }
        } header: {
            Text("Expenses")
        } footer: {
            Text("Attach bills or vouchers to each expense. Amounts approved through approval requests on this task count as the budget.")
        }
        .lookRows()
        .sheet(isPresented: $adding) { NavigationStack { ExpenseEditor(task: task, expense: nil) } }
        .sheet(item: $editing) { x in NavigationStack { ExpenseEditor(task: task, expense: x) } }
    }

    private func row(_ x: Expense) -> some View {
        let cat = ExpenseCategory(rawValue: x.category) ?? .other
        return HStack(spacing: 12) {
            Image(systemName: cat.icon).foregroundStyle(look.accent)
                .frame(width: 36, height: 36).background(look.accent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(x.title).font(.subheadline.weight(.medium))
                Text("\(cat.rawValue) · paid by \(engine.name(of: x.paidBy)) · \(x.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(look.textSecondary)
                if !x.receipts.isEmpty {
                    HStack(spacing: 6) { ForEach(x.receipts) { AttachmentThumb(ref: $0, size: 34) } }
                }
            }
            Spacer(minLength: 0)
            Text(Money.format(x.amount)).font(.subheadline.bold()).monospacedDigit()
        }
    }
}

struct ExpenseEditor: View {
    let task: TaskItem
    let expense: Expense?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var title = ""
    @State private var amountText = ""
    @State private var date = Date.now
    @State private var paidBy = ""
    @State private var category = ExpenseCategory.travel
    @State private var kept: [AttachmentRef] = []
    @State private var pending = PendingAttachments()

    private var people: [String] {
        var ids = task.convID.flatMap { engine.conversation($0)?.members.map(\.id) } ?? []
        if !ids.contains(engine.me) { ids.insert(engine.me, at: 0) }
        return ids
    }

    var body: some View {
        Form {
            AIScanSection(spec: ScanSpec(title: "Scan the receipt", what: "a receipt, bill or ticket for a work expense",
                                         fields: [.text("title", "What for"), .money("amount", "Total amount"), .date("date", "Date"),
                                                  .choice("category", "Category", ExpenseCategory.allCases.map(\.rawValue))])) { o in
                if let v = o.str("title") { title = v }
                if let v = o.amountText("amount") { amountText = v }
                if let v = o.date("date") { date = v }
                if let v = o.str("category"), let c = ExpenseCategory(rawValue: v) { category = c }
                for p in o.files { pending.add(p) }
            }
            Section {
                TextField("What was it for? (e.g. Court fee, Taxi)", text: $title)
                TextField("Amount", text: $amountText).keyboardType(.decimalPad).font(.title3.bold())
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Category", selection: $category) {
                    ForEach(ExpenseCategory.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                Picker("Paid by", selection: $paidBy) {
                    ForEach(people, id: \.self) { Text($0 == engine.me ? "Me" : engine.name(of: $0)).tag($0) }
                }
            }
            .lookRows()
            Section {
                if !kept.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(kept) { ref in
                                AttachmentThumb(ref: ref).overlay(alignment: .topTrailing) {
                                    Button { kept.removeAll { $0.id == ref.id } } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                }
                            }
                        }
                    }
                }
                AttachmentAdder(pending: $pending, title: "Add bill / voucher (camera, photo or PDF)")
            } header: {
                Text("Bills & vouchers")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle(expense == nil ? "New expense" : "Edit expense")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let amount = Double(amountText.replacingOccurrences(of: ",", with: "")) else { return }
                    engine.saveExpense(task, id: expense?.id, title: title.trimmingCharacters(in: .whitespaces), amount: amount,
                                       date: date, paidBy: paidBy.isEmpty ? engine.me : paidBy, category: category.rawValue,
                                       receipts: kept + pending.refs, uploads: pending.uploads)
                    Haptics.success()
                    dismiss()
                }
                .bold()
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || Double(amountText.replacingOccurrences(of: ",", with: "")) == nil)
            }
        }
        .onAppear {
            if let x = expense {
                title = x.title
                amountText = String(format: x.amount.rounded() == x.amount ? "%.0f" : "%.2f", x.amount)
                date = x.date
                paidBy = x.paidBy
                category = ExpenseCategory(rawValue: x.category) ?? .other
                kept = x.receipts
            } else {
                paidBy = engine.me
            }
        }
    }
}

// MARK: - Approvals on a task

struct TaskApprovalsSection: View {
    let task: TaskItem
    @EnvironmentObject var engine: SyncEngine
    @Query private var approvals: [Approval]
    @State private var requesting = false

    init(task: TaskItem) {
        self.task = task
        let oid: String? = task.id
        _approvals = Query(filter: #Predicate<Approval> { $0.taskID == oid }, sort: \Approval.createdAt)
    }

    var body: some View {
        if let convID = task.convID, let conv = engine.conversation(convID), !conv.left {
            Section("Approvals") {
                ForEach(approvals) { a in ApprovalCard(approvalID: a.id).padding(.vertical, 4) }
                Button { requesting = true } label: { Label("Request approval", systemImage: "checkmark.seal") }
            }
            .lookRows()
            .sheet(isPresented: $requesting) { NavigationStack { ApprovalRequestView(conv: conv, task: task) } }
        }
    }
}
