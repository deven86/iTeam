import Foundation
import SwiftData

// MARK: - Builder & Infra (construction / real-estate development)
//
// One stored record type. Every kind (project, building, unit, sale, party, material, equipment, test…) keeps
// its fields in a [String: String] blob described by `BuildKinds`, so new fields never need a migration.
// Company = an Attendance company (so it shows in Finance books, CRM, Attendance everywhere).
// Project team group chat carries everything; buyers, partners and rehab tenants get only their own records
// in their one-to-one chat ("Managed by X"). Vault documents and partner/investor details go only to my own devices.

@Model final class BuildRecord {
    @Attribute(.unique) var id: String
    var kind: String = ""
    /// Attendance company id.
    var companyID: String = ""
    /// "" for company-level records (company profile, company partners).
    var projectID: String = ""
    /// Parent record (sale → unit, payment → sale/party, move → material, log → equipment, unit → building).
    var parentID: String = ""
    var status: String = ""
    var ownerID: String = ""
    var deleted: Bool = false
    var by: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var data: Data = Data()

    init(id: String, kind: String) { self.id = id; self.kind = kind }

    var d: BuildData {
        get { (try? JSONDecoder().decode(BuildData.self, from: data)) ?? BuildData() }
        set { data = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    func f(_ k: String) -> String { d.f[k] ?? "" }
    func num(_ k: String) -> Double { BuildData.number(f(k)) }
    var title: String { d.title(kind) }
}

struct BuildData: Codable, Equatable {
    var f: [String: String] = [:]
    var files: [AttachmentRef] = []
    /// Project: team (all members), admins (may change sales, money, approvals), group chat.
    var team: [String] = []
    var admins: [String] = []
    var convID = ""
    /// The iTeam user this record is about (buyer, partner, rehab tenant) — they get their own copy.
    var subjectID = ""

    subscript(_ k: String) -> String {
        get { f[k] ?? "" }
        set { f[k] = newValue.isEmpty ? nil : newValue }
    }
    static func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) ?? 0 }
    static func date(_ s: String) -> Date? { Double(s).map { Date(timeIntervalSince1970: $0) } }
    static func dateString(_ d: Date) -> String { String(Int(d.timeIntervalSince1970)) }

    func title(_ kind: String) -> String {
        switch kind {
        case "unit": return [self["wing"], self["number"]].filter { !$0.isEmpty }.joined(separator: "-")
        case "sale": return self["buyer"]
        case "payment", "demand", "move", "log": return self["title"].isEmpty ? self["type"] : self["title"]
        default: return self["name"]
        }
    }
}

struct BuildItem: Codable {
    var id: String
    var kind: String
    var companyID: String
    var projectID: String
    var parentID: String = ""
    var status: String = ""
    var ownerID: String
    var deleted: Bool = false
    var data: Data
    var at: Date = .now
}

struct BuildPayload: Codable { var items: [BuildItem] }

// MARK: - Field specs

enum BFType { case text, long, number, money, area, date, phone, email, choice, percent }

struct BField: Identifiable {
    let key: String
    let label: String
    var type: BFType = .text
    var options: [String] = []
    var section: String = ""
    /// Only shown for these party roles / unit kinds.
    var roles: [String]? = nil
    var id: String { key }
}

struct BKind {
    let id: String
    let label: String
    let plural: String
    let icon: String
    let fields: [BField]
    var statuses: [String] = []
    /// Site team (not only admins) may add / update.
    var operational = false
    /// Only on my own devices (and the subject's copy) — never the team chat.
    var privateKind = false
    /// Gets a QR sticker.
    var qr = false
    func field(_ k: String) -> BField? { fields.first { $0.key == k } }
}

