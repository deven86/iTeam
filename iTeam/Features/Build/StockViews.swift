import SwiftUI
import SwiftData

// MARK: - 📦 Stock & Inventory (business core, free)
//
// Shops, warehouses, offices and sites keep items with QR stickers, receive / issue / transfer stock and see
// low-stock alerts. It shares one store of data with Builder & Infra: a store is a `BuildRecord` of kind "store"
// (with its own team chat), items are the same "material" / "asset" records, entries are "move" records.
// So Builder site stock appears here too, and stock can be transferred between a store and a site.

extension SyncEngine {
    /// Saves a store; its team gets a group chat (like a Builder project).
    @discardableResult
    func bSaveStore(_ existing: BuildRecord?, company: String, data: BuildData, status: String) -> String {
        var d = data
        if let g = conversation(d.convID) {
            let have = Set(g.members.map(\.id))
            let add = d.team.filter { !have.contains($0) }.compactMap { contact($0) }
            if !add.isEmpty { addMembers(g, add) }
        } else if !d.team.isEmpty {
            d.convID = createGroup(title: "\(d["name"]) · Store", members: d.team.compactMap { contact($0) }, avatar: nil).id
        }
        return bSave(kind: "store", existing: existing, company: existing?.companyID ?? company, project: "", status: status, data: d)
    }
}

