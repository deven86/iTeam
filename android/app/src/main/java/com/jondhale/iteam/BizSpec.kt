package com.jondhale.iteam

// Generated from the iPhone's BizSpecs.swift — the shared record engine (Khata, Tuition, Rent, Legal, Clinic, Bills, Kids, Travel, Pet Care).

enum class BK { title, subtitle, phone, amount, date, due, status, notes }

data class BF(val key: BK, val label: String, val options: List<String> = emptyList())

data class BizKind(val id: String, val label: String, val plural: String, val icon: String, val fields: List<BF>,
                   val statuses: List<String> = emptyList(), val doneStatuses: List<String> = emptyList(), val linkable: Boolean = false,
                   val sign: Int = 0, val countWhen: String? = null, val clientCanAdd: Boolean = false, val clientAnswers: Boolean = false,
                   val extras: List<String> = emptyList()) {
    fun has(k: BK) = fields.any { it.key == k }
    fun label(k: BK) = fields.firstOrNull { it.key == k }?.label
}

data class BizSpec(val module: String, val tab: String, val title: String, val icon: String, val colors: List<Long>, val parent: BizKind?,
                   val children: List<BizKind>, val balanceLabel: String, val clientWord: String, val paid: Boolean = true) {
    fun kind(id: String) = if (parent?.id == id) parent else children.firstOrNull { it.id == id }
    val flat: BizKind? get() = if (parent == null) children.firstOrNull() else null
}

private fun longListOf(vararg v: Long) = v.toList()

object BizSpecs {
    val khata = BizSpec(
        module = "khata", tab = "khata", title = "Shop & Khata", icon = "indianrupeesign.circle.fill", colors = longListOf(0xFFF7971E, 0xFFFFD200),
        parent = BizKind(id = "customer", label = "Customer", plural = "Customers", icon = "person.crop.circle",
                        fields = listOf(BF(key = BK.title, label = "Name"), BF(key = BK.phone, label = "Phone"), BF(key = BK.notes, label = "Notes")),
                        linkable = true),
        children = listOf(
            BizKind(id = "gave", label = "You gave (credit)", plural = "Credit", icon = "arrow.up.circle.fill",
                    fields = listOf(BF(key = BK.amount, label = "Amount"), BF(key = BK.date, label = "Date"), BF(key = BK.notes, label = "Items / note")), sign = 1),
            BizKind(id = "got", label = "You got (payment)", plural = "Payments", icon = "arrow.down.circle.fill",
                    fields = listOf(BF(key = BK.amount, label = "Amount"), BF(key = BK.date, label = "Date"), BF(key = BK.subtitle, label = "Mode", options = listOf("Cash", "UPI", "Card", "Bank")), BF(key = BK.notes, label = "Note")), sign = -1),
        ),
        balanceLabel = "To collect", clientWord = "customer")

