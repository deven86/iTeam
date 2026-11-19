import SwiftUI

/// Settings → Modules: every module, what it solves, previews, price and Subscribe.
struct ModuleStoreView: View {
    @EnvironmentObject var modules: ModuleRegistry
    @ObservedObject private var store = Store.shared
    @Environment(\.look) private var look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Chat is always free. Add only what your team needs.")
                    .font(.subheadline).foregroundStyle(look.textSecondary)
                ForEach(Array(ModuleRegistry.all.enumerated()), id: \.element.id) { i, m in
                    NavigationLink { ModuleDetailView(module: m) } label: { card(m) }
                        .buttonStyle(PressStyle())
                        .appear(i)
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .lookScreen()
        .navigationTitle("Module Store")
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
            Chip(text: "Included", icon: "checkmark", color: look.success)
        case .comingSoon:
            Chip(text: "Coming soon", icon: "clock", color: look.textSecondary)
        case .paid:
            if let id = module.productID, store.isUnlocked(id) {
                Chip(text: store.active.contains(id) ? "Active" : "Unlocked for testing", icon: "checkmark.seal.fill", color: look.success)
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

    static func price(_ m: ModuleInfo, _ store: Store) -> String {
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
                        Text("Billed monthly through your Apple ID. Auto-renews until cancelled in Settings → Apple ID → Subscriptions. If a subscription ends, everything you created stays readable and exportable.")
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
    }

    @ViewBuilder
    private var action: some View {
        switch module.availability {
        case .included:
            Toggle("Show in the app", isOn: Binding(get: { modules.isVisible(module) }, set: { modules.setOn(module, $0) }))
        case .comingSoon:
            Label("We're building this. It will appear here when ready.", systemImage: "hammer").font(.subheadline)
        case .paid:
            if unlocked {
                Label("Active on this Apple ID", systemImage: "checkmark.seal.fill").foregroundStyle(look.success)
                Toggle("Show in the app", isOn: Binding(get: { modules.isVisible(module) }, set: { modules.setOn(module, $0) }))
            } else if let id = module.productID {
                Button {
                    Task { busy = true; await store.purchase(id); busy = false }
                } label: {
                    Group { if busy { ProgressView() } else { Text("Subscribe · \(Self.price(module, store))") } }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                Button("Restore purchases") { Task { await store.restore() } }.font(.subheadline)
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

    @ViewBuilder
    private var content: some View {
        switch preview {
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
