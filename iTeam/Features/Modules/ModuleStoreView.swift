import SwiftUI
import StoreKit

/// Settings → Modules: every module, what it solves, previews, price and Subscribe.
struct ModuleStoreView: View {
    @EnvironmentObject var modules: ModuleRegistry
    @ObservedObject private var store = Store.shared
    @Environment(\.look) private var look
    @State private var redeem = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Chat is always free. Add only what your team needs.")
                    .font(.subheadline).foregroundStyle(look.textSecondary)
                if store.isOwner {
                    Label("Owner — every module is free on your Apple ID", systemImage: "crown.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(look.accent)
                }
                ForEach(Array(ModuleRegistry.all.enumerated()), id: \.element.id) { i, m in
                    NavigationLink { ModuleDetailView(module: m) } label: { card(m) }
                        .buttonStyle(PressStyle())
                        .appear(i)
                }
                NavigationLink { ModuleRequestView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "lightbulb.max.fill").font(.title2).foregroundStyle(look.accent).frame(width: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Don't see what you need?").font(.headline).foregroundStyle(Color.primary)
                            Text("Request a module — tell us the problem and how it should work.").font(.caption).foregroundStyle(look.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(look.textSecondary)
                    }
                    .lookCard()
                }
                .buttonStyle(PressStyle())
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .lookScreen()
        .navigationTitle("Module Store")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Redeem code", systemImage: "giftcard") { redeem = true }
            }
        }
        .offerCodeRedemption(isPresented: $redeem) { _ in Task { await store.refresh() } }
        .task { await store.loadProducts() }
    }

    private func card(_ m: ModuleInfo) -> some View {
        HStack(spacing: 14) {
            ModuleIcon(module: m, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(m.title).font(.headline).foregroundStyle(Color.primary)
                Text(m.tagline).font(.caption).foregroundStyle(look.textSecondary).multilineTextAlignment(.leading)
                ModuleBadge(module: m)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(look.textSecondary)
        }
        .lookCard()
    }
}

