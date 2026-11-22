import SwiftUI
import SwiftData

struct FinanceHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var modules: ModuleRegistry
    @EnvironmentObject var router: Router
    @Query(filter: #Predicate<FinRecord> { !$0.deleted }, sort: \FinRecord.date, order: .reverse) private var all: [FinRecord]
    @AppStorage("fin.book") private var book = "personal"
    @State private var month = Date.now
    @State private var adding: String?
    @State private var editing: FinRecord?
    @State private var shareItems: ShareItems?
    @State private var importing = false
    @State private var goals = false
    @State private var approve: FinRecord?

    private var pro: Bool { modules.isOn(ModuleRegistry.financePro) }
    private var books: [(id: String, name: String)] { engine.finBooks }
    private var bookName: String { books.first { $0.id == book }?.name ?? "Personal" }
    private var isOwnerOfBook: Bool { book == "personal" || engine.attRecord(book)?.company.ownerID == engine.me }

    private var lines: [FinLine] {
        let mine = all.filter { $0.kind == "entry" && $0.book == book }.map { r in
            FinLine(id: r.id, date: r.date, amount: r.amount, isIn: r.isIn, status: r.status, category: r.category,
                    title: r.d.title, party: r.d.party, source: "Finance", link: nil, record: r)
        }
        return (mine + (book == "personal" ? engine.finModuleLines() : [])).sorted { $0.date > $1.date }
    }
    private func inMonth(_ l: FinLine) -> Bool { Calendar.current.isDate(l.date, equalTo: month, toGranularity: .month) }

    var body: some View {
        let ls = lines
        let paid = ls.filter { $0.status == "paid" && inMonth($0) }
        let income = paid.filter(\.isIn).reduce(0) { $0 + $1.amount }
        let expense = paid.filter { !$0.isIn }.reduce(0) { $0 + $1.amount }
        NavigationStack {
            List {
                Section {
                    AttMonthPicker(month: $month)
                    HStack(spacing: 8) {
                        AttTile(value: Fin.money(income), label: "Income", icon: "arrow.down.circle.fill", color: 0x34C759)
                        AttTile(value: Fin.money(expense), label: "Expenses", icon: "arrow.up.circle.fill", color: 0xFF3B30)
                        AttTile(value: (income - expense < 0 ? "−" : "") + Fin.money(income - expense), label: "Net", icon: "equal.circle.fill", color: 0x007AFF)
                    }
                }
                .listRowBackground(Color.clear)
                attention(ls)
                entries(ls.filter(inMonth))
                categories(paid.filter { !$0.isIn })
                if !pro {
                    Section {
                        NavigationLink { ModuleStoreView() } label: {
                            Label("Finance Pro: cheques, bounce follow-ups, recurring, approvals, bank statements, savings, Tally", systemImage: "sparkles")
                        }
                    } footer: { Text("*Note: Finance Pro is a professional module — free for your first year. Finance stays free for life.") }
                }
            }
            .lookScreen()
            .navigationTitle(bookName == "Personal" ? "Finance" : bookName)
            .toolbar { toolbar(ls) }
            .refreshable { await engine.sync() }
            .sheet(item: Binding(get: { adding.map { FinDir(dir: $0) } }, set: { adding = $0?.dir })) { x in
                NavigationStack { FinEntryEditor(book: book, existing: nil, direction: x.dir, pro: pro) }
            }
            .sheet(item: $editing) { r in NavigationStack { FinEntryEditor(book: r.book, existing: r, direction: r.direction, pro: pro) } }
            .sheet(item: $approve) { r in NavigationStack { FinApproveView(record: r) } }
            .sheet(isPresented: $importing) { NavigationStack { FinBankImportView(book: book, existing: all.filter { $0.book == book }) } }
            .sheet(isPresented: $goals) { NavigationStack { FinGoalsView(book: book) } }
            .shareSheet($shareItems)
        }
    }

    @ViewBuilder
    private func attention(_ ls: [FinLine]) -> some View {
        let soon = Date.now.addingTimeInterval(7 * 86400)
        let due = ls.filter { $0.status == "due" && $0.date < soon }.sorted { $0.date < $1.date }
        let pending = ls.filter { $0.status == "pending" }
        let bounced = all.filter { $0.book == book && $0.d.chequeStatus == "bounced" }
        if !(due.isEmpty && pending.isEmpty && bounced.isEmpty) {
            Section("Needs attention") {
                ForEach(pending) { l in
                    Button { if isOwnerOfBook, let r = l.record { approve = r } } label: {
                        AttLine(icon: "checkmark.seal.fill", color: 0xFF9500, title: "Approval: \(Fin.money(l.amount)) — \(l.title.isEmpty ? l.category : l.title)",
                                detail: "Asked by \(engine.name(of: l.record?.by ?? ""))", trailing: isOwnerOfBook ? "Decide" : "Waiting")
                    }
                }
                ForEach(bounced) { r in
                    Button { editing = r } label: {
                        AttLine(icon: "exclamationmark.triangle.fill", color: 0xFF3B30, title: "Bounced cheque \(r.d.chequeNo) — \(Fin.money(r.amount))",
                                detail: "\(r.d.party) · follow up until cleared", trailing: "Open")
                    }
                }
                ForEach(due.prefix(15)) { l in row(l, showPay: true) }
            }
            .lookRows()
        }
    }

    @ViewBuilder
    private func entries(_ ls: [FinLine]) -> some View {
        Section(month.formatted(.dateTime.month(.wide).year())) {
            if ls.isEmpty {
                Text("No money recorded this month. Tap + to add income or an expense.").foregroundStyle(.secondary)
            }
            ForEach(ls.prefix(150)) { l in row(l, showPay: false) }
        }
        .lookRows()
    }

    @ViewBuilder
    private func categories(_ out: [FinLine]) -> some View {
        let groups = Dictionary(grouping: out, by: \.category).map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }.sorted { $0.1 > $1.1 }
        if !groups.isEmpty {
            Section("Where the money went") {
                ForEach(groups, id: \.0) { g in LabeledContent(g.0, value: Fin.money(g.1)) }
            }
            .lookRows()
        }
    }

    private func row(_ l: FinLine, showPay: Bool) -> some View {
        Button {
            if let r = l.record { editing = r } else if let link = l.link, let u = URL(string: link) { router.handle(u) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: l.isIn ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                    .font(.title2).foregroundStyle(l.isIn ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.title.isEmpty ? l.category : l.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
                    Text([l.category == l.title ? "" : l.category, l.party, l.date.formatted(date: .abbreviated, time: .omitted),
                          l.source == "Finance" ? "" : "from \(l.source)", l.record?.d.files.isEmpty == false ? "📎" : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text((l.isIn ? "+" : "−") + Fin.money(l.amount)).font(.subheadline.bold()).foregroundStyle(l.isIn ? .green : .primary)
                    if l.status != "paid" { Text(l.status == "due" ? (l.isIn ? "To receive" : "To pay") : l.status.capitalized).font(.caption2.bold()).foregroundStyle(.orange) }
                }
            }
        }
        .swipeActions {
            if showPay, let r = l.record, r.status == "due" { Button("Paid") { engine.finMarkPaid(r); Haptics.success() }.tint(.green) }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ ls: [FinLine]) -> some ToolbarContent {
        if books.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(books, id: \.id) { b in
                        Button { book = b.id } label: { Label(b.name, systemImage: b.id == book ? "checkmark" : (b.id == "personal" ? "person" : "building.2")) }
                    }
                } label: { Image(systemName: book == "personal" ? "person.crop.circle" : "building.2.crop.circle") }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Income", systemImage: "arrow.down.left.circle") { adding = "in" }
                Button("Expense", systemImage: "arrow.up.right.circle") { adding = "out" }
                Button("Refund received", systemImage: "arrow.uturn.down.circle") { adding = "refundIn" }
                Button("Refund paid", systemImage: "arrow.uturn.up.circle") { adding = "refundOut" }
            } label: { Image(systemName: "plus") }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Export report (PDF)", systemImage: "doc.richtext") {
                if let u = PDFMaker.make(title: "\(bookName) — \(month.formatted(.dateTime.month(.wide).year()))", bodyHTML: FinExport.html(ls, month: month),
                                         fileName: "Finance \(bookName)", module: "Finance", icon: "indianrupeesign.circle.fill", colors: [0x0BA360, 0x3CBA92],
                                         charts: PDFCharts.finance(ls, month: month)) { shareItems = ShareItems(items: [u]) }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Export Excel (CSV)", systemImage: "tablecells") {
                if let u = Exporter.file(FinExport.csv(ls), name: "Finance \(bookName).csv") { shareItems = ShareItems(items: [u]) }
            }
        }
        if pro {
            ToolbarItem(placement: .secondaryAction) {
                Button("Export to Tally (XML)", systemImage: "arrow.down.doc") {
                    if let u = Exporter.file(FinExport.tally(ls.filter { $0.status == "paid" && inMonth($0) }, company: bookName), name: "Tally \(bookName).xml") { shareItems = ShareItems(items: [u]) }
                }
            }
            ToolbarItem(placement: .secondaryAction) { Button("Import bank statement (CSV)", systemImage: "building.columns") { importing = true } }
            ToolbarItem(placement: .secondaryAction) { Button("Savings goals", systemImage: "target") { goals = true } }
        }
    }
}

