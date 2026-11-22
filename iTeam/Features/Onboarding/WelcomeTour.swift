import SwiftUI

/// After sign-in: "What do you do?" adds the matching professional modules, then a short tour of the core app.
struct WelcomeTour: View {
    @EnvironmentObject var modules: ModuleRegistry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @AppStorage("onboard.tour.done") private var done = false
    @State private var step = 0
    @State private var picked: Set<String> = []

    struct Profession: Identifiable { let id: String; let title: String; let icon: String; let modules: [ModuleInfo] }

    static let professions: [Profession] = [
        Profession(id: "advocate", title: "Advocate / legal", icon: "building.columns.fill", modules: [ModuleRegistry.legal]),
        Profession(id: "teacher", title: "Teacher / tutor", icon: "graduationcap.fill", modules: [ModuleRegistry.tuition]),
        Profession(id: "trainer", title: "Gym / fitness trainer", icon: "dumbbell.fill", modules: [ModuleRegistry.gymTraining]),
        Profession(id: "doctor", title: "Doctor / clinic", icon: "cross.case.fill", modules: [ModuleRegistry.clinic, ModuleRegistry.doctorPatient]),
        Profession(id: "shop", title: "Shop owner / trader", icon: "indianrupeesign.circle.fill", modules: [ModuleRegistry.khata, ModuleRegistry.financePro]),
        Profession(id: "landlord", title: "Landlord / property", icon: "house.and.flag.fill", modules: [ModuleRegistry.rent]),
        Profession(id: "business", title: "Business owner / employer", icon: "briefcase.fill", modules: [ModuleRegistry.businessPro, ModuleRegistry.financePro]),
        Profession(id: "wellness", title: "Wellness / meditation coach", icon: "leaf.fill", modules: [ModuleRegistry.mindfulness]),
        Profession(id: "pets", title: "Pet parent / vet", icon: "pawprint.fill", modules: [ModuleRegistry.petCare]),
        Profession(id: "family", title: "Family / personal use", icon: "house.fill", modules: []),
        Profession(id: "student", title: "Student", icon: "book.fill", modules: []),
    ]

    static func tab(for moduleID: String) -> Router.TabID? {
        switch moduleID {
        case "gym-training": .gym
        case "business-pro": .tasks
        case "finance-pro", "finance": .finance
        case "mindfulness": .mind
        case "doctor-patient": .doctor
        default: Router.TabID(rawValue: moduleID)
        }
    }

    private let cards: [(String, String, String)] = [
        ("bubble.left.and.bubble.right.fill", "Chats & groups", "Encrypted chats, voice notes, photos, view-once media, ✨ magic moments and FaceTime calls. Tap + in a chat for tasks, polls, meetings, approvals and games."),
        ("checklist", "Turn talk into work", "Long-press any message → Create Business Task. Assign, set deadlines, follow up — open tasks show as chips at the top of the chat."),
        ("square.grid.2x2.fill", "Modules", "Attendance, Finance, Care, Events, Travel, Bills, Kids and more are free for life. Professional modules are in the Module Store — free for your first year."),
        ("bag.fill", "The Module Store", "Settings → Module Store lists every module: Attendance, Finance, Care with pets, Events, Travel, Bills, Kids, Rooms and Safety are free for life. Legal, Tuition, Clinic, Gym, Khata, Rent, Pet Care, Survey and Finance Pro are free for your first year — tap Get to add any."),
        ("star.fill", "Your bottom bar", "The modules you picked are pinned to the bottom bar. Change them any time in Settings → Modules → Bottom bar."),
        ("gearshape.fill", "Make it yours", "Settings → Notifications chooses what reaches you. Pin your favourite modules to the bottom bar. Change your QR code any time."),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 { professionStep } else { tourStep }
            }
            .padding()
            .lookScreen()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { finish() } } }
        }
        .interactiveDismissDisabled()
    }

    private var professionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What do you do?").font(.largeTitle.bold())
                Text("We'll add the tools for your work. Pick any that fit — you can change this later in the Module Store.")
                    .foregroundStyle(look.textSecondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Self.professions) { p in
                        Button {
                            if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) }
                            Haptics.tap()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: p.icon).font(.title2)
                                Text(p.title).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 84)
                            .padding(6)
                            .background(picked.contains(p.id) ? look.accent.opacity(0.25) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(picked.contains(p.id) ? look.accent : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                let adds = Self.professions.filter { picked.contains($0.id) }.flatMap(\.modules)
                if !adds.isEmpty {
                    Text("Adding: " + Array(Set(adds.map(\.title))).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(look.textSecondary)
                }
                Button {
                    for m in adds { modules.setOn(m, true) }
                    // Put the work module right in the bottom bar for one-tap access.
                    let tabs = adds.compactMap { Self.tab(for: $0.id) }
                    if !tabs.isEmpty {
                        let current = modules.pinned.compactMap(Router.TabID.init(rawValue:))
                        var pins = Array(tabs.prefix(2))
                        for t in current + [.views, .tasks] where !pins.contains(t) && pins.count < ModuleRegistry.maxPinned { pins.append(t) }
                        modules.setPins(pins)
                    }
                    withAnimation { step = 1 }
                } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large)
            }
        }
    }

    private var tourStep: some View {
        let i = min(step - 1, cards.count - 1)
        let c = cards[i]
        return VStack(spacing: 22) {
            Spacer()
            Image(systemName: c.0).font(.system(size: 64)).foregroundStyle(look.gradient)
            Text(c.1).font(.title.bold())
            Text(c.2).multilineTextAlignment(.center).foregroundStyle(look.textSecondary)
            HStack(spacing: 6) { ForEach(0..<cards.count, id: \.self) { j in Circle().fill(j == i ? look.accent : Color.secondary.opacity(0.3)).frame(width: 8, height: 8) } }
            Spacer()
            Button {
                if step < cards.count { withAnimation { step += 1 } } else { finish() }
            } label: { Text(step < cards.count ? "Next" : "Start using iTeam").frame(maxWidth: .infinity) }
            .buttonStyle(.glassProminent).controlSize(.large)
            if step == 3 {
                Button("Open the Module Store now") { finish(); Task { @MainActor in try? await Task.sleep(for: .milliseconds(500)); Router.shared.openModuleStore = true } }
                    .font(.footnote)
            }
        }
    }

    private func finish() {
        done = true
        Haptics.success()
        dismiss()
    }
}