struct ModuleIcon: View {
    let module: ModuleInfo
    var size: CGFloat = 56
    var body: some View {
        Image(systemName: module.icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: module.colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// "Included", "Active", "₹99 / month" or "Coming soon".
struct ModuleBadge: View {
    let module: ModuleInfo
    @ObservedObject private var store = Store.shared
    @Environment(\.look) private var look

    var body: some View {
        switch module.availability {
        case .included:
            if ModuleRegistry.shared.isVisible(module) {
                Chip(text: "Added", icon: "checkmark", color: look.success)
            } else {
                Chip(text: "Free · Get", icon: "arrow.down.circle", color: look.accent)
            }
        case .comingSoon:
            Chip(text: "Coming soon", icon: "clock", color: look.textSecondary)
        case .paid:
            if let id = module.productID, store.isUnlocked(id) {
                Chip(text: store.active.contains(id) ? "Active" : (store.isOwner ? "Owner · free" : "Unlocked for testing"),
                     icon: store.isOwner ? "crown.fill" : "checkmark.seal.fill", color: look.success)
            } else {
                Chip(text: ModuleDetailView.price(module, store), icon: "creditcard", color: look.accent)
            }
        }
    }
}

struct ModuleDetailView: View {
    let module: ModuleInfo
    @EnvironmentObject var modules: ModuleRegistry
    @ObservedObject private var store = Store.shared
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var redeem = false

    static func price(_ m: ModuleInfo, _ store: Store) -> String {
        if Store.allFree && m.productID != Store.plusProductID { return "Free" }
        if let id = m.productID, let p = store.products[id] { return "\(p.displayPrice) / month" }
        return m.fallbackPrice
    }

    private var unlocked: Bool { module.productID.map { store.isUnlocked($0) } ?? (module.availability == .included) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    ModuleIcon(module: module, size: 76)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(module.title).font(.title2.bold())
                        Text(module.tagline).font(.subheadline).foregroundStyle(look.textSecondary)
                        ModuleBadge(module: module)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(module.previews, id: \.self) { p in
                            ModulePreviewScreen(preview: p, colors: module.colors)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollClipDisabled()

                section("The problem", icon: "exclamationmark.bubble", items: module.problems, color: look.warning)
                section("How it helps", icon: "checkmark.circle.fill", items: module.benefits, color: look.success)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pricing").font(.headline)
                    HStack {
                        Text(Self.price(module, store)).font(.title3.bold())
                        Spacer()
                        if module.availability == .paid { Text("Cancel anytime").font(.caption).foregroundStyle(look.textSecondary) }
                    }
                    Text(module.note).font(.caption).foregroundStyle(look.textSecondary)
                    action
                    if let e = store.lastError { Text(e).font(.caption).foregroundStyle(look.danger) }
                    if module.availability == .paid {
                        Text("Billed monthly through your Apple ID. Auto-renews until cancelled in Settings → Apple ID → Subscriptions. Have an offer code? Tap Redeem offer code — Apple applies the free or discounted period. If a subscription ends, everything you created stays readable and exportable.")
                            .font(.caption2).foregroundStyle(look.textSecondary)
                    }
                }
                .lookCard()
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .lookScreen()
        .navigationTitle(module.title)
        .navigationBarTitleDisplayMode(.inline)
        .offerCodeRedemption(isPresented: $redeem) { _ in Task { await store.refresh() } }
    }

    @ViewBuilder
    private var action: some View {
        switch module.availability {
        case .included:
            if modules.isVisible(module) {
                Label("Added — find it under Modules or pin it to the bottom bar", systemImage: "checkmark.circle.fill").foregroundStyle(look.success)
                Button("Remove from my app", role: .destructive) { modules.setOn(module, false) }
                    .font(.subheadline)
                Text("Removing only hides it. Your data stays and comes back if you add it again.").font(.caption).foregroundStyle(look.textSecondary)
            } else {
                Button { modules.setOn(module, true); Haptics.success() } label: {
                    Text("Get — Free").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
            }
        case .comingSoon:
            Label("We're building this. It will appear here when ready.", systemImage: "hammer").font(.subheadline)
        case .paid:
            Text("*Note: professional module — free for your first year, no payment or card needed. Core modules are free for life.")
                .font(.caption).foregroundStyle(look.textSecondary)
            if unlocked {
                Label(Store.allFree ? "Free for everyone — enjoy!" : store.isOwner ? "Free for you as the owner" : "Active on this Apple ID",
                      systemImage: store.isOwner ? "crown.fill" : "checkmark.seal.fill").foregroundStyle(look.success)
                Toggle("Show in the app", isOn: Binding(get: { modules.isVisible(module) }, set: { modules.setOn(module, $0) }))
            } else if let id = module.productID {
                Button {
                    Task { busy = true; await store.purchase(id); busy = false }
                } label: {
                    Group { if busy { ProgressView() } else { Text("Subscribe · \(Self.price(module, store))") } }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                HStack {
                    Button("Redeem offer code") { redeem = true }
                    Spacer()
                    Button("Restore purchases") { Task { await store.restore() } }
                }
                .font(.subheadline)
            }
            if store.isSandbox, let id = module.productID, !store.active.contains(id) {
                Toggle("Unlock free for testing (TestFlight only)", isOn: Binding(get: { store.testUnlocked.contains(id) },
                                                                                  set: { store.setTestUnlock(id, $0) }))
                    .font(.caption)
            }
        }
    }

    private func section(_ title: String, icon: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon).foregroundStyle(color).frame(width: 22)
                    Text(item).font(.subheadline)
                }
            }
        }
        .lookCard()
    }
}

/// Phone-shaped previews drawn in code with sample data, so they always match the app's look.
struct ModulePreviewScreen: View {
    let preview: ModuleInfo.Preview
    let colors: [UInt32]
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold()).padding(.bottom, 2)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 200, height: 360, alignment: .top)
        .background {
            ZStack {
                LinearGradient(colors: colors.map { Color(hex: $0).opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.opacity(0.25)
            }
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 3))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
    }

    private var title: String {
        switch preview {
        case .mindDashboard: "Mindfulness"
        case .mindForm: "Set up a session"
        case .mindPlayer: "Now playing"
        case .gymDashboard: "Gym dashboard"
        case .gymForm: "Add payment form"
        case .gymSessions: "Training sessions"
        case .taskDashboard: "Tasks dashboard"
        case .taskForm: "New task form"
        case .proForm: "Recurring task form"
        case .careDashboard: "Care dashboard"
        case .medicineForm: "Add medicine form"
        case .taskList: "Tasks"
        case .approval: "Approval in chat"
        case .expenses: "Task expenses"
        case .poll: "Poll"
        case .recurring: "Recurring task"
        case .templates: "Templates"
        case .reports: "Team report"
        case .careToday: "Today's medicines"
        case .careEvent: "Injury & recovery"
        case .careVault: "Medical vault"
        case .doctorDashboard: "Doctor dashboard"
        case .eventsDashboard: "Events dashboard"
        case .eventForm: "New event"
        case .roomsDashboard: "Rooms"
        case .roomChat: "Room chat"
        case .safetyDashboard: "SOS"
        case .meetingDashboard: "Meetings dashboard"
        case .meetingForm: "New meeting"
        case .meetingMinutes: "Minutes of meeting"
        case .attDashboard: "Attendance dashboard"
        case .finDashboard: "Finance dashboard"
        case .surveyDashboard: "Survey results"
        case .surveyForm: "Field survey"
        case .finForm: "Add expense"
        case .finPro: "Cheques & approvals"
        case .attMember: "Add member"
        case .attKiosk: "Kiosk"
        case .attEmployee: "Employee: punch in"
        case .prescriptionForm: "New prescription"
        case .bizDashboard(let m): "\(BizSpecs.spec(m)?.title ?? "Module") dashboard"
        case .bizForm(let m): "New \((BizSpecs.spec(m)?.parent ?? BizSpecs.spec(m)?.children.first)?.label.lowercased() ?? "entry")"
        case .workspaces: "Workspaces"
        case .library: "Library"
        case .assistant: "What did I miss?"
        }
    }

    private func card<V: View>(@ViewBuilder _ c: () -> V) -> some View {
        c().padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ icon: String, _ text: String, _ trailing: String = "") -> some View {
        card {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(text).font(.caption2).lineLimit(2)
                Spacer(minLength: 0)
                if !trailing.isEmpty { Text(trailing).font(.caption2.bold()) }
            }
        }
    }

    private func bar(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.25))
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * value) }
            }
            .frame(height: 6)
        }
    }

    private func field(_ label: String, _ value: String, _ icon: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).opacity(0.75)
            card {
                HStack(spacing: 4) {
                    if let icon { Image(systemName: icon).font(.caption2) }
                    Text(value).font(.caption2).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.headline)
                Text(label).font(.system(size: 9))
            }
        }
    }

    private func button(_ text: String) -> some View {
        Text(text).font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(.white.opacity(0.3), in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        switch preview {
        case .taskDashboard:
            HStack(spacing: 6) { stat("7", "Open"); stat("3", "Overdue") }
            HStack(spacing: 6) { stat("12", "Done"); stat("2", "Approvals") }
            bar("This week · 64%", 0.64)
            row("exclamationmark.triangle.fill", "File reply in court", "Today")
            row("person.2.fill", "Site visit · Asha, Rahul", "Fri")
        case .taskForm:
            field("Title", "Prepare client agreement")
            field("Assign to", "Asha, Rahul", "person.2")
            field("Due", "Fri 22 Nov · 5:00 PM", "calendar")
            field("Priority", "High", "flag.fill")
            field("Checklist", "Draft · Review · Sign", "checklist")
            button("Create task")
        case .proForm:
            field("Title", "Monthly trust accounts")
            field("Repeat", "Monthly on the 1st", "repeat")
            field("Template", "Monthly audit · 5 steps", "doc.on.doc")
            field("Assign to", "Accounts team", "person.3")
            button("Save")
        case .careDashboard:
            HStack(spacing: 6) { stat("3/4", "Doses today"); stat("40%", "Recovery") }
            card { Text("Aai · B+ · Allergic to penicillin").font(.caption2) }
            row("checkmark.circle.fill", "9:00 Metformin", "Taken")
            row("exclamationmark.circle.fill", "10:00 Amlodipine", "Due")
            row("bell.badge.fill", "Family alerted: dose skipped")
        case .mindDashboard:
            HStack(spacing: 6) { stat("12", "min today"); stat("5🔥", "day streak") }
            card {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SUGGESTED NOW").font(.system(size: 9, weight: .bold))
                    Text("Wind down for sleep").font(.caption.bold())
                }
            }
            row("sparkles", "Make one for me (AI)")
            row("wind", "Box breathing · 5 min")
            row("moon.zzz.fill", "Body scan for sleep · 15 min")
        case .mindForm:
            field("Length", "10 minutes", "timer")
            field("Voice", "English · Calm female", "waveform")
            field("Sound", "Rain", "cloud.rain.fill")
            field("Mood before", "😟 → ?", "face.smiling")
            button("Begin")
        case .mindPlayer:
            card { Text("Breathe in… 4").font(.headline).frame(maxWidth: .infinity) }
            bar("6:12 of 10:00", 0.62)
            row("pause.circle.fill", "Pause")
            row("speaker.wave.2.fill", "Voice & sound volume")
        case .gymDashboard:
            HStack(spacing: 6) { stat("9", "Sessions · Nov"); stat("4", "Sessions left") }
            card {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gold's Gym · Dadar").font(.caption.bold())
                    Text("25 days left").font(.caption2)
                }
            }
            bar("Membership used", 0.93)
            button("Trained today")
            row("person.fill", "Rahul · Client · Fat loss")
        case .gymForm:
            field("For", "Personal training", "figure.strengthtraining.traditional")
            field("Amount", "₹6,000")
            field("Sessions in package", "12", "number")
            field("Paid by", "UPI", "creditcard")
            field("Receipt", "Photo attached", "doc.viewfinder")
            button("Save payment")
        case .gymSessions:
            row("checkmark.circle.fill", "Today · Legs · Nitin")
            row("checkmark.circle.fill", "Mon · Chest & triceps")
            row("checkmark.circle.fill", "Sat · Back & biceps")
            card { Text("8 of 12 paid sessions done").font(.caption2) }
            row("bell.badge.fill", "Client & trainer both notified")
        case .medicineForm:
            field("Medicine", "Metformin")
            field("Dose", "500 mg · 1 tablet", "pills.fill")
            field("Times", "9:00 AM · 9:00 PM", "clock")
            field("Days", "Every day · 30 days", "calendar")
            field("Alert family if skipped", "On", "bell.fill")
            button("Save medicine")
        case .taskList:
            row("exclamationmark.triangle.fill", "File reply in court", "Overdue")
            row("circle", "Review draft agreement", "Today")
            row("circle.lefthalf.filled", "Client meeting prep · 2/3", "Fri")
            row("checkmark.circle.fill", "Collect fee", "Done")
        case .approval:
            card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("🟡 Travel to Pune").font(.caption.bold())
                    Text("Requested ₹5,000").font(.caption2)
                    Text("✅ Asha approved ₹2,000").font(.caption2)
                    Text("“For 3 days only”").font(.caption2).italic()
                }
            }
            HStack { Text("Approve").font(.caption2.bold()); Spacer(); Text("Reject").font(.caption2) }.padding(.horizontal, 6)
        case .expenses:
            card { HStack { Text("Spent").font(.caption2); Text("₹1,850").font(.caption.bold()); Spacer(); Text("of ₹2,000").font(.caption2) } }
            bar("₹150 left", 0.92)
            row("car.fill", "Taxi to court", "₹450")
            row("building.columns.fill", "Court fee + 🧾", "₹1,200")
            row("printer.fill", "Printing", "₹200")
        case .poll:
            card { Text("Meeting day?").font(.caption.bold()) }
            bar("Friday · 4", 0.8)
            bar("Saturday · 1", 0.2)
            bar("Monday · 0", 0.02)
        case .recurring:
            row("repeat", "Monthly trust accounts", "1st")
            row("repeat", "Weekly case review", "Mon")
            row("repeat", "Daily site photos", "6 PM")
            card { Text("Finish one → the next appears automatically").font(.caption2) }
        case .templates:
            row("doc.on.doc", "New case intake · 6 steps")
            row("doc.on.doc", "Client onboarding · 4 steps")
            row("doc.on.doc", "Monthly audit · 5 steps")
            card { Text("Tap a template → task ready with checklist").font(.caption2) }
        case .reports:
            card { Text("This month").font(.caption.bold()) }
            bar("Asha · 12 done", 0.9)
            bar("Rahul · 8 done", 0.6)
            bar("You · 10 done", 0.75)
            row("exclamationmark.triangle", "Overdue", "3")
            row("square.and.arrow.up", "Export to Excel")
        case .careToday:
            row("checkmark.circle.fill", "9:00 Metformin 500 mg", "Taken")
            row("exclamationmark.circle.fill", "10:00 Amlodipine 5 mg", "Due")
            row("circle", "21:00 Metformin 500 mg", "")
            card { Text("⚠️ Group alerted if a dose is skipped").font(.caption2) }
        case .careEvent:
            row("bandage.fill", "Fractured left wrist", "Moderate")
            bar("40% recovered", 0.4)
            row("text.bubble", "“Swelling down, follow-up Monday”")
            row("photo", "X-ray attached")
        case .bizDashboard(let m):
            let spec = BizSpecs.spec(m)
            row("person.2.fill", "\(spec?.parent?.plural ?? "Items") · 24", "")
            row("indianrupeesign", spec?.balanceLabel ?? "Due", "₹12,450")
            row("calendar", "Next 7 days", "5")
        case .bizForm(let m):
            let k = BizSpecs.spec(m).flatMap { $0.parent ?? $0.children.first }
            ForEach(Array((k?.fields ?? []).prefix(4).enumerated()), id: \.offset) { _, f in row("square.and.pencil", f.label) }
        case .eventsDashboard:
            HStack(spacing: 6) { stat("3", "Upcoming"); stat("18", "Going") }
            row("party.popper.fill", "Riya's birthday · Sat 7 PM", "12 going")
            row("person.3.fill", "Team dinner · Fri", "Maybe 4")
        case .eventForm:
            row("textformat", "What: Birthday party")
            row("mappin.and.ellipse", "Where: Home, Dombivli")
            row("calendar", "Sat, 7:00 PM · 3 h")
            row("bubble.left.and.bubble.right", "Invite: Family group")
        case .roomsDashboard:
            row("person.3.sequence.fill", "Cricket fans · Mumbai", "Joined")
            row("person.3.sequence.fill", "Startup founders", "")
            row("lock.fill", "Private chat · Sky ♂", "2")
        case .roomChat:
            row("bubble.left", "Sky ♂: Anyone watching tonight?")
            row("bubble.left", "Moon ♀: Yes! Wankhede 🏏")
            row("eye", "Reveal myself")
        case .safetyDashboard:
            row("sos.circle.fill", "Hold 2 s — SOS to Family, Wife")
            row("hand.thumbsup.fill", "I'm safe now")
            row("location.circle", "Check In: Office by 10:30")
        case .meetingDashboard:
            HStack(spacing: 6) { stat("4", "This week"); stat("2", "Minutes due") }
            row("video.fill", "Design review · Online", "11:00")
            row("person.3.fill", "Site meeting · Office", "Fri")
        case .meetingForm:
            row("list.bullet", "Agenda: budget, timeline, vendors")
            row("person.2.fill", "Attending: Asha, Rahul, You")
            row("link", "Online: FaceTime link")
            row("chart.bar", "Vote: Approve budget?")
        case .meetingMinutes:
            row("checkmark.circle", "Attended: 5 of 6")
            row("doc.text", "Decisions & action items")
            row("doc.richtext", "Export minutes as PDF")
        case .surveyDashboard:
            HStack(spacing: 6) { stat("4", "Surveys"); stat("126", "Responses"); stat("3", "To answer") }
            row("building.2", "Building survey · 38 flats", "Open")
            row("map", "Plot survey Gat 112", "12 resp.")
            bar("Leakage seen · 34%", 0.34)
        case .surveyForm:
            row("text.cursor", "Survey / Gat no.: 112/3")
            row("location.fill", "GPS: 19.2183, 73.0868")
            row("camera.fill", "Site photos · 4")
            row("checkmark.circle", "Encroachment: No")
        case .finDashboard:
            HStack(spacing: 6) { stat("₹82k", "Income"); stat("₹47k", "Expenses"); stat("₹35k", "Net") }
            row("arrow.down.left.circle.fill", "Fees — Rahul (Tuition)", "+₹3,000")
            row("arrow.up.right.circle.fill", "Electricity", "−₹2,140")
            row("calendar", "Office rent due 1 Dec", "To pay")
        case .finForm:
            row("indianrupeesign", "Amount: ₹2,140")
            row("tag", "Category: Electricity")
            row("creditcard", "Mode: UPI · ref 4471…")
            row("paperclip", "Receipt photo attached")
        case .finPro:
            row("checkmark.seal.fill", "RTGS ₹1,20,000 — approve?", "Decide")
            row("exclamationmark.triangle.fill", "Cheque 004512 bounced", "Follow up")
            row("building.columns", "Bank statement: 42 matched")
        case .attDashboard:
            HStack(spacing: 6) { stat("18/20", "Present"); stat("3", "Late"); stat("1", "Leave") }
            row("person.fill", "Asha · In 9:22", "Grace")
            row("person.fill", "Rahul · In 10:05", "Late")
            row("beach.umbrella.fill", "Meera — 2 days casual", "Decide")
        case .attMember:
            row("person.crop.circle", "Name: Sunil Kale")
            row("building.2", "Store · Helper")
            row("clock", "Duty 9:30 – 18:30")
            row("lock", "Kiosk PIN · ••••")
        case .attKiosk:
            row("clock", "10:02:41 · Thursday")
            row("person.fill", "Tap your name → PIN → selfie")
            row("checkmark.circle.fill", "Sunil — punched in 10:02")
        case .attEmployee:
            row("arrow.right.circle.fill", "Punch in", "QR + selfie")
            row("location.fill", "At office · 40 m")
            row("calendar", "November: 19 P · 2 L · 1 A")
        case .doctorDashboard:
            row("person.fill", "Aai · BP follow-up", "Accepted")
            row("person.fill", "Rahul · Fever", "Waiting")
            row("calendar", "Next visits this week", "4")
        case .prescriptionForm:
            row("pills.fill", "Amlodipine 5 mg · 9:00", "30 days")
            row("pills.fill", "Paracetamol 650 · 9:00, 21:00", "5 days")
            row("text.bubble", "Advice: low salt, walk 30 min")
            row("calendar.badge.clock", "Next visit", "2 Dec")
        case .careVault:
            row("doc.text.magnifyingglass", "Blood test – Nov")
            row("pills.fill", "Prescription – Dr. K")
            row("xray", "Wrist X-ray")
            row("shield.lefthalf.filled", "Health insurance")
        case .workspaces:
            row("briefcase.fill", "Law office")
            row("building.columns.fill", "Trust")
            row("house.fill", "Family")
        case .library:
            row("folder.fill", "Court orders · 24")
            row("folder.fill", "Agreements · 11")
            row("pin.fill", "Trust deed")
        case .assistant:
            card { Text("3 things you missed: the hearing moved to Friday, Rahul needs the draft, fee approved ₹2,000.").font(.caption2) }
            row("checklist", "Suggested task: Send draft to Rahul")
        }
    }
}
