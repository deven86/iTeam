import SwiftUI

/// Every module in the Module Store. New modules are added here; chat itself is always free.
/// Paid modules are monthly StoreKit 2 subscriptions verified on the device. If one lapses,
/// its data stays readable and exportable — nothing is locked away or deleted.
struct ModuleInfo: Identifiable {
    enum Availability { case included, paid, comingSoon }

    /// Screens shown as previews on the module's page.
    enum Preview: Hashable {
        case taskDashboard, taskForm, proForm, careDashboard, medicineForm
        case taskList, approval, expenses, poll
        case recurring, templates, reports
        case careToday, careEvent, careVault
        case workspaces, library, assistant
        case gymDashboard, gymForm, gymSessions
        case mindDashboard, mindForm, mindPlayer
        case doctorDashboard, prescriptionForm
        case bizDashboard(String), bizForm(String)
        case eventsDashboard, eventForm, roomsDashboard, roomChat, safetyDashboard, meetingDashboard, meetingForm, meetingMinutes
        case attDashboard, attMember, attKiosk, attEmployee
        case finDashboard, finForm, finPro
        case surveyDashboard, surveyForm
        case crmDashboard, crmForm
        case socDashboard, socGate
        case buildDashboard, buildForm, buildStock, buildFSI
    }

    let id: String
    let title: String
    let tagline: String
    let icon: String
    let colors: [UInt32]
    let availability: Availability
    let productID: String?
    /// Shown before the App Store price loads.
    let fallbackPrice: String
    let problems: [String]
    let benefits: [String]
    let previews: [Preview]
    let note: String
}