enum BuildKinds {
    static let idTypes = ["Aadhaar", "PAN", "Passport", "Driving licence", "Voter ID", "National ID card", "Residence permit / Emirates ID",
                          "Social Security no.", "Tax ID", "Company registration", "Other"]
    static let projectTypes = ["Residential", "Commercial", "Mixed use", "Hospital", "Hotel", "School / College", "Industrial", "Warehouse / Logistics",
                               "Mall / Retail", "Office / IT park", "Bungalows / Row houses", "Plotted development", "Township",
                               "Redevelopment (society)", "Slum rehabilitation (SRA)", "Infrastructure (road, bridge, utility)", "Other"]
    static let buildingUses = ["Residential", "Commercial", "Mixed use", "Hospital", "Hotel", "School / College", "Industrial", "Warehouse", "Mall / Retail",
                               "Office", "Parking tower", "Clubhouse / Amenity", "Rehab building", "Other"]
    static let unitTypes = ["1 RK", "1 BHK", "1.5 BHK", "2 BHK", "2.5 BHK", "3 BHK", "4 BHK", "5 BHK+", "Penthouse", "Duplex", "Villa / Bungalow", "Row house", "Plot",
                            "Shop", "Showroom", "Office", "Restaurant", "Hotel room", "Suite", "Hospital ward", "ICU bed", "OPD / Clinic", "Operation theatre",
                            "Classroom", "Lab", "Hall", "Warehouse unit", "Industrial gala", "Parking", "Other"]
    static let unitStatuses = ["Available", "Hold", "Booked", "Agreement done", "Registered", "Possession given", "Rehab", "Not for sale"]
    static let roles = ["Partner", "Investor", "Landowner", "Rehab tenant / occupant", "Architect", "RCC / Structural consultant", "Civil engineer",
                        "Site engineer", "Liaison officer", "Contractor", "Sub-contractor", "Supplier", "Lawyer", "Chartered accountant",
                        "MEP consultant", "Land surveyor", "Project manager", "Sales / Broker", "Other"]
    static let professionals = ["Architect", "RCC / Structural consultant", "Civil engineer", "Site engineer", "Liaison officer", "Contractor", "Sub-contractor",
                                "Supplier", "Lawyer", "Chartered accountant", "MEP consultant", "Land surveyor", "Project manager", "Sales / Broker", "Other"]
    static let money = ["Partner", "Investor"]

    static let company = BKind(id: "company", label: "Company", plural: "Companies", icon: "building.2.fill", fields: [
        .init(key: "name", label: "Company name"),
        .init(key: "legal", label: "Constitution", type: .choice, options: ["Proprietorship", "Partnership firm", "LLP", "Private limited", "Public limited", "Trust / Society", "Other"]),
        .init(key: "reg", label: "Registration / CIN / LLPIN"),
        .init(key: "tax", label: "GST / VAT / Tax ID"),
        .init(key: "pan", label: "PAN"),
        .init(key: "rera", label: "RERA promoter registration"),
        .init(key: "address", label: "Registered address", type: .long),
        .init(key: "phone", label: "Phone", type: .phone), .init(key: "email", label: "Email", type: .email),
        .init(key: "website", label: "Website"),
        .init(key: "bank", label: "Bank account (for receipts)", type: .long),
    ], privateKind: true)

    static let project = BKind(id: "project", label: "Project", plural: "Projects", icon: "building.columns.fill", fields: [
        .init(key: "name", label: "Project name"),
        .init(key: "type", label: "Project type", type: .choice, options: projectTypes),
        .init(key: "address", label: "Location / address", type: .long),
        .init(key: "city", label: "City / town"),
        .init(key: "survey", label: "Survey / Gat / CTS / Plot no."),
        .init(key: "plot", label: "Plot area", type: .area),
        .init(key: "rera", label: "RERA project registration no."),
        .init(key: "authority", label: "Planning authority (e.g. KDMC, PMC, CIDCO)"),
        .init(key: "start", label: "Start date", type: .date),
        .init(key: "finish", label: "Planned completion", type: .date),
        .init(key: "budget", label: "Project budget", type: .money),
        .init(key: "notes", label: "Description", type: .long),
    ], statuses: ["Planning", "Approvals", "Under construction", "Completed", "On hold"])

    static let building = BKind(id: "building", label: "Building", plural: "Buildings", icon: "building.fill", fields: [
        .init(key: "name", label: "Building name / no."),
        .init(key: "use", label: "Use", type: .choice, options: buildingUses),
        .init(key: "wings", label: "Wings (comma separated, e.g. A, B, C)"),
        .init(key: "floors", label: "Floors above ground", type: .number),
        .init(key: "basements", label: "Basements", type: .number),
        .init(key: "podiums", label: "Podium / parking floors", type: .number),
        .init(key: "height", label: "Height (m)", type: .number),
        .init(key: "structure", label: "Structure", type: .choice, options: ["RCC frame", "Load bearing", "Steel", "Precast", "Mivan / Aluminium formwork", "Composite", "Other"]),
        .init(key: "builtup", label: "Total built-up area", type: .area),
        .init(key: "notes", label: "Notes", type: .long),
    ], statuses: ["Planned", "Excavation", "Foundation", "Plinth", "Superstructure", "Finishing", "Completed"], operational: false)

    static let unit = BKind(id: "unit", label: "Unit", plural: "Units", icon: "square.split.bottomrightquarter.fill", fields: [
        .init(key: "wing", label: "Wing"),
        .init(key: "number", label: "Unit / flat / room no."),
        .init(key: "floor", label: "Floor", type: .number),
        .init(key: "type", label: "Type", type: .choice, options: unitTypes),
        .init(key: "carpet", label: "Carpet area (RERA)", type: .area),
        .init(key: "builtup", label: "Built-up area", type: .area),
        .init(key: "saleable", label: "Saleable area", type: .area),
        .init(key: "facing", label: "Facing / view"),
        .init(key: "parking", label: "Parking"),
        .init(key: "price", label: "Price / agreement value", type: .money),
        .init(key: "notes", label: "Notes", type: .long),
    ], statuses: unitStatuses)