struct FinDir: Identifiable { let dir: String; var id: String { dir } }

// MARK: - Editor

struct FinEntryEditor: View {
    let book: String
    let existing: FinRecord?
    let direction: String
    let pro: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var dir = "out"
    @State private var amountText = ""
    @State private var date = Date.now
    @State private var status = "paid"
    @State private var category = ""
    @State private var d = FinData()
    @State private var needsApproval = false
    @State private var uploads: [String: String] = [:]
    @State private var loaded = false
    @State private var confirmDelete = false

    private var isCompany: Bool { book != "personal" }
    private var isOwner: Bool { !isCompany || engine.attRecord(book)?.company.ownerID == engine.me }
    private var cats: [String] { dir == "in" || dir == "refundIn" ? Fin.incomeCategories : Fin.expenseCategories }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $dir) {
                    Text("Income").tag("in"); Text("Expense").tag("out"); Text("Refund in").tag("refundIn"); Text("Refund out").tag("refundOut")
                }
                .pickerStyle(.segmented)
                TextField("Amount (₹)", text: $amountText).keyboardType(.decimalPad).font(.title2.bold())
                TextField("What for", text: $d.title)
                Picker("Category", selection: $category) {
                    ForEach(cats + (cats.contains(category) || category.isEmpty ? [] : [category]), id: \.self) { Text($0).tag($0) }
                }
                TextField(dir == "in" ? "Received from" : "Paid to", text: $d.party)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Status", selection: $status) {
                    Text("Paid").tag("paid"); Text(dir == "in" ? "To receive" : "To pay (upcoming)").tag("due")
                    if status == "pending" { Text("Waiting approval").tag("pending") }
                    if status == "rejected" { Text("Rejected").tag("rejected") }
                }
            }
            Section("Payment") {
                Picker("Mode", selection: $d.mode) { ForEach(Fin.modes, id: \.self) { Text($0).tag($0) } }
                TextField("Reference / UTR / UPI ID", text: $d.reference)
                if d.mode == "Cheque" {
                    TextField("Cheque no.", text: $d.chequeNo).keyboardType(.numberPad)
                    TextField("Bank", text: $d.chequeBank)
                    if pro {
                        Picker("Cheque status", selection: $d.chequeStatus) {
                            Text("—").tag(""); Text("Issued").tag("issued"); Text("Deposited").tag("deposited"); Text("Cleared").tag("cleared"); Text("Bounced").tag("bounced")
                        }
                    }
                }
            }
            if pro {
                Section {
                    Picker("Repeats", selection: $d.repeatRule) {
                        Text("Doesn't repeat").tag("none"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly"); Text("Quarterly").tag("quarterly"); Text("Yearly").tag("yearly")
                    }
                    if isCompany && !isOwner && existing == nil { Toggle("Needs owner's approval (cheque / RTGS / payment)", isOn: $needsApproval) }
                } header: { Text("Finance Pro") } footer: {
                    Text("Recurring items stay as 'To pay' and move to the next date each time you mark them paid.")
                }
            }
            Section("Receipt, bill, invoice") {
                ForEach(d.files) { f in Label(f.name, systemImage: f.kind == "image" ? "photo" : "doc") }
                    .onDelete { d.files.remove(atOffsets: $0) }
                Button("Add document or photo", systemImage: "paperclip") {
                    Presenter.file(types: [.pdf, .image, .data]) { url in
                        if let p = try? Attachments.prepareFile(url) { d.files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                    }
                }
                if Presenter.hasCamera {
                    Button("Photo of receipt", systemImage: "camera") {
                        Presenter.camera { img in
                            if let data = img.jpegData(compressionQuality: 0.85), let p = try? Attachments.prepareImage(data) {
                                d.files.append(p.ref); uploads[p.upload.0] = p.upload.1
                            }
                        }
                    }
                }
            }
            Section { TextField("Note", text: $d.note, axis: .vertical) }
            if let existing, existing.status == "due" {
                Button("Mark as paid now", systemImage: "checkmark.circle.fill") { engine.finMarkPaid(existing); Haptics.success(); dismiss() }
            }
            if existing != nil && (isOwner || existing?.by == engine.me) {
                Button("Delete (kept in archive)", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(existing == nil ? "New entry" : "Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled((Double(amountText) ?? 0) <= 0) }
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { if let existing { engine.finDelete(existing) }; dismiss() }
        }
        .onAppear(perform: load)
        .onChange(of: dir) { _, _ in if !cats.contains(category) { category = cats.first ?? "" } }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        dir = direction
        if let r = existing {
            amountText = r.amount.formatted(.number.grouping(.never)); date = r.date; status = r.status; category = r.category; d = r.d
        } else {
            category = cats.first ?? "Other"
        }
    }

    private func save() {
        let amount = Double(amountText) ?? 0
        let st = needsApproval ? "pending" : status
        engine.finSave(existing, book: book, date: date, amount: amount, direction: dir, status: st, category: category, data: d, uploads: uploads)
        Haptics.success()
        dismiss()
    }
}

struct FinApproveView: View {
    let record: FinRecord
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("Amount", value: Fin.money(record.amount))
                LabeledContent("For", value: record.d.title.isEmpty ? record.category : record.d.title)
                LabeledContent("To / from", value: record.d.party)
                LabeledContent("Mode", value: record.d.mode + (record.d.chequeNo.isEmpty ? "" : " · \(record.d.chequeNo)"))
                LabeledContent("Asked by", value: engine.name(of: record.by))
                if !record.d.note.isEmpty { Text(record.d.note) }
                ForEach(record.d.files) { f in Label(f.name, systemImage: "paperclip") }
            }
            Section { TextField("Note (optional)", text: $note) }
            Button("Approve", systemImage: "checkmark.seal.fill") { engine.finDecide(record, approve: true, note: note); Haptics.success(); dismiss() }
            Button("Reject", systemImage: "xmark.seal.fill", role: .destructive) { engine.finDecide(record, approve: false, note: note); dismiss() }
        }
        .navigationTitle("Payment approval")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Bank statement (CSV) → match or add

struct FinBankImportView: View {
    let book: String
    let existing: [FinRecord]
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [BankRow] = []
    @State private var error: String?

    struct BankRow: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let amount: Double   // + credit, − debit
        var match: FinRecord?
        var done = false
    }

    var body: some View {
        List {
            Section {
                Button("Choose statement file (CSV)", systemImage: "doc.badge.plus") {
                    Presenter.file(types: [.commaSeparatedText, .plainText, .data]) { url in load(url) }
                }
            } footer: { Text("Download the statement as CSV/Excel-CSV from your bank's net-banking. PDF statements can't be read reliably — export CSV instead. Rows that match an entry (same amount within 5 days) are ticked; the rest can be added in one tap.") }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach($rows) { $r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.text).font(.caption).lineLimit(2)
                        Text(r.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text((r.amount >= 0 ? "+" : "−") + Fin.money(r.amount)).font(.subheadline.bold()).foregroundStyle(r.amount >= 0 ? .green : .primary)
                    if r.done || r.match != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Add") {
                            var d = FinData(); d.title = r.text; d.mode = "Bank"; d.bankMatched = true
                            engine.finSave(nil, book: book, date: r.date, amount: abs(r.amount), direction: r.amount >= 0 ? "in" : "out",
                                           status: "paid", category: r.amount >= 0 ? "Other income" : "Other", data: d)
                            r.done = true
                        }
                        .buttonStyle(.glass).controlSize(.small)
                    }
                }
            }
        }
        .navigationTitle("Bank statement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    for r in rows { if let m = r.match, !m.d.bankMatched { var d = m.d; d.bankMatched = true
                        engine.finSave(m, book: m.book, date: m.date, amount: m.amount, direction: m.direction, status: m.status, category: m.category, data: d) } }
                    dismiss()
                }
            }
        }
    }

    private func load(_ url: URL) {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { error = "Couldn't read that file."; return }
        let parsed = BankCSV.parse(text)
        if parsed.isEmpty { error = "No transactions found. Make sure it's the CSV export with Date, Description and Debit/Credit (or Amount) columns."; return }
        error = nil
        var used = Set<String>()
        rows = parsed.map { p in
            let m = existing.first { e in
                !used.contains(e.id) && abs(e.amount - abs(p.amount)) < 0.01 && e.isIn == (p.amount >= 0) && abs(e.date.timeIntervalSince(p.date)) < 5 * 86400
            }
            if let m { used.insert(m.id) }
            return BankRow(date: p.date, text: p.text, amount: p.amount, match: m)
        }
    }
}

