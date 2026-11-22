import SwiftUI
import SwiftData
import PhotosUI

struct GroupInfoView: View {
    @ObservedObject private var ai = AISettings.shared
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var editingTitle = false
    @State private var newTitle = ""
    @State private var showAdd = false
    @State private var photo: PhotosPickerItem?
    @State private var confirmLeave = false

    private var myRole: Role? { conv.role(of: engine.me) }
    private var canManage: Bool { (myRole?.canManage ?? false) && !conv.left }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        AvatarView(name: conv.title, imageData: conv.avatar, size: 96, isGroup: true)
                    }
                    .disabled(!canManage)
                    Text(conv.title).font(.title2.bold())
                    Text("\(conv.members.count) members · created \(conv.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(look.textSecondary)
                    if canManage {
                        Button("Rename") { newTitle = conv.title; editingTitle = true }.font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: Binding(get: { conv.muted }, set: { engine.setMuted(conv, $0) })) {
                    Label("Mute notifications", systemImage: "bell.slash")
                }
                NavigationLink { ChatMediaView(conv: conv) } label: {
                    Label("Media, links & docs", systemImage: "photo.on.rectangle.angled")
                }
                NavigationLink { ChatWallpaperPicker(conv: conv) } label: {
                    Label("Chat wallpaper", systemImage: "photo.artframe")
                }
                ChatPrivacyRows(conv: conv)
                Button {
                    dismiss()
                    router.go(.tasks)
                } label: {
                    Label("Group tasks", systemImage: "checklist")
                }
            }
            .lookRows()

            Section {
                Toggle(isOn: Binding(get: { ai.groupAI.contains(conv.id) }, set: { on in
                    if on {
                        ai.groupAI.insert(conv.id)
                        engine.sendText("🤖 \(engine.myName) turned on AI reports for this group. They run on \(engine.myName)'s phone with their own AI — no key is shared.", in: conv)
                    } else {
                        ai.groupAI.remove(conv.id)
                    }
                })) {
                    Label("Run this group's AI on my phone", systemImage: "sparkles")
                }
                .disabled(!ai.ready || conv.left)
            } header: {
                Text("Group AI")
            } footer: {
                Text(ai.ready
                     ? "Reports and summaries for this group are made on your phone and posted into the chat. Your key never leaves your phone — members only see the results."
                     : "Set up AI in Settings → AI first.")
            }
            .lookRows()

            Section("Members") {
                if canManage {
                    Button { showAdd = true } label: { Label("Add members", systemImage: "person.badge.plus") }
                }
                ForEach(conv.members.sorted { roleOrder($0.role) < roleOrder($1.role) }) { m in
                    memberRow(m)
                }
            }
            .lookRows()

            Section {
                Label("Messages and tasks in this group are end-to-end encrypted. Removing someone changes the group key, so they can't read anything sent afterwards.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(look.textSecondary)
            }
            .lookRows()

            Section {
                if !conv.left {
                    Button("Leave group", role: .destructive) { confirmLeave = true }
                }
                Button("Delete chat from this device", role: .destructive) {
                    engine.deleteLocally(conv)
                    dismiss()
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Group info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .alert("Rename group", isPresented: $editingTitle) {
            TextField("Group name", text: $newTitle)
            Button("Save") {
                let t = newTitle.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && t != conv.title { engine.updateGroup(conv, title: t, note: "\(engine.myName) renamed the group to “\(t)”") }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Leave “\(conv.title)”?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave group", role: .destructive) { engine.leave(conv) }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { AddMembersView(conv: conv) }
        }
        .onChange(of: photo) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let a = OnboardingView.avatarData(d) {
                    engine.updateGroup(conv, avatar: a)
                }
            }
        }
    }

    private func roleOrder(_ r: Role) -> Int { r == .owner ? 0 : (r == .admin ? 1 : 2) }

    private func memberRow(_ m: MemberInfo) -> some View {
        let c = engine.contact(m.id)
        let name = m.id == engine.me ? "\(engine.myName) (you)" : (c?.saved == true ? c!.name : m.name)
        return HStack(spacing: 12) {
            AvatarView(name: name, imageData: m.id == engine.me ? engine.myAvatar : c?.avatar, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.weight(.medium))
                if m.role != .member { Text(m.role.title).font(.caption).foregroundStyle(look.accent) }
            }
            Spacer()
            if canManage && m.id != engine.me && m.role != .owner {
                Menu {
                    if m.role == .member {
                        Button("Make admin", systemImage: "star") { engine.setRole(conv, m.id, .admin) }
                    } else {
                        Button("Remove admin", systemImage: "star.slash") { engine.setRole(conv, m.id, .member) }
                    }
                    Button("Remove from group", systemImage: "person.badge.minus", role: .destructive) { engine.removeMember(conv, m.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
    }
}

struct AddMembersView: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var picked: Set<String> = []

    var body: some View {
        List {
            let candidates = contacts.filter { !conv.isMember($0.userID) }
            if candidates.isEmpty {
                Text("Everyone in your contacts is already in this group.").foregroundStyle(look.textSecondary)
            }
            ForEach(candidates) { c in
                Button {
                    if picked.contains(c.userID) { picked.remove(c.userID) } else if conv.members.count + picked.count < SyncEngine.maxGroupSize { picked.insert(c.userID) }
                } label: {
                    ContactRow(contact: c, trailing: AnyView(
                        Image(systemName: picked.contains(c.userID) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(picked.contains(c.userID) ? look.accent : look.textSecondary)))
                }
                .buttonStyle(.plain)
            }
            .lookRows()
            Section {
                Text("New members see messages from now on, not the earlier history. Groups hold up to \(SyncEngine.maxGroupSize) people (\(conv.members.count + picked.count) now).").font(.caption).foregroundStyle(look.textSecondary)
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Add members")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    engine.addMembers(conv, contacts.filter { picked.contains($0.userID) })
                    dismiss()
                }
                .disabled(picked.isEmpty)
            }
        }
    }
}

struct ContactInfoView: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var refreshing = false
    @Query(filter: #Predicate<TaskItem> { !$0.deleted }, sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @Query(filter: #Predicate<Conversation> { $0.kind == "group" && !$0.left }, sort: \Conversation.lastActivity, order: .reverse) private var groups: [Conversation]
    @State private var showAllGroups = false

    private var contact: Contact? { conv.peerID.flatMap { engine.contact($0) } }
    private var commonGroups: [Conversation] {
        guard let peer = conv.peerID else { return [] }
        return groups.filter { g in g.members.contains { $0.id == peer } }
    }

    /// Tasks between me and this person, from any chat.
    private var shared: [TaskItem] {
        guard let peer = conv.peerID else { return [] }
        let me = engine.me
        return allTasks.filter { t in
            t.convID == conv.id
                || (t.createdBy == me && t.assignees.contains(peer))
                || (t.createdBy == peer && t.assignees.contains(me))
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AvatarView(name: conv.title, imageData: contact?.avatar, size: 96)
                    Text(contact?.name ?? conv.title).font(.title2.bold())
                    if contact?.verified == true {
                        Label("Verified by QR code", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(look.success)
                    } else {
                        Label("Not verified in person", systemImage: "shield").font(.caption).foregroundStyle(look.warning)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: Binding(get: { conv.muted }, set: { engine.setMuted(conv, $0) })) {
                    Label("Mute notifications", systemImage: "bell.slash")
                }
                NavigationLink { ChatMediaView(conv: conv) } label: { Label("Media, links & docs", systemImage: "photo.on.rectangle.angled") }
                NavigationLink { ChatWallpaperPicker(conv: conv) } label: { Label("Chat wallpaper", systemImage: "photo.artframe") }
                ChatPrivacyRows(conv: conv)
            }
            .lookRows()

            if let about = contact?.about, !about.isEmpty {
                Section("About") { Text(about) }.lookRows()
            }

            if let peer = conv.peerID {
                PersonMeetingsSection(personID: peer)
            }

            if !commonGroups.isEmpty {
                Section("\(commonGroups.count) group\(commonGroups.count == 1 ? "" : "s") in common") {
                    ForEach(showAllGroups ? commonGroups : Array(commonGroups.prefix(3))) { g in
                        Button { dismiss(); Router.shared.show(conversation: g.id) } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: g.title, imageData: g.avatar, size: 36, isGroup: true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.title).foregroundStyle(Color.primary)
                                    Text(g.members.map { $0.id == engine.me ? "You" : $0.name }.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(look.textSecondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    if commonGroups.count > 3 && !showAllGroups { Button("See all") { showAllGroups = true } }
                }
                .lookRows()
            }

            if !shared.isEmpty, let peer = conv.peerID {
                Section("Tasks with \(contact?.name ?? conv.title)") {
                    ForEach(shared.prefix(30)) { t in
                        NavigationLink { TaskDetailView(taskID: t.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).strikethrough(t.isDone)
                                Text(t.createdBy == engine.me ? (t.assignees.contains(peer) ? "You assigned · \(t.awaitsMe(peer) ? "waiting to accept" : t.status.title)" : t.status.title)
                                     : "Assigned to you · \(t.awaitsMe(engine.me) ? "needs your answer" : t.status.title)")
                                    .font(.caption).foregroundStyle(look.textSecondary)
                            }
                        }
                    }
                }
                .lookRows()
            }

            if let contact {
                Section {
                    LabeledContent("Their code", value: E2E.fingerprint(contact.publicKey)).font(.callout.monospaced())
                    LabeledContent("Your code", value: E2E.fingerprint(engine.myPublicKey)).font(.callout.monospaced())
                    Button {
                        Task { refreshing = true; await engine.refreshProfile(contact); refreshing = false }
                    } label: {
                        HStack { Label("Refresh name and photo", systemImage: "arrow.clockwise"); if refreshing { Spacer(); ProgressView() } }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Compare “their code” with the code on their phone (Settings → My QR code). If they match, nobody is in between.")
                }
                .lookRows()

                Section {
                    if !contact.saved {
                        Button("Add to contacts") { engine.acceptRequest(contact) }
                    }
                    Button(contact.blocked ? "Unblock" : "Block", role: contact.blocked ? nil : .destructive) {
                        engine.setBlocked(contact, !contact.blocked)
                    }
                    if !contact.blocked {
                        Menu {
                            ForEach(["Abuse or harassment", "Spam or scam", "Nudity or sexual content", "Hate or threats", "Impersonation"], id: \.self) { r in
                                Button(r) { engine.report(contact, reason: r) }
                            }
                        } label: { Label("Report and block", systemImage: "exclamationmark.bubble").foregroundStyle(.red) }
                    }
                    Button("Delete chat from this device", role: .destructive) {
                        engine.deleteLocally(conv)
                        dismiss()
                    }
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

/// Per-chat wallpaper: any iLife theme, any Third Eye skin, or your own photo.
struct ChatWallpaperPicker: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @ObservedObject private var looks = LookManager.shared
    @Environment(\.look) private var look
    @State private var photo: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    conv.wallpaper = nil
                    engine.save()
                } label: {
                    Label("Follow the app look", systemImage: conv.wallpaper == nil ? "checkmark.circle.fill" : "circle")
                }
                .lookCard()

                PhotosPicker(selection: $photo, matching: .images) {
                    Label(conv.wallpaper == "photo" ? "Change my photo" : "Use a photo from my library", systemImage: "photo.on.rectangle")
                }
                .lookCard()

                Text("Prism themes").font(.headline)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(VividTheme.allCases) { t in
                        tile(key: "vivid:\(t.rawValue)", title: t.title) { VividWallpaper(theme: t, animated: false) }
                    }
                }
                Text("Zen skins").font(.headline)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Skin.builtIn) { s in
                        tile(key: "skin:\(s.rawValue)", title: s.title) { SkinArt(skin: s) }
                    }
                }
            }
            .padding()
        }
        .lookScreen()
        .navigationTitle("Chat wallpaper")
        .onChange(of: photo) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), WallpaperStore.save(d, key: "chat-\(conv.id)") {
                    conv.wallpaper = "photo"
                    looks.photoVersion += 1
                    engine.save()
                }
            }
        }
    }

    private func tile<V: View>(key: String, title: String, @ViewBuilder art: () -> V) -> some View {
        let selected = conv.wallpaper == key
        return Button {
            conv.wallpaper = key
            engine.save()
            Haptics.tap()
        } label: {
            VStack(spacing: 6) {
                art()
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? look.accent : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1))
                Text(title).font(.caption)
            }
        }
        .buttonStyle(PressStyle())
    }
}


/// Disappearing messages and chat lock, for one chat.
struct ChatPrivacyRows: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    var body: some View {
        Picker(selection: Binding(get: { conv.timer }, set: { engine.setTimer(conv, $0) })) {
            ForEach(MyDetails.timers, id: \.1) { Text($0.0).tag($0.1) }
        } label: { Label("Disappearing messages", systemImage: "timer") }
        Toggle(isOn: Binding(get: { conv.locked }, set: { v in
            Task { if await DeviceAuth.check(v ? "Lock this chat" : "Unlock this chat") { conv.locked = v; engine.save() } }
        })) { Label("Lock chat", systemImage: "lock") }
    }
}
