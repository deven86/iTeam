import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import Combine
import UniformTypeIdentifiers

/// Views (free): status at the top, then posts from people who shared with you.
struct ViewsHomeView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Post> { !$0.deleted }, sort: \Post.createdAt, order: .reverse) private var posts: [Post]
    @State private var compose: Bool?   // nil = closed, true = status, false = post
    @State private var viewing: StatusGroup?
    @AppStorage("views.lastVisit") private var lastVisit: Double = 0

    struct StatusGroup: Identifiable {
        let id: String      // author
        let items: [Post]
    }

    private var feed: [Post] { posts.filter { !$0.isStatus } }
    private var statuses: [StatusGroup] {
        let live = posts.filter { $0.isStatus && $0.isLive }
        let groups = Dictionary(grouping: live, by: \.author)
        return groups.map { StatusGroup(id: $0.key, items: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { ($0.id == engine.me ? 0 : 1, -($0.items.last?.createdAt.timeIntervalSince1970 ?? 0)) < ($1.id == engine.me ? 0 : 1, -($1.items.last?.createdAt.timeIntervalSince1970 ?? 0)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusRow
                    if feed.isEmpty {
                        EmptyStateView(icon: "play.rectangle.on.rectangle", title: "Views",
                                       message: "Share photos, 30-second videos, achievements, finished tasks and recovery milestones — only with the people and groups you choose.")
                            .padding(.top, 30)
                        Button("Share your first post", systemImage: "plus") { compose = false }
                            .buttonStyle(.glassProminent).frame(maxWidth: .infinity)
                    }
                    ForEach(feed) { p in PostCard(post: p) }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .lookScreen()
            .navigationTitle("Views")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New post", systemImage: "square.and.pencil") { compose = false }
                        Button("New status (24 h)", systemImage: "circle.dashed") { compose = true }
                        NavigationLink { AudiencesView() } label: { Label("My audiences", systemImage: "person.2.badge.gearshape") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await engine.sync() }
            .sheet(isPresented: Binding(get: { compose != nil }, set: { if !$0 { compose = nil } })) {
                NavigationStack { NewPostView(status: compose ?? false) }
            }
            .fullScreenCover(item: $viewing) { g in StatusViewer(items: g.items) }
            .onAppear { lastVisit = Date.now.timeIntervalSince1970 }
        }
    }

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if !statuses.contains(where: { $0.id == engine.me }) {
                    Button { compose = true } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(name: engine.myName, imageData: engine.myAvatar, size: 62)
                                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.white, look.accent)
                            }
                            Text("My status").font(.caption2).foregroundStyle(Color.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(statuses) { g in
                    Button { viewing = g } label: {
                        VStack(spacing: 6) {
                            let seenAll = g.items.allSatisfy { seen($0) }
                            AvatarView(name: engine.name(of: g.id), imageData: g.id == engine.me ? engine.myAvatar : engine.contact(g.id)?.avatar, size: 62)
                                .padding(3)
                                .overlay(Circle().stroke(seenAll ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(look.gradient), lineWidth: 3))
                            Text(g.id == engine.me ? "My status" : engine.name(of: g.id)).font(.caption2).lineLimit(1).frame(width: 70)
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func seen(_ p: Post) -> Bool {
        p.author == engine.me || UserDefaults.standard.bool(forKey: "views.seen." + p.id)
    }
}

// MARK: - Post card

struct PostCard: View {
    let post: Post
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var reactions: [PostReaction]
    @Query private var comments: [PostComment]
    @State private var showComments = false
    @State private var shareItems: ShareItems?
    @State private var sendToChat = false
    @State private var preview: URL?
    @State private var confirmDelete = false

    init(post: Post) {
        self.post = post
        let id = post.id
        _reactions = Query(filter: #Predicate<PostReaction> { $0.postID == id })
        _comments = Query(filter: #Predicate<PostComment> { $0.postID == id && !$0.deleted }, sort: \PostComment.createdAt)
    }

    private var liked: Bool { reactions.contains { $0.user == engine.me } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(name: engine.name(of: post.author),
                           imageData: post.author == engine.me ? engine.myAvatar : engine.contact(post.author)?.avatar, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.author == engine.me ? "You" : engine.name(of: post.author)).font(.headline)
                    Text(post.createdAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(look.textSecondary)
                }
                Spacer()
                if post.postKind != .moment {
                    Chip(text: post.postKind.title, icon: post.postKind.icon, color: look.accent)
                }
                Menu {
                    Button("Share…", systemImage: "square.and.arrow.up") { Task { await share() } }
                    Button("Send in a chat", systemImage: "arrowshape.turn.up.right") { sendToChat = true }
                    if post.author == engine.me {
                        Button("Delete post", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: { Image(systemName: "ellipsis").padding(8) }
            }
            if !post.text.isEmpty { Text(post.text).font(.body) }
            if !post.media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(post.media) { m in AttachmentView(ref: m) { preview = $0 } }
                    }
                }
            }
            HStack(spacing: 18) {
                Button {
                    engine.reactToPost(post, emoji: liked ? nil : "❤️")
                    Haptics.tap()
                } label: {
                    Label("\(reactions.count)", systemImage: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? Color.pink : Color.primary)
                }
                Button { showComments = true } label: { Label("\(comments.count)", systemImage: "bubble.right") }
                Spacer()
                if post.author == engine.me {
                    Text(audience).font(.caption2).foregroundStyle(look.textSecondary).lineLimit(1)
                }
            }
            .font(.subheadline)
            .buttonStyle(.plain)
        }
        .lookCard()
        .sheet(isPresented: $showComments) { NavigationStack { PostCommentsView(post: post) } }
        .sheet(isPresented: $sendToChat) { NavigationStack { SendToChatSheet(text: post.text, attachments: post.media) } }
        .sheet(item: Binding(get: { preview.map(PreviewItem.init) }, set: { preview = $0?.url })) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
        .shareSheet($shareItems)
        .confirmationDialog("Delete this post for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { engine.deletePost(post) }
        }
    }

    private var audience: String {
        let names = post.convIDs.compactMap { engine.conversation($0)?.title }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) chats"
    }

    private func share() async {
        var items: [Any] = []
        if !post.text.isEmpty { items.append(post.text) }
        for a in post.media { if let url = try? await Attachments.load(a) { items.append(url) } }
        if !items.isEmpty { shareItems = ShareItems(items: items) }
    }
}

struct PostCommentsView: View {
    let post: Post
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query private var comments: [PostComment]
    @Query private var reactions: [PostReaction]
    @State private var text = ""

    init(post: Post) {
        self.post = post
        let id = post.id
        _comments = Query(filter: #Predicate<PostComment> { $0.postID == id && !$0.deleted }, sort: \PostComment.createdAt)
        _reactions = Query(filter: #Predicate<PostReaction> { $0.postID == id })
    }

    var body: some View {
        List {
            if !reactions.isEmpty {
                Section("Liked by") {
                    Text(reactions.map { "\($0.emoji) \(engine.name(of: $0.user))" }.joined(separator: "  ")).font(.subheadline)
                }
                .lookRows()
            }
            Section("Comments") {
                if comments.isEmpty { Text("No comments yet.").foregroundStyle(look.textSecondary) }
                ForEach(comments) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.author == engine.me ? "You" : engine.name(of: c.author)).font(.caption.bold())
                        Text(c.text)
                        Text(c.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(look.textSecondary)
                    }
                }
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Comments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Add a comment", text: $text, axis: .vertical).lineLimit(1...4)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .lookFloating(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    engine.commentOnPost(post, text: t)
                    text = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }
}

// MARK: - Compose

struct NewPostView: View {
    let status: Bool
    var kind: PostKind = .moment
    var prefill: String = ""
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Conversation> { !$0.left }, sort: \Conversation.lastActivity, order: .reverse) private var convs: [Conversation]
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }) private var contacts: [Contact]
    @State private var postKind: PostKind = .moment
    @State private var text = ""
    @State private var picks: [PhotosPickerItem] = []
    @State private var media: [AttachmentRef] = []
    @State private var uploads: [String: String] = [:]
    @State private var preparing = false
    @State private var note: String?
    @State private var audienceMode = 0     // 0 all contacts, 1 choose, 2 saved audience
    @State private var chosen: Set<String> = []
    @State private var audienceID = ""

    private var realConvs: [Conversation] { convs.filter { !$0.id.hasPrefix("s_") } }

    var body: some View {
        Form {
            if !status {
                Section {
                    Picker("Type", selection: $postKind) { ForEach(PostKind.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                }
                .lookRows()
            }
            Section {
                TextField(status ? "What's up?" : "Say something…", text: $text, axis: .vertical).lineLimit(2...8)
                if !media.isEmpty {
                    ScrollView(.horizontal) {
                        HStack { ForEach(media) { m in AttachmentView(ref: m) { _ in }.frame(maxHeight: 160) } }
                    }
                }
                PhotosPicker(selection: $picks, maxSelectionCount: 4, matching: .any(of: [.images, .videos])) {
                    Label(preparing ? "Preparing…" : "Add photos or videos", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(preparing)
                if let note { Text(note).font(.caption).foregroundStyle(look.warning) }
            } footer: {
                Text("Videos are limited to 30 seconds — longer ones are trimmed to the first 30.")
            }
            .lookRows()
            Section {
                Picker("Who can see it", selection: $audienceMode) {
                    Text("Everyone I chat with").tag(0)
                    Text("Choose chats & groups").tag(1)
                    if !Audience.saved.isEmpty { Text("A saved audience").tag(2) }
                }
                if audienceMode == 1 {
                    ForEach(realConvs) { c in
                        Button {
                            if chosen.contains(c.id) { chosen.remove(c.id) } else { chosen.insert(c.id) }
                        } label: {
                            HStack {
                                Label(c.title, systemImage: c.isGroup ? "person.3" : "person").foregroundStyle(Color.primary)
                                Spacer()
                                if chosen.contains(c.id) { Image(systemName: "checkmark").foregroundStyle(look.accent) }
                            }
                        }
                    }
                } else if audienceMode == 2 {
                    Picker("Audience", selection: $audienceID) {
                        ForEach(Audience.saved) { Text($0.name).tag($0.id) }
                    }
                }
                if audienceMode != 0 && targets.isEmpty {
                    Text("Pick at least one chat to post.").font(.caption).foregroundStyle(look.warning)
                }
            } header: {
                Text("Audience")
            } footer: {
                Text(status ? "Your status disappears after 24 hours." : "Only these people can see it, like it and comment. Comments in a group are visible to that group.")
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle(status ? "New status" : "New post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(status ? "Share" : "Post") { publish() }.bold()
                    .disabled(preparing || (text.trimmingCharacters(in: .whitespaces).isEmpty && media.isEmpty) || (audienceMode == 0 ? (targets.isEmpty && contacts.isEmpty) : targets.isEmpty))
            }
        }
        .onAppear {
            postKind = kind
            if text.isEmpty { text = prefill }
            audienceID = Audience.saved.first?.id ?? ""
        }
        .onChange(of: picks) { _, items in Task { await load(items) } }
    }

    private var targets: [Conversation] {
        switch audienceMode {
        case 1: return realConvs.filter { chosen.contains($0.id) }
        case 2:
            let ids = Set(Audience.saved.first { $0.id == audienceID }?.convIDs ?? [])
            return realConvs.filter { ids.contains($0.id) }
        default:
            // Every one-to-one chat (existing chats only here, because this runs while drawing;
            // direct chats for contacts I haven't messaged yet are created on publish).
            return realConvs.filter { !$0.isGroup }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        preparing = true
        defer { preparing = false }
        media = []; uploads = [:]; note = nil
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try? await item.loadTransferable(type: MovieFile.self) else { continue }
                do {
                    let p = try await VideoPrep.prepare(movie.url)
                    if (p.ref.duration ?? 0) >= VideoPrep.maxSeconds - 0.1 { note = "Long videos were trimmed to 30 seconds." }
                    media.append(p.ref); uploads[p.upload.0] = p.upload.1
                } catch {
                    note = "A video couldn't be prepared: \(error.localizedDescription)"
                }
            } else if let data = try? await item.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(data) {
                media.append(p.ref); uploads[p.upload.0] = p.upload.1
            }
        }
    }

    private func publish() {
        var to = targets
        if audienceMode == 0 {
            for c in contacts where !to.contains(where: { $0.peerID == c.userID }) { to.append(engine.directConversation(with: c)) }
        }
        engine.publishPost(kind: status ? .moment : postKind, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           media: media, uploads: uploads, status: status, to: to)
        Haptics.success()
        dismiss()
    }
}

/// A picked video, copied out of the photo library.
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

// MARK: - Status viewer

struct StatusViewer: View {
    let items: [Post]
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var progress: Double = 0
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var reply = ""
    @State private var paused = false
    @Query private var seen: [PostSeen]

    private var current: Post? { items.indices.contains(index) ? items[index] : nil }
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = current {
                Group {
                    if let player { VideoPlayer(player: player).disabled(true) }
                    else if let image { Image(uiImage: image).resizable().scaledToFit() }
                    else if !p.media.isEmpty { ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !p.text.isEmpty {
                    Text(p.text).font(p.media.isEmpty ? .title.bold() : .body).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding().background(p.media.isEmpty ? .clear : .black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxHeight: .infinity, alignment: p.media.isEmpty ? .center : .bottom)
                        .padding(.bottom, 90)
                }
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
            }
            .onLongPressGesture(minimumDuration: 0.2, pressing: { paused = $0 }, perform: {})
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(items.indices, id: \.self) { i in
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.35))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white).frame(width: g.size.width * (i < index ? 1 : i == index ? progress : 0))
                                }
                        }
                        .frame(height: 3)
                    }
                }
                if let p = current {
                    HStack {
                        AvatarView(name: engine.name(of: p.author), imageData: p.author == engine.me ? engine.myAvatar : engine.contact(p.author)?.avatar, size: 34)
                        VStack(alignment: .leading) {
                            Text(p.author == engine.me ? "My status" : engine.name(of: p.author)).font(.subheadline.bold())
                            Text(p.createdAt.formatted(.relative(presentation: .named))).font(.caption2).opacity(0.8)
                        }
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.bold()) }
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                if let p = current {
                    if p.author == engine.me {
                        let viewers = seen.filter { $0.postID == p.id }
                        HStack {
                            Label("Seen by \(viewers.count)", systemImage: "eye")
                            Spacer()
                            Button("Delete", systemImage: "trash") { engine.deletePost(p); step(1) }
                        }
                        .foregroundStyle(.white).font(.subheadline)
                    } else {
                        HStack {
                            TextField("Reply…", text: $reply).padding(10).background(.white.opacity(0.15), in: Capsule()).foregroundStyle(.white)
                            Button {
                                sendReply(p)
                            } label: { Image(systemName: "paperplane.fill").foregroundStyle(.white) }
                            Button { engine.reactToPost(p, emoji: "❤️"); Haptics.tap() } label: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                        }
                    }
                }
            }
            .padding()
        }
        .task(id: index) { await load() }
        .onReceive(tick) { _ in
            guard !paused, reply.isEmpty, let p = current else { return }
            let length = p.media.first?.kind == "video" ? max(3, p.media.first?.duration ?? 6) : 5
            progress += 0.05 / length
            if progress >= 1 { step(1) }
        }
        .onDisappear { player?.pause() }
    }

    private func step(_ d: Int) {
        player?.pause()
        let next = index + d
        if next < 0 { progress = 0; return }
        if next >= items.count { dismiss(); return }
        index = next
    }

    private func load() async {
        progress = 0; image = nil; player = nil
        guard let p = current else { return }
        engine.markSeen(p)
        UserDefaults.standard.set(true, forKey: "views.seen." + p.id)
        guard let m = p.media.first, let url = try? await Attachments.load(m) else { return }
        if m.kind == "video" {
            let pl = AVPlayer(url: url); player = pl; pl.play()
        } else {
            image = UIImage(contentsOfFile: url.path)
        }
    }

    private func sendReply(_ p: Post) {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let c = engine.contact(p.author) {
            engine.sendText("↩︎ Replied to your status: \(t)", in: engine.directConversation(with: c))
        } else {
            engine.commentOnPost(p, text: t)
        }
        reply = ""
        Haptics.success()
    }
}