    val tuition = BizSpec(
        module = "tuition", tab = "tuition", title = "Tuition & Classes", icon = "graduationcap.fill", colors = longListOf(0xFF00C9FF, 0xFF92FE9D),
        parent = BizKind(id = "student", label = "Student", plural = "Students", icon = "person.crop.circle",
                        fields = listOf(BF(key = BK.title, label = "Student name"), BF(key = BK.subtitle, label = "Class / batch"), BF(key = BK.phone, label = "Parent phone"), BF(key = BK.notes, label = "Notes")),
                        linkable = true),
        children = listOf(
            BizKind(id = "attendance", label = "Attendance", plural = "Attendance", icon = "checkmark.circle",
                    fields = listOf(BF(key = BK.date, label = "Date"), BF(key = BK.status, label = "Status")), statuses = listOf("Present", "Absent", "Late")),
            BizKind(id = "fee", label = "Fee", plural = "Fees", icon = "indianrupeesign.circle",
                    fields = listOf(BF(key = BK.title, label = "For (e.g. November)"), BF(key = BK.amount, label = "Amount"), BF(key = BK.due, label = "Due date"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("Due", "Paid"), doneStatuses = listOf("Paid"), sign = 1, countWhen = "Due"),
            BizKind(id = "homework", label = "Homework", plural = "Homework", icon = "book.closed",
                    fields = listOf(BF(key = BK.title, label = "Homework"), BF(key = BK.due, label = "Due"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Details")),
                    statuses = listOf("Assigned", "Done"), doneStatuses = listOf("Done"), clientAnswers = true),
            BizKind(id = "progress", label = "Test / progress", plural = "Progress", icon = "chart.line.uptrend.xyaxis",
                    fields = listOf(BF(key = BK.title, label = "Test / topic"), BF(key = BK.subtitle, label = "Marks"), BF(key = BK.date, label = "Date"), BF(key = BK.notes, label = "Remarks"))),
        ),
        balanceLabel = "Fees due", clientWord = "parent")

    val rent = BizSpec(
        module = "rent", tab = "rent", title = "Property & Rent", icon = "house.and.flag.fill", colors = longListOf(0xFF8E2DE2, 0xFF4A00E0),
        parent = BizKind(id = "tenant", label = "Tenant", plural = "Tenants", icon = "person.crop.circle",
                        fields = listOf(BF(key = BK.title, label = "Tenant name"), BF(key = BK.subtitle, label = "Property / flat"), BF(key = BK.amount, label = "Monthly rent"),
                                 BF(key = BK.due, label = "Next rent due"), BF(key = BK.date, label = "Agreement start"), BF(key = BK.phone, label = "Phone"),
                                 BF(key = BK.notes, label = "Deposit, agreement…")),
                        linkable = true, extras = listOf("Yearly raise %")),
        children = listOf(
            BizKind(id = "charge", label = "Rent / charge", plural = "Charges", icon = "doc.text",
                    fields = listOf(BF(key = BK.title, label = "For (e.g. Rent Dec)"), BF(key = BK.amount, label = "Amount"), BF(key = BK.due, label = "Due"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("Due", "Paid"), doneStatuses = listOf("Paid"), sign = 1, countWhen = "Due"),
            BizKind(id = "payment", label = "Payment received", plural = "Payments", icon = "arrow.down.circle.fill",
                    fields = listOf(BF(key = BK.amount, label = "Amount"), BF(key = BK.date, label = "Date"), BF(key = BK.subtitle, label = "Mode", options = listOf("Cash", "UPI", "Bank", "Cheque")), BF(key = BK.notes, label = "Note"))),
            BizKind(id = "issue", label = "Maintenance / damage / complaint", plural = "Maintenance, damage & complaints", icon = "wrench.and.screwdriver",
                    fields = listOf(BF(key = BK.title, label = "Problem"), BF(key = BK.subtitle, label = "Type", options = listOf("Maintenance", "Damage", "Complaint")),
                             BF(key = BK.date, label = "Reported"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Details")),
                    statuses = listOf("Open", "In progress", "Fixed"), doneStatuses = listOf("Fixed"), clientCanAdd = true),
            BizKind(id = "agreement", label = "Agreement / document", plural = "Agreements & documents", icon = "doc.text.magnifyingglass",
                    fields = listOf(BF(key = BK.title, label = "Document"), BF(key = BK.date, label = "Date"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Notes")),
                    statuses = listOf("Waiting for tenant", "Accepted", "Declined"), doneStatuses = listOf("Accepted"), clientAnswers = true),
        ),
        balanceLabel = "Rent due", clientWord = "tenant")

    val legal = BizSpec(
        module = "legal", tab = "legal", title = "Legal Matters", icon = "building.columns.fill", colors = longListOf(0xFF232526, 0xFF414345),
        parent = BizKind(id = "case", label = "Matter", plural = "Matters", icon = "folder.fill",
                        fields = listOf(BF(key = BK.title, label = "Matter / parties"), BF(key = BK.subtitle, label = "Court & case no."), BF(key = BK.phone, label = "Client phone"),
                                 BF(key = BK.status, label = "Stage"), BF(key = BK.notes, label = "Facts / notes")),
                        statuses = listOf("Filing", "Pending", "Arguments", "Reserved", "Disposed"), doneStatuses = listOf("Disposed"), linkable = true),
        children = listOf(
            BizKind(id = "hearing", label = "Hearing", plural = "Hearings", icon = "calendar",
                    fields = listOf(BF(key = BK.date, label = "Date"), BF(key = BK.title, label = "Purpose"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "What happened / next step")),
                    statuses = listOf("Upcoming", "Done", "Adjourned"), doneStatuses = listOf("Done", "Adjourned")),
            BizKind(id = "update", label = "Client update", plural = "Updates", icon = "text.bubble",
                    fields = listOf(BF(key = BK.title, label = "Update"), BF(key = BK.date, label = "Date"), BF(key = BK.notes, label = "Details"))),
            BizKind(id = "question", label = "Client question", plural = "Client questions", icon = "questionmark.bubble",
                    fields = listOf(BF(key = BK.title, label = "Question"), BF(key = BK.date, label = "Asked"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Answer")),
                    statuses = listOf("Open", "Answered"), doneStatuses = listOf("Answered"), clientCanAdd = true),
            BizKind(id = "approval", label = "Client approval", plural = "Approvals from client", icon = "checkmark.seal",
                    fields = listOf(BF(key = BK.title, label = "What needs the client's OK"), BF(key = BK.date, label = "Asked"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Details")),
                    statuses = listOf("Waiting for client", "Approved", "Rejected"), doneStatuses = listOf("Approved", "Rejected"), clientAnswers = true),
            BizKind(id = "vakalat", label = "e-Vakalatnama", plural = "e-Vakalatnama", icon = "signature",
                    fields = listOf(BF(key = BK.title, label = "Court & matter"), BF(key = BK.date, label = "Requested"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Advocate(s) / terms")),
                    statuses = listOf("Waiting for client", "Signed", "Declined"), doneStatuses = listOf("Signed", "Declined"), clientAnswers = true),
            BizKind(id = "fee", label = "Fee", plural = "Fees", icon = "indianrupeesign.circle",
                    fields = listOf(BF(key = BK.title, label = "For"), BF(key = BK.amount, label = "Amount"), BF(key = BK.due, label = "Due"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("Due", "Paid"), doneStatuses = listOf("Paid"), sign = 1, countWhen = "Due"),
        ),
        balanceLabel = "Fees due", clientWord = "client")

    val clinic = BizSpec(
        module = "clinic", tab = "clinic", title = "Clinic Desk", icon = "cross.case.fill", colors = longListOf(0xFF11998E, 0xFF38EF7D),
        parent = BizKind(id = "patient", label = "Patient", plural = "Patients", icon = "person.crop.circle",
                        fields = listOf(BF(key = BK.title, label = "Patient name"), BF(key = BK.subtitle, label = "Age / gender"), BF(key = BK.phone, label = "Phone"), BF(key = BK.notes, label = "History, allergies")),
                        linkable = true),
        children = listOf(
            BizKind(id = "appointment", label = "Appointment", plural = "Appointments", icon = "calendar.badge.clock",
                    fields = listOf(BF(key = BK.date, label = "Date & time"), BF(key = BK.title, label = "Reason"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("Booked", "Arrived", "Done", "Missed", "Cancelled"), doneStatuses = listOf("Done", "Missed", "Cancelled")),
            BizKind(id = "visit", label = "Visit note", plural = "Visit notes", icon = "note.text",
                    fields = listOf(BF(key = BK.date, label = "Date"), BF(key = BK.title, label = "Complaint"), BF(key = BK.notes, label = "Findings & advice"))),
            BizKind(id = "bill", label = "Bill", plural = "Bills", icon = "indianrupeesign.circle",
                    fields = listOf(BF(key = BK.title, label = "For"), BF(key = BK.amount, label = "Amount"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("Due", "Paid"), doneStatuses = listOf("Paid"), sign = 1, countWhen = "Due"),
        ),
        balanceLabel = "Bills due", clientWord = "patient")

    val bills = BizSpec(
        module = "bills", tab = "bills", title = "Bills & Renewals", icon = "calendar.badge.exclamationmark", colors = longListOf(0xFFFF512F, 0xFFDD2476),
        parent = nil,
        children = listOf(
            BizKind(id = "bill", label = "Bill / renewal", plural = "Bills", icon = "doc.text",
                    fields = listOf(BF(key = BK.title, label = "What (electricity, insurance, PUC…)"), BF(key = BK.amount, label = "Amount"), BF(key = BK.due, label = "Due date"),
                             BF(key = BK.subtitle, label = "Repeats", options = listOf("Once", "Monthly", "Every 3 months", "Yearly")), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Account no., notes")),
                    statuses = listOf("Due", "Approving", "Paid"), doneStatuses = listOf("Paid"), sign = 1, countWhen = "Due"),
        ),
        balanceLabel = "Due", clientWord = "", paid = false)

    val kids = BizSpec(
        module = "kids", tab = "kids", title = "Kids", icon = "figure.and.child.holdinghands", colors = longListOf(0xFFFDC830, 0xFFF37335),
        parent = BizKind(id = "child", label = "Child", plural = "Children", icon = "face.smiling",
                        fields = listOf(BF(key = BK.title, label = "Name"), BF(key = BK.date, label = "Birth date"), BF(key = BK.subtitle, label = "School & class"),
                                 BF(key = BK.phone, label = "School / teacher phone"), BF(key = BK.notes, label = "Allergies, blood group, notes")),
                        linkable = true),
        children = listOf(
            BizKind(id = "vaccine", label = "Vaccination", plural = "Vaccinations", icon = "syringe",
                    fields = listOf(BF(key = BK.title, label = "Vaccine"), BF(key = BK.due, label = "Due date"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Doctor / notes")),
                    statuses = listOf("Due", "Done"), doneStatuses = listOf("Done")),
            BizKind(id = "event", label = "School event", plural = "School events", icon = "calendar",
                    fields = listOf(BF(key = BK.title, label = "What (PTM, exam, trip…)"), BF(key = BK.date, label = "Date & time"), BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Notes")),
                    statuses = listOf("Upcoming", "Done"), doneStatuses = listOf("Done")),
            BizKind(id = "fee", label = "School fee", plural = "Fees", icon = "indianrupeesign.circle",
                    fields = listOf(BF(key = BK.title, label = "For"), BF(key = BK.amount, label = "Amount"), BF(key = BK.due, label = "Due"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("Due", "Paid"), doneStatuses = listOf("Paid"), sign = 1, countWhen = "Due"),
            BizKind(id = "timetable", label = "Timetable / class", plural = "Timetable", icon = "clock",
                    fields = listOf(BF(key = BK.title, label = "Class / activity"), BF(key = BK.subtitle, label = "Day", options = listOf("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")),
                             BF(key = BK.notes, label = "Time, teacher, place"))),
        ),
        balanceLabel = "Fees due", clientWord = "family member", paid = false)

    val travel = BizSpec(
        module = "travel", tab = "travel", title = "Travel Planner", icon = "airplane.departure", colors = longListOf(0xFF2193B0, 0xFF6DD5ED),
        parent = BizKind(id = "trip", label = "Trip", plural = "Trips", icon = "suitcase.rolling.fill",
                        fields = listOf(BF(key = BK.title, label = "Destination / trip name"), BF(key = BK.date, label = "Start"), BF(key = BK.due, label = "End"),
                                 BF(key = BK.subtitle, label = "Who's going"), BF(key = BK.amount, label = "Budget"), BF(key = BK.notes, label = "Notes")),
                        linkable = true),
        children = listOf(
            BizKind(id = "day", label = "Day plan", plural = "Itinerary", icon = "map",
                    fields = listOf(BF(key = BK.date, label = "Day"), BF(key = BK.title, label = "Plan (places, activities)"), BF(key = BK.notes, label = "Details, timings"))),
            BizKind(id = "booking", label = "Booking", plural = "Bookings", icon = "ticket",
                    fields = listOf(BF(key = BK.subtitle, label = "Type", options = listOf("Flight", "Train", "Bus", "Hotel", "Cab", "Activity", "Other")),
                             BF(key = BK.title, label = "Details (PNR, hotel name…)"), BF(key = BK.date, label = "Date & time"),
                             BF(key = BK.phone, label = "Confirmation / PNR no."), BF(key = BK.amount, label = "Cost"), BF(key = BK.notes, label = "Notes")), sign = 1),
            BizKind(id = "packing", label = "Packing item", plural = "Packing list", icon = "checklist",
                    fields = listOf(BF(key = BK.title, label = "Item"), BF(key = BK.subtitle, label = "Who packs it"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("To pack", "Packed"), doneStatuses = listOf("Packed")),
            BizKind(id = "expense", label = "Expense", plural = "Expenses", icon = "indianrupeesign.circle",
                    fields = listOf(BF(key = BK.title, label = "For"), BF(key = BK.amount, label = "Amount"), BF(key = BK.subtitle, label = "Paid by"), BF(key = BK.date, label = "Date")), sign = 1),
        ),
        balanceLabel = "Spent", clientWord = "travel group", paid = false)

    val petcare = BizSpec(
        module = "petcare", tab = "petcare", title = "Pet Care", icon = "pawprint.fill", colors = longListOf(0xFFEA580C, 0xFFF59E0B),
        parent = BizKind(id = "pet", label = "Pet", plural = "Pets", icon = "pawprint.circle.fill",
                        fields = listOf(BF(key = BK.title, label = "Pet name"), BF(key = BK.subtitle, label = "Species", options = listOf("Dog", "Cat", "Bird", "Rabbit", "Fish", "Other")),
                                 BF(key = BK.date, label = "Birth date"), BF(key = BK.phone, label = "Vet phone"), BF(key = BK.notes, label = "Notes, allergies, diet")),
                        linkable = true, extras = listOf("Breed", "Weight (kg)", "Microchip / tag ID")),
        children = listOf(
            BizKind(id = "vaccine", label = "Vaccination", plural = "Vaccinations", icon = "syringe",
                    fields = listOf(BF(key = BK.title, label = "Vaccine"), BF(key = BK.date, label = "Given on"), BF(key = BK.due, label = "Next booster"),
                             BF(key = BK.status, label = "Status"), BF(key = BK.notes, label = "Batch / vet")),
                    statuses = listOf("Due", "Done"), doneStatuses = listOf("Done")),
            BizKind(id = "deworming", label = "Deworming / tick & flea", plural = "Deworming", icon = "pills",
                    fields = listOf(BF(key = BK.title, label = "Treatment"), BF(key = BK.date, label = "Given on"), BF(key = BK.due, label = "Next due"), BF(key = BK.status, label = "Status")),
                    statuses = listOf("Due", "Done"), doneStatuses = listOf("Done")),
            BizKind(id = "medication", label = "Medicine", plural = "Medicines", icon = "pills.fill",
                    fields = listOf(BF(key = BK.title, label = "Medicine"), BF(key = BK.subtitle, label = "Dose"), BF(key = BK.date, label = "Daily time"), BF(key = BK.notes, label = "Instructions"))),
            BizKind(id = "feeding", label = "Feeding", plural = "Feeding", icon = "fork.knife",
                    fields = listOf(BF(key = BK.title, label = "Meal (e.g. Breakfast)"), BF(key = BK.subtitle, label = "Food & quantity"), BF(key = BK.date, label = "Daily time"))),
            BizKind(id = "vet", label = "Vet visit", plural = "Vet visits", icon = "cross.case",
                    fields = listOf(BF(key = BK.date, label = "Date"), BF(key = BK.title, label = "Reason"), BF(key = BK.amount, label = "Cost"), BF(key = BK.notes, label = "Diagnosis / advice"))),
            BizKind(id = "grooming", label = "Grooming / training", plural = "Grooming & training", icon = "scissors",
                    fields = listOf(BF(key = BK.date, label = "Date"), BF(key = BK.title, label = "What"), BF(key = BK.amount, label = "Cost"), BF(key = BK.notes, label = "Notes"))),
            BizKind(id = "weight", label = "Weight", plural = "Weight log", icon = "scalemass",
                    fields = listOf(BF(key = BK.date, label = "Date"), BF(key = BK.title, label = "Weight (kg)"))),
        ),
        balanceLabel = "Spent", clientWord = "pet parent")



    val all = listOf(khata, tuition, rent, legal, clinic, bills, kids, travel, petcare)
    fun spec(module: String) = all.firstOrNull { it.module == module }
}