    static let sale = BKind(id: "sale", label: "Sale / booking", plural: "Sales", icon: "person.text.rectangle.fill", fields: [
        .init(key: "buyer", label: "Buyer full name", section: "Buyer"),
        .init(key: "coBuyer", label: "Co-applicant", section: "Buyer"),
        .init(key: "phone", label: "Phone", type: .phone, section: "Buyer"),
        .init(key: "email", label: "Email", type: .email, section: "Buyer"),
        .init(key: "address", label: "Address", type: .long, section: "Buyer"),
        .init(key: "dob", label: "Date of birth", type: .date, section: "Buyer"),
        .init(key: "occupation", label: "Occupation / employer", section: "Buyer"),
        .init(key: "nationality", label: "Nationality / residency", section: "Buyer"),
        .init(key: "idType", label: "Government ID", type: .choice, options: idTypes, section: "Identity"),
        .init(key: "idNo", label: "ID number", section: "Identity"),
        .init(key: "pan", label: "PAN / Tax ID", section: "Identity"),
        .init(key: "booked", label: "Booking date", type: .date, section: "Deal"),
        .init(key: "bookingAmt", label: "Booking amount", type: .money, section: "Deal"),
        .init(key: "value", label: "Agreement value", type: .money, section: "Deal"),
        .init(key: "plan", label: "Payment plan", type: .choice, options: ["Construction linked", "Down payment", "Time linked", "Subvention", "Custom"], section: "Deal"),
        .init(key: "stamp", label: "Stamp duty", type: .money, section: "Agreement"),
        .init(key: "regFee", label: "Registration fee", type: .money, section: "Agreement"),
        .init(key: "gst", label: "GST / VAT", type: .money, section: "Agreement"),
        .init(key: "agreement", label: "Agreement date", type: .date, section: "Agreement"),
        .init(key: "regNo", label: "Registration / document no.", section: "Agreement"),
        .init(key: "office", label: "Sub-registrar / registry office", section: "Agreement"),
        .init(key: "loan", label: "Home loan", type: .choice, options: ["No loan", "Applied", "Sanctioned", "Disbursing", "Fully disbursed", "Rejected", "Closed"], section: "Loan"),
        .init(key: "bank", label: "Bank / lender", section: "Loan"),
        .init(key: "loanAmt", label: "Loan amount", type: .money, section: "Loan"),
        .init(key: "loanAcc", label: "Loan account / reference", section: "Loan"),
        .init(key: "sanction", label: "Sanction date", type: .date, section: "Loan"),
        .init(key: "possession", label: "Possession date", type: .date, section: "Possession"),
        .init(key: "notes", label: "Notes", type: .long, section: "Possession"),
    ], statuses: ["Booked", "Agreement done", "Registered", "Possession given", "Cancelled"])

    static let payment = BKind(id: "payment", label: "Payment", plural: "Payments", icon: "indianrupeesign.circle.fill", fields: [
        .init(key: "title", label: "For (stage / milestone)"),
        .init(key: "amount", label: "Amount", type: .money),
        .init(key: "date", label: "Date", type: .date),
        .init(key: "mode", label: "Mode", type: .choice, options: ["Cheque", "RTGS / NEFT", "UPI", "Cash", "Bank loan disbursement", "Card", "Wire transfer", "Other"]),
        .init(key: "ref", label: "Cheque / UTR / reference"),
        .init(key: "notes", label: "Notes", type: .long),
    ], statuses: ["Received", "Cleared", "Bounced"])

    static let demand = BKind(id: "demand", label: "Demand / instalment", plural: "Demands", icon: "calendar.badge.exclamationmark", fields: [
        .init(key: "title", label: "Milestone (e.g. Plinth, 3rd slab)"),
        .init(key: "percent", label: "% of agreement value", type: .percent),
        .init(key: "amount", label: "Amount", type: .money),
        .init(key: "due", label: "Due date", type: .date),
    ], statuses: ["Due", "Paid", "Waived"])

