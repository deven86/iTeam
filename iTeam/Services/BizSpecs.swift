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
    /// The linked client/parent/tenant can add this kind (a question, a complaint).
    var clientCanAdd = false
    /// The linked client answers this kind by changing its status (approval, e-vakalatnama, homework done).
    var clientAnswers = false
    /// Extra text fields kept in `extra` (label = key).
    var extras: [String] = []
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
                    statuses: ["Assigned", "Done"], doneStatuses: ["Done"], clientAnswers: true),
            BizKind(id: "progress", label: "Test / progress", plural: "Progress", icon: "chart.line.uptrend.xyaxis",
                    fields: [.init(key: .title, label: "Test / topic"), .init(key: .subtitle, label: "Marks"), .init(key: .date, label: "Date"), .init(key: .notes, label: "Remarks")]),
        ],
        balanceLabel: "Fees due", clientWord: "parent")

    static let rent = BizSpec(
        module: "rent", tab: .rent, title: "Property & Rent", icon: "house.and.flag.fill", colors: [0x8E2DE2, 0x4A00E0],
        parent: BizKind(id: "tenant", label: "Tenant", plural: "Tenants", icon: "person.crop.circle",
                        fields: [.init(key: .title, label: "Tenant name"), .init(key: .subtitle, label: "Property / flat"), .init(key: .amount, label: "Monthly rent"),
                                 .init(key: .due, label: "Next rent due"), .init(key: .date, label: "Agreement start"), .init(key: .phone, label: "Phone"),
                                 .init(key: .notes, label: "Deposit, agreement…")],
                        linkable: true, extras: ["Yearly raise %"]),
        children: [
            BizKind(id: "charge", label: "Rent / charge", plural: "Charges", icon: "doc.text",
                    fields: [.init(key: .title, label: "For (e.g. Rent Dec)"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "payment", label: "Payment received", plural: "Payments", icon: "arrow.down.circle.fill",
                    fields: [.init(key: .amount, label: "Amount"), .init(key: .date, label: "Date"), .init(key: .subtitle, label: "Mode", options: ["Cash", "UPI", "Bank", "Cheque"]), .init(key: .notes, label: "Note")]),
            BizKind(id: "issue", label: "Maintenance / damage / complaint", plural: "Maintenance, damage & complaints", icon: "wrench.and.screwdriver",
                    fields: [.init(key: .title, label: "Problem"), .init(key: .subtitle, label: "Type", options: ["Maintenance", "Damage", "Complaint"]),
                             .init(key: .date, label: "Reported"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Details")],
                    statuses: ["Open", "In progress", "Fixed"], doneStatuses: ["Fixed"], clientCanAdd: true),
            BizKind(id: "agreement", label: "Agreement / document", plural: "Agreements & documents", icon: "doc.text.magnifyingglass",
                    fields: [.init(key: .title, label: "Document"), .init(key: .date, label: "Date"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Notes")],
                    statuses: ["Waiting for tenant", "Accepted", "Declined"], doneStatuses: ["Accepted"], clientAnswers: true),
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
            BizKind(id: "question", label: "Client question", plural: "Client questions", icon: "questionmark.bubble",
                    fields: [.init(key: .title, label: "Question"), .init(key: .date, label: "Asked"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Answer")],
                    statuses: ["Open", "Answered"], doneStatuses: ["Answered"], clientCanAdd: true),
            BizKind(id: "approval", label: "Client approval", plural: "Approvals from client", icon: "checkmark.seal",
                    fields: [.init(key: .title, label: "What needs the client's OK"), .init(key: .date, label: "Asked"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Details")],
                    statuses: ["Waiting for client", "Approved", "Rejected"], doneStatuses: ["Approved", "Rejected"], clientAnswers: true),
            BizKind(id: "vakalat", label: "e-Vakalatnama", plural: "e-Vakalatnama", icon: "signature",
                    fields: [.init(key: .title, label: "Court & matter"), .init(key: .date, label: "Requested"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Advocate(s) / terms")],
                    statuses: ["Waiting for client", "Signed", "Declined"], doneStatuses: ["Signed", "Declined"], clientAnswers: true),
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

    static let kids = BizSpec(
        module: "kids", tab: .kids, title: "Kids", icon: "figure.and.child.holdinghands", colors: [0xFDC830, 0xF37335],
        parent: BizKind(id: "child", label: "Child", plural: "Children", icon: "face.smiling",
                        fields: [.init(key: .title, label: "Name"), .init(key: .subtitle, label: "School & class"), .init(key: .phone, label: "School / teacher phone"),
                                 .init(key: .notes, label: "Allergies, blood group, notes")],
                        linkable: true),
        children: [
            BizKind(id: "vaccine", label: "Vaccination", plural: "Vaccinations", icon: "syringe",
                    fields: [.init(key: .title, label: "Vaccine"), .init(key: .due, label: "Due date"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Doctor / notes")],
                    statuses: ["Due", "Done"], doneStatuses: ["Done"]),
            BizKind(id: "event", label: "School event", plural: "School events", icon: "calendar",
                    fields: [.init(key: .title, label: "What (PTM, exam, trip…)"), .init(key: .date, label: "Date & time"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Notes")],
                    statuses: ["Upcoming", "Done"], doneStatuses: ["Done"]),
            BizKind(id: "fee", label: "School fee", plural: "Fees", icon: "indianrupeesign.circle",
                    fields: [.init(key: .title, label: "For"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "timetable", label: "Timetable / class", plural: "Timetable", icon: "clock",
                    fields: [.init(key: .title, label: "Class / activity"), .init(key: .subtitle, label: "Day", options: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]),
                             .init(key: .notes, label: "Time, teacher, place")]),
        ],
        balanceLabel: "Fees due", clientWord: "family member", paid: false)

    static let travel = BizSpec(
        module: "travel", tab: .travel, title: "Travel Planner", icon: "airplane.departure", colors: [0x2193B0, 0x6DD5ED],
        parent: BizKind(id: "trip", label: "Trip", plural: "Trips", icon: "suitcase.rolling.fill",
                        fields: [.init(key: .title, label: "Destination / trip name"), .init(key: .date, label: "Start"), .init(key: .due, label: "End"),
                                 .init(key: .subtitle, label: "Who's going"), .init(key: .amount, label: "Budget"), .init(key: .notes, label: "Notes")],
                        linkable: true),
        children: [
            BizKind(id: "day", label: "Day plan", plural: "Itinerary", icon: "map",
                    fields: [.init(key: .date, label: "Day"), .init(key: .title, label: "Plan (places, activities)"), .init(key: .notes, label: "Details, timings")]),
            BizKind(id: "booking", label: "Booking", plural: "Bookings", icon: "ticket",
                    fields: [.init(key: .subtitle, label: "Type", options: ["Flight", "Train", "Bus", "Hotel", "Cab", "Activity", "Other"]),
                             .init(key: .title, label: "Details (PNR, hotel name…)"), .init(key: .date, label: "Date & time"),
                             .init(key: .phone, label: "Confirmation / PNR no."), .init(key: .amount, label: "Cost"), .init(key: .notes, label: "Notes")], sign: 1),
            BizKind(id: "packing", label: "Packing item", plural: "Packing list", icon: "checklist",
                    fields: [.init(key: .title, label: "Item"), .init(key: .subtitle, label: "Who packs it"), .init(key: .status, label: "Status")],
                    statuses: ["To pack", "Packed"], doneStatuses: ["Packed"]),
            BizKind(id: "expense", label: "Expense", plural: "Expenses", icon: "indianrupeesign.circle",
                    fields: [.init(key: .title, label: "For"), .init(key: .amount, label: "Amount"), .init(key: .subtitle, label: "Paid by"), .init(key: .date, label: "Date")], sign: 1),
        ],
        balanceLabel: "Spent", clientWord: "travel group", paid: false)

    static let all: [BizSpec] = [khata, tuition, rent, legal, clinic, bills, kids, travel]
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
