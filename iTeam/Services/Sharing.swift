import SwiftUI
import SwiftData
import UIKit

/// Everything in iTeam can leave the app three ways: Copy, the share sheet, or a PDF.
/// PDFs are made on the device from simple HTML (multi-page, A4) — nothing is uploaded.
/// A chart drawn on the PDF's first page: pie (shares), bar (volume per item) or line (trend over time).
struct PDFChart {
    enum Kind { case pie, bar, line }
    var kind: Kind
    var title: String
    var labels: [String]
    var values: [Double]
    /// Optional colour per slice / bar.
    var colors: [UInt32]? = nil
    var unit: String = ""
}

enum PDFMaker {
    static let palette: [UInt32] = [0x5B8DEF, 0xF0567A, 0x34C759, 0xFF9500, 0xAF52DE, 0x30B0C7, 0xFFCC00, 0xFF3B30, 0x8E8E93, 0x5856D6]

    /// `module` and `icon`/`colors` brand every page: iTeam logo on the left, the module's icon and name on the right.
    @MainActor static func make(title: String, bodyHTML: String, fileName: String, module: String = "", icon: String = "doc.richtext",
                     colors: [UInt32] = [0xF0567A, 0x7B3FE4], charts: [PDFChart] = []) -> URL? {
        let html = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica; font-size: 11pt; color: #111; }
        h1 { font-size: 18pt; margin: 0 0 4pt 0; } h2 { font-size: 13pt; margin: 14pt 0 4pt 0; }
        .muted { color: #666; font-size: 9pt; } .msg { margin: 0 0 6pt 0; } .who { font-weight: 600; }
        table { border-collapse: collapse; width: 100%; } td, th { border-bottom: 0.5pt solid #ccc; padding: 3pt; text-align: left; font-size: 10pt; }
        </style></head><body>
        <h1>\(esc(title))</h1>
        <div class="muted">Exported from iTeam · \(esc(Date.now.formatted(date: .long, time: .shortened)))</div>
        \(bodyHTML)
        </body></html>
        """
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)   // A4 in points
        let chartPages = charts.isEmpty ? 0 : (charts.count + 1) / 2
        let renderer = BrandedRenderer(module: module, icon: icon, colors: colors, offset: chartPages, logo: logo)
        renderer.addPrintFormatter(UIMarkupTextPrintFormatter(markupText: html), startingAtPageAt: 0)
        renderer.headerHeight = 46
        renderer.footerHeight = 26
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 40, dy: 30), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        let total = max(renderer.numberOfPages, 1) + chartPages
        renderer.total = total
        // Charts first: two per page, under the same branded header.
        for p in 0..<chartPages {
            UIGraphicsBeginPDFPage()
            renderer.drawHeader(pageNumber: p, in: page)
            renderer.drawFooter(pageNumber: p, in: page)
            if p == 0 { drawText(title, at: CGPoint(x: 40, y: 82), font: .boldSystemFont(ofSize: 18), color: .black) }
            for (i, c) in charts.dropFirst(p * 2).prefix(2).enumerated() {
                let box = CGRect(x: 40, y: 120 + CGFloat(i) * 345, width: page.width - 80, height: 320)
                drawChart(c, in: box)
            }
        }
        for i in 0..<max(renderer.numberOfPages, 1) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe(fileName) + ".pdf")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    // MARK: Header / footer on every page

    final class BrandedRenderer: UIPrintPageRenderer {
        let module: String, icon: String, colors: [UInt32], offset: Int, logo: UIImage
        var total = 1
        init(module: String, icon: String, colors: [UInt32], offset: Int, logo: UIImage) {
            self.module = module; self.icon = icon; self.colors = colors; self.offset = offset; self.logo = logo
        }

        override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
            drawHeader(pageNumber: pageIndex + offset, in: paperRect)
        }
        override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
            drawFooter(pageNumber: pageIndex + offset, in: paperRect)
        }

        func drawHeader(pageNumber: Int, in page: CGRect) {
            let y: CGFloat = 22
            logo.draw(in: CGRect(x: 40, y: y, width: 30, height: 30))
            PDFMaker.drawText("iTeam", at: CGPoint(x: 76, y: y + 2), font: .boldSystemFont(ofSize: 15), color: .black)
            PDFMaker.drawText("Chat · Tasks · Modules", at: CGPoint(x: 76, y: y + 19), font: .systemFont(ofSize: 7.5), color: .gray)
            if !module.isEmpty {
                let font = UIFont.boldSystemFont(ofSize: 12)
                let w = (module as NSString).size(withAttributes: [.font: font]).width
                let tile = CGRect(x: page.width - 40 - 26, y: y + 2, width: 26, height: 26)
                PDFMaker.drawTile(icon: icon, colors: colors, in: tile)
                PDFMaker.drawText(module, at: CGPoint(x: tile.minX - 8 - w, y: y + 8), font: font, color: UIColor(hexValue: colors.first ?? 0x333333))
            }
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 40, y: y + 36)); line.addLine(to: CGPoint(x: page.width - 40, y: y + 36))
            UIColor(white: 0.85, alpha: 1).setStroke(); line.lineWidth = 0.5; line.stroke()
        }

        func drawFooter(pageNumber: Int, in page: CGRect) {
            let text = "Made with iTeam\(module.isEmpty ? "" : " · " + module) · Page \(pageNumber + 1) of \(max(total, pageNumber + 1))"
            PDFMaker.drawText(text, at: CGPoint(x: 40, y: page.height - 26), font: .systemFont(ofSize: 7.5), color: .gray)
        }
    }

    // MARK: Drawing helpers

    /// The iT glass logo, rendered once.
    @MainActor static let logo: UIImage = {
        let r = ImageRenderer(content: AppLogo(size: 120))
        r.scale = 2
        return r.uiImage ?? UIImage()
    }()

    static func drawText(_ s: String, at p: CGPoint, font: UIFont, color: UIColor, width: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let width { (s as NSString).draw(in: CGRect(x: p.x, y: p.y, width: width, height: font.lineHeight * 2), withAttributes: attrs) }
        else { (s as NSString).draw(at: p, withAttributes: attrs) }
    }

    static func drawTile(icon: String, colors: [UInt32], in r: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        UIBezierPath(roundedRect: r, cornerRadius: r.width * 0.26).addClip()
        let cs = colors.count > 1 ? colors : colors + colors + [0x333333]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cs.prefix(2).map { UIColor(hexValue: $0).cgColor } as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        }
        ctx.restoreGState()
        let cfg = UIImage.SymbolConfiguration(pointSize: r.width * 0.5, weight: .semibold)
        if let img = UIImage(systemName: icon, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let s = img.size
            img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    static func color(_ c: PDFChart, _ i: Int) -> UIColor {
        UIColor(hexValue: c.colors?[safe: i] ?? palette[i % palette.count])
    }

    static func drawChart(_ c: PDFChart, in box: CGRect) {
        UIColor(white: 0.97, alpha: 1).setFill(); UIBezierPath(roundedRect: box, cornerRadius: 10).fill()
        drawText(c.title, at: CGPoint(x: box.minX + 14, y: box.minY + 10), font: .boldSystemFont(ofSize: 12), color: .black)
        let area = CGRect(x: box.minX + 14, y: box.minY + 34, width: box.width - 28, height: box.height - 46)
        let total = c.values.reduce(0, +)
        guard !c.values.isEmpty, c.values.contains(where: { $0 != 0 }) else {
            drawText("No data yet", at: CGPoint(x: area.midX - 30, y: area.midY), font: .systemFont(ofSize: 11), color: .gray); return
        }
        switch c.kind {
        case .pie:
            let d = min(area.height, area.width * 0.5)
            let center = CGPoint(x: area.minX + d / 2 + 6, y: area.midY)
            var a = -CGFloat.pi / 2
            for (i, v) in c.values.enumerated() where v > 0 {
                let end = a + CGFloat(v / total) * 2 * .pi
                let path = UIBezierPath()
                path.move(to: center); path.addArc(withCenter: center, radius: d / 2, startAngle: a, endAngle: end, clockwise: true); path.close()
                color(c, i).setFill(); path.fill()
                UIColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
                a = end
            }
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - d * 0.22, y: center.y - d * 0.22, width: d * 0.44, height: d * 0.44)).fill()
            let tot = total.formatted(.number.precision(.fractionLength(0...1)))
            drawText(tot, at: CGPoint(x: center.x - CGFloat(tot.count) * 4, y: center.y - 8), font: .boldSystemFont(ofSize: 13), color: .black)
            // Legend
            var y = area.minY + 4
            let lx = area.minX + d + 30
            for (i, v) in c.values.enumerated() where v > 0 {
                guard y < area.maxY - 12 else { break }
                color(c, i).setFill(); UIBezierPath(roundedRect: CGRect(x: lx, y: y + 2, width: 10, height: 10), cornerRadius: 2).fill()
                let pct = Int((v / total * 100).rounded())
                drawText("\(c.labels[safe: i] ?? "") — \(v.formatted(.number.precision(.fractionLength(0...1))))\(c.unit) (\(pct)%)",
                         at: CGPoint(x: lx + 16, y: y), font: .systemFont(ofSize: 9.5), color: .darkGray, width: area.maxX - lx - 16)
                y += 17
            }
        case .bar:
            let maxV = max(c.values.max() ?? 1, 1)
            let n = CGFloat(c.values.count)
            let slot = area.width / n
            let barW = min(slot * 0.62, 46)
            let base = area.maxY - 26
            for (i, v) in c.values.enumerated() {
                let h = CGFloat(v / maxV) * (base - area.minY - 14)
                let x = area.minX + CGFloat(i) * slot + (slot - barW) / 2
                color(c, i).setFill()
                UIBezierPath(roundedRect: CGRect(x: x, y: base - h, width: barW, height: max(h, 1)), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 4, height: 4)).fill()
                let vs = v.formatted(.number.precision(.fractionLength(0...1)))
                drawText(vs, at: CGPoint(x: x, y: base - h - 12), font: .systemFont(ofSize: 7.5), color: .darkGray)
                drawText(String((c.labels[safe: i] ?? "").prefix(n > 12 ? 3 : 10)), at: CGPoint(x: x - 4, y: base + 4), font: .systemFont(ofSize: n > 12 ? 6.5 : 8), color: .darkGray)
            }
            UIColor(white: 0.75, alpha: 1).setStroke()
            let axis = UIBezierPath(); axis.move(to: CGPoint(x: area.minX, y: base)); axis.addLine(to: CGPoint(x: area.maxX, y: base)); axis.stroke()
        case .line:
            let maxV = max(c.values.max() ?? 1, 1), minV = min(c.values.min() ?? 0, 0)
            let base = area.maxY - 22
            let top = area.minY + 10
            let step = c.values.count > 1 ? area.width / CGFloat(c.values.count - 1) : 0
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: area.minX + CGFloat(i) * step, y: base - CGFloat((c.values[i] - minV) / max(maxV - minV, 1)) * (base - top))
            }
            for g in 0...3 {   // grid
                let gy = base - CGFloat(g) / 3 * (base - top)
                let p = UIBezierPath(); p.move(to: CGPoint(x: area.minX, y: gy)); p.addLine(to: CGPoint(x: area.maxX, y: gy))
                UIColor(white: 0.88, alpha: 1).setStroke(); p.lineWidth = 0.5; p.stroke()
                drawText((minV + (maxV - minV) * Double(g) / 3).formatted(.number.precision(.fractionLength(0))), at: CGPoint(x: area.minX - 2, y: gy - 10), font: .systemFont(ofSize: 6.5), color: .gray)
            }
            let fill = UIBezierPath(); fill.move(to: CGPoint(x: area.minX, y: base))
            let line = UIBezierPath()
            for i in c.values.indices {
                if i == 0 { line.move(to: pt(i)) } else { line.addLine(to: pt(i)) }
                fill.addLine(to: pt(i))
            }
            fill.addLine(to: CGPoint(x: area.minX + CGFloat(max(c.values.count - 1, 0)) * step, y: base)); fill.close()
            color(c, 0).withAlphaComponent(0.15).setFill(); fill.fill()
            color(c, 0).setStroke(); line.lineWidth = 2; line.lineJoinStyle = .round; line.stroke()
            let every = max(1, c.values.count / 8)
            for i in c.values.indices where i % every == 0 || i == c.values.count - 1 {
                color(c, 0).setFill(); UIBezierPath(ovalIn: CGRect(x: pt(i).x - 2.5, y: pt(i).y - 2.5, width: 5, height: 5)).fill()
                drawText(c.labels[safe: i] ?? "", at: CGPoint(x: pt(i).x - 8, y: base + 5), font: .systemFont(ofSize: 7), color: .darkGray)
            }
        }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
    }

    static func safe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces).isEmpty ? "iTeam" : String(cleaned.prefix(60))
    }

    /// Plain text → simple paragraphs.
    static func paragraphs(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { "<p>\(esc($0))</p>" }.joined()
    }
}

/// The system share sheet (AirDrop, WhatsApp, Mail, Files, Print, Copy…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

extension View {
    /// Presents the share sheet when `items` is set.
    func shareSheet(_ items: Binding<ShareItems?>) -> some View {
        sheet(item: items) { s in ShareSheet(items: s.items).presentationDetents([.medium, .large]) }
    }
}

/// A “Share” menu for anything that has a text form: Copy · Share text · Share as PDF.
struct ShareMenu: View {
    let title: String
    let text: () -> String
    var html: (() -> String)? = nil
    var label: String = "Share"
    var module: String = ""
    var icon: String = "doc.richtext"
    var colors: [UInt32] = [0xF0567A, 0x7B3FE4]
    var charts: (() -> [PDFChart])? = nil
    @State private var items: ShareItems?

    var body: some View {
        Menu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text()
                Haptics.success()
            }
            Button("Share text…", systemImage: "square.and.arrow.up") { items = ShareItems(items: [text()]) }
            Button("Share as PDF…", systemImage: "doc.richtext") {
                let body = html?() ?? PDFMaker.paragraphs(text())
                if let url = PDFMaker.make(title: title, bodyHTML: body, fileName: title, module: module, icon: icon, colors: colors, charts: charts?() ?? []) { items = ShareItems(items: [url]) }
            }
        } label: {
            Label(label, systemImage: "square.and.arrow.up")
        }
        .shareSheet($items)
    }
}

/// Text and PDF forms of iTeam things.
@MainActor
enum ShareText {
    static func message(_ m: Message, engine: SyncEngine) -> String {
        var parts: [String] = []
        if !m.text.isEmpty { parts.append(m.text) }
        for a in m.attachments { parts.append("📎 \(a.name)") }
        return parts.joined(separator: "\n")
    }

    static func chatHTML(_ conv: Conversation, _ messages: [Message], engine: SyncEngine) -> String {
        var html = ""
        var day: Date?
        for m in messages where !m.deleted {
            if day == nil || !Calendar.current.isDate(day!, inSameDayAs: m.createdAt) {
                day = m.createdAt
                html += "<h2>\(PDFMaker.esc(m.createdAt.formatted(date: .complete, time: .omitted)))</h2>"
            }
            let who = m.isSystem ? "" : "<span class=\"who\">\(PDFMaker.esc(engine.name(of: m.senderID)))</span> "
            let time = "<span class=\"muted\">\(m.createdAt.formatted(date: .omitted, time: .shortened))</span>"
            html += "<div class=\"msg\">\(time) \(who)\(PDFMaker.esc(m.preview))</div>"
        }
        return html
    }

    static func chatText(_ conv: Conversation, _ messages: [Message], engine: SyncEngine) -> String {
        messages.filter { !$0.deleted }.map { m in
            "[\(m.createdAt.formatted(date: .abbreviated, time: .shortened))] \(m.isSystem ? "" : engine.name(of: m.senderID) + ": ")\(m.preview)"
        }.joined(separator: "\n")
    }
}

extension ShareText {
    static func expenses(of t: TaskItem, engine: SyncEngine) -> [Expense] {
        let id = t.id
        return (try? engine.context?.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.taskID == id && !$0.deleted },
                                                                     sortBy: [SortDescriptor(\.date)]))) ?? []
    }

    static func task(_ t: TaskItem, checklist: [ChecklistItem], comments: [TaskComment], engine: SyncEngine) -> String {
        var lines = ["✅ \(t.title)", "Status: \(t.status.title) · Priority: \(t.priority.title)"]
        if let due = t.dueAt { lines.append("Due: \(due.formatted(date: .abbreviated, time: .shortened))") }
        if !t.assignees.isEmpty { lines.append("Assigned: " + t.assignees.map { engine.name(of: $0) }.joined(separator: ", ")) }
        if !t.notes.isEmpty { lines.append("\n\(t.notes)") }
        if !checklist.isEmpty {
            lines.append("\nChecklist:")
            lines += checklist.map { "\($0.done ? "☑︎" : "☐") \($0.title)" }
        }
        let ex = expenses(of: t, engine: engine)
        if !ex.isEmpty {
            lines.append("\nExpenses (total \(Money.format(ex.reduce(0) { $0 + $1.amount }))):")
            lines += ex.map { "• \($0.title) — \(Money.format($0.amount)) · \($0.date.formatted(date: .abbreviated, time: .omitted))" }
        }
        if !comments.isEmpty {
            lines.append("\nComments:")
            lines += comments.map { "\(engine.name(of: $0.authorID)): \($0.body)" }
        }
        return lines.joined(separator: "\n")
    }

    static func taskHTML(_ t: TaskItem, checklist: [ChecklistItem], comments: [TaskComment], engine: SyncEngine) -> String {
        let e = PDFMaker.esc
        var h = "<p><b>Status:</b> \(e(t.status.title)) · <b>Priority:</b> \(e(t.priority.title))"
        if let due = t.dueAt { h += " · <b>Due:</b> \(e(due.formatted(date: .abbreviated, time: .shortened)))" }
        h += "</p>"
        if !t.assignees.isEmpty { h += "<p><b>Assigned:</b> \(e(t.assignees.map { engine.name(of: $0) }.joined(separator: ", ")))</p>" }
        if !t.notes.isEmpty { h += "<h2>Notes</h2><p>\(e(t.notes))</p>" }
        if !checklist.isEmpty {
            h += "<h2>Checklist</h2>" + checklist.map { "<div>\($0.done ? "☑︎" : "☐") \(e($0.title))</div>" }.joined()
        }
        let ex = expenses(of: t, engine: engine)
        if !ex.isEmpty {
            h += "<h2>Expenses</h2><table><tr><th>Date</th><th>Item</th><th>Category</th><th>Paid by</th><th>Amount</th></tr>"
            h += ex.map { "<tr><td>\(e($0.date.formatted(date: .abbreviated, time: .omitted)))</td><td>\(e($0.title))</td><td>\(e($0.category))</td><td>\(e(engine.name(of: $0.paidBy)))</td><td>\(e(Money.format($0.amount)))</td></tr>" }.joined()
            h += "<tr><th colspan=4>Total</th><th>\(e(Money.format(ex.reduce(0) { $0 + $1.amount })))</th></tr></table>"
        }
        if !comments.isEmpty {
            h += "<h2>Comments</h2>" + comments.map { "<div class=\"msg\"><span class=\"who\">\(e(engine.name(of: $0.authorID)))</span> \(e($0.body))</div>" }.joined()
        }
        return h
    }
}

extension ShareText {
    private static func clock(_ minutes: Int) -> String {
        let d = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        return d.formatted(date: .omitted, time: .shortened)
    }

    /// A one-page health summary for a doctor or hospital.
    static func care(_ p: CareProfile, meds: [Medicine], events: [HealthEvent]) -> String {
        var l = ["🩺 \(p.name)\(p.relation.isEmpty ? "" : " (\(p.relation))")"]
        if !p.bloodGroup.isEmpty { l.append("Blood group: \(p.bloodGroup)") }
        if !p.allergies.isEmpty { l.append("Allergies: \(p.allergies)") }
        if !p.conditions.isEmpty { l.append("Conditions: \(p.conditions)") }
        if !p.emergencyContact.isEmpty { l.append("Emergency contact: \(p.emergencyContact)") }
        let active = meds.filter { $0.active && !$0.deleted }
        if !active.isEmpty {
            l.append("\nMedicines:")
            l += active.map { "• \($0.name) \($0.dose) — \($0.times.map(clock).joined(separator: ", "))\($0.instructions.isEmpty ? "" : " · \($0.instructions)")" }
        }
        let ev = events.filter { !$0.deleted }
        if !ev.isEmpty {
            l.append("\nHealth events:")
            l += ev.map { "• \($0.date.formatted(date: .abbreviated, time: .omitted)) \($0.title) — \($0.status), \($0.recovery)% recovered" }
        }
        if !p.notes.isEmpty { l.append("\nNotes: \(p.notes)") }
        return l.joined(separator: "\n")
    }

    static func careHTML(_ p: CareProfile, meds: [Medicine], events: [HealthEvent]) -> String {
        let e = PDFMaker.esc
        var h = "<table>"
        for (k, v) in [("Relation", p.relation), ("Blood group", p.bloodGroup), ("Allergies", p.allergies),
                       ("Conditions", p.conditions), ("Emergency contact", p.emergencyContact)] where !v.isEmpty {
            h += "<tr><th>\(k)</th><td>\(e(v))</td></tr>"
        }
        h += "</table>"
        let active = meds.filter { $0.active && !$0.deleted }
        if !active.isEmpty {
            h += "<h2>Current medicines</h2><table><tr><th>Medicine</th><th>Dose</th><th>Times</th><th>Instructions</th></tr>"
            h += active.map { "<tr><td>\(e($0.name))</td><td>\(e($0.dose))</td><td>\(e($0.times.map(clock).joined(separator: ", ")))</td><td>\(e($0.instructions))</td></tr>" }.joined()
            h += "</table>"
        }
        let ev = events.filter { !$0.deleted }
        if !ev.isEmpty {
            h += "<h2>Health events</h2><table><tr><th>Date</th><th>Event</th><th>Status</th><th>Recovery</th></tr>"
            h += ev.map { "<tr><td>\(e($0.date.formatted(date: .abbreviated, time: .omitted)))</td><td>\(e($0.title))<br><span class=muted>\(e($0.details))</span></td><td>\(e($0.status))</td><td>\($0.recovery)%</td></tr>" }.joined()
            h += "</table>"
        }
        if !p.notes.isEmpty { h += "<h2>Notes</h2><p>\(e(p.notes))</p>" }
        return h
    }
}

/// Forward messages to one or more chats, like WhatsApp. Files are re-sent by reference:
/// the encrypted file in iCloud is reused, so nothing is uploaded again.
struct ForwardSheet: View {
    let messages: [Message]
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Conversation> { !$0.left }, sort: \Conversation.lastActivity, order: .reverse)
    private var convs: [Conversation]
    @State private var picked: Set<String> = []
    @State private var search = ""

    private var shown: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? convs : convs.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section {
                ForEach(messages) { m in
                    Text(m.preview).font(.subheadline).lineLimit(3).foregroundStyle(look.textSecondary)
                }
            } header: { Text("Forwarding") }
            .lookRows()
            Section("Send to") {
                ForEach(shown) { c in
                    Button {
                        if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: c.title, imageData: c.isGroup ? c.avatar : c.peerID.flatMap { engine.contact($0)?.avatar },
                                       size: 36, isGroup: c.isGroup)
                            Text(c.title).foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(c.id) ? look.accent : look.textSecondary)
                        }
                    }
                }
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search)
        .lookScreen()
        .navigationTitle("Forward")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send\(picked.isEmpty ? "" : " (\(picked.count))")") { send() }.disabled(picked.isEmpty)
            }
        }
    }

    private func send() {
        for c in convs where picked.contains(c.id) {
            for m in messages where !m.deleted && (!m.text.isEmpty || !m.attachments.isEmpty) {
                engine.sendText(m.text, in: c, attachments: m.attachments, forwarded: true)
            }
        }
        Haptics.success()
        dismiss()
    }
}


extension UIColor {
    convenience init(hexValue h: UInt32) {
        self.init(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
