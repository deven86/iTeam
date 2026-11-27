import SwiftUI
import SwiftData

struct ChatListView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Conversation.lastActivity, order: .reverse) private var conversations: [Conversation]
    @State private var showPending = false
    @Query(filter: #Predicate<ActivityItem> { !$0.read }, sort: \ActivityItem.date, order: .reverse) private var newActivity: [ActivityItem]
    @Query(filter: #Predicate<Contact> { $0.isRequest && !$0.blocked }) private var requests: [Contact]

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unread = "Unread", personal = "Personal", groups = "Groups", archived = "Archived"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showNewChat = false
    @State private var showAddContact = false
    @State private var editProfile = false
    @State private var askPresence = false
    @ObservedObject private var backup = Backup.shared
    @Query(filter: #Predicate<Post> { !$0.deleted && $0.isStatus }) private var minis: [Post]
    /// People with a live mini: true = something unseen (coloured ring), false = all seen (grey ring).
    private var miniRing: [String: Bool] {
        var out: [String: Bool] = [:]
        for p in minis where p.isLive && p.author != engine.me {
            let unseen = !UserDefaults.standard.bool(forKey: "views.seen." + p.id)
            out[p.author] = (out[p.author] ?? false) || unseen
        }
        return out
    }
    @State private var path: [String] = []
    @State private var selection: String?

    private var visible: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return conversations
            .filter { !$0.locked && !$0.pendingInvite }
            .filter { c in
                switch filter {
                case .all: !c.archived
                case .unread: !c.archived && c.unread > 0
                case .personal: !c.archived && !c.isGroup
                case .groups: !c.archived && c.isGroup
                case .archived: c.archived
                }
            }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.lastPreview.lowercased().contains(q) }
            .sorted { ($0.pinned ? 1 : 0, $0.lastActivity) > ($1.pinned ? 1 : 0, $1.lastActivity) }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    decorated(List(selection: $selection) { listContent })
                } detail: {
                    NavigationStack {
                        if let selection { ChatView(convID: selection).id(selection) }
                        else { EmptyStateView(icon: "bubble.left.and.bubble.right", title: "Pick a chat", message: "Or start a new one with the compose button.") }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    decorated(List { listContent })
                        .navigationDestination(for: String.self) { ChatView(convID: $0) }
                }
            }
        }
        .sheet(isPresented: $showNewChat) {
            NewChatView { conv in open(conv.id) }
        }
        .sheet(isPresented: $showAddContact) { AddContactView() }
        .sheet(isPresented: $editProfile) { NavigationStack { EditProfileView() } }
        .task { DemoChats.ensureAvatars(engine) }
        .sheet(item: $router.pendingInvite) { invite in AddContactView(invite: invite) }
        .onChange(of: router.openConversation) { _, id in
            guard let id else { return }
            open(id)
            router.openConversation = nil
        }
    }

    private func open(_ id: String) {
        if sizeClass == .regular { selection = id } else { path = [id] }
    }

    @ViewBuilder
    private var listContent: some View {
            // Title row: Chats with Rooms always beside it.
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Text("Chats").font(.largeTitle.bold())
                    Button { router.go(.rooms) } label: {
                        Label("Rooms", systemImage: "person.3.sequence.fill")
                            .font(.headline)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("Open public and private rooms")
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
            }
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                syncBanner
                if backup.iCloudFull {
                    NavigationLink { BackupView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud is full — backup failed").font(.footnote.bold())
                                Text("Messages still send, but your chats aren't backed up. Free space: Settings → your name → iCloud → Manage Storage, or upgrade iCloud+.").font(.caption2)
                            }
                        } icon: { Image(systemName: "icloud.slash.fill") }
                        .foregroundStyle(look.danger)
                    }
                } else if backup.needsWarning && conversations.contains(where: { !$0.isDemo }) {
                    NavigationLink { BackupView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.lastDate == nil ? "Not backed up" : "Backup is out of date").font(.footnote.bold())
                                Text("Deleting iTeam would erase these chats. Tap to back up to iCloud.").font(.caption2)
                            }
                        } icon: { Image(systemName: "exclamationmark.icloud") }
                        .foregroundStyle(look.warning)
                    }
                }
            }

            if filter == .all && search.isEmpty {
                Section {
                    MiniRow()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                } header: { Text("mini") }
            }

            let invites = conversations.filter { $0.pendingInvite && !$0.left }
            if !invites.isEmpty && filter == .all {
                Section("Group invites") {
                    ForEach(invites) { g in
                        HStack(spacing: 12) {
                            AvatarView(name: g.title, imageData: g.avatar, size: 40, isGroup: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.title).font(.headline)
                                Text("Added by someone not in your contacts").font(.caption).foregroundStyle(look.textSecondary)
                            }
                            Spacer()
                            Button("Join") { g.pendingInvite = false; engine.save() }.buttonStyle(.glassProminent).controlSize(.small)
                            Button("Leave") { engine.leave(g); g.pendingInvite = false; engine.save() }.buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
                .lookRows()
            }

            if !requests.isEmpty && filter == .all {
                Section("Message requests") {
                    ForEach(requests) { c in RequestRow(contact: c) }
                }
                .lookRows()
            }

            Section {
                if visible.isEmpty {
                    emptyState.listRowBackground(Color.clear)
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, c in
                    NavigationLink(value: c.id) { ConversationRow(conv: c, ring: c.isGroup ? nil : c.peerID.flatMap { miniRing[$0] }) }
                        .tag(c.id)
                        .appear(i)
                        .swipeActions(edge: .leading) {
                            Button { c.unread = c.unread > 0 ? 0 : 1; engine.save() } label: {
                                Label(c.unread > 0 ? "Read" : "Unread", systemImage: c.unread > 0 ? "envelope.open" : "envelope.badge")
                            }.tint(.blue)
                            Button { c.pinned.toggle(); engine.save() } label: {
                                Label(c.pinned ? "Unpin" : "Pin", systemImage: c.pinned ? "pin.slash" : "pin")
                            }.tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { c.archived.toggle(); engine.save() } label: {
                                Label(c.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
                            }.tint(.indigo)
                            Button { engine.setMuted(c, !c.muted) } label: {
                                Label(c.muted ? "Unmute" : "Mute", systemImage: c.muted ? "bell" : "bell.slash")
                            }.tint(.gray)
                        }
                        .contextMenu {
                            Button(c.pinned ? "Unpin" : "Pin", systemImage: "pin") { c.pinned.toggle(); engine.save() }
                            Button(c.muted ? "Unmute" : "Mute", systemImage: "bell.slash") { engine.setMuted(c, !c.muted) }
                            Button(c.archived ? "Unarchive" : "Archive", systemImage: "archivebox") { c.archived.toggle(); engine.save() }
                            Button("Delete from this device", systemImage: "trash", role: .destructive) { engine.deleteLocally(c) }
                        }
                }
            }
            .lookRows()
    }

    private func decorated<L: View>(_ list: L) -> some View {
        list
        .listStyle(.insetGrouped)
        .lookScreen()
        .searchable(text: $search, prompt: "Search chats")
        .refreshable { await engine.sync(); await engine.refreshPresence(force: true) }
        .task {
            // Online dots: refresh who's active while the chat list is on screen.
            while !Task.isCancelled {
                await engine.refreshPresence()
                try? await Task.sleep(for: .seconds(50))
            }
        }
        .onAppear {
            if !MyDetails.lastSeenEveryone && !UserDefaults.standard.bool(forKey: "presence.asked") { askPresence = true }
        }
        .alert("Show when you're online?", isPresented: $askPresence) {
            Button("Turn on") {
                UserDefaults.standard.set(true, forKey: "presence.asked")
                MyDetails.lastSeenEveryone = true
                UserDefaults.standard.set(0, forKey: "lastSeen.pushed")
                Task { await engine.touchLastSeen(); await engine.refreshPresence(force: true) }
            }
            Button("Not now", role: .cancel) { UserDefaults.standard.set(true, forKey: "presence.asked") }
        } message: {
            Text("Your contacts see a green dot when you're online and your last seen time — and you see theirs. You can change this anytime in Settings → Privacy.")
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { editProfile = true } label: {
                    AvatarView(name: engine.myName, imageData: engine.myAvatar, size: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("My profile")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showAddContact = true } label: { Image(systemName: "qrcode.viewfinder") }
                    .accessibilityLabel("Scan or show QR code")
                Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
            }
        }
    }

    @ViewBuilder
    private var syncBanner: some View {
        switch engine.status {
        case .offline, .noAccount, .failed:
            Label(engine.status.label, systemImage: engine.status == .offline ? "wifi.slash" : "exclamationmark.icloud")
                .font(.footnote)
                .foregroundStyle(look.warning)
                .listRowBackground(Color.clear)
        default:
            // Latest 10 unseen activities; opening one marks it seen and the next one takes its place.
            // ("Waiting to sync" now lives in Settings.)
            if !newActivity.isEmpty && !ScreenshotMode.on {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(newActivity.prefix(10)) { a in
                            Button { openActivity(a) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(a.text).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(a.date, style: .relative).font(.caption2).foregroundStyle(look.textSecondary)
                                }
                                .frame(width: 170, alignment: .leading).padding(10)
                                .background(look.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }
    }

    private func openActivity(_ a: ActivityItem) {
        a.read = true
        if !a.link.isEmpty, let url = URL(string: a.link) { router.handle(url) }
        else if let t = a.taskID { router.show(task: t) }
        else if let c = a.convID { router.show(conversation: c) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if conversations.isEmpty {
            VStack(spacing: 4) {
                EmptyStateView(icon: "bubble.left.and.bubble.right", title: "No chats yet",
                               message: "Add someone by scanning their iTeam QR code, then say hello.",
                               actionTitle: "Add a contact") { showAddContact = true }
                Button {
                    let conv = DemoChats.create(engine)
                    open(conv.id)
                } label: {
                    Label("Try a demo team chat", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Button("Notes to self") { open(DemoChats.notesToSelf(engine).id) }
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text(search.isEmpty ? "Nothing here." : "No chats match “\(search)”.")
                .foregroundStyle(look.textSecondary).frame(maxWidth: .infinity).padding()
        }
    }
}

struct ConversationRow: View {
    let conv: Conversation
    /// nil = no mini; true = unseen mini; false = seen.
    var ring: Bool? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    private var avatar: Data? {
        if conv.isGroup { return conv.avatar }
        return conv.peerID.flatMap { engine.contact($0)?.avatar }
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: conv.title, imageData: avatar, size: ring == nil ? 50 : 44, isGroup: conv.isGroup)
                .padding(ring == nil ? 0 : 3)
                .overlay {
                    if let ring {
                        Circle().stroke(ring ? AnyShapeStyle(look.gradient) : AnyShapeStyle(Color.secondary.opacity(0.45)), lineWidth: 2.5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !conv.isGroup, let p = conv.peerID, p != engine.me, engine.contact(p)?.isOnline == true {
                        Circle().fill(Color.red).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                            .accessibilityLabel("Online")
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conv.title).font(.headline).lineLimit(1)
                    if !conv.isGroup, let p = conv.peerID, engine.contact(p)?.plus == true { PlusBadge() }
                    if conv.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(look.textSecondary) }
                    if conv.muted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(look.textSecondary) }
                    Spacer()
                    Text(Fmt.chatTime(conv.lastActivity)).font(.caption)
                        .foregroundStyle(conv.unread > 0 && !conv.muted ? look.accent : look.textSecondary)
                }
                HStack {
                    Text(conv.left ? "You're no longer in this group" : (conv.lastPreview.isEmpty ? "No messages yet" : conv.lastPreview))
                        .font(.subheadline).foregroundStyle(look.textSecondary).lineLimit(2)
                    Spacer()
                    if conv.unread > 0 { CountBadge(count: conv.unread, muted: conv.muted) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct RequestRow: View {
    let contact: Contact
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: contact.name, imageData: contact.avatar, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(.headline)
                Text("Not in your contacts").font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer()
            Button("Add") { engine.acceptRequest(contact) }.buttonStyle(.glassProminent).controlSize(.small)
            Menu {
                Button("Block", systemImage: "hand.raised", role: .destructive) { engine.setBlocked(contact, true) }
                Button("Report spam and block", systemImage: "exclamationmark.bubble", role: .destructive) { engine.report(contact, reason: "Spam or scam (message request)") }
            } label: { Text("Block") }.buttonStyle(.glass).controlSize(.small)
        }
    }
}


/// What's waiting to be sent, and why — with a retry.
struct PendingSyncView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \OutboxItem.createdAt) private var items: [OutboxItem]
    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { i in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(i.kind == "key" ? "Chat key" : "Update") for \(engine.conversation(i.convID)?.title ?? "a chat")").font(.subheadline.weight(.semibold))
                        Text("Waiting since \(i.createdAt.formatted(date: .abbreviated, time: .shortened)) · tries \(i.attempts)").font(.caption).foregroundStyle(.secondary)
                        if let e = i.lastError, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.orange) }
                    }
                    .swipeActions { Button("Discard", role: .destructive) { engine.context.delete(i); engine.save(); engine.refreshCounts() } }
                }
            }
            .navigationTitle("Waiting to sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Retry now") { engine.retryFailed() } }
            }
        }
    }
}
