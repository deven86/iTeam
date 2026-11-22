import SwiftUI
import UserNotifications

/// Settings → Notifications: choose which kinds of notifications reach you.
struct NotificationSettingsView: View {
    @State private var muted = AppGroup.mutedKinds
    @State private var previews = AppGroup.showPreviews
    @State private var allowed = true

    var body: some View {
        List {
            if !allowed {
                Section {
                    Button("Notifications are off for iTeam — open Settings", systemImage: "bell.slash") {
                        if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                    }
                }
            }
            Section {
                Toggle("Show message previews", isOn: $previews)
                    .onChange(of: previews) { _, v in AppGroup.showPreviews = v }
            }
            Section {
                ForEach(NotifyRoute.kinds) { k in
                    Toggle(isOn: Binding(get: { !muted.contains(k.id) }, set: { on in
                        if on { muted.remove(k.id) } else { muted.insert(k.id) }
                        AppGroup.mutedKinds = muted
                    })) { Label(k.title, systemImage: k.icon) }
                }
            } header: { Text("Notify me about") } footer: {
                Text("Turned-off kinds arrive silently, with nothing shown. Tapping a notification opens the exact item — the task, case update, meeting or bill. Muting a single chat is in that chat's info.")
            }
        }
        .lookScreen()
        .navigationTitle("Notifications")
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        }
    }
}
