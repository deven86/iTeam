import SwiftUI
import SwiftData

/// Settings → Archive: everything deleted across modules. Nothing is erased — only the creator can
/// delete, and the item stays here marked "Deleted by X · date".
struct ArchiveView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<CareProfile> { $0.deleted }) private var careProfiles: [CareProfile]
    @Query(filter: #Predicate<Medicine> { $0.deleted }) private var medicines: [Medicine]
    @Query(filter: #Predicate<HealthEvent> { $0.deleted }) private var healthEvents: [HealthEvent]
    @Query(filter: #Predicate<VaultItem> { $0.deleted }) private var vault: [VaultItem]
    @Query(filter: #Predicate<GymMember> { $0.deleted }) private var gymMembers: [GymMember]
    @Query(filter: #Predicate<GymPlan> { $0.deleted }) private var gymPlans: [GymPlan]
    @Query(filter: #Predicate<GymSession> { $0.deleted }) private var gymSessions: [GymSession]
    @Query(filter: #Predicate<GymPayment> { $0.deleted }) private var gymPayments: [GymPayment]
    @Query(filter: #Predicate<Post> { $0.deleted }) private var posts: [Post]
    @Query(filter: #Predicate<WalletDoc> { $0.deleted }) private var wallet: [WalletDoc]
    @Query(filter: #Predicate<MeditationLog> { $0.deleted }) private var mind: [MeditationLog]
    @Query(filter: #Predicate<TaskItem> { $0.deleted }) private var tasks: [TaskItem]

    var body: some View {
        List {
            Section {
                Text("Only the person who created an item can delete it. Deleted items are kept here, and the deletion is also noted in the chat it belonged to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !tasks.isEmpty {
                Section("Tasks") {
                    ForEach(tasks) { t in row(t.title, by: t.deletedBy ?? t.createdBy, at: t.deletedAt ?? t.updatedAt) }
                }
            }
            if !(careProfiles.isEmpty && medicines.isEmpty && healthEvents.isEmpty && vault.isEmpty) {
                Section("Care") {
                    ForEach(careProfiles) { p in row("Profile: \(p.name)", by: p.createdBy, at: p.updatedAt) }
                    ForEach(medicines) { m in row("Medicine: \(m.name) \(m.dose)", by: m.addedBy, at: m.updatedAt) }
                    ForEach(healthEvents) { h in row("Event: \(h.title)", by: h.createdBy, at: h.updatedAt) }
                    ForEach(vault) { v in row("Document: \(v.title)", by: v.addedBy, at: v.date) }
                }
            }
            if !(gymMembers.isEmpty && gymPlans.isEmpty && gymSessions.isEmpty && gymPayments.isEmpty) {
                Section("Gym & Training") {
                    ForEach(gymMembers) { m in row("Member: \(m.name)", by: m.createdBy, at: m.updatedAt) }
                    ForEach(gymPlans) { p in row("Membership: \(p.gymName) \(p.planName)", by: nil, at: p.updatedAt) }
                    ForEach(gymSessions) { s in row("Session \(s.date.formatted(date: .abbreviated, time: .omitted))", by: s.by, at: s.updatedAt) }
                    ForEach(gymPayments) { p in row("Payment \(Money.format(p.amount))", by: p.by, at: p.updatedAt) }
                }
            }
            if !posts.isEmpty {
                Section("Views & mini") {
                    ForEach(posts) { p in row(p.text.isEmpty ? (p.isStatus ? "mini" : "Post") : p.text, by: p.author, at: p.createdAt) }
                }
            }
            if !wallet.isEmpty {
                Section("Personal Wallet") {
                    ForEach(wallet) { d in
                        row(d.title.isEmpty ? (WalletKind(rawValue: d.kind)?.title ?? "Document") : d.title, by: engine.me, at: d.deletedAt ?? d.createdAt)
                            .swipeActions { Button("Restore") { d.deleted = false; try? ctx.save() }.tint(.green) }
                    }
                }
            }
            if !mind.isEmpty {
                Section("Mindfulness") {
                    ForEach(mind) { l in
                        row("\(l.title) · \(Int(l.minutes)) min", by: engine.me, at: l.deletedAt ?? l.date)
                            .swipeActions { Button("Restore") { l.deleted = false; try? ctx.save() }.tint(.green) }
                    }
                }
            }
            Section("Archives inside modules") {
                NavigationLink("Meetings (cancelled)") { MeetingsHomeView() }
                NavigationLink("Events (cancelled)") { EventsHomeView() }
                NavigationLink("Prescriptions (cancelled)") { DoctorHomeView() }
                ForEach(BizSpecs.all, id: \.module) { spec in
                    NavigationLink(spec.title) { BizArchiveView(spec: spec) }
                }
            }
        }
        .lookScreen()
        .navigationTitle("Archive")
    }

    private func row(_ title: String, by: String?, at: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(2)
            Text("Deleted\(by.map { " by " + ($0 == engine.me ? "you" : engine.name(of: $0)) } ?? "") · \(at.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.red)
        }
    }
}
