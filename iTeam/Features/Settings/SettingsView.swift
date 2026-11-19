import SwiftUI
import SwiftData
import PhotosUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var modules: ModuleRegistry
    @EnvironmentObject var looks: LookManager
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved }, sort: \Contact.name) private var contacts: [Contact]
    @Query(filter: #Predicate<Contact> { $0.blocked }) private var blocked: [Contact]

    @State private var showQR = false
    @State private var editProfile = false
    @State private var previews = AppGroup.showPreviews
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var cacheSize = 0
    @State private var exportURL: URL?
    @State private var confirmErase = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { editProfile = true } label: {
                        HStack(spacing: 14) {
                            AvatarView(name: engine.myName, imageData: engine.myAvatar, size: 64)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(engine.myName).font(.title3.bold())
                                Text("Edit name and photo").font(.caption).foregroundStyle(look.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Button { showQR = true } label: { Label("My QR code & invite link", systemImage: "qrcode") }
                }
                .lookRows()

                Section("Look & feel") {
                    NavigationLink { AppearanceView() } label: {
                        Label { HStack { Text("Appearance"); Spacer(); Text(looks.style.title).foregroundStyle(look.textSecondary) } } icon: { Image(systemName: "paintbrush.fill") }
                    }
                }
                .lookRows()

                Section {
                    LabeledContent {
                        Text(notifLabel).foregroundStyle(notifStatus == .authorized ? look.success : look.warning)
                    } label: {
                        Label("Notifications", systemImage: "bell.badge.fill")
                    }
                    if notifStatus != .authorized {
                        Button("Turn on notifications") {
                            Task {
                                _ = await Reminders.shared.requestAuthorization()
                                await loadStatus()
                                if notifStatus != .authorized, let url = URL(string: UIApplication.openSettingsURLString) {
                                    await UIApplication.shared.open(url)
                                }
                            }
                        }
                    }
                    if let problem = engine.pushProblem {
                        Label("Background alerts not active yet: \(problem)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(look.warning)
                    }
                    Toggle("Show message text on Lock Screen", isOn: $previews)
                        .onChange(of: previews) { _, v in AppGroup.showPreviews = v }
                    NavigationLink { HowNotificationsWorkView() } label: { Label("How notifications work", systemImage: "questionmark.circle") }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Messages and task assignments arrive as Apple push notifications through iCloud, even when iTeam is closed. Deadline reminders are scheduled on this device and work offline.")
                }
                .lookRows()

                Section {
                    ForEach(ModuleRegistry.all) { m in
                        Toggle(isOn: Binding(get: { modules.isOn(m) }, set: { modules.setOn(m, $0) })) {
                            Label { VStack(alignment: .leading) { Text(m.title); Text(m.summary).font(.caption).foregroundStyle(look.textSecondary) } } icon: { Image(systemName: m.icon) }
                        }
                        .disabled(!modules.isEntitled(m))
                    }
                    ForEach(ModuleRegistry.upcoming, id: \.0) { item in
                        Label { VStack(alignment: .leading) { Text(item.0); Text(item.1).font(.caption).foregroundStyle(look.textSecondary) } } icon: { Image(systemName: item.2) }
                            .foregroundStyle(look.textSecondary)
                    }
                } header: {
                    Text("Modules")
                } footer: {
                    Text("Chat is always free. Modules can be switched off; turning one off hides it but never deletes its data.")
                }
                .lookRows()

                Section("Privacy & security") {
                    Toggle(isOn: $lock.lockEnabled) { Label("Lock with \(lock.biometryName)", systemImage: "faceid") }
                    LabeledContent("Your security code", value: E2E.fingerprint(engine.myPublicKey)).font(.callout)
                    NavigationLink { ContactsListView() } label: { Label("Contacts (\(contacts.count))", systemImage: "person.2") }
                    if !blocked.isEmpty {
                        NavigationLink { BlockedView() } label: { Label("Blocked (\(blocked.count))", systemImage: "hand.raised") }
                    }
                }
                .lookRows()

                Section {
                    SyncStatusCard().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    LabeledContent("Downloaded files", value: Fmt.bytes(cacheSize))
                    Button("Clear downloaded files") { Attachments.clearCache(); cacheSize = 0 }
                    Button {
                        exportURL = DataExport.make(context: engine.context, me: engine.me)
                    } label: { Label("Export my chats and tasks (JSON)", systemImage: "square.and.arrow.up") }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share export file", systemImage: "doc.badge.arrow.up") }
                    }
                    Button("Remove demo chats") { DemoChats.remove(engine) }
                    Button("Erase all data on this device", role: .destructive) { confirmErase = true }
                } header: {
                    Text("Storage & sync")
                } footer: {
                    Text("Your chats live on this device. Encrypted copies wait in iCloud for up to \(SyncEngine.retentionDays) days so your other devices and contacts can pick them up, then they are deleted.")
                }
                .lookRows()

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    NavigationLink { AboutView() } label: { Label("How iTeam keeps your data", systemImage: "lock.shield") }
                }
                .lookRows()
            }
            .listStyle(.insetGrouped)
            .lookScreen()
            .navigationTitle("Settings")
            .sheet(isPresented: $showQR) { AddContactView() }
            .sheet(isPresented: $editProfile) { NavigationStack { EditProfileView() } }
            .confirmationDialog("Erase everything on this device?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { engine.eraseLocalData() }
            } message: {
                Text("Chats, tasks and contacts are removed from this iPhone/iPad. Your identity stays, so you can keep chatting.")
            }
            .task {
                await loadStatus()
                cacheSize = Attachments.cacheSize()
            }
        }
    }

    private var notifLabel: String {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        default: "Not set"
        }
    }

    private func loadStatus() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

