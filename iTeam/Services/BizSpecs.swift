import Foundation
import SwiftUI

/// Field slots every business record has. Each module decides what they mean.
enum BizKey: String { case title, subtitle, phone, amount, date, due, status, notes }

struct BizField {
    let key: BizKey
    let label: String
    var options: [String] = []
}

/// A kind of record inside a module (customer, payment, student, attendance…).
struct BizKind {
    let id: String
    let label: String
    let plural: String
    let icon: String
    let fields: [BizField]
    var statuses: [String] = []
    /// Statuses that mean "finished" (no reminder, not owed).
    var doneStatuses: [String] = []
    /// A person or thing that can be linked to an iTeam contact (they then see their own records).
    var linkable = false
    /// +1 adds to what the client owes, -1 reduces it, 0 = not money.
    var sign: Double = 0
    /// Only counts while in this status (e.g. a fee counts while "Due").
    var countWhen: String? = nil
}

struct BizSpec {
    let module: String
    let tab: Router.TabID
    let title: String
    let icon: String
    let colors: [UInt32]
    /// Top-level kind (customers, students…); nil = a flat list (Bills).
    let parent: BizKind?
    let children: [BizKind]
    let balanceLabel: String
    let clientWord: String
    var paid = true

    func kind(_ id: String) -> BizKind? { parent?.id == id ? parent : children.first { $0.id == id } }
    var flat: BizKind? { parent == nil ? children.first : nil }
}

enum BizSpecs {
    static let khata = BizSpec(
        module: "khata", tab: .khata, title: "Shop & Khata", icon: "indianrupeesign.circle.fill", colors: [0xF7971E, 0xFFD200],
        parent: BizKind(id: "customer", label: "Customer", plural: "Customers", icon: "person.crop.circle",
                        fields: [.init(key: .title, label: "Name"), .init(key: .phone, label: "Phone"), .init(key: .notes, label: "Notes")],
                        linkable: true),
        children: [
            BizKind(id: "gave", label: "You gave (credit)", plural: "Credit", icon: "arrow.up.circle.fill",
                    fields: [.init(key: .amount, label: "Amount"), .init(key: .date, label: "Date"), .init(key: .notes, label: "Items / note")], sign: 1),
            BizKind(id: "got", label: "You got (payment)", plural: "Payments", icon: "arrow.down.circle.fill",
                    fields: [.init(key: .amount, label: "Amount"), .init(key: .date, label: "Date"), .init(key: .subtitle, label: "Mode", options: ["Cash", "UPI", "Card", "Bank"]), .init(key: .notes, label: "Note")], sign: -1),
        ],
        balanceLabel: "To collect", clientWord: "customer")

