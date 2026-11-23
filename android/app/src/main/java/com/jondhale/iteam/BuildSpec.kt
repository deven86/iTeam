package com.jondhale.iteam

// Generated from the iPhone's BuildModels.swift (field specs + catalogs) — keep the two in step.

enum class BT { text, long, number, money, area, date, phone, email, choice, percent }

data class F(val key: String, val label: String, val type: BT = BT.text, val options: List<String> = emptyList(), val section: String = "", val roles: List<String>? = null)

data class BKind(val id: String, val label: String, val plural: String, val icon: String, val fields: List<F>, val statuses: List<String> = emptyList(),
                 val operational: Boolean = false, val privateKind: Boolean = false, val qr: Boolean = false) {
    fun field(k: String) = fields.firstOrNull { it.key == k }
}

object BuildKinds {
    val idTypes = listOf("Aadhaar", "PAN", "Passport", "Driving licence", "Voter ID", "National ID card", "Residence permit / Emirates ID",
                          "Social Security no.", "Tax ID", "Company registration", "Other")
    val projectTypes = listOf("Residential", "Commercial", "Mixed use", "Hospital", "Hotel", "School / College", "Industrial", "Warehouse / Logistics",
                               "Mall / Retail", "Office / IT park", "Bungalows / Row houses", "Plotted development", "Township",
                               "Redevelopment (society)", "Slum rehabilitation (SRA)", "Infrastructure (road, bridge, utility)", "Other")
    val buildingUses = listOf("Residential", "Commercial", "Mixed use", "Hospital", "Hotel", "School / College", "Industrial", "Warehouse", "Mall / Retail",
                               "Office", "Parking tower", "Clubhouse / Amenity", "Rehab building", "Other")
    val unitTypes = listOf("1 RK", "1 BHK", "1.5 BHK", "2 BHK", "2.5 BHK", "3 BHK", "4 BHK", "5 BHK+", "Penthouse", "Duplex", "Villa / Bungalow", "Row house", "Plot",
                            "Shop", "Showroom", "Office", "Restaurant", "Hotel room", "Suite", "Hospital ward", "ICU bed", "OPD / Clinic", "Operation theatre",
                            "Classroom", "Lab", "Hall", "Warehouse unit", "Industrial gala", "Parking", "Other")
    val unitStatuses = listOf("Available", "Hold", "Booked", "Agreement done", "Registered", "Possession given", "Rehab", "Not for sale")
    val roles = listOf("Partner", "Investor", "Landowner", "Rehab tenant / occupant", "Architect", "RCC / Structural consultant", "Civil engineer",
                        "Site engineer", "Liaison officer", "Contractor", "Sub-contractor", "Supplier", "Lawyer", "Chartered accountant",
                        "MEP consultant", "Land surveyor", "Project manager", "Sales / Broker", "Other")
    val professionals = listOf("Architect", "RCC / Structural consultant", "Civil engineer", "Site engineer", "Liaison officer", "Contractor", "Sub-contractor",
                                "Supplier", "Lawyer", "Chartered accountant", "MEP consultant", "Land surveyor", "Project manager", "Sales / Broker", "Other")
    val money = listOf("Partner", "Investor")

    val company = BKind(id = "company", label = "Company", plural = "Companies", icon = "building.2.fill", fields = listOf(
        F(key = "name", label = "Company name"),
        F(key = "legal", label = "Constitution", type = BT.choice, options = listOf("Proprietorship", "Partnership firm", "LLP", "Private limited", "Public limited", "Trust / Society", "Other")),
        F(key = "reg", label = "Registration / CIN / LLPIN"),
        F(key = "tax", label = "GST / VAT / Tax ID"),
        F(key = "pan", label = "PAN"),
        F(key = "rera", label = "RERA promoter registration"),
        F(key = "address", label = "Registered address", type = BT.long),
        F(key = "phone", label = "Phone", type = BT.phone), F(key = "email", label = "Email", type = BT.email),
        F(key = "website", label = "Website"),
        F(key = "bank", label = "Bank account (for receipts)", type = BT.long),
    ), privateKind = true)

