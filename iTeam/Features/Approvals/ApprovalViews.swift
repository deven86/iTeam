import SwiftUI
import SwiftData

/// The card shown in a chat for an approval request: title, details, amount, files,
/// each approver's answer with their note, and Approve / Reject buttons for approvers.
struct ApprovalCard: View {
    let approvalID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var found: [Approval]
    @State private var deciding: Bool?

    init(approvalID: String) {
        self.approvalID = approvalID
        _found = Query(filter: #Predicate<Approval> { $0.id == approvalID })
    }

    var body: some View {
        if let a = found.first {
            content(a)
        } else {
            Label("Approval request", systemImage: "hourglass").font(.subheadline)
        }
    }

    private func statusColor(_ s: ApprovalStatus) -> Color {
        switch s {
        case .pending: look.warning
        case .approved: look.success
        case .rejected: look.danger
        }
    }

    private func content(_ a: Approval) -> some View {
        let status = a.status
        let mine = a.decisions[engine.me]
        let canDecide = a.approvers.contains(engine.me)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                Text(status.title.uppercased()).font(.caption2.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(statusColor(status))

            Text(a.title).font(.headline)
            if !a.details.isEmpty { Text(a.details).font(.subheadline).opacity(0.9) }
            if let amount = a.amount {
                HStack {
                    Text("Requested").font(.caption).opacity(0.75)
                    Text(Money.format(amount)).font(.subheadline.bold())
                    if let ok = a.approvedAmount, ok != amount {
                        Text("· Approved \(Money.format(ok))").font(.subheadline.bold()).foregroundStyle(look.success)
                    }
                }
            }
            if !a.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(a.attachments) { AttachmentThumb(ref: $0, size: 52) } }
                }
            }