struct StockHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(filter: #Predicate<BuildRecord> { !$0.deleted }) private var recs: [BuildRecord]
    @AppStorage("stock.place") private var placeID = ""
    @State private var sheet: StockSheet?
    @State private var search = ""

    private func canSee(_ p: BuildRecord) -> Bool { p.ownerID == engine.me || p.d.team.contains(engine.me) || p.d.admins.contains(engine.me) }
    private var stores: [BuildRecord] { recs.filter { $0.kind == "store" && canSee($0) }.sorted { $0.title < $1.title } }
    private var sites: [BuildRecord] { recs.filter { $0.kind == "project" && canSee($0) }.sorted { $0.title < $1.title } }
    private var places: [BuildRecord] { stores + sites }
    private var place: BuildRecord? { places.first { $0.id == placeID } ?? places.first }
    private var placeIDs: Set<String> { Set(places.map(\.id)) }
    private var allItems: [BuildRecord] { recs.filter { ["material", "asset"].contains($0.kind) && placeIDs.contains($0.projectID) } }
    private var items: [BuildRecord] {
        guard let place else { return [] }
        return allItems.filter { $0.projectID == place.id }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.f("category").localizedCaseInsensitiveContains(search) || $0.f("serial").localizedCaseInsensitiveContains(search) }
            .sorted { $0.title < $1.title }
    }
    private func stock(_ r: BuildRecord) -> Double { r.kind == "material" ? engine.bStock(r) : 1 }
    private func low(_ r: BuildRecord) -> Bool { r.kind == "material" && r.num("reorder") > 0 && stock(r) <= r.num("reorder") }
    private func value(_ r: BuildRecord) -> Double { r.kind == "material" ? max(stock(r), 0) * r.num("rate") : r.num("value") }

    var body: some View {
        NavigationStack {
            List {
                if places.isEmpty {
                    EmptyStateView(icon: "shippingbox.fill", title: "Stock & Inventory",
                                    message: "Items with QR stickers, stock received and issued, low-stock alerts and transfers between shops, warehouses and sites. Builder & Infra site stock shows here too.")
                    Button { sheet = .store(nil) } label: { Label("Set up my first store / warehouse", systemImage: "plus") }
                } else {
                    dashboard
                    placePicker
                    lowSection
                    itemsSection
                }
            }
            .listStyle(.insetGrouped)
            .lookScreen()
            .navigationTitle("Stock & Inventory")
            .searchable(text: $search, prompt: "Item, category, serial")
            .refreshable { await engine.sync() }
            .toolbar { toolbar }
            .sheet(item: $sheet) { s in sheetView(s) }
        }
    }

    // MARK: Sections

    private var dashboard: some View {
        let lows = allItems.filter(low)
        return Section {
            HStack(spacing: 10) {
                GymStat(value: "\(allItems.count)", label: "Items", icon: "shippingbox")
                GymStat(value: "\(lows.count)", label: "Low stock", icon: "exclamationmark.triangle", warn: !lows.isEmpty)
                GymStat(value: Money.format(allItems.reduce(0) { $0 + value($1) }), label: "Stock value", icon: "indianrupeesign.circle")
            }
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
    }

    private var placePicker: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(places) { p in
                        Button { placeID = p.id } label: {
                            Label(p.title, systemImage: p.kind == "store" ? "building.2" : "building.columns").font(.caption.bold())
                        }
                        .buttonStyle(.bordered).tint(p.id == place?.id ? .accentColor : .secondary)
                    }
                    Button { sheet = .store(nil) } label: { Image(systemName: "plus") }.buttonStyle(.bordered)
                }
            }
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            if let place {
                HStack {
                    Text(place.kind == "store" ? [place.f("type"), place.f("address")].filter { !$0.isEmpty }.joined(separator: " · ")
                                               : "Builder & Infra site — same stock as in Builder").font(.caption).foregroundStyle(look.textSecondary)
                    Spacer()
                    if place.kind == "store" && engine.bIsAdmin(place) { Button("Edit") { sheet = .store(place) }.font(.caption) }
                }
            }
        } header: { Text("Stores & sites") }
    }

    @ViewBuilder private var lowSection: some View {
        let lows = allItems.filter(low)
        if !lows.isEmpty {
            Section {
                ForEach(lows) { r in
                    NavigationLink { BuildDetail(r: r) } label: {
                        HStack {
                            Label(r.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Spacer()
                            Text("\(BuildFmt.fmtQty(stock(r))) \(r.f("unit")) · \(places.first { $0.id == r.projectID }?.title ?? "")").font(.caption).foregroundStyle(look.textSecondary)
                        }
                    }
                }
            } header: { Text("Needs re-order") }
            .lookRows()
        }
    }

    @ViewBuilder private var itemsSection: some View {
        if let place {
            let canAdd = engine.bIsAdmin(place) || place.d.team.contains(engine.me)
            Section {
                if items.isEmpty { Text("No items here yet.").foregroundStyle(look.textSecondary) }
                ForEach(items) { r in
                    NavigationLink { BuildDetail(r: r) } label: {
                        HStack {
                            Image(systemName: r.kind == "asset" ? "qrcode" : "shippingbox.fill").foregroundStyle(low(r) ? .red : look.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.body.weight(.medium))
                                Text([r.f("category"), r.kind == "asset" ? r.status : nil, r.f("store"), r.f("where")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(look.textSecondary)
                            }
                            Spacer()
                            if r.kind == "material" {
                                Text("\(BuildFmt.fmtQty(stock(r))) \(r.f("unit"))").font(.callout.monospacedDigit().bold()).foregroundStyle(low(r) ? .red : .primary)
                            }
                        }
                    }
                }
                if canAdd {
                    HStack {
                        Button { sheet = .item("material") } label: { Label("Item", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }.buttonStyle(.glassProminent)
                        Button { sheet = .item("asset") } label: { Label("Fixed asset", systemImage: "plus.circle").frame(maxWidth: .infinity) }.buttonStyle(.glass)
                        Button { sheet = .transfer } label: { Label("Transfer", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }.buttonStyle(.glass)
                    }
                    .listRowBackground(Color.clear)
                }
            } header: { Text("\(place.title) · \(items.count) items") } footer: {
                Text("Open an item to receive or issue stock and print its QR sticker. Items marked “Paid now” go to the company's Finance book.")
            }
            .lookRows()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { Button { sheet = .scan } label: { Image(systemName: "qrcode.viewfinder") } }
        if let place {
            ToolbarItem(placement: .secondaryAction) { Button("QR sticker sheet", systemImage: "printer") { sheet = .labels(place) } }
            ToolbarItem(placement: .secondaryAction) {
                ShareMenu(title: "Stock — \(place.title)", text: { report(place) }, html: { reportHTML(place) }, label: "Export report (PDF)",
                          module: "Stock & Inventory", icon: "shippingbox.fill", colors: ModuleRegistry.stock.colors, charts: { charts(place) })
            }
        }
        ToolbarItem(placement: .secondaryAction) { Button("New store / warehouse", systemImage: "building.2") { sheet = .store(nil) } }
    }

    @ViewBuilder private func sheetView(_ s: StockSheet) -> some View {
        switch s {
        case .store(let r): NavigationStack { StoreEditor(existing: r) }
        case .item(let kind): NavigationStack { BuildEditor(kind: kind, company: place?.companyID ?? "", project: place?.id ?? "") }
        case .transfer: NavigationStack { StockTransferView(places: places, from: place) }
        case .labels(let p): NavigationStack { BuildLabelsView(project: p, recs: recs.filter { $0.projectID == p.id }) }
        case .scan: BuildScanView()
        }
    }

    // MARK: Reports

    private func report(_ p: BuildRecord) -> String {
        "Stock — \(p.title) — \(Date.now.formatted(date: .abbreviated, time: .omitted))\n" +
        allItems.filter { $0.projectID == p.id }.sorted { $0.title < $1.title }.map { r in
            r.kind == "material" ? "• \(r.title): \(BuildFmt.fmtQty(stock(r))) \(r.f("unit"))\(low(r) ? " ⚠️ low" : "")" : "• \(r.title) (asset) · \(r.status)"
        }.joined(separator: "\n")
    }

    private func reportHTML(_ p: BuildRecord) -> String {
        let e = BuildShare.esc
        let list = allItems.filter { $0.projectID == p.id }.sorted { $0.title < $1.title }
        var h = "<h2>\(e(p.title))</h2><p>Stock value: <b>\(Money.format(list.reduce(0) { $0 + value($1) }))</b> · \(Date.now.formatted(date: .long, time: .shortened))</p>"
        h += "<table><tr><th>Item</th><th>Category</th><th>In stock</th><th>Re-order at</th><th>Rate</th><th>Value</th></tr>"
        for r in list where r.kind == "material" {
            h += "<tr><td>\(e(r.title))\(low(r) ? " ⚠️" : "")</td><td>\(e(r.f("category")))</td><td>\(BuildFmt.fmtQty(stock(r))) \(e(r.f("unit")))</td><td>\(e(r.f("reorder")))</td><td>\(e(r.f("rate")))</td><td>\(Money.format(value(r)))</td></tr>"
        }
        h += "</table>"
        let assets = list.filter { $0.kind == "asset" }
        if !assets.isEmpty {
            h += "<h3>Fixed assets</h3><table><tr><th>Asset</th><th>Serial</th><th>Location</th><th>Holder</th><th>Status</th><th>Value</th></tr>"
            for a in assets { h += "<tr><td>\(e(a.title))</td><td>\(e(a.f("serial")))</td><td>\(e(a.f("where")))</td><td>\(e(a.f("holder")))</td><td>\(e(a.status))</td><td>\(Money.format(value(a)))</td></tr>" }
            h += "</table>"
        }
        return h
    }

    private func charts(_ p: BuildRecord) -> [PDFChart] {
        let mats = allItems.filter { $0.projectID == p.id && $0.kind == "material" }
        var byCat: [String: Double] = [:]
        for m in mats { byCat[m.f("category").isEmpty ? "Other" : m.f("category"), default: 0] += value(m) }
        let top = mats.sorted { value($0) > value($1) }.prefix(8)
        return [PDFChart(kind: .pie, title: "Stock value by category", labels: Array(byCat.keys), values: Array(byCat.values)),
                PDFChart(kind: .bar, title: "Top items by value", labels: top.map(\.title), values: top.map(value))]
            .filter { $0.values.contains { $0 > 0 } }
    }
}

enum StockSheet: Identifiable {
    case store(BuildRecord?), item(String), transfer, labels(BuildRecord), scan
    var id: String {
        switch self {
        case .store(let r): "store" + (r?.id ?? "")
        case .item(let k): "item" + k
        case .transfer: "transfer"
        case .labels(let p): "labels" + p.id
        case .scan: "scan"
        }
    }
}

// MARK: - Store editor

struct StoreEditor: View {
    let existing: BuildRecord?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<AttRecord> { $0.kind == "company" && !$0.deleted }) private var companies: [AttRecord]
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var d = BuildData()
    @State private var company = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. Main godown, Shop 1)", text: Binding(get: { d["name"] }, set: { d["name"] = $0 }))
                Picker("Type", selection: Binding(get: { d["type"] }, set: { d["type"] = $0 })) {
                    ForEach(["Shop", "Warehouse / godown", "Office", "Factory", "Site store", "Hospital / clinic store", "School store", "Home"], id: \.self) { Text($0).tag($0) }
                }
                TextField("Address", text: Binding(get: { d["address"] }, set: { d["address"] = $0 }), axis: .vertical)
                TextField("Store keeper", text: Binding(get: { d["manager"] }, set: { d["manager"] = $0 }))
                if existing == nil {
                    Picker("Company (for Finance)", selection: $company) {
                        Text("Personal / none").tag("")
                        ForEach(companies.filter { $0.company.isStaff(engine.me) }) { c in Text(c.company.name).tag(c.id) }
                    }
                }
            }
            Section {
                ForEach(contacts) { c in
                    Toggle(c.name, isOn: Binding(get: { d.team.contains(c.userID) }, set: { on in
                        if on { d.team.append(c.userID) } else { d.team.removeAll { $0 == c.userID }; d.admins.removeAll { $0 == c.userID } }
                    }))
                }
            } header: { Text("Store team") } footer: {
                Text("Team members can receive and issue stock and get a store group chat with every change. Leave empty to keep it just for you.")
            }
        }
        .navigationTitle(existing == nil ? "New store" : "Edit store")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if d["type"].isEmpty { d["type"] = "Warehouse / godown" }
                    let id = engine.bSaveStore(existing, company: company, data: d, status: "Active")
                    UserDefaults.standard.set(id, forKey: "stock.place")
                    dismiss()
                }
                .disabled(d["name"].trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let e = existing { d = e.d }
        }
    }
}