    val project = BKind(id = "project", label = "Project", plural = "Projects", icon = "building.columns.fill", fields = listOf(
        F(key = "name", label = "Project name"),
        F(key = "type", label = "Project type", type = BT.choice, options = projectTypes),
        F(key = "address", label = "Location / address", type = BT.long),
        F(key = "city", label = "City / town"),
        F(key = "survey", label = "Survey / Gat / CTS / Plot no."),
        F(key = "plot", label = "Plot area", type = BT.area),
        F(key = "rera", label = "RERA project registration no."),
        F(key = "authority", label = "Planning authority (e.g. KDMC, PMC, CIDCO)"),
        F(key = "start", label = "Start date", type = BT.date),
        F(key = "finish", label = "Planned completion", type = BT.date),
        F(key = "budget", label = "Project budget", type = BT.money),
        F(key = "notes", label = "Description", type = BT.long),
    ), statuses = listOf("Planning", "Approvals", "Under construction", "Completed", "On hold"))

    val building = BKind(id = "building", label = "Building", plural = "Buildings", icon = "building.fill", fields = listOf(
        F(key = "name", label = "Building name / no."),
        F(key = "use", label = "Use", type = BT.choice, options = buildingUses),
        F(key = "wings", label = "Wings (comma separated, e.g. A, B, C)"),
        F(key = "floors", label = "Floors above ground", type = BT.number),
        F(key = "basements", label = "Basements", type = BT.number),
        F(key = "podiums", label = "Podium / parking floors", type = BT.number),
        F(key = "height", label = "Height (m)", type = BT.number),
        F(key = "structure", label = "Structure", type = BT.choice, options = listOf("RCC frame", "Load bearing", "Steel", "Precast", "Mivan / Aluminium formwork", "Composite", "Other")),
        F(key = "builtup", label = "Total built-up area", type = BT.area),
        F(key = "notes", label = "Notes", type = BT.long),
    ), statuses = listOf("Planned", "Excavation", "Foundation", "Plinth", "Superstructure", "Finishing", "Completed"), operational = false)

    val unit = BKind(id = "unit", label = "Unit", plural = "Units", icon = "square.split.bottomrightquarter.fill", fields = listOf(
        F(key = "wing", label = "Wing"),
        F(key = "number", label = "Unit / flat / room no."),
        F(key = "floor", label = "Floor", type = BT.number),
        F(key = "type", label = "Type", type = BT.choice, options = unitTypes),
        F(key = "carpet", label = "Carpet area (RERA)", type = BT.area),
        F(key = "builtup", label = "Built-up area", type = BT.area),
        F(key = "saleable", label = "Saleable area", type = BT.area),
        F(key = "facing", label = "Facing / view"),
        F(key = "parking", label = "Parking"),
        F(key = "price", label = "Price / agreement value", type = BT.money),
        F(key = "notes", label = "Notes", type = BT.long),
    ), statuses = unitStatuses)

    val sale = BKind(id = "sale", label = "Sale / booking", plural = "Sales", icon = "person.text.rectangle.fill", fields = listOf(
        F(key = "buyer", label = "Buyer full name", section = "Buyer"),
        F(key = "coBuyer", label = "Co-applicant", section = "Buyer"),
        F(key = "phone", label = "Phone", type = BT.phone, section = "Buyer"),
        F(key = "email", label = "Email", type = BT.email, section = "Buyer"),
        F(key = "address", label = "Address", type = BT.long, section = "Buyer"),
        F(key = "dob", label = "Date of birth", type = BT.date, section = "Buyer"),
        F(key = "occupation", label = "Occupation / employer", section = "Buyer"),
        F(key = "nationality", label = "Nationality / residency", section = "Buyer"),
        F(key = "idType", label = "Government ID", type = BT.choice, options = idTypes, section = "Identity"),
        F(key = "idNo", label = "ID number", section = "Identity"),
        F(key = "pan", label = "PAN / Tax ID", section = "Identity"),
        F(key = "booked", label = "Booking date", type = BT.date, section = "Deal"),
        F(key = "bookingAmt", label = "Booking amount", type = BT.money, section = "Deal"),
        F(key = "value", label = "Agreement value", type = BT.money, section = "Deal"),
        F(key = "plan", label = "Payment plan", type = BT.choice, options = listOf("Construction linked", "Down payment", "Time linked", "Subvention", "Custom"), section = "Deal"),
        F(key = "stamp", label = "Stamp duty", type = BT.money, section = "Agreement"),
        F(key = "regFee", label = "Registration fee", type = BT.money, section = "Agreement"),
        F(key = "gst", label = "GST / VAT", type = BT.money, section = "Agreement"),
        F(key = "agreement", label = "Agreement date", type = BT.date, section = "Agreement"),
        F(key = "regNo", label = "Registration / document no.", section = "Agreement"),
        F(key = "office", label = "Sub-registrar / registry office", section = "Agreement"),
        F(key = "loan", label = "Home loan", type = BT.choice, options = listOf("No loan", "Applied", "Sanctioned", "Disbursing", "Fully disbursed", "Rejected", "Closed"), section = "Loan"),
        F(key = "bank", label = "Bank / lender", section = "Loan"),
        F(key = "loanAmt", label = "Loan amount", type = BT.money, section = "Loan"),
        F(key = "loanAcc", label = "Loan account / reference", section = "Loan"),
        F(key = "sanction", label = "Sanction date", type = BT.date, section = "Loan"),
        F(key = "possession", label = "Possession date", type = BT.date, section = "Possession"),
        F(key = "notes", label = "Notes", type = BT.long, section = "Possession"),
    ), statuses = listOf("Booked", "Agreement done", "Registered", "Possession given", "Cancelled"))

