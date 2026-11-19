import SwiftUI
import SwiftData
import UIKit

/// Everything in iTeam can leave the app three ways: Copy, the share sheet, or a PDF.
/// PDFs are made on the device from simple HTML (multi-page, A4) — nothing is uploaded.
enum PDFMaker {
    static func make(title: String, bodyHTML: String, fileName: String) -> URL? {
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
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)   // A4 in points
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 40, dy: 48), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for i in 0..<max(renderer.numberOfPages, 1) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe(fileName) + ".pdf")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
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
                if let url = PDFMaker.make(title: title, bodyHTML: body, fileName: title) { items = ShareItems(items: [url]) }
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