@MainActor
final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()

    static let businessTasks = ModuleInfo(
        id: "business-tasks", title: "Business Tasks",
        tagline: "Turn any message into work that gets done.",
        icon: "checklist", colors: [0x28BEE6, 0x3A5BD9], availability: .included, productID: nil, fallbackPrice: "Free",
        problems: ["Work gets lost in long chat threads",
                   "Nobody knows who is doing what, or by when",
                   "Approvals and spending are scattered across calls and slips of paper"],
        benefits: ["Long-press a message → Create Business Task, with the chat linked",
                   "Assign people, set due dates and reminders, track each person's part",
                   "Approval requests with notes and approved amounts",
                   "Expenses with photos of bills and vouchers, against the approved budget",
                   "Polls to decide quickly"],
        previews: [.taskDashboard, .taskForm, .taskList, .approval, .expenses, .poll],
        note: "Included free with iTeam.")

    static let businessPro = ModuleInfo(
        id: "business-pro", title: "Business Tasks Pro",
        tagline: "Repeat work automatically and see how the team is doing.",
        icon: "chart.bar.doc.horizontal.fill", colors: [0x7850F0, 0xC2378C], availability: .paid,
        productID: Store.proProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Recreating the same weekly or monthly tasks by hand",
                   "Typing the same checklist every time a new case, client or job starts",
                   "No clear picture of who finished what, what is overdue and what was spent"],
        benefits: ["Recurring tasks: daily, weekly or monthly — the next one appears when you finish",
                   "Templates: save any task with its checklist and start new ones in one tap",
                   "Reports: done, open and overdue per person; expenses by category and month",
                   "Export reports and expenses to Excel (CSV) to share or file"],
        previews: [.reports, .proForm, .recurring, .templates],
        note: "Only the person who sets up recurring tasks and templates needs Pro; everyone can work on them.")

    static let iLifeCare = ModuleInfo(
        id: "ilife-care", title: "iLife Care",
        tagline: "Look after family health together.",
        icon: "heart.text.square.fill", colors: [0xFF8A5B, 0xE5486B], availability: .included,
        productID: nil, fallbackPrice: "Free",
        problems: ["Missed or double doses when several people look after one person",
                   "Injury and recovery updates lost in family chats",
                   "Reports and prescriptions scattered across phones and paper files"],
        benefits: ["Medicine schedule with reminders on everyone's phone — Taken or Skip",
                   "The whole group is alerted when a dose is skipped or a new event is logged",
                   "Injuries and major health events with severity and recovery progress",
                   "Medical vault for reports, prescriptions, X-rays and insurance",
                   "Doctors write prescriptions in Care; patients accept them straight into reminders — free for both",
                   "Blood group, allergies, conditions and emergency contact in one place"],
        previews: [.careDashboard, .medicineForm, .careToday, .careEvent, .careVault],
        note: "Free for everyone — caring for family and patients is never charged.")

    static let doctorPatient = ModuleInfo(
        id: "doctor-patient", title: "Doctor & Patient",
        tagline: "Prescriptions that land straight in your Care reminders.",
        icon: "stethoscope", colors: [0x36D1DC, 0x5B86E5], availability: .included,
        productID: nil, fallbackPrice: "Free",
        problems: ["Paper prescriptions get lost and doses are misread",
                   "Patients forget when to take which medicine",
                   "Doctors don't know if the patient actually started the treatment"],
        benefits: ["Doctor writes the prescription in the chat: medicines, dose, times, days",
                   "Patient taps Accept — medicines go into Care with reminders automatically",
                   "Doctor sees Waiting / Accepted / Declined for every prescription",
                   "Next visit date, advice and notes kept with each prescription",
                   "PDF prescription to print or share, end-to-end encrypted"],
        previews: [.doctorDashboard, .prescriptionForm],
        note: "Free for both doctor and patient — always.")

    static func biz(_ id: String, _ spec: BizSpec, tagline: String, product: String?, problems: [String], benefits: [String], note: String) -> ModuleInfo {
        ModuleInfo(id: id, title: spec.title, tagline: tagline, icon: spec.icon, colors: spec.colors,
                   availability: product == nil ? .included : .paid, productID: product,
                   fallbackPrice: product == nil ? "Free" : "₹99 / $0.99 a month",
                   problems: problems, benefits: benefits, previews: [.bizDashboard(spec.module), .bizForm(spec.module)], note: note)
    }

    static let petCare = biz("petcare", BizSpecs.petcare, tagline: "Vaccinations, deworming, feeding, medicines, vet visits and grooming — synced to iLife Care.",
        product: Store.petCareProductID,
        problems: ["Missed boosters and deworming dates", "Who fed the dog? Did anyone give the medicine?", "Vet papers scattered everywhere"],
        benefits: ["Every pet automatically appears in free iLife Care, with medicine and feeding reminders for the whole family",
                   "Vaccination and deworming due dates with reminders", "Vet visits with diagnosis, cost and reports attached",
                   "Grooming, training and weight log", "Costs flow into Finance", "Vets and trainers: link the pet parent — they see only their pet"],
        note: "Professional module: only the pet owner or vet pays. Family and pet parents see shared pets free — and always in iLife Care.")

    static let travel = biz("travel", BizSpecs.travel, tagline: "Plan trips together — days, bookings, packing and expenses.",
        product: nil,
        problems: ["Tickets and hotel details scattered across chats and emails", "Nobody knows the day plan", "Forgotten items and messy expense splits"],
        benefits: ["Trip with day-by-day plan", "Flights, trains, hotels and cabs with confirmation numbers", "Shared packing checklist",
                   "Trip expenses with who paid", "Share the trip in your group — everyone sees it live", "Trip PDF to print"],
        note: "Completely free.")

    static let events = ModuleInfo(
        id: "events", title: "Events", tagline: "Invite a chat or group — Going, Maybe or Can't.",
        icon: "party.popper.fill", colors: [0xF953C6, 0xB91D73], availability: .included, productID: nil, fallbackPrice: "Free",
        problems: ["Counting who is coming over chat messages", "People forgetting the date and place"],
        benefits: ["Invite any chat or group in one step", "Going / Maybe / Can't with a live count", "Reminder 1 hour before",
                   "Add to Apple Calendar", "Guest list PDF"],
        previews: [.eventsDashboard, .eventForm], note: "Free for everyone.")

    static let rooms = ModuleInfo(
        id: "rooms", title: "Rooms", tagline: "Public chat rooms with a room name — reveal only when you both agree.",
        icon: "person.3.sequence.fill", colors: [0x7F7FD5, 0x86A8E7], availability: .included, productID: nil, fallbackPrice: "Free",
        problems: ["Meeting people with the same interests without sharing your number"],
        benefits: ["Create or join topic rooms", "Room name, gender and picture only", "Private chats end-to-end encrypted",
                   "Reveal and add to iTeam only when both agree", "Report, block and a room host who can remove messages"],
        previews: [.roomsDashboard, .roomChat], note: "Free. 18+ only.")

    static let safety = ModuleInfo(
        id: "safety", title: "Family Safety", tagline: "One-press SOS with your location to the people you trust.",
        icon: "sos.circle.fill", colors: [0xFF416C, 0xB31217], availability: .included, productID: nil, fallbackPrice: "Free",
        problems: ["In an emergency there is no time to type", "Family doesn't know you reached safely"],
        benefits: ["Hold SOS for 2 seconds — location goes to your emergency chats", "“I'm safe” in one tap", "Check In with arrival alerts", "Call 112 shortcut"],
        previews: [.safetyDashboard], note: "Free for everyone.")

    static let khata = biz("khata", BizSpecs.khata, tagline: "Udhaar khata for shops — who owes what, with UPI reminders.",
        product: Store.khataProductID,
        problems: ["Credit written in a notebook gets lost or disputed", "Awkward to remind customers for money", "No idea of total money pending"],
        benefits: ["Customer-wise credit and payments with running balance", "Ask for payment with your UPI link in one tap",
                   "Link a customer on iTeam and they see their own khata live", "Statement PDF to share", "Total to collect on the dashboard"],
        note: "Only the shop owner pays. Customers never buy it — they just see their own khata.")
    static let tuition = biz("tuition", BizSpecs.tuition, tagline: "Students, attendance, fees and homework — parents see their child's.",
        product: Store.tuitionProductID,
        problems: ["Fee follow-ups with every parent", "Attendance kept on paper", "Parents keep asking about homework and progress"],
        benefits: ["Student list by class/batch", "Attendance, fees due/paid, homework, test marks", "Fee reminders with UPI link",
                   "Parents linked on iTeam see only their child's records", "Progress statement PDF"],
        note: "Only the teacher or institute pays. Parents never buy it.")
    static let rent = biz("rent", BizSpecs.rent, tagline: "Tenants, rent due, payments and repairs in one place.",
        product: Store.rentProductID,
        problems: ["Chasing rent every month", "No record of who paid when", "Repair requests lost in calls"],
        benefits: ["Tenants with monthly rent and next due date", "Rent charges, payments received, receipts as PDF",
                   "Maintenance requests with status", "Tenants on iTeam see their own rent and requests"],
        note: "Only the owner or property manager pays. Tenants never buy it.")
    static let legal = biz("legal", BizSpecs.legal, tagline: "Matters, hearing dates and client updates for advocates.",
        product: Store.legalProductID,
        problems: ["Missing hearing dates across many courts", "Clients calling for every update", "Fee tracking across matters"],
        benefits: ["Matters with court, case number and stage", "Hearings with reminders an hour before",
                   "Client updates shared with the client on iTeam", "Fees due per matter, statement PDF"],
        note: "Only the advocate pays. Clients never buy it — they see only their own matter.")
    static let clinic = biz("clinic", BizSpecs.clinic, tagline: "Appointments, visit notes and bills for small clinics.",
        product: Store.clinicProductID,
        problems: ["Appointment book on paper", "Patients forgetting visits", "Visit history scattered"],
        benefits: ["Patients with history", "Appointments with status and reminders", "Visit notes and bills",
                   "Patients on iTeam see their own appointments", "Prescriptions stay free in Doctor & Patient"],
        note: "Only the clinic pays. Patients are always free.")
    static let kids = biz("kids", BizSpecs.kids, tagline: "School, vaccinations, fees and timetable — shared with your partner.",
        product: nil,
        problems: ["Missed vaccinations and school deadlines", "Both parents not knowing the same things"],
        benefits: ["Each child with school, class and health notes", "Vaccination schedule with reminders", "School events, fees and weekly timetable",
                   "Link your partner and you both see the same records"],
        note: "Free for every family.")
    static let bills = biz("bills", BizSpecs.bills, tagline: "Never miss a bill, EMI, insurance or PUC renewal.",
        product: nil,
        problems: ["Late fees for forgotten bills", "Insurance and PUC expiring unnoticed"],
        benefits: ["Bills and renewals with due dates and reminders", "Repeating monthly, quarterly or yearly", "Mark paid with a swipe — the next one is created"],
        note: "Free for everyone.")

    static let attendance = ModuleInfo(
        id: "attendance", title: "Attendance",
        tagline: "Punch in by phone, selfie + location, rotating QR or kiosk — with leaves, holidays and Tally export.",
        icon: "person.badge.clock.fill", colors: [0x11998E, 0x38EF7D], availability: .included,
        productID: Store.attendanceProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Paper registers and buddy-punching", "Arguments about late marks, half days and leave",
                   "Month-end: counting days by hand for salary and Tally"],
        benefits: ["Owner sets duty time, grace and half-day limit — Present, Grace, Late, Half day and Absent are worked out automatically",
                   "Employees on iTeam punch in and out on their own phone: one tap, selfie, location check or the rotating office QR",
                   "People without iTeam: kiosk on your phone or iPad with PIN and selfie, or marked by the owner/admin",
                   "Leave requests with reason, attachments, paid/unpaid — approved leave shows on the calendar",
                   "Holidays (owner approves admin entries); admins' changes to entries need the owner's approval",
                   "Live dashboard: present, late, absent, on leave, and what needs attention",
                   "Monthly register PDF, Excel (CSV) and Tally XML; payable days ready for salary"],
        previews: [.attDashboard, .attMember, .attKiosk, .attEmployee],
        note: "Only the owner (employer) pays. Admins and employees never pay — employees see only their own attendance.")

    static let finance = ModuleInfo(
        id: "finance", title: "Finance",
        tagline: "Income and expenses — personal or per company — with money from every module in one place.",
        icon: "indianrupeesign.circle.fill", colors: [0x0BA360, 0x3CBA92], availability: .included,
        productID: nil, fallbackPrice: "Free",
        problems: ["Money scattered across notebooks, UPI apps and modules", "No idea where the month's money went"],
        benefits: ["Add income, expenses and refunds with receipt photos in seconds",
                   "Personal book plus a book for each company you own or manage",
                   "Fees, rent, khata payments, bills, trip costs and task expenses from other modules appear automatically",
                   "Monthly income, expenses and net, by category; reminders for what's due",
                   "PDF report with charts and Excel (CSV) export"],
        previews: [.finDashboard, .finForm],
        note: "Core module — free for life.")

    static let financePro = ModuleInfo(
        id: "finance-pro", title: "Finance Pro",
        tagline: "Cheques, bounce follow-ups, recurring payments, approvals, bank statements, savings and Tally.",
        icon: "building.columns.fill", colors: [0x134E5E, 0x71B280], availability: .paid,
        productID: Store.financeProProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Cheques that bounce and nobody follows up", "Staff paying without the owner's OK", "Typing bank statements into Tally"],
        benefits: ["Cheque tracking: issued, deposited, cleared, bounced — with daily follow-up reminders",
                   "Recurring payments (rent, salaries, EMIs, subscriptions) that move forward when paid",
                   "Admins ask for payment approval (cheque, RTGS, UPI); only the owner approves",
                   "Import a bank statement (CSV) — matching entries are ticked, the rest added in one tap",
                   "Savings goals with progress",
                   "Tally XML export of receipts and payments"],
        previews: [.finPro, .finDashboard],
        note: "Professional module: only the master account pays; everyone else in the company uses it free.")

    static let survey = ModuleInfo(
        id: "survey", title: "Survey",
        tagline: "Land, building, online and poll surveys — with photos, videos and GPS, online or offline.",
        icon: "list.clipboard.fill", colors: [0x6366F1, 0x10B981], availability: .paid,
        productID: Store.surveyProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Field surveys on paper, photos lost on someone's phone", "Google Forms can't do GPS, site photos or offline work"],
        benefits: ["Ready templates: land survey, building survey, online survey, poll",
                   "Questions with text, numbers, choices, ratings, photos, video, GPS location and dates",
                   "Online: send to a chat or group — answers come privately to you",
                   "Offline field mode: collect one response per plot, flat or person, even without internet",
                   "Live results; PDF report with charts and Excel (CSV) export"],
        previews: [.surveyDashboard, .surveyForm],
        note: "Professional module: only the survey creator pays. People who answer never pay.")

    static let crm = ModuleInfo(
        id: "crm", title: "CRM",
        tagline: "Leads, follow-ups and quotes for every company you work in — managed together in team groups.",
        icon: "person.crop.circle.badge.checkmark", colors: [0x2563EB, 0x0EA5E9], availability: .paid,
        productID: Store.crmProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Leads scattered across WhatsApp, diaries and Excel", "Nobody knows who called the client last or what was quoted",
                   "Follow-ups missed, deals lost"],
        benefits: ["Unlimited companies — the same companies as Attendance, switch with one tap",
                   "CRM team groups: a pod of colleagues manages its leads together, every change logged in the chat",
                   "Pipeline: New → Contacted → Proposal → Negotiation → Won / Lost with deal value and probability",
                   "Calls, visits, notes and photos on each lead's timeline",
                   "Send a quote to the client on iTeam — they accept or decline in their chat",
                   "Follow-up reminders, PDF pipeline report with charts, AI follow-up drafts"],
        previews: [.crmDashboard, .crmForm],
        note: "Professional module: only the company owner / CRM subscriber pays. Team members and linked clients use it free.")

    static let society = ModuleInfo(
        id: "society", title: "Society & Apartment",
        tagline: "Maintenance bills, complaints, notices and a gate & reception kiosk with visitor approvals and staff attendance.",
        icon: "building.2.crop.circle.fill", colors: [0x0F766E, 0x14B8A6], availability: .paid,
        productID: Store.societyProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Guards call flat owners for every delivery", "Maintenance collected in cash with no record", "Complaints lost in a WhatsApp group"],
        benefits: ["Gate & reception kiosk: guard logs a visitor, the flat owner taps Allow / Deny on their phone",
                   "Guards, housekeeping and reception punch attendance on the same kiosk (PIN)",
                   "Monthly maintenance bills for every flat; owners pay by UPI and send the reference, committee verifies",
                   "Complaints with photos and status; notices to every flat",
                   "Flat owners must be on iTeam — everything reaches them privately and encrypted",
                   "PDF dues report with charts"],
        previews: [.socDashboard, .socGate],
        note: "Professional module: only the society committee subscriber pays. Flat owners, guards and staff use it free.")

    static let build = ModuleInfo(
        id: "build", title: "Builder & Infra",
        tagline: "Run a construction or real-estate company: projects, buildings, units, sales, partners, stock with QR stickers, machines, tests, approvals and an easy FSI calculator.",
        icon: "building.columns.fill", colors: [0xF59E0B, 0xB45309], availability: .paid,
        productID: Store.buildProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Booking forms, agreements and payment follow-ups spread across files and WhatsApp",
                   "Cement, steel and sand go missing — nobody knows the real stock",
                   "Machines idle or rented without a log; service and insurance dates missed",
                   "Approvals, tests and disputes tracked in someone's head",
                   "Partners and investors unsure of their share"],
        benefits: ["Company → projects → buildings → wings → floors → units, generated in one tap; residential, commercial, hospital, hotel, school and more",
                   "Sales with full buyer KYC, agreement, stamp duty, registration, home-loan status and a construction-linked payment schedule",
                   "Every payment lands in the company's Finance book; buyers see only their own unit and payments",
                   "Partners & investors (investment and profit share %), landowners, rehab tenants with old and commuted area",
                   "Architect, RCC consultant, engineers, liaison officer and contractors with appointment details",
                   "Stock & fixed assets with printable QR stickers — scan with the camera or from a photo",
                   "Machines: Poclain, JCB, roller, mixer, breaker, cranes and 70+ more, with daily logs, fuel and service reminders",
                   "Quality tests, government approvals & inspections, disputes (send to Legal Matters), land & survey records",
                   "Group tasks, group approvals, events, bills, rewards, site reports to Views, CRM enquiries, staff attendance",
                   "Secure vault for agreements and title documents — only on your devices, opened with Face ID",
                   "FSI calculator: Maharashtra UDCPR-2020 tables, plus FAR / plot-ratio for any country"],
        previews: [.buildDashboard, .buildForm, .buildStock, .buildFSI],
        note: "Professional module: only the company owner pays. Team members, buyers, partners and rehab tenants use it free.")

    static let gymTraining = ModuleInfo(
        id: "gym-training", title: "Gym & Training",
        tagline: "Memberships, trainer sessions and payments — shared with your trainer, clients or family.",
        icon: "dumbbell.fill", colors: [0x4FD1C5, 0x2B6CB0], availability: .paid,
        productID: Store.gymProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Forgetting when the gym membership runs out",
                   "Arguments over how many personal-training sessions are done and how many are paid",
                   "Fees, supplement bills and receipts scattered across UPI apps and paper"],
        benefits: ["Full iLife fitness: exercise library with guides, workout logging with sets & reps, plans, live workout timer",
                   "Nutrition: meals with photos, water, custom foods, daily macros; supplements with dose reminders",
                   "Body: transformation photos, side-by-side compare, measurements",
                   "Add yourself, family or clients — with relations like Client, or your own custom relation",
                   "Membership with days left, renewal warnings, directions and call buttons",
                   "One-tap “Trained today” — sessions counted per training day, visible to trainer and client",
                   "Training balance: sessions paid vs done, so both sides always agree",
                   "Payments with receipt photos; monthly and yearly spend; PDF statement to share"],
        previews: [.gymDashboard, .gymForm, .gymSessions],
        note: "Only the trainer (or the person managing the gym records) pays. Clients never buy it: they just see the updates about themselves.")

    static let mindfulness = ModuleInfo(
        id: "mindfulness", title: "Mindfulness",
        tagline: "Guided meditation, breathing and sleep — in English or Hindi.",
        icon: "leaf.fill", colors: [0x7ED6B2, 0x3B8D99], availability: .paid,
        productID: Store.mindProductID, fallbackPrice: "₹99 / $0.99 a month",
        problems: ["Stress and racing thoughts after a long day",
                   "Trouble falling asleep",
                   "No time for a class — and most apps are expensive or ad-filled"],
        benefits: ["Guided sessions read aloud: calm, focus, sleep, gratitude, body scan and more",
                   "Breathing patterns with on-screen pacing (box, 4-7-8, coherent breathing)",
                   "Soundscapes — rain, ocean, singing bowls, binaural — or your own audio file",
                   "English and Hindi voices; optional natural voices with your own Google key",
                   "“Make one for me”: AI writes a session for how you feel right now",
                   "Mood before and after, streaks, minutes and history"],
        previews: [.mindDashboard, .mindForm, .mindPlayer],
        note: "Personal: your sessions and moods stay on your devices.")

    static let teamWorkspace = ModuleInfo(
        id: "team-workspace", title: "Team Workspace",
        tagline: "Keep office, trust and family separate.",
        icon: "building.2.fill", colors: [0x4CD38A, 0x1E9A6E], availability: .comingSoon, productID: nil, fallbackPrice: "Coming soon",
        problems: ["Work, trust and family chats and tasks mixed in one list", "No record of who changed what"],
        benefits: ["Separate workspaces with their own chats, tasks and care profiles", "More roles and an audit history"],
        previews: [.workspaces], note: "In development.")

    static let filesKnowledge = ModuleInfo(
        id: "files-knowledge", title: "Files & Knowledge",
        tagline: "Every document your group shares, in one library.",
        icon: "folder.fill", colors: [0xFFC94D, 0xF07B2C], availability: .comingSoon, productID: nil, fallbackPrice: "Coming soon",
        problems: ["Hunting through months of chat for one PDF"],
        benefits: ["Folders and search across chats and tasks", "Pinned important documents"],
        previews: [.library], note: "In development.")

    static let aiAssistant = ModuleInfo(
        id: "ai-assistant", title: "AI Assistant",
        tagline: "Catch up in seconds — privately, on your iPhone.",
        icon: "sparkles", colors: [0xB57CFF, 0x6F5BD6], availability: .comingSoon, productID: nil, fallbackPrice: "Coming soon",
        problems: ["Too many unread messages to read", "Tasks hidden inside conversations"],
        benefits: ["“What did I miss?” summaries", "Suggested tasks from messages", "Runs on-device with Apple Intelligence (iPhone 15 Pro and newer)"],
        previews: [.assistant], note: "In development.")

    static let all: [ModuleInfo] = [businessTasks, businessPro, iLifeCare, travel, events, safety, rooms, bills, kids, khata, tuition, rent, legal, clinic, petCare, survey, crm, society, build, attendance, finance, financePro, gymTraining, mindfulness, teamWorkspace]

    @Published private var enabled: [String: Bool]
    /// Modules the user wants in the iPhone bottom bar, in order (Router.TabID raw values).
    @Published private(set) var pinned: [String]
    /// The iPhone bar holds Chats, up to this many modules, Modules and Settings — five in all,
    /// the most iOS shows before it hides tabs behind “More”.
    static let maxPinned = 3

    private init() {
        enabled = UserDefaults.standard.dictionary(forKey: "modules.enabled") as? [String: Bool] ?? [:]
        pinned = UserDefaults.standard.stringArray(forKey: "modules.pinned2") ?? ["views", "tasks", "activity"]
    }

    /// Which of the available module tabs go in the bar: the user's pins first, then the rest in order.
    func barTabs(available: [Router.TabID]) -> [Router.TabID] {
        let pins = pinned.compactMap(Router.TabID.init(rawValue:)).filter(available.contains)
        let rest = available.filter { !pins.contains($0) }
        return Array((pins + rest).prefix(Self.maxPinned))
    }

    func setPins(_ tabs: [Router.TabID]) {
        pinned = tabs.map(\.rawValue)
        UserDefaults.standard.set(pinned, forKey: "modules.pinned2")
    }

    /// The user has the right to use the module: included ones always; paid ones with an active subscription.
    func isEntitled(_ m: ModuleInfo) -> Bool {
        switch m.availability {
        case .included: true
        case .paid: m.productID.map { Store.shared.isUnlocked($0) } ?? false
        case .comingSoon: false
        }
    }

    /// Entitled and switched on in Settings.
    func isOn(_ m: ModuleInfo) -> Bool { isEntitled(m) && isVisible(m) }

    /// Shown in the app (paid modules show their store page until subscribed).
    /// Free extras are added from the Module Store ("Get"); core and paid ones start on.
    /// Core modules show for everyone; professional modules start hidden and are added from the Module Store.
    static let optIn: Set<String> = ["survey", "crm", "society", "build", "petcare", "finance-pro", "business-pro", "gym-training", "mindfulness", "khata", "tuition", "rent", "legal", "clinic"]
    func isVisible(_ m: ModuleInfo) -> Bool { enabled[m.id] ?? !Self.optIn.contains(m.id) }

    func setOn(_ m: ModuleInfo, _ on: Bool) {
        enabled[m.id] = on
        UserDefaults.standard.set(enabled, forKey: "modules.enabled")
    }
}