    val payment = BKind(id = "payment", label = "Payment", plural = "Payments", icon = "indianrupeesign.circle.fill", fields = listOf(
        F(key = "title", label = "For (stage / milestone)"),
        F(key = "amount", label = "Amount", type = BT.money),
        F(key = "date", label = "Date", type = BT.date),
        F(key = "mode", label = "Mode", type = BT.choice, options = listOf("Cheque", "RTGS / NEFT", "UPI", "Cash", "Bank loan disbursement", "Card", "Wire transfer", "Other")),
        F(key = "ref", label = "Cheque / UTR / reference"),
        F(key = "notes", label = "Notes", type = BT.long),
    ), statuses = listOf("Received", "Cleared", "Bounced"))

    val demand = BKind(id = "demand", label = "Demand / instalment", plural = "Demands", icon = "calendar.badge.exclamationmark", fields = listOf(
        F(key = "title", label = "Milestone (e.g. Plinth, 3rd slab)"),
        F(key = "percent", label = "% of agreement value", type = BT.percent),
        F(key = "amount", label = "Amount", type = BT.money),
        F(key = "due", label = "Due date", type = BT.date),
    ), statuses = listOf("Due", "Paid", "Waived"))

    val party = BKind(id = "party", label = "Person / firm", plural = "People", icon = "person.2.fill", fields = listOf(
        F(key = "role", label = "Role", type = BT.choice, options = roles),
        F(key = "name", label = "Full name / firm name"),
        F(key = "firm", label = "Firm / company"),
        F(key = "phone", label = "Phone", type = BT.phone), F(key = "email", label = "Email", type = BT.email),
        F(key = "address", label = "Address", type = BT.long),
        F(key = "dob", label = "Date of birth", type = BT.date, roles = listOf("Partner", "Investor", "Landowner", "Rehab tenant / occupant")),
        F(key = "idType", label = "Government ID", type = BT.choice, options = idTypes, section = "Identity"),
        F(key = "idNo", label = "ID number", section = "Identity"),
        F(key = "pan", label = "PAN / Tax ID", section = "Identity"),
        F(key = "licence", label = "Licence / registration (COA, engineer, liaison)", section = "Appointment", roles = professionals),
        F(key = "appointed", label = "Appointed on", type = BT.date, section = "Appointment", roles = professionals),
        F(key = "fee", label = "Fee / contract value", type = BT.money, section = "Appointment", roles = professionals),
        F(key = "scope", label = "Scope of work", type = BT.long, section = "Appointment", roles = professionals),
        F(key = "invest", label = "Capital invested", type = BT.money, section = "Share", roles = money),
        F(key = "investShare", label = "Investment share %", type = BT.percent, section = "Share", roles = money),
        F(key = "profitShare", label = "Profit share %", type = BT.percent, section = "Share", roles = money),
        F(key = "bankDetails", label = "Bank details", type = BT.long, section = "Share", roles = money),
        F(key = "landArea", label = "Land area given", type = BT.area, section = "Land", roles = listOf("Landowner")),
        F(key = "landSurvey", label = "Survey / CTS no.", section = "Land", roles = listOf("Landowner")),
        F(key = "deal", label = "Arrangement", type = BT.choice, options = listOf("Joint development (area share)", "Revenue share", "Outright sale", "Development agreement + POA", "Lease"), section = "Land", roles = listOf("Landowner")),
        F(key = "consideration", label = "Consideration (money / area share)", type = BT.long, section = "Land", roles = listOf("Landowner")),
        F(key = "oldUnit", label = "Old house / room no.", section = "Rehab", roles = listOf("Rehab tenant / occupant")),
        F(key = "oldArea", label = "Old carpet area", type = BT.area, section = "Rehab", roles = listOf("Rehab tenant / occupant")),
        F(key = "newArea", label = "New area entitled (commuted)", type = BT.area, section = "Rehab", roles = listOf("Rehab tenant / occupant")),
        F(key = "rehabUnit", label = "Rehab unit allotted", section = "Rehab", roles = listOf("Rehab tenant / occupant")),
        F(key = "transitRent", label = "Transit rent / month", type = BT.money, section = "Rehab", roles = listOf("Rehab tenant / occupant")),
        F(key = "corpus", label = "Corpus / hardship amount", type = BT.money, section = "Rehab", roles = listOf("Rehab tenant / occupant")),
        F(key = "notes", label = "Notes", type = BT.long),
    ), statuses = listOf("Active", "Consent pending", "Consent signed", "Shifted to transit", "Rehab allotted", "Possession given", "Exited"))

