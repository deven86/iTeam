import SwiftUI
import SwiftData
import CoreLocation

/// Family Safety (free): one long-press SOS to your emergency chats with your location,
/// "I'm safe", and quick Check In.
struct SafetyView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @ObservedObject private var monitor = CheckInMonitor.shared
    @Query(filter: #Predicate<Conversation> { !$0.left && !$0.isDemo }, sort: \Conversation.lastActivity, order: .reverse) private var chats: [Conversation]
    @AppStorage("safety.chats") private var saved = ""
    @State private var pressing = false
    @State private var sent: Date?
    @State private var choose = false
    @State private var checkInFor: Conversation?

    private var targets: [Conversation] {
        let ids = Set(saved.split(separator: ",").map(String.init))
        return chats.filter { ids.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Text("Hold for 2 seconds").font(.caption).foregroundStyle(look.textSecondary)
                        Circle()
                            .fill(LinearGradient(colors: [.red, Color(hex: 0xB31217)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 170, height: 170)
                            .overlay(Text("SOS").font(.system(size: 48, weight: .black)).foregroundStyle(.white))
                            .scaleEffect(pressing ? 0.92 : 1)
                            .shadow(color: .red.opacity(0.5), radius: pressing ? 30 : 12)
                            .onLongPressGesture(minimumDuration: 2, pressing: { p in withAnimation(.easeInOut(duration: 0.2)) { pressing = p } }) { sendSOS() }
                        if let sent { Label("SOS sent at \(sent.formatted(date: .omitted, time: .shortened)) to \(targets.count) chat(s)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        Button("I'm safe now", systemImage: "hand.thumbsup.fill") { broadcast("✅ I'm safe now. Thank you.") }
                            .buttonStyle(.glass).disabled(targets.isEmpty)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .listRowBackground(Color.clear)

                Section {
                    if targets.isEmpty { Text("Choose who gets your SOS first.").foregroundStyle(look.warning) }
                    ForEach(targets) { c in
                        HStack {
                            AvatarView(name: c.title, imageData: c.avatar, size: 30, isGroup: c.isGroup)
                            Text(c.title)
                            Spacer()
                            Button("Check In") { checkInFor = c }.font(.caption).buttonStyle(.bordered)
                        }
                    }
                    Button("Choose emergency chats", systemImage: "person.2.badge.plus") { choose = true }
                } header: { Text("Emergency chats") } footer: {
                    Text("SOS sends your location (Apple Maps + Google Maps links) as a loud notification to these chats. Also save emergency numbers: 112 (India) works from any phone.")
                }
                .lookRows()

                Section {
                    Link(destination: URL(string: "tel:112")!) { Label("Call 112 — Emergency", systemImage: "phone.fill").foregroundStyle(.red) }
                }
                .lookRows()
            }
            .lookScreen()
            .navigationTitle("Family Safety")
            .sheet(isPresented: $choose) { NavigationStack { SafetyChatPicker(saved: $saved) } }
            .sheet(item: $checkInFor) { c in NavigationStack { CheckInSheet(conv: c) } }
            .onAppear { monitor.requestAlways() }
        }
    }

    private func sendSOS() {
        Haptics.success()
        var text = "🆘 SOS from \(engine.myName) — I need help."
        if let l = monitor.lastLocation?.coordinate {
            text += "\nLocation: https://maps.apple.com/?q=\(l.latitude),\(l.longitude)\nGoogle Maps: https://www.google.com/maps?q=\(l.latitude),\(l.longitude)"
        } else {
            text += "\n(Location unavailable — please call me.)"
        }
        broadcast(text)
        sent = .now
    }

    private func broadcast(_ text: String) {
        for c in targets { engine.sendText(text, in: c) }
    }
}

struct SafetyChatPicker: View {
    @Binding var saved: String
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Conversation> { !$0.left && !$0.isDemo }, sort: \Conversation.title) private var chats: [Conversation]
    var body: some View {
        let ids = Set(saved.split(separator: ",").map(String.init))
        List(chats) { c in
            Button {
                var s = ids
                if s.contains(c.id) { s.remove(c.id) } else { s.insert(c.id) }
                saved = s.sorted().joined(separator: ",")
            } label: {
                HStack {
                    AvatarView(name: c.title, imageData: c.avatar, size: 30, isGroup: c.isGroup)
                    Text(c.title).foregroundStyle(Color.primary)
                    Spacer()
                    if ids.contains(c.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Emergency chats")
        .toolbar { Button("Done") { dismiss() } }
    }
}