// MARK: - Audiences and sending to a chat

struct AudiencesView: View {
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Conversation> { !$0.left }, sort: \Conversation.title) private var convs: [Conversation]
    @State private var list = Audience.saved
    @State private var editing: Audience?

    var body: some View {
        List {
            Section {
                ForEach(list) { a in
                    Button { editing = a } label: {
                        VStack(alignment: .leading) {
                            Text(a.name).font(.headline).foregroundStyle(Color.primary)
                            Text("\(a.convIDs.count) chats").font(.caption).foregroundStyle(look.textSecondary)
                        }
                    }
                }
                .onDelete { idx in list.remove(atOffsets: idx); Audience.saved = list }
                Button("New audience", systemImage: "plus") { editing = Audience(name: "", convIDs: []) }
            } footer: {
                Text("Save groups of people — like “Close family” or “Gym clients” — and pick them when you post.")
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("My audiences")
        .sheet(item: $editing) { a in
            NavigationStack { AudienceEditor(audience: a, convs: convs.filter { !$0.id.hasPrefix("s_") }) { saved in
                if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                Audience.saved = list
            } }
        }
    }
}

struct AudienceEditor: View {
    @State var audience: Audience
    let convs: [Conversation]
    var onSave: (Audience) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look

    var body: some View {
        Form {
            TextField("Name (e.g. Close family)", text: $audience.name).lookRows()
            Section("Who") {
                ForEach(convs) { c in
                    Button {
                        if let i = audience.convIDs.firstIndex(of: c.id) { audience.convIDs.remove(at: i) } else { audience.convIDs.append(c.id) }
                    } label: {
                        HStack {
                            Label(c.title, systemImage: c.isGroup ? "person.3" : "person").foregroundStyle(Color.primary)
                            Spacer()
                            if audience.convIDs.contains(c.id) { Image(systemName: "checkmark").foregroundStyle(look.accent) }
                        }
                    }
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Audience")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(audience); dismiss() }
                    .disabled(audience.name.trimmingCharacters(in: .whitespaces).isEmpty || audience.convIDs.isEmpty)
            }
        }
    }
}

/// Sends text and files into one or more chats (used by Views posts).
struct SendToChatSheet: View {
    let text: String
    let attachments: [AttachmentRef]
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Conversation> { !$0.left }, sort: \Conversation.lastActivity, order: .reverse) private var convs: [Conversation]
    @State private var picked: Set<String> = []

    var body: some View {
        List {
            ForEach(convs) { c in
                Button {
                    if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                } label: {
                    HStack {
                        Text(c.title).foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(look.accent)
                    }
                }
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Send in a chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    for c in convs where picked.contains(c.id) { engine.sendText(text, in: c, attachments: attachments, forwarded: true) }
                    Haptics.success()
                    dismiss()
                }
                .disabled(picked.isEmpty)
            }
        }
    }
}