    val material = BKind(id = "material", label = "Material", plural = "Materials", icon = "shippingbox.fill", fields = listOf(
        F(key = "name", label = "Material"),
        F(key = "category", label = "Category", type = BT.choice, options = BuildCatalog.materials.map { it.first }),
        F(key = "unit", label = "Unit", type = BT.choice, options = BuildCatalog.units),
        F(key = "reorder", label = "Re-order level", type = BT.number),
        F(key = "rate", label = "Rate per unit", type = BT.money),
        F(key = "supplier", label = "Usual supplier"),
        F(key = "store", label = "Store / yard location"),
        F(key = "notes", label = "Notes", type = BT.long),
    ), operational = true, qr = true)

    val move = BKind(id = "move", label = "Stock entry", plural = "Stock entries", icon = "arrow.left.arrow.right", fields = listOf(
        F(key = "type", label = "Entry", type = BT.choice, options = listOf("Received", "Issued", "Returned", "Transferred", "Wastage", "Count correction")),
        F(key = "qty", label = "Quantity", type = BT.number),
        F(key = "rate", label = "Rate", type = BT.money),
        F(key = "date", label = "Date", type = BT.date),
        F(key = "party", label = "Supplier / issued to"),
        F(key = "challan", label = "Challan / bill no."),
        F(key = "where", label = "Used at (building / floor / work)"),
        F(key = "paid", label = "Paid now (adds to company Finance)", type = BT.choice, options = listOf("No", "Yes")),
    ), operational = true)

    val equipment = BKind(id = "equipment", label = "Machine / equipment", plural = "Machines", icon = "truck.box.fill", fields = listOf(
        F(key = "name", label = "Name / number"),
        F(key = "type", label = "Type", type = BT.choice, options = BuildCatalog.equipment.flatMap { it.second }),
        F(key = "make", label = "Make / model"),
        F(key = "reg", label = "Registration / serial no."),
        F(key = "own", label = "Ownership", type = BT.choice, options = listOf("Owned", "Rented", "Contractor's")),
        F(key = "rent", label = "Rent rate", type = BT.money),
        F(key = "per", label = "Rent per", type = BT.choice, options = listOf("Hour", "Day", "Month", "Trip")),
        F(key = "operator", label = "Operator / driver"),
        F(key = "meter", label = "Hour meter / km", type = BT.number),
        F(key = "service", label = "Next service", type = BT.date),
        F(key = "insurance", label = "Insurance / fitness expiry", type = BT.date),
        F(key = "value", label = "Purchase value", type = BT.money),
        F(key = "notes", label = "Notes", type = BT.long),
    ), statuses = listOf("Working", "Idle", "Breakdown", "Under service", "Returned"), operational = true, qr = true)

    val log = BKind(id = "log", label = "Machine log", plural = "Machine logs", icon = "gauge.with.needle", fields = listOf(
        F(key = "title", label = "Work done"),
        F(key = "date", label = "Date", type = BT.date),
        F(key = "hours", label = "Hours / km", type = BT.number),
        F(key = "fuel", label = "Fuel (litres)", type = BT.number),
        F(key = "cost", label = "Cost (fuel, rent, repair)", type = BT.money),
        F(key = "operator", label = "Operator"),
        F(key = "paid", label = "Paid now (adds to company Finance)", type = BT.choice, options = listOf("No", "Yes")),
        F(key = "notes", label = "Breakdown / notes", type = BT.long),
    ), operational = true)

