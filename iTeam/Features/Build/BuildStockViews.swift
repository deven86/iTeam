import SwiftUI
import SwiftData
import PhotosUI
import CoreImage
import LocalAuthentication

// MARK: - QR stickers

enum BuildQR {
    static let prefix = "iteam-build:"
    static func code(_ r: BuildRecord) -> String { prefix + r.id }
    static func id(from text: String) -> String? {
        if text.hasPrefix(prefix) { return String(text.dropFirst(prefix.count)) }
        if let u = URL(string: text), u.scheme == "iteam", u.host == "item", u.pathComponents.count >= 3, u.pathComponents[1] == "build" { return u.pathComponents[2] }
        return nil
    }

    /// Reads a QR code from a photo.
    static func read(_ image: UIImage) -> String? {
        guard let ci = CIImage(image: image),
              let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return det.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    /// A4 sheet of stickers: 3 × 7 per page, each with QR, name, unit/type and the project.
    @MainActor static func labelsPDF(_ recs: [BuildRecord], copies: Int, project: String) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let cols = 3, rows = 7
        let margin: CGFloat = 18
        let w = (page.width - margin * 2) / CGFloat(cols), h = (page.height - margin * 2) / CGFloat(rows)
        let all = recs.flatMap { Array(repeating: $0, count: max(1, copies)) }
        guard !all.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QR stickers.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        do {
            try renderer.writePDF(to: url) { ctx in
                for (i, r) in all.enumerated() {
                    if i % (cols * rows) == 0 { ctx.beginPage() }
                    let slot = i % (cols * rows)
                    let cell = CGRect(x: margin + CGFloat(slot % cols) * w, y: margin + CGFloat(slot / cols) * h, width: w, height: h).insetBy(dx: 4, dy: 4)
                    UIColor.lightGray.setStroke()
                    let path = UIBezierPath(roundedRect: cell, cornerRadius: 8)
                    path.setLineDash([3, 3], count: 2, phase: 0)
                    path.stroke()
                    let side = cell.height - 16
                    QRCode.image(code(r))?.draw(in: CGRect(x: cell.minX + 8, y: cell.minY + 8, width: side, height: side))
                    let textRect = CGRect(x: cell.minX + side + 14, y: cell.minY + 10, width: cell.width - side - 20, height: cell.height - 20)
                    let sub = r.kind == "material" ? [r.f("unit"), r.f("category")] : [r.f("type"), r.f("reg").isEmpty ? r.f("serial") : r.f("reg")]
                    let text = NSMutableAttributedString(string: r.title + "\n", attributes: [.font: UIFont.boldSystemFont(ofSize: 10)])
                    text.append(NSAttributedString(string: sub.filter { !$0.isEmpty }.joined(separator: " · ") + "\n" + project + "\nScan in iTeam",
                                                   attributes: [.font: UIFont.systemFont(ofSize: 7.5), .foregroundColor: UIColor.darkGray]))
                    text.draw(in: textRect)
                }
            }
            return url
        } catch { return nil }
    }
}

struct BuildQRCard: View {
    let r: BuildRecord
    @EnvironmentObject var engine: SyncEngine
    @State private var copies = 1
    @State private var pdf: URL?

    var body: some View {
        HStack(spacing: 14) {
            if let img = QRCode.image(BuildQR.code(r)) {
                Image(uiImage: img).interpolation(.none).resizable().frame(width: 110, height: 110)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Print and stick on the item, rack or machine. Scan it in Builder → Scan to see details and update stock.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Copies: \(copies)", value: $copies, in: 1...21).font(.caption)
                Button("Make sticker PDF", systemImage: "printer.fill") {
                    pdf = BuildQR.labelsPDF([r], copies: copies, project: engine.bRecord(r.projectID)?.title ?? "")
                }
                .buttonStyle(.glass).controlSize(.small)
                if let pdf { ShareLink(item: pdf) { Label("Print / share", systemImage: "square.and.arrow.up") }.font(.caption) }
            }
        }
    }
}

/// Stickers for many items at once.
struct BuildLabelsView: View {
    let project: BuildRecord
    let recs: [BuildRecord]
    @State private var picked: Set<String> = []
    @State private var copies = 1
    @State private var pdf: URL?