/// Reads common Indian bank CSV exports: Date, Narration/Description, Debit/Withdrawal, Credit/Deposit (or a signed Amount).
enum BankCSV {
    static func split(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() } else if ch == "," && !quoted { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "₹", with: "").replacingOccurrences(of: "Cr", with: "").replacingOccurrences(of: "Dr", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Double(t)
    }
    static func date(_ s: String) -> Date? {
        for f in ["dd/MM/yyyy", "dd/MM/yy", "dd-MM-yyyy", "dd-MMM-yyyy", "dd MMM yyyy", "yyyy-MM-dd", "dd-MM-yy", "dd.MM.yyyy", "MM/dd/yyyy"] {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_IN"); df.dateFormat = f
            if let d = df.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
    static func parse(_ text: String) -> [(date: Date, text: String, amount: Double)] {
        let lines = text.components(separatedBy: .newlines).map(split).filter { $0.count >= 3 }
        guard let hi = lines.firstIndex(where: { r in r.contains { $0.lowercased().contains("date") } }) else { return [] }
        let h = lines[hi].map { $0.lowercased() }
        func col(_ keys: [String]) -> Int? { h.firstIndex { c in keys.contains { c.contains($0) } } }
        guard let dc = col(["date"]) else { return [] }
        let tc = col(["narration", "description", "particular", "remarks", "details"])
        let debit = col(["debit", "withdrawal", "dr"]), credit = col(["credit", "deposit", "cr"]), amt = col(["amount"])
        var out: [(Date, String, Double)] = []
        for r in lines.dropFirst(hi + 1) {
            guard r.count > dc, let d = date(r[dc]) else { continue }
            var a: Double?
            if let debit, debit < r.count, let v = number(r[debit]), v != 0 { a = -abs(v) }
            if let credit, credit < r.count, let v = number(r[credit]), v != 0 { a = abs(v) }
            if a == nil, let amt, amt < r.count, let v = number(r[amt]) { a = v }
            guard let a else { continue }
            out.append((d, tc.flatMap { $0 < r.count ? r[$0] : nil } ?? "Bank entry", a))
        }
        return out
    }
}

// MARK: - Savings goals

struct FinGoalsView: View {
    let book: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<FinRecord> { !$0.deleted }) private var all: [FinRecord]
    @State private var name = ""
    @State private var target = ""
    @State private var addTo: FinRecord?
    @State private var addAmount = ""

    var body: some View {
        let goals = all.filter { $0.kind == "goal" && $0.book == book }
        List {
            ForEach(goals) { g in
                let saved = all.filter { $0.kind == "entry" && $0.d.goalID == g.id && $0.status == "paid" }.reduce(0) { $0 + $1.amount }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(g.d.title).font(.headline); Spacer(); Text("\(Fin.money(saved)) of \(Fin.money(g.d.target))").font(.caption) }
                    ProgressView(value: min(saved, g.d.target), total: max(g.d.target, 1))
                    Button("Add savings", systemImage: "plus.circle") { addTo = g }.font(.caption).buttonStyle(.borderless)
                }
            }
            Section("New goal") {
                TextField("Goal (e.g. Office laptop)", text: $name)
                TextField("Target ₹", text: $target).keyboardType(.decimalPad)
                Button("Create goal") {
                    var d = FinData(); d.title = name; d.target = Double(target) ?? 0
                    engine.finSave(nil, kind: "goal", book: book, date: .now, amount: 0, direction: "out", status: "paid", category: "Savings", data: d)
                    name = ""; target = ""
                }
                .disabled(name.isEmpty || (Double(target) ?? 0) <= 0)
            }
        }
        .navigationTitle("Savings goals")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .alert("Add to “\(addTo?.d.title ?? "")”", isPresented: Binding(get: { addTo != nil }, set: { if !$0 { addTo = nil } })) {
            TextField("Amount ₹", text: $addAmount).keyboardType(.decimalPad)
            Button("Add") {
                if let g = addTo, let a = Double(addAmount), a > 0 {
                    var d = FinData(); d.title = "Savings — \(g.d.title)"; d.goalID = g.id
                    engine.finSave(nil, book: book, date: .now, amount: a, direction: "out", status: "paid", category: "Savings", data: d)
                }
                addAmount = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Exports

enum FinExport {
    private static func c(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func x(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

    static func html(_ ls: [FinLine], month: Date) -> String {
        let m = ls.filter { Calendar.current.isDate($0.date, equalTo: month, toGranularity: .month) }
        let paid = m.filter { $0.status == "paid" }
        let inc = paid.filter(\.isIn).reduce(0) { $0 + $1.amount }, exp = paid.filter { !$0.isIn }.reduce(0) { $0 + $1.amount }
        var h = "<p>Income <b>\(Fin.money(inc))</b> · Expenses <b>\(Fin.money(exp))</b> · Net <b>\(inc - exp < 0 ? "−" : "")\(Fin.money(inc - exp))</b></p>"
        h += "<table><tr><th>Date</th><th>What</th><th>Category</th><th>Party</th><th>Status</th><th>Source</th><th>In</th><th>Out</th></tr>"
        for l in m.sorted(by: { $0.date < $1.date }) {
            h += "<tr><td>\(l.date.formatted(date: .abbreviated, time: .omitted))</td><td>\(PDFMaker.esc(l.title))</td><td>\(PDFMaker.esc(l.category))</td><td>\(PDFMaker.esc(l.party))</td>"
            h += "<td>\(l.status)</td><td>\(l.source)</td><td>\(l.isIn ? Fin.money(l.amount) : "")</td><td>\(l.isIn ? "" : Fin.money(l.amount))</td></tr>"
        }
        return h + "</table>"
    }

    static func csv(_ ls: [FinLine]) -> String {
        (["Date,Type,Amount,Status,Category,What,Party,Mode,Reference,Cheque,Source"] + ls.map { l in
            let d = l.record?.d
            return [Att.key(l.date), l.isIn ? "Income" : "Expense", String(format: "%.2f", l.amount), l.status, c(l.category), c(l.title), c(l.party),
                    c(d?.mode ?? ""), c(d?.reference ?? ""), c(d?.chequeNo ?? ""), c(l.source)].joined(separator: ",")
        }).joined(separator: "\n")
    }

    /// TallyPrime: Receipt vouchers for income, Payment vouchers for expenses (party/category ledger vs Cash or Bank).
    static func tally(_ ls: [FinLine], company: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        var v = ""
        for l in ls {
            let type = l.isIn ? "Receipt" : "Payment"
            let ledger = x(l.party.isEmpty ? l.category : l.party)
            let cashBank = (l.record?.d.mode ?? "Cash") == "Cash" ? "Cash" : "Bank"
            let amt = String(format: "%.2f", l.amount)
            v += """
              <TALLYMESSAGE xmlns:UDF="TallyUDF"><VOUCHER VCHTYPE="\(type)" ACTION="Create">
               <DATE>\(f.string(from: l.date))</DATE><VOUCHERTYPENAME>\(type)</VOUCHERTYPENAME><NARRATION>\(x(l.title))</NARRATION>
               <ALLLEDGERENTRIES.LIST><LEDGERNAME>\(ledger)</LEDGERNAME><ISDEEMEDPOSITIVE>\(l.isIn ? "No" : "Yes")</ISDEEMEDPOSITIVE><AMOUNT>\(l.isIn ? amt : "-" + amt)</AMOUNT></ALLLEDGERENTRIES.LIST>
               <ALLLEDGERENTRIES.LIST><LEDGERNAME>\(cashBank)</LEDGERNAME><ISDEEMEDPOSITIVE>\(l.isIn ? "Yes" : "No")</ISDEEMEDPOSITIVE><AMOUNT>\(l.isIn ? "-" + amt : amt)</AMOUNT></ALLLEDGERENTRIES.LIST>
              </VOUCHER></TALLYMESSAGE>

            """
        }
        return """
        <ENVELOPE><HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER><BODY><IMPORTDATA>
         <REQUESTDESC><REPORTNAME>Vouchers</REPORTNAME><STATICVARIABLES><SVCURRENTCOMPANY>\(x(company))</SVCURRENTCOMPANY></STATICVARIABLES></REQUESTDESC>
         <REQUESTDATA>
        \(v) </REQUESTDATA>
        </IMPORTDATA></BODY></ENVELOPE>
        """
    }
}