    val asset = BKind(id = "asset", label = "Fixed asset", plural = "Fixed assets", icon = "qrcode", fields = listOf(
        F(key = "name", label = "Asset"),
        F(key = "category", label = "Category", type = BT.choice, options = listOf("Site office / container", "Furniture", "Computer / IT", "Tools", "Safety equipment", "Scaffolding / shuttering", "Survey instrument", "Vehicle", "Other")),
        F(key = "serial", label = "Serial / tag no."),
        F(key = "where", label = "Location"),
        F(key = "holder", label = "Assigned to"),
        F(key = "bought", label = "Purchase date", type = BT.date),
        F(key = "value", label = "Value", type = BT.money),
        F(key = "notes", label = "Notes", type = BT.long),
    ), statuses = listOf("In use", "In store", "Under repair", "Lost", "Disposed"), operational = true, qr = true)

    val test = BKind(id = "test", label = "Quality test", plural = "Quality tests", icon = "testtube.2", fields = listOf(
        F(key = "name", label = "Test", type = BT.choice, options = BuildCatalog.tests),
        F(key = "where", label = "Sample from (building / floor / element)"),
        F(key = "cast", label = "Cast / sample date", type = BT.date),
        F(key = "date", label = "Test date", type = BT.date),
        F(key = "lab", label = "Lab / tested by"),
        F(key = "required", label = "Required value"),
        F(key = "result", label = "Result value"),
        F(key = "notes", label = "Remarks", type = BT.long),
    ), statuses = listOf("Pending", "Pass", "Fail", "Retest"), operational = true)

    val approval = BKind(id = "approval", label = "Govt. approval", plural = "Govt. approvals", icon = "checkmark.seal.fill", fields = listOf(
        F(key = "name", label = "Approval / NOC", type = BT.choice, options = BuildCatalog.approvals),
        F(key = "authority", label = "Authority"),
        F(key = "applied", label = "Applied on", type = BT.date),
        F(key = "date", label = "Approved on", type = BT.date),
        F(key = "number", label = "Approval / order no."),
        F(key = "expiry", label = "Valid until", type = BT.date),
        F(key = "fees", label = "Fees / premium paid", type = BT.money),
        F(key = "liaison", label = "Handled by (liaison officer)"),
        F(key = "notes", label = "Conditions / queries", type = BT.long),
    ), statuses = listOf("Not applied", "Applied", "Query raised", "Approved", "Rejected", "Expired"))

    val inspection = BKind(id = "inspection", label = "Inspection", plural = "Inspections", icon = "magnifyingglass.circle.fill", fields = listOf(
        F(key = "name", label = "Inspection (e.g. Plinth checking, Fire audit)"),
        F(key = "authority", label = "Authority / inspector"),
        F(key = "date", label = "Date", type = BT.date),
        F(key = "stage", label = "Stage / area"),
        F(key = "notes", label = "Observations", type = BT.long),
        F(key = "comply", label = "Comply by", type = BT.date),
    ), statuses = listOf("Scheduled", "Satisfactory", "Compliance needed", "Stop-work notice", "Closed"), operational = true)

    val dispute = BKind(id = "dispute", label = "Dispute", plural = "Disputes", icon = "exclamationmark.bubble.fill", fields = listOf(
        F(key = "name", label = "Dispute"),
        F(key = "type", label = "Type", type = BT.choice, options = listOf("Land / title", "Tenant / occupant", "Buyer", "Partner", "Contractor / supplier", "Neighbour", "Municipal / government", "Labour", "Other")),
        F(key = "against", label = "Against / with"),
        F(key = "forum", label = "Forum / court"),
        F(key = "caseNo", label = "Case no."),
        F(key = "filed", label = "Raised on", type = BT.date),
        F(key = "next", label = "Next date", type = BT.date),
        F(key = "amount", label = "Amount involved", type = BT.money),
        F(key = "lawyer", label = "Lawyer"),
        F(key = "notes", label = "Facts / status", type = BT.long),
    ), statuses = listOf("Notice", "Negotiation", "Filed", "Hearing", "Settled", "Closed"))