struct EditProfileView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var name = ""
    @State private var avatar: Data?
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) {
                        AvatarView(name: name, imageData: avatar, size: 100)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
                TextField("Name", text: $name)
                if avatar != nil { Button("Remove photo", role: .destructive) { avatar = nil } }
            }
            .lookRows()
            if let error { Text(error).foregroundStyle(look.danger) }
        }
        .lookScreen()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .onAppear { name = engine.myName; avatar = engine.myAvatar }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = OnboardingView.avatarData(d) } }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await engine.cloud.saveProfile(userID: engine.me, name: clean, publicKey: engine.myPublicKey, avatar: avatar)
            engine.saveIdentity(id: engine.me, name: clean, avatar: avatar)
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.cloudMessage)"
        }
    }
}

struct ContactsListView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved }, sort: \Contact.name) private var contacts: [Contact]
    @State private var showAdd = false

    var body: some View {
        List {
            ForEach(contacts) { c in
                Button {
                    let conv = engine.directConversation(with: c)
                    router.show(conversation: conv.id)
                } label: { ContactRow(contact: c) }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Remove", role: .destructive) { c.saved = false; engine.save() }
                    Button("Block") { engine.setBlocked(c, true) }.tint(.orange)
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Contacts")
        .toolbar { Button { showAdd = true } label: { Image(systemName: "person.badge.plus") } }
        .sheet(isPresented: $showAdd) { AddContactView() }
        .overlay {
            if contacts.isEmpty {
                EmptyStateView(icon: "person.2", title: "No contacts", message: "Scan someone's QR code to add them.",
                               actionTitle: "Add contact") { showAdd = true }
            }
        }
    }
}

struct BlockedView: View {
    @EnvironmentObject var engine: SyncEngine
    @Query(filter: #Predicate<Contact> { $0.blocked }) private var blocked: [Contact]
    var body: some View {
        List {
            ForEach(blocked) { c in
                HStack {
                    ContactRow(contact: c)
                    Button("Unblock") { engine.setBlocked(c, false) }.buttonStyle(.glass)
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Blocked")
    }
}

struct HowNotificationsWorkView: View {
    @Environment(\.look) private var look
    var body: some View {
        List {
            Section("Works with no server") {
                row("bubble.left.fill", "New messages", "Delivered by Apple push through iCloud, even when iTeam is closed. The preview is decrypted on your phone.")
                row("person.crop.circle.badge.checkmark", "Tasks assigned to you, comments", "Same as messages.")
                row("alarm.fill", "Deadline reminders", "Scheduled on this device. They work offline and after a restart.")
            }
            .lookRows()
            Section("Good to know") {
                row("wifi.slash", "If your phone is offline", "Notifications arrive when it's back online. Messages wait in iCloud for \(SyncEngine.retentionDays) days.")
                row("bell.slash", "Muted chats", "Still arrive, silently, in Notification Center.")
                row("calendar.badge.clock", "Due-date changes by others", "Your reminder moves when the change reaches this device.")
                row("ipad.and.iphone", "iPhone and iPad", "Both get notifications if both are signed into the same iCloud account.")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Notifications")
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(look.textSecondary)
            }
        } icon: { Image(systemName: icon).foregroundStyle(look.accent) }
    }
}

struct AboutView: View {
    @Environment(\.look) private var look
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AppLogo(size: 64)
                Text("No servers. No phone number. No ads.").font(.title2.bold())
                point("iphone", "Your data lives on your devices", "Chats, tasks and contacts are stored in iTeam on your iPhone and iPad.")
                point("lock.fill", "End-to-end encrypted", "Every message, task and file is encrypted with Apple CryptoKit before it leaves your device. Only the people in the chat hold the keys.")
                point("icloud", "iCloud is just the postman", "Encrypted envelopes travel through Apple's iCloud and are deleted after \(SyncEngine.retentionDays) days. Apple can't read them, and neither can we.")
                point("person.badge.key", "You decide who can see what", "People only get the chats, groups and tasks you share with them. Removing someone from a group changes the key.")
                point("exclamationmark.triangle", "What no app can promise", "Once someone has read a message, they could copy or screenshot it. Removing their access stops future messages, not copies they already made.")
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
        }
        .lookScreen()
        .navigationTitle("Privacy")
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(look.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(look.textSecondary)
            }
        }
        .lookCard()
    }
}

/// Local export of everything readable, as one JSON file.
@MainActor
enum DataExport {
    struct Dump: Encodable {
        struct Chat: Encodable { var id, title, kind: String; var members: [String]; var messages: [Msg] }
        struct Msg: Encodable { var from, text: String; var at: Date; var files: [String] }
        struct TaskRow: Encodable { var title, notes, status, chat: String; var due: Date?; var assignees: [String]; var checklist: [String]; var comments: [String] }
        var exportedAt = Date.now
        var chats: [Chat]
        var tasks: [TaskRow]
    }

    static func make(context: ModelContext, me: String) -> URL? {
        let engine = SyncEngine.shared
        let convs = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let chats = convs.map { c in
            Dump.Chat(id: c.id, title: c.title, kind: c.kind, members: c.members.map(\.name),
                      messages: engine.messages(in: c.id).filter { !$0.deleted }.map {
                          Dump.Msg(from: $0.isSystem ? "system" : engine.name(of: $0.senderID), text: $0.text, at: $0.createdAt, files: $0.attachments.map(\.name))
                      })
        }
        let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>())) ?? []).filter { !$0.deleted }.map { t -> Dump.TaskRow in
            let tid = t.id
            let items = (try? context.fetch(FetchDescriptor<ChecklistItem>(predicate: #Predicate { $0.taskID == tid && !$0.deleted }))) ?? []
            let comments = (try? context.fetch(FetchDescriptor<TaskComment>(predicate: #Predicate { $0.taskID == tid }))) ?? []
            return Dump.TaskRow(title: t.title, notes: t.notes, status: t.status.title,
                                chat: t.convID.flatMap { engine.conversation($0)?.title } ?? "Personal",
                                due: t.dueAt, assignees: t.assignees.map { engine.name(of: $0) },
                                checklist: items.map { ($0.done ? "[x] " : "[ ] ") + $0.title },
                                comments: comments.map { "\(engine.name(of: $0.authorID)): \($0.body)" })
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Dump(chats: chats, tasks: tasks)) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iTeam-export-\(Date.now.formatted(.iso8601.year().month().day())).json")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}