    static let party = BKind(id: "party", label: "Person / firm", plural: "People", icon: "person.2.fill", fields: [
        .init(key: "role", label: "Role", type: .choice, options: roles),
        .init(key: "name", label: "Full name / firm name"),
        .init(key: "firm", label: "Firm / company"),
        .init(key: "phone", label: "Phone", type: .phone), .init(key: "email", label: "Email", type: .email),
        .init(key: "address", label: "Address", type: .long),
        .init(key: "dob", label: "Date of birth", type: .date, roles: ["Partner", "Investor", "Landowner", "Rehab tenant / occupant"]),
        .init(key: "idType", label: "Government ID", type: .choice, options: idTypes, section: "Identity"),
        .init(key: "idNo", label: "ID number", section: "Identity"),
        .init(key: "pan", label: "PAN / Tax ID", section: "Identity"),
        .init(key: "licence", label: "Licence / registration (COA, engineer, liaison)", section: "Appointment", roles: professionals),
        .init(key: "appointed", label: "Appointed on", type: .date, section: "Appointment", roles: professionals),
        .init(key: "fee", label: "Fee / contract value", type: .money, section: "Appointment", roles: professionals),
        .init(key: "scope", label: "Scope of work", type: .long, section: "Appointment", roles: professionals),
        .init(key: "invest", label: "Capital invested", type: .money, section: "Share", roles: money),
        .init(key: "investShare", label: "Investment share %", type: .percent, section: "Share", roles: money),
        .init(key: "profitShare", label: "Profit share %", type: .percent, section: "Share", roles: money),
        .init(key: "bankDetails", label: "Bank details", type: .long, section: "Share", roles: money),
        .init(key: "landArea", label: "Land area given", type: .area, section: "Land", roles: ["Landowner"]),
        .init(key: "landSurvey", label: "Survey / CTS no.", section: "Land", roles: ["Landowner"]),
        .init(key: "deal", label: "Arrangement", type: .choice, options: ["Joint development (area share)", "Revenue share", "Outright sale", "Development agreement + POA", "Lease"], section: "Land", roles: ["Landowner"]),
        .init(key: "consideration", label: "Consideration (money / area share)", type: .long, section: "Land", roles: ["Landowner"]),
        .init(key: "oldUnit", label: "Old house / room no.", section: "Rehab", roles: ["Rehab tenant / occupant"]),
        .init(key: "oldArea", label: "Old carpet area", type: .area, section: "Rehab", roles: ["Rehab tenant / occupant"]),
        .init(key: "newArea", label: "New area entitled (commuted)", type: .area, section: "Rehab", roles: ["Rehab tenant / occupant"]),
        .init(key: "rehabUnit", label: "Rehab unit allotted", section: "Rehab", roles: ["Rehab tenant / occupant"]),
        .init(key: "transitRent", label: "Transit rent / month", type: .money, section: "Rehab", roles: ["Rehab tenant / occupant"]),
        .init(key: "corpus", label: "Corpus / hardship amount", type: .money, section: "Rehab", roles: ["Rehab tenant / occupant"]),
        .init(key: "notes", label: "Notes", type: .long),
    ], statuses: ["Active", "Consent pending", "Consent signed", "Shifted to transit", "Rehab allotted", "Possession given", "Exited"])

    static let material = BKind(id: "material", label: "Material", plural: "Materials", icon: "shippingbox.fill", fields: [
        .init(key: "name", label: "Material"),
        .init(key: "category", label: "Category", type: .choice, options: BuildCatalog.materials.map(\.0)),
        .init(key: "unit", label: "Unit", type: .choice, options: BuildCatalog.units),
        .init(key: "reorder", label: "Re-order level", type: .number),
        .init(key: "rate", label: "Rate per unit", type: .money),
        .init(key: "supplier", label: "Usual supplier"),
        .init(key: "store", label: "Store / yard location"),
        .init(key: "notes", label: "Notes", type: .long),
    ], operational: true, qr: true)

    static let move = BKind(id: "move", label: "Stock entry", plural: "Stock entries", icon: "arrow.left.arrow.right", fields: [
        .init(key: "type", label: "Entry", type: .choice, options: ["Received", "Issued", "Returned", "Transferred", "Wastage", "Count correction"]),
        .init(key: "qty", label: "Quantity", type: .number),
        .init(key: "rate", label: "Rate", type: .money),
        .init(key: "date", label: "Date", type: .date),
        .init(key: "party", label: "Supplier / issued to"),
        .init(key: "challan", label: "Challan / bill no."),
        .init(key: "where", label: "Used at (building / floor / work)"),
        .init(key: "paid", label: "Paid now (adds to company Finance)", type: .choice, options: ["No", "Yes"]),
    ], operational: true)