    val progress = BKind(id = "progress", label = "Site report", plural = "Site reports", icon = "photo.on.rectangle.angled", fields = listOf(
        F(key = "name", label = "Work done today"),
        F(key = "date", label = "Date", type = BT.date),
        F(key = "where", label = "Building / floor / stage"),
        F(key = "labour", label = "Labour on site", type = BT.number),
        F(key = "weather", label = "Weather", type = BT.choice, options = listOf("Clear", "Cloudy", "Rain", "Heavy rain", "Heat", "Cold")),
        F(key = "issues", label = "Issues / delays", type = BT.long),
    ), operational = true)

    val land = BKind(id = "land", label = "Land survey", plural = "Land & survey", icon = "map.fill", fields = listOf(
        F(key = "name", label = "Survey / Gat / CTS no."),
        F(key = "hissa", label = "Hissa / sub-division"),
        F(key = "village", label = "Village / locality"),
        F(key = "taluka", label = "Taluka / district / state"),
        F(key = "area", label = "Area", type = BT.area),
        F(key = "holder", label = "7/12 holder / title holder"),
        F(key = "mutation", label = "Mutation entry no."),
        F(key = "na", label = "Land status", type = BT.choice, options = listOf("Agricultural", "NA applied", "NA granted", "Gaothan", "Freehold", "Leasehold", "Government / MIDC lease")),
        F(key = "boundaries", label = "Boundaries (N/S/E/W)", type = BT.long),
        F(key = "encumbrance", label = "Encumbrances / reservations", type = BT.long),
        F(key = "surveyor", label = "Land surveyor / TILR measurement"),
    ), statuses = listOf("Title search", "Title clear", "Measurement done", "Issue found"))

    val reward = BKind(id = "reward", label = "Reward", plural = "Rewards", icon = "gift.fill", fields = listOf(
        F(key = "name", label = "Given to"),
        F(key = "reason", label = "For", type = BT.choice, options = listOf("Safety star", "Best worker of the month", "Quality", "Early completion", "Buyer referral", "Sales target", "Other")),
        F(key = "amount", label = "Cash / gift value", type = BT.money),
        F(key = "date", label = "Date", type = BT.date),
        F(key = "notes", label = "Notes", type = BT.long),
    ), operational = false)

    val vault = BKind(id = "vault", label = "Vault document", plural = "Secure vault", icon = "lock.doc.fill", fields = listOf(
        F(key = "name", label = "Document"),
        F(key = "category", label = "Category", type = BT.choice, options = listOf("Title deed / sale deed", "7/12 / property card", "Development agreement", "Power of attorney", "Partnership deed",
                                                                          "Approvals & NOCs", "Plans (sanctioned)", "Loan / finance", "Insurance", "Agreement (buyer)", "Tax / GST", "Other")),
        F(key = "date", label = "Date", type = BT.date),
        F(key = "notes", label = "Notes", type = BT.long),
    ), privateKind = true)



    val all = listOf(company, project, building, unit, sale, payment, demand, party, material, move, equipment, log, asset, test, approval, inspection, dispute, progress, land, reward, vault)
    fun of(id: String) = all.firstOrNull { it.id == id } ?: progress
    fun adminOnly(kind: String) = !of(kind).operational
    fun isPrivate(kind: String, f: Map<String, String>) = of(kind).privateKind || (kind == "party" && f["role"] in money)
}

object BuildCatalog {
    val units = listOf("Bag", "Tonne", "Kg", "Quintal", "Brass", "Cu.m", "Cu.ft", "Sq.m", "Sq.ft", "Rft", "Rmt", "Nos", "Litre", "Box", "Bundle", "Roll", "Set", "Trip", "Load")