    private var items: [BuildRecord] { recs.filter { BuildKinds.of($0.kind).qr }.sorted { $0.title < $1.title } }

    var body: some View {
        List {
            Section {
                Stepper("Copies of each: \(copies)", value: $copies, in: 1...21)
                Button(picked.count == items.count ? "Select none" : "Select all") {
                    picked = picked.count == items.count ? [] : Set(items.map(\.id))
                }
                Button("Make sticker sheet (\(picked.count))", systemImage: "printer.fill") {
                    pdf = BuildQR.labelsPDF(items.filter { picked.contains($0.id) }, copies: copies, project: project.title)
                }
                .disabled(picked.isEmpty)
                if let pdf { ShareLink(item: pdf) { Label("Print / share PDF", systemImage: "square.and.arrow.up") } }
            } footer: { Text("A4 sheet, 21 stickers per page. Use label paper or print and laminate.") }
            ForEach(items) { r in
                Button {
                    if picked.contains(r.id) { picked.remove(r.id) } else { picked.insert(r.id) }
                } label: {
                    HStack {
                        Image(systemName: picked.contains(r.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(picked.contains(r.id) ? .blue : .secondary)
                        BuildRow(r: r)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("QR stickers")
    }
}

// MARK: - Scanner

struct BuildScanView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var found: BuildRecord?
    @State private var message = ""
    @State private var photo: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ZStack {
                    QRScanner { text in handle(text) }
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.7), lineWidth: 2).padding(40)
                }
                .frame(maxHeight: 420)
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Scan from a photo", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass).controlSize(.large)
                Spacer()
            }
            .padding()
            .navigationTitle("Scan sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .navigationDestination(item: $found) { r in BuildDetail(r: r) }
            .onChange(of: photo) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                    if let text = BuildQR.read(img) { handle(text) } else { message = "No QR code found in that photo." }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard found == nil else { return }
        guard let id = BuildQR.id(from: text) else { message = "That isn't an iTeam Builder sticker."; return }
        if let r = engine.bRecord(id), !r.deleted { Haptics.big(); found = r } else { message = "Sticker not found — it may belong to a project you're not in." }
    }
}

// MARK: - Secure vault (only my devices, Face ID)

struct BuildVaultView: View {
    let company: String
    let project: String
    @EnvironmentObject var engine: SyncEngine
    @Query(filter: #Predicate<BuildRecord> { $0.kind == "vault" && !$0.deleted }, sort: \BuildRecord.createdAt, order: .reverse) private var docs: [BuildRecord]
    @State private var unlocked = false
    @State private var adding = false

    private var mine: [BuildRecord] { docs.filter { $0.ownerID == engine.me && ($0.projectID == project || project.isEmpty) } }

    var body: some View {
        Group {
            if unlocked {
                List {
                    Section {
                        if mine.isEmpty { Text("No documents yet.").foregroundStyle(.secondary) }
                        ForEach(mine) { r in NavigationLink { BuildDetail(r: r) } label: { BuildRow(r: r) } }
                    } footer: {
                        Text("Only on your own devices, end-to-end encrypted. Not shared with the project team, buyers or partners. Keep originals safe too — files are cached on devices where you've opened them.")
                    }
                }
                .listStyle(.insetGrouped)
                .lookScreen()
                .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") } } }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "lock.doc.fill").font(.system(size: 54)).foregroundStyle(.orange)
                    Text("Secure vault").font(.title2.bold())
                    Text("Agreements, title deeds, 7/12, approvals and partnership deeds.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Unlock", systemImage: "faceid") { Task { await unlock() } }.buttonStyle(.glassProminent).controlSize(.large)
                }
                .padding()
                .task { await unlock() }
            }
        }
        .navigationTitle("Secure vault")
        .sheet(isPresented: $adding) { NavigationStack { BuildEditor(kind: "vault", company: company, project: project) } }
    }

    private func unlock() async {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { unlocked = true; return }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open the project vault")) == true { unlocked = true }
    }
}

// MARK: - Share text / PDF

enum BuildShare {
    @MainActor static func recordText(_ r: BuildRecord, engine: SyncEngine) -> String {
        let k = BuildKinds.of(r.kind)
        var lines = ["\(k.label): \(r.title)" + (r.status.isEmpty ? "" : " — \(r.status)")]
        if let p = engine.bRecord(r.projectID) { lines.append("Project: \(p.title)") }
        for f in k.fields where !r.f(f.key).isEmpty && f.key != "idNo" && f.key != "bankDetails" {
            lines.append("\(f.label): \(BuildFmt.display(f, r.f(f.key)))")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor static func recordHTML(_ r: BuildRecord, kids: [BuildRecord], engine: SyncEngine) -> String {
        let k = BuildKinds.of(r.kind)
        var h = "<h2>\(esc(r.title))</h2><p>\(esc(k.label))\(r.status.isEmpty ? "" : " · <b>\(esc(r.status))</b>")\(engine.bRecord(r.projectID).map { " · " + esc($0.title) } ?? "")</p><table>"
        for f in k.fields where !r.f(f.key).isEmpty {
            h += "<tr><th>\(esc(f.label))</th><td>\(esc(BuildFmt.display(f, r.f(f.key))))</td></tr>"
        }
        h += "</table>"
        for kind in ["demand", "payment", "move", "log", "unit", "sale"] {
            let list = kids.filter { $0.kind == kind }
            guard !list.isEmpty else { continue }
            h += "<h3>\(BuildKinds.of(kind).plural)</h3><table><tr><th>Item</th><th>Details</th><th>Status</th></tr>"
            for c in list { h += "<tr><td>\(esc(c.title))</td><td>\(esc(BuildFmt.subtitle(c, engine: engine)))</td><td>\(esc(c.status))</td></tr>" }
            h += "</table>"
        }
        if r.kind == "sale" {
            let paid = kids.filter { $0.kind == "payment" && $0.status != "Bounced" }.reduce(0) { $0 + $1.num("amount") }
            h += "<p><b>Agreement value:</b> \(Money.format(r.num("value"))) · <b>Received:</b> \(Money.format(paid)) · <b>Balance:</b> \(Money.format(max(0, r.num("value") - paid)))</p>"
        }
        return h
    }

    @MainActor static func viewsText(_ r: BuildRecord, engine: SyncEngine) -> String {
        let project = engine.bRecord(r.projectID)?.title ?? ""
        switch r.kind {
        case "progress": return "🏗️ \(project): \(r.title)" + (r.f("where").isEmpty ? "" : " — \(r.f("where"))")
        case "reward": return "🏆 \(r.f("name")) — \(r.f("reason")) at \(project). Thank you!"
        case "test": return "🧪 \(project): \(r.title) — \(r.status)"
        case "approval": return "✅ \(project): \(r.title) received"
        default: return "🏗️ \(project): \(r.title) — \(r.status)"
        }
    }

    @MainActor static func projectText(_ p: BuildRecord, recs: [BuildRecord], engine: SyncEngine) -> String {
        let units = recs.filter { $0.kind == "unit" }
        let sold = units.filter { ["Booked", "Agreement done", "Registered", "Possession given"].contains($0.status) }
        let sales = recs.filter { $0.kind == "sale" && $0.status != "Cancelled" }
        let collected = recs.filter { $0.kind == "payment" && $0.status != "Bounced" && sales.map(\.id).contains($0.parentID) }.reduce(0) { $0 + $1.num("amount") }
        let value = sales.reduce(0) { $0 + $1.num("value") }
        var out = ["🏗️ \(p.title) (\(p.f("type"))) — \(p.status)", "\(p.f("address")) \(p.f("city"))",
                   "Units: \(units.count), sold \(sold.count). Sales value \(Money.format(value)), collected \(Money.format(collected)), balance \(Money.format(max(0, value - collected))).",
                   "Buildings: " + recs.filter { $0.kind == "building" }.map { "\($0.title) (\($0.status))" }.joined(separator: ", ")]
        let low = recs.filter { $0.kind == "material" && $0.num("reorder") > 0 && engine.bStock($0) <= $0.num("reorder") }
        if !low.isEmpty { out.append("Low stock: " + low.map { "\($0.title) \(BuildFmt.fmtQty(engine.bStock($0))) \($0.f("unit"))" }.joined(separator: ", ")) }
        let pending = recs.filter { $0.kind == "approval" && $0.status != "Approved" }
        if !pending.isEmpty { out.append("Approvals pending: " + pending.map { "\($0.title) (\($0.status))" }.joined(separator: ", ")) }
        let failed = recs.filter { $0.kind == "test" && $0.status == "Fail" }
        if !failed.isEmpty { out.append("Failed tests: " + failed.map { "\($0.title) at \($0.f("where"))" }.joined(separator: ", ")) }
        let disputes = recs.filter { $0.kind == "dispute" && !["Settled", "Closed"].contains($0.status) }
        if !disputes.isEmpty { out.append("Open disputes: " + disputes.map { "\($0.title) (\($0.status))" }.joined(separator: ", ")) }
        let machines = recs.filter { $0.kind == "equipment" }
        if !machines.isEmpty { out.append("Machines: " + machines.map { "\($0.title) \($0.status)" }.joined(separator: ", ")) }
        return out.joined(separator: "\n")
    }

    @MainActor static func projectHTML(_ p: BuildRecord, recs: [BuildRecord], engine: SyncEngine) -> String {
        var h = "<h2>\(esc(p.title))</h2><p>\(esc(p.f("type"))) · \(esc(p.status)) · \(esc(p.f("address"))) \(esc(p.f("city")))</p>"
        h += "<p>RERA: \(esc(p.f("rera"))) · Plot: \(esc(p.f("plot"))) \(BuildFmt.areaUnit) · Authority: \(esc(p.f("authority")))</p>"
        func table(_ kind: String, _ cols: [String], _ row: (BuildRecord) -> [String]) {
            let list = recs.filter { $0.kind == kind }
            guard !list.isEmpty else { return }
            h += "<h3>\(BuildKinds.of(kind).plural) (\(list.count))</h3><table><tr>" + cols.map { "<th>\($0)</th>" }.joined() + "</tr>"
            for r in list.sorted(by: { $0.title < $1.title }) { h += "<tr>" + row(r).map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }
            h += "</table>"
        }
        table("building", ["Building", "Use", "Wings", "Floors", "Stage"]) { [$0.title, $0.f("use"), $0.f("wings"), $0.f("floors"), $0.status] }
        table("sale", ["Buyer", "Unit", "Value", "Received", "Loan", "Status"]) { s in
            let paid = recs.filter { $0.kind == "payment" && $0.parentID == s.id && $0.status != "Bounced" }.reduce(0) { $0 + $1.num("amount") }
            return [s.title, engine.bRecord(s.parentID)?.title ?? "", Money.format(s.num("value")), Money.format(paid), [s.f("loan"), s.f("bank")].filter { !$0.isEmpty }.joined(separator: " "), s.status]
        }
        table("material", ["Material", "Stock", "Re-order"]) { [$0.title, "\(BuildFmt.fmtQty(engine.bStock($0))) \($0.f("unit"))", $0.f("reorder")] }
        table("equipment", ["Machine", "Type", "Ownership", "Status"]) { [$0.title, $0.f("type"), $0.f("own"), $0.status] }
        table("approval", ["Approval", "Authority", "No.", "Status"]) { [$0.title, $0.f("authority"), $0.f("number"), $0.status] }
        table("test", ["Test", "Where", "Result", "Status"]) { [$0.title, $0.f("where"), $0.f("result"), $0.status] }
        table("dispute", ["Dispute", "With", "Forum", "Status"]) { [$0.title, $0.f("against"), $0.f("forum"), $0.status] }
        table("party", ["Name", "Role", "Phone"]) { BuildKinds.money.contains($0.f("role")) ? [$0.title, $0.f("role"), ""] : [$0.title, $0.f("role"), $0.f("phone")] }
        return h
    }

    @MainActor static func charts(_ recs: [BuildRecord]) -> [PDFChart] {
        let units = recs.filter { $0.kind == "unit" }
        let statuses = BuildKinds.unitStatuses.filter { s in units.contains { $0.status == s } }
        var out = [PDFChart(kind: .pie, title: "Units by status", labels: statuses, values: statuses.map { s in Double(units.filter { $0.status == s }.count) })]
        let approvals = recs.filter { $0.kind == "approval" }
        let aStat = BuildKinds.approval.statuses.filter { s in approvals.contains { $0.status == s } }
        if !aStat.isEmpty { out.append(PDFChart(kind: .bar, title: "Approvals", labels: aStat, values: aStat.map { s in Double(approvals.filter { $0.status == s }.count) })) }
        return out
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
