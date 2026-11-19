import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    let convID: String
    @EnvironmentObject var engine: SyncEngine
    @ObservedObject private var looks = LookManager.shared
    @Environment(\.look) private var look
    @Query private var convs: [Conversation]
    @Query private var messages: [Message]

    @State private var text = ""
    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var taskFrom: Message?
    @State private var showInfo = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var sendError: String?
    @State private var quickLook: URL?
    @State private var showCamera = false
    @State private var askLink = false
    @State private var linkText = ""
    @State private var showApproval = false
    @FocusState private var focused: Bool

    init(convID: String) {
        self.convID = convID
        _convs = Query(filter: #Predicate<Conversation> { $0.id == convID })
        _messages = Query(filter: #Predicate<Message> { $0.convID == convID }, sort: \Message.createdAt)
    }

    private var conv: Conversation? { convs.first }

    var body: some View {
        Group {
            if let conv {
                content(conv)
            } else {
                EmptyStateView(icon: "bubble.left", title: "Chat not found", message: "It may have been deleted from this device.")
            }
        }
    }

    private func content(_ conv: Conversation) -> some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                encryptionNote
                ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                    if i == 0 || !Calendar.current.isDate(messages[i - 1].createdAt, inSameDayAs: m.createdAt) {
                        dayHeader(m.createdAt)
                    }
                    let showName = conv.isGroup && m.senderID != engine.me &&
                        (i == 0 || messages[i - 1].senderID != m.senderID || messages[i - 1].isSystem)
                    MessageBubble(message: m, conv: conv, showSender: showName, all: messages,
                                  onReply: { replyTo = m; editing = nil; focused = true },
                                  onEdit: { editing = m; text = m.text; replyTo = nil; focused = true },
                                  onTask: { taskFrom = m },
                                  onOpen: { url in quickLook = url })
                        .id(m.id)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background { ChatWallpaper(conv: conv) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if conv.left {
                Text("You're no longer a member of this group.")
                    .font(.footnote).foregroundStyle(look.textSecondary)
                    .frame(maxWidth: .infinity).padding()
                    .lookFloating(in: Rectangle())
            } else {
                composer(conv)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showInfo = true } label: { header(conv) }.buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { taskFrom = nil; showInfo = false; newTaskInChat = true } label: { Image(systemName: "checklist") }
                    .accessibilityLabel("New task in this chat")
            }
        }
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                if conv.isGroup { GroupInfoView(conv: conv) } else { ContactInfoView(conv: conv) }
            }
        }
        .sheet(item: $taskFrom) { m in
            NavigationStack { TaskEditorView(conv: conv, source: m) }
        }
        .sheet(isPresented: $newTaskInChat) {
            NavigationStack { TaskEditorView(conv: conv, source: nil) }
        }
        .sheet(item: Binding(get: { quickLook.map(PreviewItem.init) }, set: { quickLook = $0?.url })) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in
                if let data = img.jpegData(compressionQuality: 0.9), let p = try? Attachments.prepareImage(data) {
                    engine.sendText(text, in: conv, replyTo: replyTo?.id, attachments: [p.ref], uploads: [p.upload.0: p.upload.1])
                    text = ""
                    replyTo = nil
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showApproval) {
            NavigationStack { ApprovalRequestView(conv: conv) }
        }
        .alert("Share a link", isPresented: $askLink) {
            TextField("https://…", text: $linkText).keyboardType(.URL).textInputAutocapitalization(.never)
            Button("Send") {
                let t = linkText.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { engine.sendText(t.hasPrefix("http") ? t : "https://" + t, in: conv) }
                linkText = ""
            }
            Button("Cancel", role: .cancel) { linkText = "" }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { sendFiles(urls, conv: conv) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPhotos(items, conv: conv) }
        }
        .onAppear {
            engine.openConversation = conv.id
            engine.markRead(conv)
            if text.isEmpty { text = conv.draft }
        }
        .onDisappear {
            if engine.openConversation == conv.id { engine.openConversation = nil }
            conv.draft = editing == nil ? text : ""
            engine.save()
        }
        .onChange(of: messages.count) { _, _ in
            if conv.unread > 0 { engine.markRead(conv) }
        }
        .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "") }
    }

    @State private var newTaskInChat = false

    // MARK: Header

    private func header(_ conv: Conversation) -> some View {
        HStack(spacing: 8) {
            AvatarView(name: conv.title, imageData: conv.isGroup ? conv.avatar : conv.peerID.flatMap { engine.contact($0)?.avatar },
                       size: 32, isGroup: conv.isGroup)
            VStack(alignment: .leading, spacing: 0) {
                Text(conv.title).font(.headline).lineLimit(1)
                Text(subtitle(conv)).font(.caption2).foregroundStyle(look.textSecondary).lineLimit(1)
            }
        }
    }

    private func subtitle(_ conv: Conversation) -> String {
        switch engine.status {
        case .offline: return "Offline · messages wait on this device"
        case .syncing: return "Syncing…"
        default:
            if conv.isGroup { return "\(conv.members.count) members · tap for info" }
            return "End-to-end encrypted · tap for info"
        }
    }

    private var encryptionNote: some View {
        Label("Messages are end-to-end encrypted. Only the people in this chat can read them.", systemImage: "lock.fill")
            .font(.caption2)
            .multilineTextAlignment(.center)
            .foregroundStyle(look.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .lookCard(cornerRadius: 14, padding: 0)
            .padding(.horizontal, 30).padding(.bottom, 8)
    }

    private func dayHeader(_ date: Date) -> some View {
        Text(Calendar.current.isDateInToday(date) ? "Today" : (Calendar.current.isDateInYesterday(date) ? "Yesterday" : date.formatted(date: .complete, time: .omitted)))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .lookFloating(in: Capsule())
            .padding(.vertical, 8)
    }

    // MARK: Composer

    private func composer(_ conv: Conversation) -> some View {
        VStack(spacing: 6) {
            if let r = replyTo ?? editing {
                HStack(spacing: 8) {
                    Rectangle().fill(look.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(editing != nil ? "Edit message" : "Reply to \(engine.name(of: r.senderID))")
                            .font(.caption.bold()).foregroundStyle(look.accent)
                        Text(r.preview).font(.caption).lineLimit(1).foregroundStyle(look.textSecondary)
                    }
                    Spacer()
                    Button {
                        if editing != nil { text = "" }
                        replyTo = nil; editing = nil
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(look.textSecondary) }
                }
                .frame(height: 36)
                .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Camera", systemImage: "camera") { showCamera = true }
                    Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                    Button("Document", systemImage: "doc") { showFiles = true }
                    Button("Link", systemImage: "link") { askLink = true }
                    Divider()
                    Button("New task", systemImage: "checklist") { newTaskInChat = true }
                    if conv.members.count > 1 {
                        Button("Request approval", systemImage: "checkmark.seal") { showApproval = true }
                    }
                } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .lookFloating(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Attach")

                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .lookFloating(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { send(conv) } label: {
                    Image(systemName: editing != nil ? "checkmark" : "arrow.up")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(canSend ? Color.white : look.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(canSend ? AnyShapeStyle(look.gradient) : AnyShapeStyle(Color.clear), in: Circle())
                        .lookFloating(in: Circle(), interactive: true)
                }
                .disabled(!canSend)
                .sensoryFeedback(.impact(weight: .light), trigger: messages.count)
                .accessibilityLabel(editing != nil ? "Save edit" : "Send")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func send(_ conv: Conversation) {
        let body = text
        if let m = editing {
            if body.trimmingCharacters(in: .whitespacesAndNewlines) != m.text { engine.edit(m, text: body) }
            editing = nil
        } else {
            engine.sendText(body, in: conv, replyTo: replyTo?.id)
            replyTo = nil
        }
        text = ""
    }

    private func sendPhotos(_ items: [PhotosPickerItem], conv: Conversation) async {
        var refs: [AttachmentRef] = []
        var uploads: [String: String] = [:]
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                let p = try Attachments.prepareImage(data)
                refs.append(p.ref)
                uploads[p.upload.0] = p.upload.1
            } catch {
                sendError = error.localizedDescription
            }
        }
        photoItems = []
        guard !refs.isEmpty else { return }
        engine.sendText(text, in: conv, replyTo: replyTo?.id, attachments: refs, uploads: uploads)
        text = ""
        replyTo = nil
    }

    private func sendFiles(_ urls: [URL], conv: Conversation) {
        for url in urls {
            do {
                let p = try Attachments.prepareFile(url)
                engine.sendText("", in: conv, attachments: [p.ref], uploads: [p.upload.0: p.upload.1])
            } catch {
                sendError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}

struct PreviewItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Behind the messages: the chat's own wallpaper, or the app look.
struct ChatWallpaper: View {
    let conv: Conversation
    @ObservedObject private var looks = LookManager.shared
    @Environment(\.look) private var look

    var body: some View {
        Group {
            if let w = conv.wallpaper {
                if w == "photo", let img = WallpaperStore.image("chat-\(conv.id)", version: looks.photoVersion) {
                    PhotoWallpaper(image: img, dim: 0.25)
                } else if w.hasPrefix("vivid:"), let t = VividTheme(rawValue: String(w.dropFirst(6))) {
                    VividWallpaper(theme: t)
                } else if w.hasPrefix("skin:"), let s = Skin(rawValue: String(w.dropFirst(5))) {
                    SkinArt(skin: s).overlay(Color.black.opacity(0.25))
                } else {
                    LookBackdrop()
                }
            } else if look.style == .classic {
                Color(.systemBackground)
            } else {
                LookBackdrop()
            }
        }
        .ignoresSafeArea()
    }
}
