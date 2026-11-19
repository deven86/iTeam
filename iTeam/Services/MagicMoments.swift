import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// ✨ Magic moment — a message that appears at a chosen time.
/// It is uploaded immediately (encrypted, silent), kept hidden on the recipient's phone, and
/// revealed with a notification at the chosen time — even if the sender's phone is off.
/// Also handles disappearing messages (deleting expired ones on this device).
@MainActor
enum MagicMoments {
    static func notificationID(_ messageID: String) -> String { "magic." + messageID }

    static func schedule(_ m: Message, from: String, group: String?, muted: Bool) {
        guard let at = m.showAt else { return }
        let c = UNMutableNotificationContent()
        c.title = group ?? from
        if group != nil { c.subtitle = from }
        c.body = AppGroup.showPreviews ? (m.text.isEmpty ? "✨ Sent you a magic moment" : "✨ " + m.text) : "✨ New message"
        c.threadIdentifier = m.convID
        c.userInfo = ["conv": m.convID]
        if !muted { c.sound = .default }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID(m.id), content: c,
                                                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    static func cancel(_ messageID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID(messageID)])
    }

    /// Reveals magic moments whose time has come and removes expired disappearing messages.
    static func tick(_ engine: SyncEngine) {
        guard let ctx = engine.context else { return }
        let now = Date.now
        let due = (try? ctx.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.magicPending }))) ?? []
        var changed = false
        for m in due where (m.showAt ?? .distantPast) <= now {
            m.magicPending = false
            if let conv = engine.conversation(m.convID), !m.deleted {
                conv.lastActivity = m.showAt ?? now
                conv.lastPreview = m.preview
                if engine.openConversation != conv.id { conv.unread += 1 }
                conv.archived = false
            }
            changed = true
        }
        let expired = (try? ctx.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.expiresAt != nil }))) ?? []
        for m in expired where (m.expiresAt ?? .distantFuture) <= now {
            ctx.delete(m)
            changed = true
        }
        if changed { engine.save() }
    }
}

/// Composer sheet: pick when the message should appear.
struct MagicMomentSheet: View {
    let text: String
    let send: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var when = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now

    private var quick: [(String, Date)] {
        let cal = Calendar.current
        let tomorrow9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: .now)!)!
        let tonight = cal.date(bySettingHour: 21, minute: 0, second: 0, of: .now)!
        let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: .now)!)
        var out = [("In 1 hour", Date.now.addingTimeInterval(3600))]
        if tonight > .now { out.append(("Tonight 9 PM", tonight)) }
        out.append(("At midnight", midnight))
        out.append(("Tomorrow 9 AM", tomorrow9))
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(text.isEmpty ? "Your message" : text).lineLimit(4)
                } header: { Text("✨ Magic moment") } footer: {
                    Text("It's delivered now, encrypted and hidden, then appears with a notification at the time you pick — even if your phone is off. You can cancel it before then.")
                }
                Section("When") {
                    ForEach(quick, id: \.0) { q in
                        Button { when = q.1 } label: {
                            HStack { Text(q.0); Spacer(); if abs(when.timeIntervalSince(q.1)) < 60 { Image(systemName: "checkmark").foregroundStyle(look.accent) } }
                        }
                    }
                    DatePicker("Pick a time", selection: $when, in: Date.now.addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle("Magic moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Schedule") { send(when); dismiss() }.disabled(when <= .now) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
