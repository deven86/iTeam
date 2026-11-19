import SwiftUI
import SwiftData

struct ChatListView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Conversation.lastActivity, order: .reverse) private var conversations: [Conversation]
    @Query(filter: #Predicate<Contact> { $0.isRequest && !$0.blocked }) private var requests: [Contact]

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unread = "Unread", personal = "Personal", groups = "Groups", archived = "Archived"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showNewChat = false
    @State private var showAddContact = false
    @State private var path: [String] = []
    @State private var selection: String?

    private var visible: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return conversations
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
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                syncBanner
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
                    NavigationLink(value: c.id) { ConversationRow(conv: c) }
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
        .refreshable { await engine.sync() }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showAddContact = true } label: { Image(systemName: "qrcode.viewfinder") }
                    .accessibilityLabel("Add contact")
            }
            ToolbarItem(placement: .topBarTrailing) {
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
            if engine.pendingUploads > 0 {
                Label("\(engine.pendingUploads) waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(look.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if conversations.isEmpty {
            EmptyStateView(icon: "bubble.left.and.bubble.right", title: "No chats yet",
                           message: "Add someone by scanning their iTeam QR code, then say hello.",
                           actionTitle: "Add a contact") { showAddContact = true }
                .frame(maxWidth: .infinity)
        } else {
            Text(search.isEmpty ? "Nothing here." : "No chats match “\(search)”.")
                .foregroundStyle(look.textSecondary).frame(maxWidth: .infinity).padding()
        }
    }
}

struct ConversationRow: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    private var avatar: Data? {
        if conv.isGroup { return conv.avatar }
        return conv.peerID.flatMap { engine.contact($0)?.avatar }
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: conv.title, imageData: avatar, size: 50, isGroup: conv.isGroup)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conv.title).font(.headline).lineLimit(1)
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
            Button("Block", role: .destructive) { engine.setBlocked(contact, true) }.buttonStyle(.glass).controlSize(.small)
        }
    }
}
