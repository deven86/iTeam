import SwiftUI
import SwiftData
import PhotosUI

/// Gym & Training: everyone you train or train with — you, family or clients — shared in a chat.
struct GymHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @ObservedObject private var store = Store.shared
    @Environment(\.look) private var look
    @Query(filter: #Predicate<GymMember> { !$0.deleted }, sort: \GymMember.name) private var members: [GymMember]
    @Query(filter: #Predicate<GymPlan> { !$0.deleted }) private var plans: [GymPlan]
    @Query(filter: #Predicate<GymSession> { !$0.deleted }) private var sessions: [GymSession]
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showPaywall = false

    private var unlocked: Bool { store.isUnlocked(Store.gymProductID) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if members.isEmpty {
                    Section {
                        VStack(spacing: 14) {
                            EmptyStateView(icon: "dumbbell.fill", title: "Gym & Training",
                                           message: "Track gym memberships, personal-training sessions and payments for yourself, your family or your clients. Share in a chat so trainer and client see the same numbers.")
                            Button { startNew() } label: { Label("Add a person", systemImage: "plus") }
                                .buttonStyle(.glassProminent).controlSize(.large)
                            Button("Try a demo client") {
                                if let id = DemoGym.create(engine) { path = [id] }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section { summary.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                    ForEach(groups, id: \.0) { group in
                        Section(group.0) {
                            ForEach(group.1) { m in NavigationLink(value: m.id) { row(m) } }
                        }
                        .lookRows()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .lookScreen()
            .navigationTitle("Gym & Training")
            .navigationDestination(for: String.self) { GymMemberView(memberID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startNew() } label: { Image(systemName: "plus") }.accessibilityLabel("Add a person")
                }
            }
            .refreshable { await engine.sync() }
            .sheet(isPresented: $showNew) { NavigationStack { GymMemberEditor(member: nil) { id in path = [id] } } }
            .sheet(isPresented: $showPaywall) {
                NavigationStack {
                    ModuleDetailView(module: ModuleRegistry.gymTraining)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showPaywall = false } } }
                }
            }
            .onChange(of: router.openGym) { _, id in
                guard let id else { return }
                path = [id]
                router.openGym = nil
            }
            .onAppear { if let id = router.openGym { path = [id]; router.openGym = nil } }
        }
    }

    private func startNew() { if unlocked { showNew = true } else { showPaywall = true } }

    /// Clients first, then everyone else.
    private var groups: [(String, [GymMember])] {
        let clients = members.filter { $0.relation == "Client" }
        let others = members.filter { $0.relation != "Client" }
        return [("Clients", clients), ("Me & family", others)].filter { !$0.1.isEmpty }
    }

    private var summary: some View {
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        let monthDays = Set(sessions.filter { $0.date >= monthStart }.map { "\($0.memberID)|\(Calendar.current.startOfDay(for: $0.date).timeIntervalSince1970)" }).count
        let expiring = plans.filter { $0.isActive && $0.daysLeft <= 15 }.count
        return HStack(spacing: 10) {
            GymStat(value: "\(members.count)", label: "People", icon: "person.2.fill")
            GymStat(value: "\(monthDays)", label: "Sessions this month", icon: "figure.strengthtraining.traditional")
            GymStat(value: "\(expiring)", label: "Renew soon", icon: "exclamationmark.triangle.fill", warn: expiring > 0)
        }
        .padding(.vertical, 4)
    }

    private func row(_ m: GymMember) -> some View {
        let plan = plans.filter { $0.memberID == m.id }.max { $0.endDate < $1.endDate }
        return HStack(spacing: 12) {
            AvatarView(name: m.name, imageData: m.avatar, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.headline)
                Text([m.relation, m.trainer.isEmpty ? nil : "Trainer \(m.trainer)", engine.conversation(m.convID)?.title]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer()
            if let plan {
                Text(plan.isActive ? "\(plan.daysLeft)d" : "Expired").font(.caption.bold())
                    .foregroundStyle(!plan.isActive ? look.danger : plan.daysLeft <= 15 ? look.warning : look.success)
            }
        }
    }
}

struct GymStat: View {
    let value: String
    let label: String
    let icon: String
    var warn = false
    @Environment(\.look) private var look
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(warn ? look.warning : look.accent)
            Text(value).font(.title2.bold())
            Text(label).font(.caption2).foregroundStyle(look.textSecondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lookCard()
    }
}

/// One person's dashboard: membership, training balance, sessions and payments.
struct GymMemberView: View {
    let memberID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [GymMember]
    @Query private var plans: [GymPlan]
    @Query private var sessions: [GymSession]
    @Query private var payments: [GymPayment]
    @State private var edit = false
    @State private var editPlan: GymPlan?
    @State private var addPlan = false
    @State private var editSession: GymSession?
    @State private var addSession = false
    @State private var editPayment: GymPayment?
    @State private var addPayment = false
    @State private var preview: URL?
    @State private var confirmDelete = false
    @State private var shareToViews = false

    init(memberID: String) {
        self.memberID = memberID
        _found = Query(filter: #Predicate<GymMember> { $0.id == memberID })
        _plans = Query(filter: #Predicate<GymPlan> { $0.memberID == memberID && !$0.deleted }, sort: \GymPlan.endDate, order: .reverse)
        _sessions = Query(filter: #Predicate<GymSession> { $0.memberID == memberID && !$0.deleted }, sort: \GymSession.date, order: .reverse)
        _payments = Query(filter: #Predicate<GymPayment> { $0.memberID == memberID && !$0.deleted }, sort: \GymPayment.date, order: .reverse)
    }

    var body: some View {
        if let m = found.first, !m.deleted {
            content(m)
        } else {
            EmptyStateView(icon: "dumbbell", title: "Not found", message: "This person may have been removed.")
        }
    }

    /// Personal-training sessions count once per training day.
    private var trainingDays: Int { Set(sessions.map { Calendar.current.startOfDay(for: $0.date) }).count }
    private var paidSessions: Int { payments.filter { $0.paymentKind == .training }.reduce(0) { $0 + $1.sessions } }
    private var trainedToday: Bool { sessions.contains { Calendar.current.isDateInToday($0.date) } }

    private func content(_ m: GymMember) -> some View {
        let yearStart = Calendar.current.dateInterval(of: .year, for: .now)?.start ?? .now
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        let spentYear = payments.filter { $0.date >= yearStart }.reduce(0) { $0 + $1.amount }
        let monthDays = Set(sessions.filter { $0.date >= monthStart }.map { Calendar.current.startOfDay(for: $0.date) }).count
        let balance = paidSessions - trainingDays
        return List {
            Section {
                HStack(spacing: 14) {
                    AvatarView(name: m.name, imageData: m.avatar, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.name).font(.title2.bold())
                        Text([m.relation, m.goal].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(look.textSecondary)
                        if !m.trainer.isEmpty {
                            Label("Trainer \(m.trainer)\(m.feePerSession > 0 ? " · \(Money.format(m.feePerSession))/session" : "")",
                                  systemImage: "figure.strengthtraining.traditional").font(.caption)
                        }
                    }
                }
                if let url = URL(string: "tel://\(m.phone.filter { $0.isNumber || $0 == "+" })"), !m.phone.isEmpty {
                    Link(destination: url) { Label("Call \(m.phone)", systemImage: "phone.fill") }
                }
            }
            .lookRows()

            Section {
                HStack(spacing: 10) {
                    GymStat(value: "\(monthDays)", label: "Sessions this month", icon: "calendar")
                    GymStat(value: paidSessions == 0 ? "–" : "\(balance)", label: balance < 0 ? "Sessions unpaid" : "Sessions left",
                            icon: "creditcard", warn: balance < 0)
                    GymStat(value: Money.format(spentYear), label: "Spent this year", icon: "indianrupeesign.circle")
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Button {
                    engine.saveGymSession(m, date: .now, trainer: m.trainer, workout: "", notes: "")
                    Haptics.success()
                } label: {
                    Label(trainedToday ? "Trained today ✓" : "Trained today", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(trainedToday)
                .listRowBackground(Color.clear)
                Button("Share to Views", systemImage: "play.rectangle.on.rectangle") { shareToViews = true }
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Personal-training sessions are counted per training day. Paid sessions come from Personal training payments.")
            }

            Section {
                if plans.isEmpty { Text("No membership yet.").foregroundStyle(look.textSecondary) }
                ForEach(plans) { p in
                    Button { editPlan = p } label: { planRow(p) }.buttonStyle(.plain)
                }
                Button("Add membership", systemImage: "plus") { addPlan = true }
            } header: { Text("Gym membership") }
            .lookRows()

            Section {
                if sessions.isEmpty { Text("No sessions logged.").foregroundStyle(look.textSecondary) }
                ForEach(sessions.prefix(30)) { s in
                    Button { editSession = s } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold))
                                Text([s.workout, s.trainer.isEmpty ? "" : "with \(s.trainer)", "by \(engine.name(of: s.by))"]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(look.textSecondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button("Log a session", systemImage: "plus") { addSession = true }
            } header: { Text("Training sessions (\(trainingDays) days)") }
            .lookRows()

            Section {
                if payments.isEmpty { Text("No payments yet.").foregroundStyle(look.textSecondary) }
                ForEach(payments) { p in
                    Button { editPayment = p } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.paymentKind.icon).foregroundStyle(look.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.paymentKind.title + (p.sessions > 0 ? " · \(p.sessions) sessions" : "")).font(.subheadline.weight(.semibold))
                                Text("\(p.date.formatted(date: .abbreviated, time: .omitted)) · \(p.method)\(p.receipts.isEmpty ? "" : " · 🧾")")
                                    .font(.caption).foregroundStyle(look.textSecondary)
                            }
                            Spacer()
                            Text(Money.format(p.amount)).font(.subheadline.bold())
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button("Add payment", systemImage: "plus") { addPayment = true }
            } header: { Text("Payments") }
            .lookRows()

            if AISettings.shared.allows(.gym) {
                Section {
                    AIButton(title: "AI training insights", feature: .gym,
                             instructions: "Give short insights on attendance consistency, sessions paid vs used, membership renewal timing and spending, with 3 practical suggestions. No medical advice.",
                             context: { ShareText.gym(m, plans: plans, sessions: sessions, payments: payments, engine: engine) + "\nSessions:\n" + sessions.prefix(40).map { "- \($0.date.formatted(date: .abbreviated, time: .omitted)) \($0.workout)" }.joined(separator: "\n") })
                }
                .lookRows()
            }
            if m.createdBy == engine.me {
                Section { Button("Remove \(m.name)", role: .destructive) { confirmDelete = true } }.lookRows()
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle(m.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareMenu(title: "Gym statement – \(m.name)",
                          text: { ShareText.gym(m, plans: plans, sessions: sessions, payments: payments, engine: engine) },
                          html: { ShareText.gymHTML(m, plans: plans, sessions: sessions, payments: payments, engine: engine) })
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { edit = true } }
        }
        .sheet(isPresented: $edit) { NavigationStack { GymMemberEditor(member: m) { _ in } } }
        .sheet(isPresented: $shareToViews) {
            NavigationStack { NewPostView(status: false, kind: .training, prefill: "💪 \(m.name): \(trainingDays) training days and counting") }
        }
        .sheet(isPresented: $addPlan) { NavigationStack { GymPlanEditor(member: m, plan: nil) } }
        .sheet(item: $editPlan) { p in NavigationStack { GymPlanEditor(member: m, plan: p) } }
        .sheet(isPresented: $addSession) { NavigationStack { GymSessionEditor(member: m, session: nil) } }
        .sheet(item: $editSession) { s in NavigationStack { GymSessionEditor(member: m, session: s) } }
        .sheet(isPresented: $addPayment) { NavigationStack { GymPaymentEditor(member: m, payment: nil) } }
        .sheet(item: $editPayment) { p in NavigationStack { GymPaymentEditor(member: m, payment: p) } }
        .confirmationDialog("Remove \(m.name) for everyone in the chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let conv = engine.conversation(m.convID) {
                    engine.saveGymMember(in: conv, id: m.id, name: m.name, relation: m.relation, phone: m.phone, goal: m.goal,
                                         trainer: m.trainer, fee: m.feePerSession, avatar: nil, deleted: true)
                }
                dismiss()
            }
        }
    }

    private func planRow(_ p: GymPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.gymName.isEmpty ? "Gym" : p.gymName).font(.headline)
                    Text([p.branch, p.planName, "till \(p.endDate.formatted(date: .abbreviated, time: .omitted))"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(look.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(p.isActive ? "\(p.daysLeft)" : "Expired").font(p.isActive ? .title3.bold() : .caption.bold())
                        .foregroundStyle(!p.isActive ? look.danger : p.daysLeft <= 15 ? look.warning : look.success)
                    if p.isActive { Text("days left").font(.caption2).foregroundStyle(look.textSecondary) }
                }
            }
            if p.isActive { ProgressView(value: p.progress).tint(p.daysLeft <= 15 ? look.warning : look.success) }
            if !p.gymName.isEmpty {
                Button("Directions", systemImage: "map.fill") {
                    let q = (p.gymName + " " + p.branch).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "http://maps.apple.com/?q=\(q)") { UIApplication.shared.open(url) }
                }
                .font(.caption).buttonStyle(.bordered)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Editors

struct GymMemberEditor: View {
    let member: GymMember?
    var onSaved: (String) -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.lastActivity, order: .reverse) private var conversations: [Conversation]
    @State private var chatID = ""
    @State private var name = ""
    @State private var relation = "Client"
    @State private var phone = ""
    @State private var goal = ""
    @State private var trainer = ""
    @State private var fee = ""
    @State private var avatar: Data?
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        AvatarView(name: name.isEmpty ? "?" : name, imageData: avatar, size: 64)
                    }
                    TextField("Name", text: $name).font(.title3)
                }
                RelationPicker(relation: $relation)
                TextField("Mobile (optional)", text: $phone).keyboardType(.phonePad)
                TextField("Goal (e.g. Fat loss, Strength, Rehab)", text: $goal)
            }
            .lookRows()
            Section("Personal trainer") {
                TextField("Trainer's name", text: $trainer)
                TextField("Fee per session", text: $fee).keyboardType(.decimalPad)
            }
            .lookRows()
            if member == nil {
                Section {
                    Picker("Share in", selection: $chatID) {
                        Text("Only me (Notes to self)").tag("")
                        ForEach(conversations.filter { !$0.left && !$0.id.hasPrefix("s_") }) { c in Text(c.title).tag(c.id) }
                    }
                } header: {
                    Text("Who can see and update it")
                } footer: {
                    Text("Trainer? Pick the chat with your client. Family? Pick the family group. Everyone in it can log sessions and payments and gets the updates.")
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle(member == nil ? "Add a person" : "Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let conv = member.flatMap { engine.conversation($0.convID) }
                        ?? (chatID.isEmpty ? DemoChats.notesToSelf(engine) : engine.conversation(chatID))
                    guard let conv else { return }
                    let id = engine.saveGymMember(in: conv, id: member?.id, name: name.trimmingCharacters(in: .whitespaces),
                                                  relation: relation, phone: phone, goal: goal, trainer: trainer,
                                                  fee: Double(fee.replacingOccurrences(of: ",", with: "")) ?? 0, avatar: avatar)
                    Haptics.success()
                    dismiss()
                    onSaved(id)
                }
                .bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let m = member else { return }
            name = m.name; relation = m.relation; phone = m.phone; goal = m.goal; trainer = m.trainer; avatar = m.avatar
            fee = m.feePerSession > 0 ? String(format: "%.0f", m.feePerSession) : ""
        }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = OnboardingView.avatarData(d) } }
        }
    }
}

struct GymPlanEditor: View {
    let member: GymMember
    let plan: GymPlan?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var gymName = ""
    @State private var branch = ""
    @State private var planName = "12 months"
    @State private var start = Date.now
    @State private var end = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    @State private var fee = ""
    @State private var notes = ""

    private let plansList = ["1 month", "3 months", "6 months", "12 months"]

    var body: some View {
        Form {
            Section {
                TextField("Gym name", text: $gymName)
                TextField("Branch / area", text: $branch)
                Picker("Plan", selection: $planName) { ForEach(plansList, id: \.self) { Text($0).tag($0) } }
                    .onChange(of: planName) { _, p in
                        let months = Int(p.split(separator: " ").first ?? "12") ?? 12
                        end = Calendar.current.date(byAdding: .month, value: months, to: start) ?? end
                    }
                DatePicker("Starts", selection: $start, displayedComponents: .date)
                DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date)
                TextField("Fee", text: $fee).keyboardType(.decimalPad)
                TextField("Notes (member ID, locker…)", text: $notes, axis: .vertical)
            }
            .lookRows()
            if plan != nil {
                Section { Button("Delete membership", role: .destructive) { save(deleted: true) } }.lookRows()
            }
        }
        .lookScreen()
        .navigationTitle(plan == nil ? "Add membership" : "Membership")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(deleted: false) }.bold().disabled(gymName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let p = plan else { return }
            gymName = p.gymName; branch = p.branch; planName = p.planName.isEmpty ? "12 months" : p.planName
            start = p.startDate; end = p.endDate; notes = p.notes
            fee = p.fee > 0 ? String(format: "%.0f", p.fee) : ""
        }
    }

    private func save(deleted: Bool) {
        engine.saveGymPlan(member, id: plan?.id, gymName: gymName, branch: branch, planName: planName, start: start, end: end,
                           fee: Double(fee.replacingOccurrences(of: ",", with: "")) ?? 0, notes: notes, deleted: deleted)
        Haptics.success()
        dismiss()
    }
}

struct GymSessionEditor: View {
    let member: GymMember
    let session: GymSession?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var trainer = ""
    @State private var workout = ""
    @State private var notes = ""

    private let workouts = ["", "Chest & triceps", "Back & biceps", "Legs", "Shoulders", "Full body", "Cardio", "Core", "Mobility & stretching"]

    var body: some View {
        Form {
            Section {
                DatePicker("When", selection: $date)
                TextField("Trainer", text: $trainer)
                Picker("Workout", selection: $workout) { ForEach(workouts, id: \.self) { Text($0.isEmpty ? "Not set" : $0).tag($0) } }
                TextField("Notes (weights, how it felt…)", text: $notes, axis: .vertical)
            }
            .lookRows()
            if session != nil {
                Section { Button("Delete session", role: .destructive) { save(deleted: true) } }.lookRows()
            }
        }
        .lookScreen()
        .navigationTitle(session == nil ? "Log session" : "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save(deleted: false) }.bold() }
        }
        .onAppear {
            trainer = member.trainer
            guard let s = session else { return }
            date = s.date; trainer = s.trainer; workout = s.workout; notes = s.notes
        }
    }

    private func save(deleted: Bool) {
        engine.saveGymSession(member, id: session?.id, date: date, trainer: trainer, workout: workout, notes: notes, deleted: deleted)
        Haptics.success()
        dismiss()
    }
}

struct GymPaymentEditor: View {
    let member: GymMember
    let payment: GymPayment?
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var kind: GymPaymentKind = .membership
    @State private var amount = ""
    @State private var date = Date.now
    @State private var method = "UPI"
    @State private var sessions = 12
    @State private var notes = ""
    @State private var receipts: [AttachmentRef] = []
    @State private var uploads: [String: String] = [:]
    @State private var photo: PhotosPickerItem?
    @State private var preview: URL?

    private let methods = ["UPI", "Cash", "Card", "Bank transfer", "Cheque"]

    var body: some View {
        Form {
            Section {
                Picker("For", selection: $kind) { ForEach(GymPaymentKind.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                TextField("Amount", text: $amount).keyboardType(.decimalPad).font(.title3)
                if kind == .training {
                    Stepper("Sessions in package: \(sessions)", value: $sessions, in: 1...200)
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Paid by", selection: $method) { ForEach(methods, id: \.self) { Text($0).tag($0) } }
                TextField("Notes / reference", text: $notes, axis: .vertical)
            }
            .lookRows()
            Section("Receipt") {
                ForEach(receipts) { r in
                    AttachmentView(ref: r) { preview = $0 }
                }
                PhotosPicker(selection: $photo, matching: .images) { Label("Add receipt photo", systemImage: "doc.viewfinder") }
            }
            .lookRows()
            if payment != nil {
                Section { Button("Delete payment", role: .destructive) { save(deleted: true) } }.lookRows()
            }
        }
        .lookScreen()
        .navigationTitle(payment == nil ? "Add payment" : "Payment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(deleted: false) }.bold().disabled((Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0) <= 0)
            }
        }
        .onAppear {
            guard let p = payment else { return }
            kind = p.paymentKind; amount = String(format: "%.0f", p.amount); date = p.date; method = p.method
            sessions = max(1, p.sessions); notes = p.notes; receipts = p.receipts
        }
        .onChange(of: photo) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let prepared = try? Attachments.prepareImage(d) {
                    receipts.append(prepared.ref)
                    uploads[prepared.upload.0] = prepared.upload.1
                }
            }
        }
        .sheet(item: Binding(get: { preview.map(PreviewItem.init) }, set: { preview = $0?.url })) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
    }

    private func save(deleted: Bool) {
        engine.saveGymPayment(member, id: payment?.id, kind: kind, amount: Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0,
                              date: date, method: method, sessions: kind == .training ? sessions : 0, notes: notes,
                              receipts: receipts, uploads: uploads, deleted: deleted)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Share / PDF statement

extension ShareText {
    static func gym(_ m: GymMember, plans: [GymPlan], sessions: [GymSession], payments: [GymPayment], engine: SyncEngine) -> String {
        var l = ["🏋️ \(m.name)\(m.relation.isEmpty ? "" : " (\(m.relation))")"]
        if !m.trainer.isEmpty { l.append("Trainer: \(m.trainer)") }
        for p in plans {
            l.append("Membership: \(p.gymName) \(p.planName) · \(p.startDate.formatted(date: .abbreviated, time: .omitted)) – \(p.endDate.formatted(date: .abbreviated, time: .omitted))\(p.isActive ? " (\(p.daysLeft) days left)" : " (expired)")")
        }
        let days = Set(sessions.map { Calendar.current.startOfDay(for: $0.date) }).count
        let paid = payments.filter { $0.paymentKind == .training }.reduce(0) { $0 + $1.sessions }
        l.append("Training days: \(days)\(paid > 0 ? " of \(paid) paid" : "")")
        if !payments.isEmpty {
            l.append("\nPayments (total \(Money.format(payments.reduce(0) { $0 + $1.amount }))):")
            l += payments.map { "• \($0.date.formatted(date: .abbreviated, time: .omitted)) \($0.paymentKind.title) — \(Money.format($0.amount)) · \($0.method)" }
        }
        return l.joined(separator: "\n")
    }

    static func gymHTML(_ m: GymMember, plans: [GymPlan], sessions: [GymSession], payments: [GymPayment], engine: SyncEngine) -> String {
        let e = PDFMaker.esc
        var h = "<p>\(e([m.relation, m.goal, m.trainer.isEmpty ? "" : "Trainer \(m.trainer)"].filter { !$0.isEmpty }.joined(separator: " · ")))</p>"
        if !plans.isEmpty {
            h += "<h2>Memberships</h2><table><tr><th>Gym</th><th>Plan</th><th>From</th><th>To</th><th>Fee</th></tr>"
            h += plans.map { "<tr><td>\(e($0.gymName)) \(e($0.branch))</td><td>\(e($0.planName))</td><td>\(e($0.startDate.formatted(date: .abbreviated, time: .omitted)))</td><td>\(e($0.endDate.formatted(date: .abbreviated, time: .omitted)))</td><td>\(e(Money.format($0.fee)))</td></tr>" }.joined()
            h += "</table>"
        }
        let days = Set(sessions.map { Calendar.current.startOfDay(for: $0.date) }).count
        let paid = payments.filter { $0.paymentKind == .training }.reduce(0) { $0 + $1.sessions }
        h += "<h2>Training</h2><p>\(days) training days\(paid > 0 ? " · \(paid) paid · balance \(paid - days)" : "")</p><table><tr><th>Date</th><th>Workout</th><th>Trainer</th></tr>"
        h += sessions.prefix(100).map { "<tr><td>\(e($0.date.formatted(date: .abbreviated, time: .shortened)))</td><td>\(e($0.workout))</td><td>\(e($0.trainer))</td></tr>" }.joined()
        h += "</table>"
        if !payments.isEmpty {
            h += "<h2>Payments</h2><table><tr><th>Date</th><th>For</th><th>Method</th><th>Amount</th></tr>"
            h += payments.map { "<tr><td>\(e($0.date.formatted(date: .abbreviated, time: .omitted)))</td><td>\(e($0.paymentKind.title))\($0.sessions > 0 ? " (\($0.sessions) sessions)" : "")</td><td>\(e($0.method))</td><td>\(e(Money.format($0.amount)))</td></tr>" }.joined()
            h += "<tr><th colspan=3>Total</th><th>\(e(Money.format(payments.reduce(0) { $0 + $1.amount })))</th></tr></table>"
        }
        return h
    }
}

// MARK: - Demo

/// A demo client in the demo team, so the module can be tried alone.
@MainActor
enum DemoGym {
    static func create(_ engine: SyncEngine) -> String? {
        let team = DemoChats.create(engine)
        let gid = "g_demo"
        if engine.gymMember(gid) != nil { return gid }
        let now = Date.now
        func apply(_ body: Event.Body, from: String, at: Date = .now) {
            _ = EventApplier(engine: engine).apply(Event(id: UUID().uuidString, conv: team.id, from: from, at: at, body: body), local: false)
        }
        apply(.gymMember(GymMemberPayload(id: gid, name: "Rahul (demo)", relation: "Client", phone: "", goal: "Fat loss",
                                          trainer: "Nitin", fee: 500, avatar: nil, deleted: false, at: now)), from: DemoChats.rahul)
        apply(.gymPlan(GymPlanPayload(id: "gp_demo", memberID: gid, gymName: "Gold's Gym", branch: "Dadar", planName: "12 months",
                                      start: now.addingTimeInterval(-340 * 86400), end: now.addingTimeInterval(25 * 86400),
                                      fee: 18000, notes: "", deleted: false, at: now)), from: DemoChats.rahul)
        apply(.gymPayment(GymPaymentPayload(id: "gpay_demo", memberID: gid, kind: GymPaymentKind.training.rawValue, amount: 6000,
                                            date: now.addingTimeInterval(-20 * 86400), method: "UPI", sessions: 12, notes: "",
                                            receipts: [], deleted: false, at: now)), from: DemoChats.rahul)
        for (i, w) in ["Legs", "Chest & triceps", "Back & biceps", "Cardio", "Full body"].enumerated() {
            apply(.gymSession(GymSessionPayload(id: "gs_demo\(i)", memberID: gid, date: now.addingTimeInterval(Double(-(i * 2 + 1)) * 86400),
                                                trainer: "Nitin", workout: w, notes: "", deleted: false, at: now)), from: DemoChats.asha)
        }
        engine.save()
        return gid
    }
}