    static let equipment = BKind(id: "equipment", label: "Machine / equipment", plural: "Machines", icon: "truck.box.fill", fields: [
        .init(key: "name", label: "Name / number"),
        .init(key: "type", label: "Type", type: .choice, options: BuildCatalog.equipment.flatMap(\.1)),
        .init(key: "make", label: "Make / model"),
        .init(key: "reg", label: "Registration / serial no."),
        .init(key: "own", label: "Ownership", type: .choice, options: ["Owned", "Rented", "Contractor's"]),
        .init(key: "rent", label: "Rent rate", type: .money),
        .init(key: "per", label: "Rent per", type: .choice, options: ["Hour", "Day", "Month", "Trip"]),
        .init(key: "operator", label: "Operator / driver"),
        .init(key: "meter", label: "Hour meter / km", type: .number),
        .init(key: "service", label: "Next service", type: .date),
        .init(key: "insurance", label: "Insurance / fitness expiry", type: .date),
        .init(key: "value", label: "Purchase value", type: .money),
        .init(key: "notes", label: "Notes", type: .long),
    ], statuses: ["Working", "Idle", "Breakdown", "Under service", "Returned"], operational: true, qr: true)

    static let log = BKind(id: "log", label: "Machine log", plural: "Machine logs", icon: "gauge.with.needle", fields: [
        .init(key: "title", label: "Work done"),
        .init(key: "date", label: "Date", type: .date),
        .init(key: "hours", label: "Hours / km", type: .number),
        .init(key: "fuel", label: "Fuel (litres)", type: .number),
        .init(key: "cost", label: "Cost (fuel, rent, repair)", type: .money),
        .init(key: "operator", label: "Operator"),
        .init(key: "paid", label: "Paid now (adds to company Finance)", type: .choice, options: ["No", "Yes"]),
        .init(key: "notes", label: "Breakdown / notes", type: .long),
    ], operational: true)

    static let asset = BKind(id: "asset", label: "Fixed asset", plural: "Fixed assets", icon: "qrcode", fields: [
        .init(key: "name", label: "Asset"),
        .init(key: "category", label: "Category", type: .choice, options: ["Site office / container", "Furniture", "Computer / IT", "Tools", "Safety equipment", "Scaffolding / shuttering", "Survey instrument", "Vehicle", "Other"]),
        .init(key: "serial", label: "Serial / tag no."),
        .init(key: "where", label: "Location"),
        .init(key: "holder", label: "Assigned to"),
        .init(key: "bought", label: "Purchase date", type: .date),
        .init(key: "value", label: "Value", type: .money),
        .init(key: "notes", label: "Notes", type: .long),
    ], statuses: ["In use", "In store", "Under repair", "Lost", "Disposed"], operational: true, qr: true)

    static let test = BKind(id: "test", label: "Quality test", plural: "Quality tests", icon: "testtube.2", fields: [
        .init(key: "name", label: "Test", type: .choice, options: BuildCatalog.tests),
        .init(key: "where", label: "Sample from (building / floor / element)"),
        .init(key: "cast", label: "Cast / sample date", type: .date),
        .init(key: "date", label: "Test date", type: .date),
        .init(key: "lab", label: "Lab / tested by"),
        .init(key: "required", label: "Required value"),
        .init(key: "result", label: "Result value"),
        .init(key: "notes", label: "Remarks", type: .long),
    ], statuses: ["Pending", "Pass", "Fail", "Retest"], operational: true)

    static let approval = BKind(id: "approval", label: "Govt. approval", plural: "Govt. approvals", icon: "checkmark.seal.fill", fields: [
        .init(key: "name", label: "Approval / NOC", type: .choice, options: BuildCatalog.approvals),
        .init(key: "authority", label: "Authority"),
        .init(key: "applied", label: "Applied on", type: .date),
        .init(key: "date", label: "Approved on", type: .date),
        .init(key: "number", label: "Approval / order no."),
        .init(key: "expiry", label: "Valid until", type: .date),
        .init(key: "fees", label: "Fees / premium paid", type: .money),
        .init(key: "liaison", label: "Handled by (liaison officer)"),
        .init(key: "notes", label: "Conditions / queries", type: .long),
    ], statuses: ["Not applied", "Applied", "Query raised", "Approved", "Rejected", "Expired"])

    static let inspection = BKind(id: "inspection", label: "Inspection", plural: "Inspections", icon: "magnifyingglass.circle.fill", fields: [
        .init(key: "name", label: "Inspection (e.g. Plinth checking, Fire audit)"),
        .init(key: "authority", label: "Authority / inspector"),
        .init(key: "date", label: "Date", type: .date),
        .init(key: "stage", label: "Stage / area"),
        .init(key: "notes", label: "Observations", type: .long),
        .init(key: "comply", label: "Comply by", type: .date),
    ], statuses: ["Scheduled", "Satisfactory", "Compliance needed", "Stop-work notice", "Closed"], operational: true)

