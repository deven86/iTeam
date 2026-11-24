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
                    statuses: ["Due", "Approving", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
        ],
        balanceLabel: "Due", clientWord: "", paid: false)

    static let kids = BizSpec(
        module: "kids", tab: .kids, title: "Kids", icon: "figure.and.child.holdinghands", colors: [0xFDC830, 0xF37335],
        parent: BizKind(id: "child", label: "Child", plural: "Children", icon: "face.smiling",
                        fields: [.init(key: .title, label: "Name"), .init(key: .date, label: "Birth date"), .init(key: .subtitle, label: "School & class"),
                                 .init(key: .phone, label: "School / teacher phone"), .init(key: .notes, label: "Allergies, blood group, notes")],
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

    static let petcare = BizSpec(
        module: "petcare", tab: .petcare, title: "Pet Care", icon: "pawprint.fill", colors: [0xEA580C, 0xF59E0B],
        parent: BizKind(id: "pet", label: "Pet", plural: "Pets", icon: "pawprint.circle.fill",
                        fields: [.init(key: .title, label: "Pet name"), .init(key: .subtitle, label: "Species", options: ["Dog", "Cat", "Bird", "Rabbit", "Fish", "Other"]),
                                 .init(key: .date, label: "Birth date"), .init(key: .phone, label: "Vet phone"), .init(key: .notes, label: "Notes, allergies, diet")],
                        linkable: true, extras: ["Breed", "Weight (kg)", "Microchip / tag ID"]),
        children: [
            BizKind(id: "vaccine", label: "Vaccination", plural: "Vaccinations", icon: "syringe",
                    fields: [.init(key: .title, label: "Vaccine"), .init(key: .date, label: "Given on"), .init(key: .due, label: "Next booster"),
                             .init(key: .status, label: "Status"), .init(key: .notes, label: "Batch / vet")],
                    statuses: ["Due", "Done"], doneStatuses: ["Done"]),
            BizKind(id: "deworming", label: "Deworming / tick & flea", plural: "Deworming", icon: "pills",
                    fields: [.init(key: .title, label: "Treatment"), .init(key: .date, label: "Given on"), .init(key: .due, label: "Next due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Done"], doneStatuses: ["Done"]),
            BizKind(id: "medication", label: "Medicine", plural: "Medicines", icon: "pills.fill",
                    fields: [.init(key: .title, label: "Medicine"), .init(key: .subtitle, label: "Dose"), .init(key: .date, label: "Daily time"), .init(key: .notes, label: "Instructions")]),
            BizKind(id: "feeding", label: "Feeding", plural: "Feeding", icon: "fork.knife",
                    fields: [.init(key: .title, label: "Meal (e.g. Breakfast)"), .init(key: .subtitle, label: "Food & quantity"), .init(key: .date, label: "Daily time")]),
            BizKind(id: "vet", label: "Vet visit", plural: "Vet visits", icon: "cross.case",
                    fields: [.init(key: .date, label: "Date"), .init(key: .title, label: "Reason"), .init(key: .amount, label: "Cost"), .init(key: .notes, label: "Diagnosis / advice")]),
            BizKind(id: "grooming", label: "Grooming / training", plural: "Grooming & training", icon: "scissors",
                    fields: [.init(key: .date, label: "Date"), .init(key: .title, label: "What"), .init(key: .amount, label: "Cost"), .init(key: .notes, label: "Notes")]),
            BizKind(id: "weight", label: "Weight", plural: "Weight log", icon: "scalemass",
                    fields: [.init(key: .date, label: "Date"), .init(key: .title, label: "Weight (kg)")]),
        ],
        balanceLabel: "Spent", clientWord: "pet parent")

    // MARK: Admissions (schools & colleges)
    static let admissions = BizSpec(
        module: "admissions", tab: .admissions, title: "Admissions", icon: "graduationcap.circle.fill", colors: [0x00B4DB, 0x0083B0],
        parent: BizKind(id: "applicant", label: "Applicant", plural: "Applicants", icon: "person.crop.circle.badge.plus",
                        fields: [.init(key: .title, label: "Student name"), .init(key: .subtitle, label: "Class / course applying for"),
                                 .init(key: .phone, label: "Parent / student phone"), .init(key: .date, label: "Enquiry date"),
                                 .init(key: .status, label: "Stage"), .init(key: .notes, label: "Notes")],
                        statuses: ["Enquiry", "Applied", "Documents pending", "Test / interview", "Selected", "Waitlisted", "Admitted", "Rejected", "Withdrawn"],
                        doneStatuses: ["Admitted", "Rejected", "Withdrawn"], linkable: true,
                        extras: ["Parent / guardian", "Academic year", "Previous school / college", "Marks / %", "Category", "Source (walk-in, website, referral)"]),
        children: [
            BizKind(id: "followup", label: "Follow-up", plural: "Follow-ups", icon: "phone.arrow.up.right",
                    fields: [.init(key: .date, label: "Date & time"), .init(key: .title, label: "Call / visit about"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Outcome")],
                    statuses: ["Planned", "Done", "No answer"], doneStatuses: ["Done", "No answer"]),
            BizKind(id: "test", label: "Entrance test / interview", plural: "Tests & interviews", icon: "pencil.and.list.clipboard",
                    fields: [.init(key: .date, label: "Date & time"), .init(key: .title, label: "Test / interview"), .init(key: .status, label: "Result"), .init(key: .notes, label: "Marks, remarks")],
                    statuses: ["Scheduled", "Passed", "Failed", "Absent"], doneStatuses: ["Passed", "Failed", "Absent"]),
            BizKind(id: "document", label: "Document", plural: "Documents checklist", icon: "doc.badge.ellipsis",
                    fields: [.init(key: .title, label: "Document (LC, marksheet, Aadhaar…)"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Notes")],
                    statuses: ["Pending", "Received", "Verified"], doneStatuses: ["Verified"], clientCanAdd: true),
            BizKind(id: "fee", label: "Admission fee", plural: "Fees", icon: "indianrupeesign.circle",
                    fields: [.init(key: .title, label: "For (form, admission, term 1…)"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "payment", label: "Payment received", plural: "Payments", icon: "arrow.down.circle.fill",
                    fields: [.init(key: .amount, label: "Amount"), .init(key: .date, label: "Date"), .init(key: .subtitle, label: "Mode", options: ["Cash", "UPI", "Bank", "Cheque", "DD"]), .init(key: .notes, label: "Receipt no.")]),
        ],
        balanceLabel: "Fees due", clientWord: "parent")

    // MARK: Vendors, suppliers & contracts
    static let vendors = BizSpec(
        module: "vendors", tab: .vendors, title: "Vendors & Contracts", icon: "shippingbox.and.arrow.backward.fill", colors: [0x614385, 0x516395],
        parent: BizKind(id: "vendor", label: "Vendor", plural: "Vendors", icon: "building.2",
                        fields: [.init(key: .title, label: "Vendor / supplier name"),
                                 .init(key: .subtitle, label: "Type", options: ["Supplier", "AMC / service", "Contractor", "Consultant", "Transporter", "Other"]),
                                 .init(key: .phone, label: "Phone"), .init(key: .notes, label: "Address, bank (last 4 digits), notes")],
                        linkable: true, extras: ["Contact person", "Email", "GSTIN", "PAN", "Rating (1–5)"]),
        children: [
            BizKind(id: "rate", label: "Rate card / quotation", plural: "Rate cards & quotations", icon: "list.bullet.rectangle",
                    fields: [.init(key: .title, label: "Item / service"), .init(key: .amount, label: "Rate"), .init(key: .date, label: "Valid from"), .init(key: .due, label: "Valid till"), .init(key: .notes, label: "Unit, terms")]),
            BizKind(id: "contract", label: "Contract / AMC", plural: "Contracts & AMCs", icon: "doc.text.fill",
                    fields: [.init(key: .title, label: "Contract / AMC"), .init(key: .amount, label: "Value"), .init(key: .date, label: "Start"), .init(key: .due, label: "Expiry / renewal"),
                             .init(key: .subtitle, label: "Renews", options: ["Yearly", "Every 6 months", "Monthly", "Once"]), .init(key: .status, label: "Status"), .init(key: .notes, label: "Scope, rate revision clause")],
                    statuses: ["Active", "Renewal due", "Renewed", "Expired", "Cancelled"], doneStatuses: ["Renewed", "Expired", "Cancelled"]),
            BizKind(id: "wo", label: "Work / purchase order", plural: "Work orders", icon: "doc.plaintext",
                    fields: [.init(key: .title, label: "WO / PO no. & what"), .init(key: .amount, label: "Amount"), .init(key: .date, label: "Issued"), .init(key: .due, label: "Deliver / finish by"), .init(key: .status, label: "Status")],
                    statuses: ["Issued", "In progress", "Delivered", "Cancelled"], doneStatuses: ["Delivered", "Cancelled"]),
            BizKind(id: "challan", label: "Delivery challan", plural: "Delivery challans", icon: "shippingbox",
                    fields: [.init(key: .title, label: "Challan no. & items"), .init(key: .date, label: "Received on"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Short / damaged items")],
                    statuses: ["Received OK", "Short", "Damaged", "Rejected"], doneStatuses: ["Received OK", "Short", "Damaged", "Rejected"]),
            BizKind(id: "bill", label: "Vendor bill", plural: "Bills", icon: "doc.text",
                    fields: [.init(key: .title, label: "Bill no. & for"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Approving", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "payment", label: "Payment made", plural: "Payments", icon: "arrow.up.circle.fill",
                    fields: [.init(key: .amount, label: "Amount"), .init(key: .date, label: "Date"), .init(key: .subtitle, label: "Mode", options: ["UPI", "Bank / RTGS", "Cheque", "Cash"]), .init(key: .notes, label: "UTR / cheque no.")]),
        ],
        balanceLabel: "Payable", clientWord: "vendor")

    // MARK: My Home
    static let home = BizSpec(
        module: "home", tab: .home, title: "My Home", icon: "house.fill", colors: [0xF7971E, 0xFFD200],
        parent: BizKind(id: "house", label: "Home", plural: "Homes", icon: "house",
                        fields: [.init(key: .title, label: "Home (e.g. Dadar flat)"), .init(key: .subtitle, label: "Address"), .init(key: .notes, label: "Notes")],
                        linkable: true),
        children: [
            BizKind(id: "utility", label: "Utility bill", plural: "Electricity, water, gas & internet", icon: "bolt.fill",
                    fields: [.init(key: .subtitle, label: "Type", options: ["Electricity", "Water", "Gas", "Internet", "Mobile", "DTH / OTT", "Property tax", "Other"]),
                             .init(key: .title, label: "Month / account"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "maintenance", label: "Society maintenance", plural: "Society maintenance", icon: "building.2",
                    fields: [.init(key: .title, label: "Month / period"), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "appliance", label: "Appliance & warranty", plural: "Appliances & warranties", icon: "washer",
                    fields: [.init(key: .title, label: "Appliance"), .init(key: .subtitle, label: "Brand / model / serial"), .init(key: .date, label: "Bought on"),
                             .init(key: .due, label: "Warranty / AMC till"), .init(key: .amount, label: "Price"), .init(key: .notes, label: "Service centre, invoice no.")]),
            BizKind(id: "repair", label: "Repair / service", plural: "Repairs & services", icon: "wrench.and.screwdriver",
                    fields: [.init(key: .title, label: "What needs fixing"), .init(key: .subtitle, label: "Type", options: ["Plumbing", "Electrical", "Carpentry", "Appliance", "Painting", "Pest control", "Cleaning", "Other"]),
                             .init(key: .date, label: "Reported / done"), .init(key: .due, label: "Next service"), .init(key: .amount, label: "Cost"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Who fixed it, phone")],
                    statuses: ["Requested", "Scheduled", "Done"], doneStatuses: ["Done"]),
            BizKind(id: "policy", label: "Insurance / property paper", plural: "Insurance & property papers", icon: "doc.text.magnifyingglass",
                    fields: [.init(key: .title, label: "Policy / document"), .init(key: .subtitle, label: "Type", options: ["Home insurance", "Sale deed", "Agreement", "Share certificate", "Tax receipt", "Other"]),
                             .init(key: .amount, label: "Premium / value"), .init(key: .due, label: "Renew by"), .init(key: .notes, label: "Policy no., insurer")]),
        ],
        balanceLabel: "Bills due", clientWord: "family member", paid: false)

    // MARK: Lost & Found
    static let lostfound = BizSpec(
        module: "lostfound", tab: .lostfound, title: "Lost & Found", icon: "magnifyingglass.circle.fill", colors: [0xEB3349, 0xF45C43],
        parent: nil,
        children: [
            BizKind(id: "item", label: "Lost or found item", plural: "Lost & found", icon: "questionmark.diamond",
                    fields: [.init(key: .subtitle, label: "Lost or found?", options: ["Lost", "Found"]), .init(key: .title, label: "What (phone, wallet, pet, document…)"),
                             .init(key: .date, label: "When"), .init(key: .notes, label: "Where & how it looks"), .init(key: .phone, label: "Contact phone"),
                             .init(key: .amount, label: "Reward (optional)"), .init(key: .status, label: "Status")],
                    statuses: ["Searching", "Found / returned", "Closed"], doneStatuses: ["Found / returned", "Closed"]),
        ],
        balanceLabel: "", clientWord: "", paid: false)

    // MARK: Procurement
    static let procurement = BizSpec(
        module: "procurement", tab: .procurement, title: "Procurement", icon: "cart.fill.badge.plus", colors: [0x1D976C, 0x93F9B9],
        parent: BizKind(id: "request", label: "Purchase requisition", plural: "Requisitions", icon: "doc.badge.plus",
                        fields: [.init(key: .title, label: "What is needed"), .init(key: .subtitle, label: "Department / site"), .init(key: .amount, label: "Budget"),
                                 .init(key: .due, label: "Needed by"), .init(key: .status, label: "Status"), .init(key: .notes, label: "Specs, quantity, reason")],
                        statuses: ["Draft", "Waiting for approval", "Approved", "Rejected", "Ordered", "Delivered", "Closed"],
                        doneStatuses: ["Rejected", "Delivered", "Closed"], linkable: true, extras: ["Quantity", "Requested by", "Project / cost centre"]),
        children: [
            BizKind(id: "quote", label: "Supplier quotation", plural: "Quotations", icon: "list.bullet.rectangle.portrait",
                    fields: [.init(key: .title, label: "Supplier"), .init(key: .amount, label: "Quoted amount"), .init(key: .date, label: "Received"), .init(key: .due, label: "Valid till"),
                             .init(key: .status, label: "Status"), .init(key: .notes, label: "Delivery days, warranty, terms")],
                    statuses: ["Received", "Selected", "Rejected"], doneStatuses: ["Selected", "Rejected"]),
            BizKind(id: "approval", label: "Approval", plural: "Approvals", icon: "checkmark.seal",
                    fields: [.init(key: .title, label: "What needs approval"), .init(key: .amount, label: "Amount"), .init(key: .date, label: "Asked"), .init(key: .status, label: "Decision"), .init(key: .notes, label: "Approver's note")],
                    statuses: ["Waiting", "Approved", "Rejected"], doneStatuses: ["Approved", "Rejected"], clientAnswers: true),
            BizKind(id: "po", label: "Purchase order", plural: "Purchase orders", icon: "doc.plaintext.fill",
                    fields: [.init(key: .title, label: "PO no. & supplier"), .init(key: .amount, label: "Amount"), .init(key: .date, label: "Issued"), .init(key: .due, label: "Delivery by"), .init(key: .status, label: "Status")],
                    statuses: ["Issued", "Partly delivered", "Delivered", "Cancelled"], doneStatuses: ["Delivered", "Cancelled"]),
            BizKind(id: "delivery", label: "Delivery / GRN", plural: "Deliveries", icon: "shippingbox",
                    fields: [.init(key: .title, label: "Challan / GRN no."), .init(key: .date, label: "Received"), .init(key: .status, label: "Condition"), .init(key: .notes, label: "Short / damaged items")],
                    statuses: ["Received OK", "Short", "Damaged", "Rejected"], doneStatuses: ["Received OK", "Short", "Damaged", "Rejected"]),
            BizKind(id: "bill", label: "Supplier bill", plural: "Bills", icon: "doc.text",
                    fields: [.init(key: .title, label: "Bill no."), .init(key: .amount, label: "Amount"), .init(key: .due, label: "Due"), .init(key: .status, label: "Status")],
                    statuses: ["Due", "Paid"], doneStatuses: ["Paid"], sign: 1, countWhen: "Due"),
            BizKind(id: "rating", label: "Supplier rating", plural: "Supplier performance", icon: "star.leadinghalf.filled",
                    fields: [.init(key: .title, label: "Supplier"), .init(key: .subtitle, label: "Rating", options: ["★★★★★ Excellent", "★★★★ Good", "★★★ OK", "★★ Poor", "★ Bad"]),
                             .init(key: .notes, label: "On time? Quality? Price?")]),
        ],
        balanceLabel: "To pay", clientWord: "requester")

    // MARK: Grievances (private: raiser ↔ admin, or owner when it's about an admin)
    static let grievance = BizSpec(
        module: "grievance", tab: .grievance, title: "Grievances", icon: "exclamationmark.bubble.fill", colors: [0xC04848, 0x480048],
        parent: nil,
        children: [
            BizKind(id: "grievance", label: "Grievance", plural: "Grievances", icon: "exclamationmark.bubble",
                    fields: [.init(key: .title, label: "Subject"),
                             .init(key: .subtitle, label: "About", options: ["A member", "An admin", "Work / tasks", "Payment / salary", "Behaviour", "Process", "Other"]),
                             .init(key: .date, label: "Raised"), .init(key: .status, label: "Status"), .init(key: .notes, label: "What happened, and what would fix it")],
                    statuses: ["Open", "Under review", "Resolved", "Not upheld", "Closed"], doneStatuses: ["Resolved", "Not upheld", "Closed"], clientAnswers: true,
                    extras: ["Group", "Handled by", "Resolution"]),
        ],
        balanceLabel: "", clientWord: "handler", paid: false)

    static let all: [BizSpec] = [khata, tuition, rent, legal, clinic, bills, kids, travel, petcare, admissions, vendors, home, lostfound, procurement, grievance]
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
