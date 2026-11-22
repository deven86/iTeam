import SwiftUI
import SwiftData
import CoreLocation

/// Find people and businesses near me who chose to be findable, and be findable myself (opt-in, expires).
struct NearbyView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @StateObject private var nearby = Nearby.shared
    @Query(filter: #Predicate<Contact> { $0.blocked }) private var blockedContacts: [Contact]
    @Query(filter: #Predicate<Contact> { $0.saved }) private var saved: [Contact]
    @State private var radius = 5.0
    @State private var filter = "All"
    @State private var text = ""
    @State private var showSetup = false
    @State private var adding: String?
    @State private var added: Set<String> = []
    @State private var addError: String?

    private var shown: [Nearby.Listing] {
        nearby.results.filter { l in
            (filter == "All" || (filter == "People" ? l.kind == "person" : l.kind != "person")) &&
            (text.isEmpty || l.name.localizedCaseInsensitiveContains(text) || l.category.localizedCaseInsensitiveContains(text) || l.about.localizedCaseInsensitiveContains(text))
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            visibility
            VStack(spacing: 10) {
                HStack {
                    Text("Within \(Int(radius)) km").font(.subheadline.bold()).frame(width: 110, alignment: .leading)
                    Slider(value: $radius, in: 1...15, step: 1)
                }
                Picker("Show", selection: $filter) { ForEach(["All", "People", "Businesses"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                TextField("Search name or category (e.g. plumber, gym)", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await nearby.search(me: engine.me, blocked: Set(blockedContacts.map(\.userID)), radiusKm: radius) }
                } label: { Label(nearby.busy ? "Searching…" : "Search nearby", systemImage: "location.magnifyingglass").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large).disabled(nearby.busy)
            }
            .lookCard()
            if let e = nearby.error ?? addError { Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(look.danger).lookCard() }
            if !nearby.busy && nearby.results.isEmpty {
                Text("Only people and businesses who turned on “Be findable nearby” appear here. Distances are approximate (about 1 km).")
                    .font(.footnote).foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
            }
            ForEach(shown) { l in row(l) }
        }
        .sheet(isPresented: $showSetup) { NavigationStack { NearbySetupView() } }
    }

    private var visibility: some View {
        HStack(spacing: 12) {
            Image(systemName: nearby.visibleUntil == nil ? "eye.slash.fill" : "dot.radiowaves.left.and.right")
                .font(.title2).foregroundStyle(nearby.visibleUntil == nil ? look.textSecondary : look.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(nearby.visibleUntil == nil ? "You're not findable" : "You're findable nearby").font(.subheadline.bold())
                Text(nearby.visibleUntil.map { "Until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Let nearby iTeam users find you or your business.")
                    .font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer()
            Button(nearby.visibleUntil == nil ? "Turn on" : "Change") { showSetup = true }.buttonStyle(.glass)
        }
        .lookCard()
    }

    private func row(_ l: Nearby.Listing) -> some View {
        let known = saved.contains { $0.userID == l.id } || added.contains(l.id)
        return HStack(spacing: 12) {
            AvatarView(name: l.name, imageData: nil, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(l.name).font(.headline)
                Text([l.kind == "person" ? "" : l.category, String(format: "≈ %.1f km", l.km)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(look.textSecondary)
                if !l.about.isEmpty { Text(l.about).font(.caption).lineLimit(2) }
            }
            Spacer()
            if known {
                Label("Added", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(look.success).font(.title2)
            } else {
                Button(adding == l.id ? "…" : "Add") { Task { await add(l) } }.buttonStyle(.glassProminent).disabled(adding != nil)
            }
        }
        .lookCard()
    }

    private func add(_ l: Nearby.Listing) async {
        adding = l.id; addError = nil
        defer { adding = nil }
        do {
            _ = try await engine.addContact(SyncEngine.Invite(userID: l.id, publicKey: l.publicKey, name: l.name))
            added.insert(l.id)
            Haptics.big()
        } catch { addError = error.localizedDescription }
    }
}

struct NearbySetupView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var nearby = Nearby.shared
    @AppStorage("nearby.kind") private var kind = "person"
    @AppStorage("nearby.name") private var name = ""
    @AppStorage("nearby.cat") private var category = "Other"
    @AppStorage("nearby.about") private var about = ""
    @State private var hours = 24

    var body: some View {
        Form {
            Section {
                Picker("Show me as", selection: $kind) {
                    Text("Person").tag("person"); Text("Business / professional").tag("business")
                }
                .pickerStyle(.segmented)
                TextField(kind == "person" ? "Name shown" : "Business name", text: $name)
                if kind != "person" {
                    Picker("Category", selection: $category) { ForEach(Nearby.categories, id: \.self) { Text($0).tag($0) } }
                }
                TextField("One line about you (optional)", text: $about, axis: .vertical).lineLimit(1...3)
                Picker("Findable for", selection: $hours) {
                    Text("1 hour").tag(1); Text("8 hours").tag(8); Text("1 day").tag(24); Text("7 days").tag(168); Text("30 days").tag(720)
                }
            } footer: {
                Text("Shown to iTeam users within about 15 km: this name, the line above and your distance rounded to about 1 km — never your exact location, phone or email. People who find you can add you and message you; you can block anyone. It switches off by itself when the time ends.")
            }
            if nearby.visibleUntil != nil {
                Section { Button("Stop being findable", role: .destructive) { Task { await nearby.remove(userID: engine.me); dismiss() } } }
            }
            if let e = nearby.error { Section { Text(e).foregroundStyle(.red) } }
        }
        .navigationTitle("Be findable nearby")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if name.isEmpty { name = engine.myName } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(nearby.busy ? "…" : "Turn on") {
                    Task {
                        if await nearby.publish(userID: engine.me, publicKey: engine.myPublicKey, name: name.trimmingCharacters(in: .whitespaces),
                                                kind: kind, category: kind == "person" ? "" : category, about: about, hours: hours) {
                            Haptics.big(); dismiss()
                        }
                    }
                }
                .bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || nearby.busy)
            }
        }
    }
}