    static let dispute = BKind(id: "dispute", label: "Dispute", plural: "Disputes", icon: "exclamationmark.bubble.fill", fields: [
        .init(key: "name", label: "Dispute"),
        .init(key: "type", label: "Type", type: .choice, options: ["Land / title", "Tenant / occupant", "Buyer", "Partner", "Contractor / supplier", "Neighbour", "Municipal / government", "Labour", "Other"]),
        .init(key: "against", label: "Against / with"),
        .init(key: "forum", label: "Forum / court"),
        .init(key: "caseNo", label: "Case no."),
        .init(key: "filed", label: "Raised on", type: .date),
        .init(key: "next", label: "Next date", type: .date),
        .init(key: "amount", label: "Amount involved", type: .money),
        .init(key: "lawyer", label: "Lawyer"),
        .init(key: "notes", label: "Facts / status", type: .long),
    ], statuses: ["Notice", "Negotiation", "Filed", "Hearing", "Settled", "Closed"])

    static let progress = BKind(id: "progress", label: "Site report", plural: "Site reports", icon: "photo.on.rectangle.angled", fields: [
        .init(key: "name", label: "Work done today"),
        .init(key: "date", label: "Date", type: .date),
        .init(key: "where", label: "Building / floor / stage"),
        .init(key: "labour", label: "Labour on site", type: .number),
        .init(key: "weather", label: "Weather", type: .choice, options: ["Clear", "Cloudy", "Rain", "Heavy rain", "Heat", "Cold"]),
        .init(key: "issues", label: "Issues / delays", type: .long),
    ], operational: true)

    static let land = BKind(id: "land", label: "Land survey", plural: "Land & survey", icon: "map.fill", fields: [
        .init(key: "name", label: "Survey / Gat / CTS no."),
        .init(key: "hissa", label: "Hissa / sub-division"),
        .init(key: "village", label: "Village / locality"),
        .init(key: "taluka", label: "Taluka / district / state"),
        .init(key: "area", label: "Area", type: .area),
        .init(key: "holder", label: "7/12 holder / title holder"),
        .init(key: "mutation", label: "Mutation entry no."),
        .init(key: "na", label: "Land status", type: .choice, options: ["Agricultural", "NA applied", "NA granted", "Gaothan", "Freehold", "Leasehold", "Government / MIDC lease"]),
        .init(key: "boundaries", label: "Boundaries (N/S/E/W)", type: .long),
        .init(key: "encumbrance", label: "Encumbrances / reservations", type: .long),
        .init(key: "surveyor", label: "Land surveyor / TILR measurement"),
    ], statuses: ["Title search", "Title clear", "Measurement done", "Issue found"])

    static let reward = BKind(id: "reward", label: "Reward", plural: "Rewards", icon: "gift.fill", fields: [
        .init(key: "name", label: "Given to"),
        .init(key: "reason", label: "For", type: .choice, options: ["Safety star", "Best worker of the month", "Quality", "Early completion", "Buyer referral", "Sales target", "Other"]),
        .init(key: "amount", label: "Cash / gift value", type: .money),
        .init(key: "date", label: "Date", type: .date),
        .init(key: "notes", label: "Notes", type: .long),
    ], operational: false)

    static let vault = BKind(id: "vault", label: "Vault document", plural: "Secure vault", icon: "lock.doc.fill", fields: [
        .init(key: "name", label: "Document"),
        .init(key: "category", label: "Category", type: .choice, options: ["Title deed / sale deed", "7/12 / property card", "Development agreement", "Power of attorney", "Partnership deed",
                                                                          "Approvals & NOCs", "Plans (sanctioned)", "Loan / finance", "Insurance", "Agreement (buyer)", "Tax / GST", "Other"]),
        .init(key: "date", label: "Date", type: .date),
        .init(key: "notes", label: "Notes", type: .long),
    ], privateKind: true)

    static let all: [BKind] = [company, project, building, unit, sale, payment, demand, party, material, move, equipment, log, asset, test, approval, inspection, dispute, progress, land, reward, vault]
    static func of(_ id: String) -> BKind { all.first { $0.id == id } ?? progress }

    /// Kinds that only the owner/admins may write.
    static func adminOnly(_ kind: String) -> Bool { !of(kind).operational }
    /// Kinds kept off the team chat.
    static func isPrivate(_ kind: String, data: BuildData) -> Bool {
        if of(kind).privateKind { return true }
        if kind == "party" { return money.contains(data["role"]) }
        if kind == "payment" { return false }
        return false
    }
}

// MARK: - Catalogs

enum BuildCatalog {
    static let units = ["Bag", "Tonne", "Kg", "Quintal", "Brass", "Cu.m", "Cu.ft", "Sq.m", "Sq.ft", "Rft", "Rmt", "Nos", "Litre", "Box", "Bundle", "Roll", "Set", "Trip", "Load"]