            Divider().opacity(0.4)
            ForEach(a.approvers, id: \.self) { id in
                let d = a.decisions[id]
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: d == nil ? "circle.dotted" : (d!.approved ? "checkmark.circle.fill" : "xmark.circle.fill"))
                        .foregroundStyle(d == nil ? Color.secondary : (d!.approved ? look.success : look.danger))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(engine.name(of: id) + (d == nil ? " · pending" : (d!.approved ? " approved" : " rejected")))
                            .font(.caption.weight(.semibold))
                        if let d, let amt = d.amount { Text("Amount: \(Money.format(amt))").font(.caption) }
                        if let d, !d.note.isEmpty { Text("“\(d.note)”").font(.caption).italic() }
                    }
                }
            }

            if canDecide {
                HStack {
                    Button { deciding = true } label: {
                        Label(mine?.approved == true ? "Change" : "Approve", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(look.success)
                    Button { deciding = false } label: {
                        Label("Reject", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(look.danger)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .frame(minWidth: 240, alignment: .leading)
        .sheet(item: Binding(get: { deciding.map(DecisionChoice.init) }, set: { deciding = $0?.approve })) { choice in
            NavigationStack { DecisionSheet(approval: a, approve: choice.approve) }
                .presentationDetents([.medium, .large])
        }
    }
}

private struct DecisionChoice: Identifiable {
    let approve: Bool
    var id: Bool { approve }
}

/// Approve or reject with a note, and optionally a different amount.
struct DecisionSheet: View {
    let approval: Approval
    let approve: Bool
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var note = ""
    @State private var amountText = ""

    var body: some View {
        Form {
            Section {
                Text(approval.title).font(.headline)
                if let amount = approval.amount { LabeledContent("Requested", value: Money.format(amount)) }
            }
            .lookRows()
            if approve && approval.amount != nil {
                Section {
                    TextField("Approved amount", text: $amountText).keyboardType(.decimalPad)
                } header: {
                    Text("Approve how much?")
                } footer: {
                    Text("Leave as is to approve the full amount, or enter less (e.g. only 200).")
                }
                .lookRows()
            }
            Section {
                TextField(approve ? "e.g. Approved for 3 days only" : "Reason", text: $note, axis: .vertical).lineLimit(2...6)
            } header: {
                Text("Note (optional)")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle(approve ? "Approve" : "Reject")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(approve ? "Approve" : "Reject") {
                    let amt = approve ? Double(amountText.replacingOccurrences(of: ",", with: "")) : nil
                    engine.decide(approval, approved: approve, note: note, amount: amt)
                    approve ? Haptics.success() : Haptics.warning()
                    dismiss()
                }
                .bold()
                .disabled(!approve && note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if let a = approval.amount { amountText = String(format: a.rounded() == a ? "%.0f" : "%.2f", a) }
            if let mine = approval.decisions[engine.me] { note = mine.note }
        }
    }
}

/// New approval request: what, why, how much, who approves, supporting files.
struct ApprovalRequestView: View {
    let conv: Conversation
    var task: TaskItem? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var title = ""
    @State private var details = ""
    @State private var amountText = ""
    @State private var approvers: Set<String> = []
    @State private var pending = PendingAttachments()

    private var candidates: [MemberInfo] { conv.members.filter { $0.id != engine.me } }

    var body: some View {
        Form {
            Section {
                TextField("What needs approval? (e.g. Travel to Pune)", text: $title, axis: .vertical).lineLimit(1...3)
                TextField("Details (optional)", text: $details, axis: .vertical).lineLimit(2...6)
                TextField("Amount (optional)", text: $amountText).keyboardType(.decimalPad)
            } footer: {
                if let task { Text("Linked to task “\(task.title)”.") }
            }
            .lookRows()

            Section("Who approves") {
                if candidates.isEmpty {
                    Text("Add people to this chat first.").foregroundStyle(look.textSecondary)
                }
                ForEach(candidates) { m in
                    Button {
                        if approvers.contains(m.id) { approvers.remove(m.id) } else { approvers.insert(m.id) }
                    } label: {
                        HStack {
                            AvatarView(name: engine.name(of: m.id), imageData: engine.contact(m.id)?.avatar, size: 30)
                            VStack(alignment: .leading) {
                                Text(engine.contact(m.id)?.name ?? m.name).foregroundStyle(Color.primary)
                                if m.role != .member { Text(m.role.title).font(.caption2).foregroundStyle(look.accent) }
                            }
                            Spacer()
                            Image(systemName: approvers.contains(m.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(approvers.contains(m.id) ? look.accent : look.textSecondary)
                        }
                    }
                }
            }
            .lookRows()

            Section {
                AttachmentAdder(pending: $pending, title: "Attach quote, bill or document")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Request approval")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    engine.requestApproval(in: conv, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                           details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                                           amount: Double(amountText.replacingOccurrences(of: ",", with: "")),
                                           approvers: candidates.map(\.id).filter { approvers.contains($0) },
                                           taskID: task?.id, attachments: pending.refs, uploads: pending.uploads)
                    Haptics.success()
                    dismiss()
                }
                .bold()
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || approvers.isEmpty)
            }
        }
        .onAppear {
            if approvers.isEmpty {
                // Default: the group's owner/admins, or the other person in a one-to-one chat.
                let managers = candidates.filter { $0.role != .member }.map(\.id)
                approvers = Set(managers.isEmpty && candidates.count == 1 ? candidates.map(\.id) : managers)
            }
            if let task, title.isEmpty { title = task.title }
        }
    }
}

/// All approvals: waiting for me, sent by me, and history.
struct ApprovalsListView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Query(sort: \Approval.createdAt, order: .reverse) private var all: [Approval]

    var body: some View {
        List {
            let waiting = all.filter { $0.status == .pending && $0.approvers.contains(engine.me) && $0.decisions[engine.me] == nil }
            let mine = all.filter { $0.requestedBy == engine.me && $0.status == .pending }
            let done = all.filter { $0.status != .pending }
            if all.isEmpty {
                EmptyStateView(icon: "checkmark.seal", title: "No approvals yet",
                               message: "In any chat tap + → Request approval, or use the button on a task.")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            if !waiting.isEmpty { section("Waiting for you", waiting) }
            if !mine.isEmpty { section("Sent by you · pending", mine) }
            if !done.isEmpty { section("Decided", done) }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Approvals")
    }

    private func section(_ title: String, _ items: [Approval]) -> some View {
        Section(title) {
            ForEach(items) { a in
                VStack(alignment: .leading, spacing: 6) {
                    ApprovalCard(approvalID: a.id)
                    Button {
                        router.show(conversation: a.convID)
                    } label: {
                        Label("\(engine.conversation(a.convID)?.title ?? "Chat") · \(engine.name(of: a.requestedBy)) · \(Fmt.chatTime(a.createdAt))",
                              systemImage: "bubble.left")
                            .font(.caption2).foregroundStyle(look.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
        .lookRows()
    }
}
