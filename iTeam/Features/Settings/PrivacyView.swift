import SwiftUI
import SwiftData
import LocalAuthentication

/// Settings → Privacy, modelled on WhatsApp's privacy page.
struct PrivacyView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var lock: AppLock
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.blocked }) private var blocked: [Contact]
    @Query(filter: #Predicate<Conversation> { $0.locked }) private var lockedChats: [Conversation]

    @State private var lastSeen = MyDetails.lastSeenEveryone
    @State private var photoContacts = MyDetails.photoContactsOnly
    @State private var about = MyDetails.about
    @State private var aboutContacts = MyDetails.aboutContacts
    @State private var groupsContacts = MyDetails.groupsContactsOnly
    @State private var receipts = MyDetails.readReceipts
    @State private var timer = MyDetails.defaultTimer
    @State private var shareFT = MyDetails.shareFaceTime
    @AppStorage("privacy.nowPlaying") private var nowPlaying = false
    @AppStorage("views.defaultMiniAudience") private var miniAudience = "contacts"

    var body: some View {
        Form {
            Section {
                Picker("Last seen & online", selection: $lastSeen) {
                    Text("Everyone").tag(true); Text("Nobody").tag(false)
                }
                .onChange(of: lastSeen) { _, v in
                    MyDetails.lastSeenEveryone = v
                    Task { if v { UserDefaults.standard.set(0, forKey: "lastSeen.pushed"); await engine.touchLastSeen() } else { await engine.clearLastSeen() } }
                }
                Picker("Profile photo", selection: $photoContacts) {
                    Text("My contacts").tag(true); Text("Everyone").tag(false)
                }
                .onChange(of: photoContacts) { _, v in MyDetails.photoContactsOnly = v; Task { await engine.updatePhotoSharing() } }
                Picker("About", selection: $aboutContacts) {
                    Text("My contacts").tag(true); Text("Nobody").tag(false)
                }
                .onChange(of: aboutContacts) { _, v in MyDetails.aboutContacts = v; engine.updateAbout() }
                if aboutContacts {
                    TextField("About (e.g. Available, At the gym)", text: $about)
                        .onSubmit { MyDetails.about = about; engine.updateAbout() }
                }
                Picker("Groups — who can add me", selection: $groupsContacts) {
                    Text("My contacts").tag(true); Text("Everyone").tag(false)
                }
                .onChange(of: groupsContacts) { _, v in MyDetails.groupsContactsOnly = v }
                Picker("mini — default audience", selection: $miniAudience) {
                    Text("Everyone I chat with").tag("contacts"); Text("Only people I choose").tag("choose")
                }
            } footer: {
                Text("Last seen is shown only if you set Everyone, and then you see others' last seen too. With Groups set to My contacts, a group made by someone not in your contacts waits for you to Join or Leave.")
            }
            .lookRows()

            Section {
                Toggle("Read receipts", isOn: $receipts)
                    .onChange(of: receipts) { _, v in MyDetails.readReceipts = v }
            } footer: {
                Text("If you turn this off, people won't see when you've read their messages. Delivered ticks still show.")
            }
            .lookRows()

            Section {
                Picker("Default message timer", selection: $timer) {
                    ForEach(MyDetails.timers, id: \.1) { Text($0.0).tag($0.1) }
                }
                .onChange(of: timer) { _, v in MyDetails.defaultTimer = v }
            } header: { Text("Disappearing messages") } footer: {
                Text("New chats you start use this timer. Change it for any chat in its info screen.")
            }
            .lookRows()

            Section {
                Toggle(isOn: $lock.lockEnabled) { Label("App lock (\(lock.biometryName))", systemImage: "faceid") }
                NavigationLink { LockedChatsView() } label: {
                    LabeledContent { Text("\(lockedChats.count)") } label: { Label("Chat lock", systemImage: "lock.rectangle.stack") }
                }
            } footer: { Text("Lock a chat from its info screen. Locked chats are hidden from the list and open with \(lock.biometryName).") }
            .lookRows()

            Section {
                Toggle("Share my FaceTime with contacts", isOn: $shareFT)
                    .onChange(of: shareFT) { _, v in
                        MyDetails.shareFaceTime = v && !MyDetails.facetime.isEmpty
                        engine.updateFaceTimeSharing()
                    }
                Toggle("Share what I'm listening to", isOn: $nowPlaying)
                NavigationLink { BlockedView() } label: { Label("Blocked (\(blocked.count))", systemImage: "hand.raised") }
            } header: { Text("Calls, music & contacts") } footer: {
                Text("Calls use FaceTime. Set the FaceTime number or email in Edit profile. Now Playing works with Apple Music.")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Privacy")
        .onDisappear {
            if about != MyDetails.about { MyDetails.about = about; engine.updateAbout() }
        }
    }
}

/// Locked chats, opened with Face ID.
struct LockedChatsView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Conversation> { $0.locked }, sort: \Conversation.lastActivity, order: .reverse) private var chats: [Conversation]
    @State private var open = false

    var body: some View {
        List {
            if open {
                if chats.isEmpty {
                    Text("No locked chats. Open a chat's info and turn on Lock chat.").foregroundStyle(look.textSecondary)
                }
                ForEach(chats) { c in
                    NavigationLink { ChatView(convID: c.id) } label: { ConversationRow(conv: c) }
                        .swipeActions { Button("Unlock") { c.locked = false; engine.save() }.tint(.orange) }
                }
            } else {
                Button("Unlock to view") { Task { open = await DeviceAuth.check("Open locked chats") } }
            }
        }
        .lookScreen()
        .navigationTitle("Locked chats")
        .task { open = await DeviceAuth.check("Open locked chats") }
    }
}

enum DeviceAuth {
    @MainActor
    static func check(_ reason: String) async -> Bool {
        let c = LAContext()
        var err: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}