    /// (category, items)
    static let materials: [(String, [String])] = [
        ("Cement & binders", ["OPC 43 cement", "OPC 53 cement", "PPC cement", "PSC cement", "White cement", "Rapid hardening cement", "Fly ash", "GGBS", "Micro silica", "Lime", "Gypsum plaster", "POP"]),
        ("Sand & aggregates", ["River sand", "M-sand (manufactured)", "Plaster sand (P-sand)", "Crush sand", "10 mm aggregate", "20 mm aggregate", "40 mm aggregate", "Grit / dust", "Murum / soil", "Rubble / boulders", "GSB (granular sub-base)", "WMM (wet mix macadam)"]),
        ("Steel & metal", ["TMT bar 8 mm", "TMT bar 10 mm", "TMT bar 12 mm", "TMT bar 16 mm", "TMT bar 20 mm", "TMT bar 25 mm", "TMT bar 32 mm", "Binding wire", "Structural steel (I/H/C sections)", "MS angle / channel", "MS plate", "MS pipe", "GI sheet", "Welded mesh", "Couplers", "Cover blocks", "Anchor bolts"]),
        ("Concrete & RMC", ["RMC M15", "RMC M20", "RMC M25", "RMC M30", "RMC M35", "RMC M40", "RMC M50", "PCC", "Self-compacting concrete", "Shotcrete", "Grout"]),
        ("Bricks & blocks", ["Red clay bricks", "Fly ash bricks", "AAC blocks", "Concrete solid blocks", "Hollow blocks", "Paver blocks", "Kerb stones", "Laterite stone", "Basalt stone"]),
        ("Formwork & scaffolding", ["Plywood shuttering", "Film-faced plywood", "Steel plates", "Aluminium formwork (Mivan)", "Props / jacks", "Scaffolding pipes", "Cup-lock", "Clamps", "Shuttering oil", "Tie rods"]),
        ("Admixtures & chemicals", ["Plasticiser", "Super-plasticiser", "Retarder", "Accelerator", "Curing compound", "Bonding agent", "Epoxy", "Anti-termite chemical", "Tile adhesive", "Tile grout"]),
        ("Waterproofing", ["Crystalline waterproofing", "APP membrane", "SBS membrane", "Polyurethane coating", "Acrylic coating", "Cementitious coating", "Bitumen", "Brick-bat coba", "Injection grout", "PVC water-stop"]),
        ("Flooring & tiles", ["Vitrified tiles", "Ceramic tiles", "Wall tiles", "Anti-skid tiles", "Marble", "Granite", "Kota stone", "Shahabad stone", "Wooden flooring", "Vinyl / epoxy flooring", "IPS / screed"]),
        ("Plumbing & sanitary", ["CPVC pipes", "UPVC pipes", "PVC SWR pipes", "GI pipes", "HDPE pipes", "PPR pipes", "Fittings & valves", "Water tanks", "Wash basins", "WC / EWC", "Faucets / CP fittings", "Shower sets", "Sinks", "Manhole covers", "Gully traps"]),
        ("Electrical", ["Copper wire 1.5 sq.mm", "Copper wire 2.5 sq.mm", "Copper wire 4 sq.mm", "Armoured cable", "PVC conduit", "Switches & sockets", "MCB / DB", "Earthing material", "LED fittings", "Transformer", "Meter panels", "Cable trays", "DG cables"]),
        ("Doors, windows & glass", ["Door frames", "Flush doors", "Fire doors", "Safety doors", "Aluminium windows", "UPVC windows", "Glass", "Toughened glass", "Hardware (hinges, locks, handles)", "Grills / railings", "Rolling shutters"]),
        ("Paint & finishes", ["Wall putty", "Primer", "Interior emulsion", "Exterior emulsion", "Enamel paint", "Texture paint", "Distemper", "Wood polish", "Thinner"]),
        ("Timber & boards", ["Teak wood", "Hardwood", "Plywood", "Block board", "MDF", "Particle board", "Laminates", "Gypsum board", "Cement board"]),
        ("Roofing & insulation", ["Metal roofing sheets", "Clay tiles", "Insulation sheets", "Thermal insulation", "False ceiling grid", "Polycarbonate sheets"]),
        ("Fire & safety", ["Fire extinguishers", "Hydrant pipes", "Sprinklers", "Fire alarm", "Safety helmets", "Safety shoes", "Safety harness", "Safety nets", "Barricades", "Reflective jackets"]),
        ("MEP & lifts", ["Lift / elevator", "HVAC units", "Ducting", "Pumps", "STP equipment", "Solar panels", "Water heater", "Rain-water harvesting kit"]),
        ("Roads & infrastructure", ["Bitumen VG-30", "Emulsion", "Asphalt / DBM", "Pre-cast drains", "Hume pipes", "Geotextile", "Road markings", "Street lights", "Crash barriers"]),
        ("Consumables", ["Diesel", "Petrol", "Lubricants", "Welding rods", "Cutting wheels", "Nails", "Screws", "Polythene sheets", "Gunny bags", "Water (tanker)", "Other"]),
    ]