    static let tuition = BizSpec(
        module: "tuition", tab: .tuition, title: "Tuition & Classes", icon: "graduationcap.fill", colors: [0x00C9FF, 0x92FE9D],
        parent: BizKind(id: "student", label: "Student", plural: "Students", icon: "person.crop.circle",
                        fields: [.init(key: .title, label: "Student name"), .init(key: .subtitle, label: "Class / batch"), .init(key: .phone, label: "Parent phone"), .init(key: .notes, label: "Notes")],
                        linkable: true),
        children: [
            BizKind(id: "attendance", label: "Attendance", plural: "Attendance", icon: "checkmark.circle",
                    fields: [.init(key: .date, label: "Date"), .init(key: .status, label: "Status")], statuses: ["Present", "Absent", "Late"]),
            BizKind(id: "fee", label: "Fee", plural: "Fees", icon: "indianrupeesign.circle",
                    fields: [.init(key: .title, label: "For (e.g. November)"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due date"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "homework", label: "Homework", plural: "Homework", icon: "book.closed",
                    fields: [.init(key: .title, label: "Homework"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Details")],
                    statuses: ["Assigned", "Done"], doneStatuses: ["Done"]),
            BizKind(id: "progress", label: "Test / progress", plural: "Progress", icon: "chart.line.uptrend.xyaxis",
                    fields: [.init(key: .title, label: "Test / topic"), .init(key: .subtitle, label: "Marks"), .init(key: .date, label: "Date"), .init(key: .notes, label: "Remarks")]),
        ],
        balanceLabel: "Fees due", clientWord: "parent")

    static let rent = BizSpec(
        module: "rent", tab: .rent, title: "Property & Rent", icon: "house.and.flag.fill", colors: [0x8E2DE2, 0x4A00E0],
        parent: BizKind(id: "tenant", label: "Tenant", plural: "Tenants", icon: "person.crop.circle",
                        fields: [.init(key: .title, label: "Tenant name"), .init(key: .subtitle, label: "Property / flat"), .init(key: .amount, label: "Monthly rent"),
                                 .init(key: .due, label: "Next rent due"), .init(key: .phone, label: "Phone"), .init(key: .notes, label: "Deposit, agreement…")],
                        linkable: true),
        children: [
            BizKind(id: "charge", label: "Rent / charge", plural: "Charges", icon: "doc.text",
                    fields: [.init(key: .title, label: "For (e.g. Rent Dec)"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "payment", label: "Payment received", plural: "Payments", icon: "arrow.down.circle.fill",
                    fields: [.init(key: .amount, label: "Amount"), .init(key: .date, label: "Date"), .init(key: .subtitle, label: "Mode", options: ["Cash", "UPI", "Bank", "Cheque"]), .init(key: .notes, label: "Note")]),
            BizKind(id: "issue", label: "Maintenance", plural: "Maintenance", icon: "wrench.and.screwdriver",
                    fields: [.init(key: .title, label: "Problem"), .init(key: .date, label: "Reported"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Details")],
                    statuses: ["Open", "In progress", "Fixed"], doneStatuses: ["Fixed"]),
        ],
        balanceLabel: "Rent due", clientWord: "tenant")

    static let legal = BizSpec(
        module: "legal", tab: .legal, title: "Legal Matters", icon: "building.columns.fill", colors: [0x232526, 0x414345],
        parent: BizKind(id: "case", label: "Matter", plural: "Matters", icon: "folder.fill",
                        fields: [.init(key: .title, label: "Matter / parties"), .init(key: .subtitle, label: "Court & case no."), .init(key: .phone, label: "Client phone"),
                                 .init(key: .status, label: "Stage"), .init(key: .notes, label: "Facts / notes")],
                        statuses: ["Filing", "Pending", "Arguments", "Reserved", "Disposed"], doneStatuses: ["Disposed"], linkable: true),
        children: [
            BizKind(id: "hearing", label: "Hearing", plural: "Hearings", icon: "calendar",
                    fields: [.init(key: .date, label: "Date"), .init(key: .title, label: "Purpose"), .init(key: .status, label: "Status"), .init(key: .notes, label: "What happened / next step")],
                    statuses: ["Upcoming", "Done", "Adjourned"], doneStatuses: ["Done", "Adjourned"]),
            BizKind(id: "update", label: "Client update", plural: "Updates", icon: "text.bubble",
                    fields: [.init(key: .title, label: "Update"), .init(key: .date, label: "Date"), .init(key: .notes, label: "Details")]),
            BizKind(id: "fee", label: "Fee", plural: "Fees", icon: "indianrupeesign.circle",
                    fields: [.init(key: .title, label: "For"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
        ],
        balanceLabel: "Fees due", clientWord: "client")

    static let clinic = BizSpec(
        module: "clinic", tab: .clinic, title: "Clinic Desk", icon: "cross.case.fill", colors: [0x11998E, 0x38EF7D],
        parent: BizKind(id: "patient", label: "Patient", plural: "Patients", icon: "person.crop.circle",
                        fields: [.init(key: .title, label: "Patient name"), .init(key: .subtitle, label: "Age / gender"), .init(key: .phone, label: "Phone"), .init(key: .notes, label: "History, allergies")],
                        linkable: true),
        children: [
            BizKind(id: "appointment", label: "Appointment", plural: "Appointments", icon: "calendar.badge.clock",
                    fields: [.init(key: .date, label: "Date & time"), .init(key: .title, label: "Reason"), .init(key: .status, label: "Status")],
                    statuses: ["Booked", "Arrived", "Done", "Missed", "Cancelled"], doneStatuses: ["Done", "Missed", "Cancelled"]),
            BizKind(id: "visit", label: "Visit note", plural: "Visit notes", icon: "note.text",
                    fields: [.init(key: .date, label: "Date"), .init(key: .title, label: "Complaint"), .init(key: .notes, label: "Findings & advice")]),
            BizKind(id: "bill", label: "Bill", plural: "Bills", icon: "indianrupeesign.circle",
                    fields: [.init(key: .title, label: "For"), .init(key: .amount, label: "Amount"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
        ],
        balanceLabel: "Bills due", clientWord: "patient")

    static let bills = BizSpec(
        module: "bills", tab: .bills, title: "Bills & Renewals", icon: "calendar.badge.exclamationmark", colors: [0xFF512F, 0xDD2476],
        parent: nil,
        children: [
            BizKind(id: "bill", label: "Bill / renewal", plural: "Bills", icon: "doc.text",
                    fields: [.init(key: .title, label: "What (electricity, insurance, PUC…)"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due date"),
                             .init(key: .subtitle, label: "Repeats", options: ["Once", "Monthly", "Every 3 months", "Yearly"]), .init(key: .status, label: "Status"), .init(key: .notes, label: "Account no., notes")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
        ],
        balanceLabel: "Due", clientWord: "", paid: false)

    static let all: [BizSpec] = [khata, tuition, rent, legal, clinic, bills]
    static func spec(_ module: String) -> BizSpec? { all.first { $0.module == module } }

    static func money(_ v: Double) -> String { "₹" + (v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v)) }

    /// The change-log line written into the chat.
    static func logLine(_ p: BizPayload, who: String, isNew: Bool) -> String {
        let kind = spec(p.module)?.kind(p.kind)
        let what = kind?.label ?? p.kind
        var detail = [p.title, p.amount != 0 ? money(p.amount) : "", p.status].filter { !$0.isEmpty }.joined(separator: " · ")
        if let d = p.date ?? p.due { detail += (detail.isEmpty ? "" : " · ") + d.formatted(date: .abbreviated, time: .omitted) }
        let verb = p.deleted ? "deleted" : isNew ? "added" : "updated"
        return "📒 \(who) \(verb) \(what.lowercased())\(detail.isEmpty ? "" : " — " + detail)"
    }
}