    // (category, items)
    val materials = listOf(
        Pair("Cement & binders", listOf("OPC 43 cement", "OPC 53 cement", "PPC cement", "PSC cement", "White cement", "Rapid hardening cement", "Fly ash", "GGBS", "Micro silica", "Lime", "Gypsum plaster", "POP")),
        Pair("Sand & aggregates", listOf("River sand", "M-sand (manufactured)", "Plaster sand (P-sand)", "Crush sand", "10 mm aggregate", "20 mm aggregate", "40 mm aggregate", "Grit / dust", "Murum / soil", "Rubble / boulders", "GSB (granular sub-base)", "WMM (wet mix macadam)")),
        Pair("Steel & metal", listOf("TMT bar 8 mm", "TMT bar 10 mm", "TMT bar 12 mm", "TMT bar 16 mm", "TMT bar 20 mm", "TMT bar 25 mm", "TMT bar 32 mm", "Binding wire", "Structural steel (I/H/C sections)", "MS angle / channel", "MS plate", "MS pipe", "GI sheet", "Welded mesh", "Couplers", "Cover blocks", "Anchor bolts")),
        Pair("Concrete & RMC", listOf("RMC M15", "RMC M20", "RMC M25", "RMC M30", "RMC M35", "RMC M40", "RMC M50", "PCC", "Self-compacting concrete", "Shotcrete", "Grout")),
        Pair("Bricks & blocks", listOf("Red clay bricks", "Fly ash bricks", "AAC blocks", "Concrete solid blocks", "Hollow blocks", "Paver blocks", "Kerb stones", "Laterite stone", "Basalt stone")),
        Pair("Formwork & scaffolding", listOf("Plywood shuttering", "Film-faced plywood", "Steel plates", "Aluminium formwork (Mivan)", "Props / jacks", "Scaffolding pipes", "Cup-lock", "Clamps", "Shuttering oil", "Tie rods")),
        Pair("Admixtures & chemicals", listOf("Plasticiser", "Super-plasticiser", "Retarder", "Accelerator", "Curing compound", "Bonding agent", "Epoxy", "Anti-termite chemical", "Tile adhesive", "Tile grout")),
        Pair("Waterproofing", listOf("Crystalline waterproofing", "APP membrane", "SBS membrane", "Polyurethane coating", "Acrylic coating", "Cementitious coating", "Bitumen", "Brick-bat coba", "Injection grout", "PVC water-stop")),
        Pair("Flooring & tiles", listOf("Vitrified tiles", "Ceramic tiles", "Wall tiles", "Anti-skid tiles", "Marble", "Granite", "Kota stone", "Shahabad stone", "Wooden flooring", "Vinyl / epoxy flooring", "IPS / screed")),
        Pair("Plumbing & sanitary", listOf("CPVC pipes", "UPVC pipes", "PVC SWR pipes", "GI pipes", "HDPE pipes", "PPR pipes", "Fittings & valves", "Water tanks", "Wash basins", "WC / EWC", "Faucets / CP fittings", "Shower sets", "Sinks", "Manhole covers", "Gully traps")),
        Pair("Electrical", listOf("Copper wire 1.5 sq.mm", "Copper wire 2.5 sq.mm", "Copper wire 4 sq.mm", "Armoured cable", "PVC conduit", "Switches & sockets", "MCB / DB", "Earthing material", "LED fittings", "Transformer", "Meter panels", "Cable trays", "DG cables")),
        Pair("Doors, windows & glass", listOf("Door frames", "Flush doors", "Fire doors", "Safety doors", "Aluminium windows", "UPVC windows", "Glass", "Toughened glass", "Hardware (hinges, locks, handles)", "Grills / railings", "Rolling shutters")),
        Pair("Paint & finishes", listOf("Wall putty", "Primer", "Interior emulsion", "Exterior emulsion", "Enamel paint", "Texture paint", "Distemper", "Wood polish", "Thinner")),
        Pair("Timber & boards", listOf("Teak wood", "Hardwood", "Plywood", "Block board", "MDF", "Particle board", "Laminates", "Gypsum board", "Cement board")),
        Pair("Roofing & insulation", listOf("Metal roofing sheets", "Clay tiles", "Insulation sheets", "Thermal insulation", "False ceiling grid", "Polycarbonate sheets")),
        Pair("Fire & safety", listOf("Fire extinguishers", "Hydrant pipes", "Sprinklers", "Fire alarm", "Safety helmets", "Safety shoes", "Safety harness", "Safety nets", "Barricades", "Reflective jackets")),
        Pair("MEP & lifts", listOf("Lift / elevator", "HVAC units", "Ducting", "Pumps", "STP equipment", "Solar panels", "Water heater", "Rain-water harvesting kit")),
        Pair("Roads & infrastructure", listOf("Bitumen VG-30", "Emulsion", "Asphalt / DBM", "Pre-cast drains", "Hume pipes", "Geotextile", "Road markings", "Street lights", "Crash barriers")),
        Pair("Consumables", listOf("Diesel", "Petrol", "Lubricants", "Welding rods", "Cutting wheels", "Nails", "Screws", "Polythene sheets", "Gunny bags", "Water (tanker)", "Other")),
    )