// MARK: - Transfer between stores and sites

struct StockTransferView: View {
    let places: [BuildRecord]
    let from: BuildRecord?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<BuildRecord> { !$0.deleted && $0.kind == "material" }) private var materials: [BuildRecord]
    @State private var fromID = ""
    @State private var toID = ""
    @State private var itemID = ""
    @State private var qty = ""
    @State private var note = ""

    private var source: [BuildRecord] { materials.filter { $0.projectID == fromID }.sorted { $0.title < $1.title } }
    private var item: BuildRecord? { source.first { $0.id == itemID } }
    private var q: Double { BuildData.number(qty) }

    var body: some View {
        Form {
            Section {
                Picker("From", selection: $fromID) { ForEach(places) { p in Text(p.title).tag(p.id) } }
                Picker("Item", selection: $itemID) {
                    Text("Choose…").tag("")
                    ForEach(source) { m in Text("\(m.title) · \(BuildFmt.fmtQty(engine.bStock(m))) \(m.f("unit"))").tag(m.id) }
                }
                TextField("Quantity", text: $qty).keyboardType(.decimalPad)
                Picker("To", selection: $toID) {
                    Text("Choose…").tag("")
                    ForEach(places.filter { $0.id != fromID }) { p in Text(p.title).tag(p.id) }
                }
                TextField("Note (vehicle, challan…)", text: $note)
            } footer: {
                if let item, q > engine.bStock(item) { Text("More than in stock (\(BuildFmt.fmtQty(engine.bStock(item)))).").foregroundStyle(.red) }
                else { Text("Issued here as “Transferred” and received there; the item is created at the destination if it isn't there yet.") }
            }
        }
        .navigationTitle("Transfer stock")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Transfer") { transfer() }.disabled(item == nil || toID.isEmpty || q <= 0) }
        }
        .onAppear { if fromID.isEmpty { fromID = from?.id ?? places.first?.id ?? "" } }
        .onChange(of: fromID) { _, _ in itemID = "" }
    }

    private func transfer() {
        guard let item, let to = places.first(where: { $0.id == toID }), let src = places.first(where: { $0.id == fromID }) else { return }
        let today = BuildData.dateString(.now)
        var out = BuildData()
        out["type"] = "Transferred"; out["qty"] = qty; out["date"] = today; out["party"] = "To \(to.title)"; out["challan"] = note; out["rate"] = item.f("rate")
        engine.bSave(kind: "move", existing: nil, company: item.companyID, project: src.id, parent: item.id, status: "", data: out)
        // Same item at the destination (matched by name), created if needed.
        let destID: String
        if let dest = materials.first(where: { $0.projectID == to.id && $0.title.caseInsensitiveCompare(item.title) == .orderedSame }) {
            destID = dest.id
        } else {
            var copy = BuildData()
            for k in ["name", "category", "unit", "reorder", "rate", "supplier"] { copy[k] = item.f(k) }
            destID = engine.bSave(kind: "material", existing: nil, company: to.companyID, project: to.id, status: "", data: copy)
        }
        var inn = BuildData()
        inn["type"] = "Received"; inn["qty"] = qty; inn["date"] = today; inn["party"] = "From \(src.title)"; inn["challan"] = note; inn["rate"] = item.f("rate")
        engine.bSave(kind: "move", existing: nil, company: to.companyID, project: to.id, parent: destID, status: "", data: inn)
        Haptics.big()
        dismiss()
    }
}