    /// (group, machines)
    static let equipment: [(String, [String])] = [
        ("Earthmoving", ["Excavator (Poclain)", "Backhoe loader (JCB)", "Mini excavator", "Bulldozer / dozer", "Wheel loader", "Skid-steer loader (Bobcat)", "Motor grader", "Trencher", "Scraper"]),
        ("Compaction", ["Vibratory roller", "Tandem roller", "Pneumatic tyre roller", "Sheep-foot roller", "Plate compactor", "Rammer"]),
        ("Concrete", ["Concrete mixer (half bag / one bag)", "Transit mixer", "Batching plant", "Concrete pump (stationary)", "Boom placer / boom pump", "Needle vibrator", "Power trowel", "Concrete cutter", "Shotcrete machine"]),
        ("Breaking & drilling", ["Rock breaker (hydraulic hammer)", "Jack hammer / breaker", "Compressor", "Drilling rig", "Core cutting machine", "Wire saw"]),
        ("Lifting", ["Tower crane", "Mobile crane", "Crawler crane", "Hydra crane", "Material hoist / builder's lift", "Passenger hoist", "Gantry crane", "Forklift", "Telehandler", "Chain pulley block", "Winch"]),
        ("Piling & foundation", ["Piling rig (rotary)", "Hammer piling rig", "DMC piling rig", "Sheet pile driver", "Grouting pump", "Dewatering pump"]),
        ("Steel work", ["Bar bending machine", "Bar cutting machine", "Rebar threading machine", "Welding machine", "Gas cutting set", "Grinder"]),
        ("Transport", ["Dumper", "Tipper", "Tractor with trolley", "Water tanker", "Trailer", "Pickup", "Site bus / van"]),
        ("Roads", ["Asphalt paver", "Hot mix plant", "Bitumen sprayer", "Kerb machine", "Milling machine", "Line marking machine"]),
        ("Power & utilities", ["DG set / generator", "Lighting tower", "Water pump", "Submersible pump", "Air compressor", "Welding generator"]),
        ("Survey & testing", ["Total station", "Auto level", "Theodolite", "GPS / DGPS", "Drone", "Cube testing machine", "Rebound hammer"]),
        ("Other", ["Scaffolding set", "Shuttering set", "Other machine"]),
    ]

    static let tests = ["Concrete cube test — 7 days", "Concrete cube test — 28 days", "Slump test", "Soil bearing capacity (SBC)", "Plate load test", "SPT (standard penetration)",
                        "Soil investigation / bore log", "Steel tensile & bend test", "Brick compressive strength", "Brick water absorption", "Sand silt content", "Aggregate impact / crushing value",
                        "Water quality test", "Waterproofing ponding test", "Pile integrity test", "Pile load test", "Rebound hammer (NDT)", "UPV (ultrasonic pulse velocity)", "Core cutting test",
                        "Plumbing pressure test", "Electrical insulation / earth resistance", "Fire system hydro test", "Lift load test", "Field density test", "Bitumen / asphalt test", "Other"]

    static let approvals = ["Title clearance / search report", "NA (non-agricultural) permission", "Zone certificate", "Layout approval", "Building permission / IOD",
                            "Commencement certificate (CC)", "Plinth checking certificate", "Further CC (upper floors)", "RERA registration", "Environment clearance",
                            "Fire NOC (provisional)", "Fire NOC (final)", "Tree authority NOC", "Airport height NOC (AAI)", "Highway / road NOC", "Railway NOC",
                            "Heritage NOC", "Pollution control (CTE / CTO)", "Water connection", "Drainage connection", "Electricity connection", "Lift licence",
                            "Labour registration / BOCW", "Occupancy certificate (OC)", "Building completion certificate", "Society / association registration",
                            "Conveyance deed", "Other"]

    /// Construction-linked plan (India typical) — edited freely after adding.
    static let clpStages: [(String, Double)] = [("Booking", 10), ("Agreement", 20), ("Plinth", 10), ("1st slab", 5), ("3rd slab", 5), ("5th slab", 5),
                                                ("7th slab", 5), ("Top slab", 10), ("Brickwork & plaster", 10), ("Flooring & finishing", 10), ("Possession", 10)]
}