    // (group, machines)
    val equipment = listOf(
        Pair("Earthmoving", listOf("Excavator (Poclain)", "Backhoe loader (JCB)", "Mini excavator", "Bulldozer / dozer", "Wheel loader", "Skid-steer loader (Bobcat)", "Motor grader", "Trencher", "Scraper")),
        Pair("Compaction", listOf("Vibratory roller", "Tandem roller", "Pneumatic tyre roller", "Sheep-foot roller", "Plate compactor", "Rammer")),
        Pair("Concrete", listOf("Concrete mixer (half bag / one bag)", "Transit mixer", "Batching plant", "Concrete pump (stationary)", "Boom placer / boom pump", "Needle vibrator", "Power trowel", "Concrete cutter", "Shotcrete machine")),
        Pair("Breaking & drilling", listOf("Rock breaker (hydraulic hammer)", "Jack hammer / breaker", "Compressor", "Drilling rig", "Core cutting machine", "Wire saw")),
        Pair("Lifting", listOf("Tower crane", "Mobile crane", "Crawler crane", "Hydra crane", "Material hoist / builder's lift", "Passenger hoist", "Gantry crane", "Forklift", "Telehandler", "Chain pulley block", "Winch")),
        Pair("Piling & foundation", listOf("Piling rig (rotary)", "Hammer piling rig", "DMC piling rig", "Sheet pile driver", "Grouting pump", "Dewatering pump")),
        Pair("Steel work", listOf("Bar bending machine", "Bar cutting machine", "Rebar threading machine", "Welding machine", "Gas cutting set", "Grinder")),
        Pair("Transport", listOf("Dumper", "Tipper", "Tractor with trolley", "Water tanker", "Trailer", "Pickup", "Site bus / van")),
        Pair("Roads", listOf("Asphalt paver", "Hot mix plant", "Bitumen sprayer", "Kerb machine", "Milling machine", "Line marking machine")),
        Pair("Power & utilities", listOf("DG set / generator", "Lighting tower", "Water pump", "Submersible pump", "Air compressor", "Welding generator")),
        Pair("Survey & testing", listOf("Total station", "Auto level", "Theodolite", "GPS / DGPS", "Drone", "Cube testing machine", "Rebound hammer")),
        Pair("Other", listOf("Scaffolding set", "Shuttering set", "Other machine")),
    )

    val tests = listOf("Concrete cube test — 7 days", "Concrete cube test — 28 days", "Slump test", "Soil bearing capacity (SBC)", "Plate load test", "SPT (standard penetration)",
                        "Soil investigation / bore log", "Steel tensile & bend test", "Brick compressive strength", "Brick water absorption", "Sand silt content", "Aggregate impact / crushing value",
                        "Water quality test", "Waterproofing ponding test", "Pile integrity test", "Pile load test", "Rebound hammer (NDT)", "UPV (ultrasonic pulse velocity)", "Core cutting test",
                        "Plumbing pressure test", "Electrical insulation / earth resistance", "Fire system hydro test", "Lift load test", "Field density test", "Bitumen / asphalt test", "Other")

    val approvals = listOf("Title clearance / search report", "NA (non-agricultural) permission", "Zone certificate", "Layout approval", "Building permission / IOD",
                            "Commencement certificate (CC)", "Plinth checking certificate", "Further CC (upper floors)", "RERA registration", "Environment clearance",
                            "Fire NOC (provisional)", "Fire NOC (final)", "Tree authority NOC", "Airport height NOC (AAI)", "Highway / road NOC", "Railway NOC",
                            "Heritage NOC", "Pollution control (CTE / CTO)", "Water connection", "Drainage connection", "Electricity connection", "Lift licence",
                            "Labour registration / BOCW", "Occupancy certificate (OC)", "Building completion certificate", "Society / association registration",
                            "Conveyance deed", "Other")

    // Construction-linked plan (India typical) — edited freely after adding.
    val clpStages = listOf(Pair("Booking", 10.0), Pair("Agreement", 20.0), Pair("Plinth", 10.0), Pair("1st slab", 5.0), Pair("3rd slab", 5.0), Pair("5th slab", 5.0),
                                                Pair("7th slab", 5.0), Pair("Top slab", 10.0), Pair("Brickwork & plaster", 10.0), Pair("Flooring & finishing", 10.0), Pair("Possession", 10.0))


}
