import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import Combine

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
    @State private var showGames = false
    @State private var showFight = false
    @State private var showRecommend = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var showOnce = false
    @State private var onceItems: [PhotosPickerItem] = []
    @State private var sendError: String?
    @State private var quickLook: URL?
    @State private var showCamera = false
    @State private var askLink = false
    @State private var linkText = ""
    @State private var showApproval = false
    @State private var showPoll = false
    @State private var showGrievance = false
    @State private var forwarding: Message?
    @State private var shareItems: ShareItems?
    @State private var aiSheet: AISheet?
    @StateObject private var recorder = VoiceRecorder()
    @State private var showGroupCall = false
    @State private var askFaceTime = false
    enum AISheet: String, Identifiable { case summary, report; var id: String { rawValue } }
    @FocusState private var focused: Bool

    init(convID: String) {
        self.convID = convID
        _convs = Query(filter: #Predicate<Conversation> { $0.id == convID })
        _messages = Query(filter: #Predicate<Message> { $0.convID == convID }, sort: \Message.createdAt)
    }

    private var conv: Conversation? { convs.first }
    @State private var magicOpen = false
    @State private var showRx = false
    @State private var showCheckIn = false
    @State private var showEvent = false
    @State private var showMeeting = false
    @State private var lastSeen: Date?
    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    /// Hides magic moments that haven't reached their time (on the recipient's phone) and expired disappearing messages.
    private var shown: [Message] {
        let now = Date.now
        return messages.filter { m in
            !(m.magicPending && m.senderID != engine.me) && (m.expiresAt ?? .distantFuture) > now
        }
    }

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
        lifecycle(pickers(sheets(chrome(messageList(conv), conv), conv), conv), conv)
    }

    private func messageList(_ conv: Conversation) -> some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                encryptionNote
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, m in
                    if i == 0 || !Calendar.current.isDate(shown[i - 1].createdAt, inSameDayAs: m.createdAt) {
                        dayHeader(m.createdAt)
                    }
                    let showName = conv.isGroup && m.senderID != engine.me &&
                        (i == 0 || shown[i - 1].senderID != m.senderID || shown[i - 1].isSystem)
                    MessageBubble(message: m, conv: conv, showSender: showName, all: shown,
                                  onReply: { replyTo = m; editing = nil; focused = true },
                                  onEdit: { editing = m; text = m.text; replyTo = nil; focused = true },
                                  onTask: { taskFrom = m },
                                  onOpen: { url in quickLook = url },
                                  onForward: { forwarding = m },
                                  onShare: { Task { await share(m) } })
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
                VStack(spacing: 6) {
                    CheckInBanner(conv: conv)
                    composer(conv)
                }
            }
        }
    }

    private func chrome<V: View>(_ v: V, _ conv: Conversation) -> some View {
        v
        .sheet(isPresented: $showGames) { XOGamesView(convID: conv.id) }
        .sheet(isPresented: $showFight) { FightInviteView(convID: conv.id) }
        .sheet(isPresented: $showRecommend) { RecommendContactView(conv: conv) }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                ChatRequestBanner(conv: conv)
                ChatTasksStrip(convID: conv.id)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showInfo = true } label: { header(conv) }.buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) { callButton(conv) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { taskFrom = nil; showInfo = false; newTaskInChat = true } label: { Image(systemName: "checklist") }
                    .accessibilityLabel("New task in this chat")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Export chat as PDF", systemImage: "doc.richtext") {
                        let html = ShareText.chatHTML(conv, messages, engine: engine)
                        if let url = PDFMaker.make(title: conv.title, bodyHTML: html, fileName: "Chat – \(conv.title)", module: conv.isGroup ? "Group chat" : "Chat", icon: "bubble.left.and.bubble.right.fill", colors: [0x28BEE6, 0x3A5BD9], charts: PDFCharts.chat(messages, engine: engine)) {
                            shareItems = ShareItems(items: [url])
                        }
                    }
                    Button("Play X and O", systemImage: "gamecontroller.fill") { showGames = true }
                    if conv.members.count > 1 { Button("Fluffy Fight", systemImage: "figure.boxing") { showFight = true } }
                    Button("Share chat as text", systemImage: "text.alignleft") {
                        shareItems = ShareItems(items: [ShareText.chatText(conv, messages, engine: engine)])
                    }
                    if AISettings.shared.allows(.chatSummary) {
                        Button("What did I miss? (AI)", systemImage: "sparkles") { aiSheet = .summary }
                    }
                    if conv.isGroup && AISettings.shared.groupAI.contains(conv.id) && AISettings.shared.allows(.groupReports) {
                        Button("Group report (AI)", systemImage: "chart.bar.doc.horizontal") { aiSheet = .report }
                    }
                    Button("Copy whole chat", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = ShareText.chatText(conv, messages, engine: engine)
                        Haptics.success()
                    }
                } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share or export chat")
            }
        }
    }

    /// FaceTime: one tap for a direct chat (if they shared FaceTime), a link card for groups.
    @ViewBuilder
    private func callButton(_ conv: Conversation) -> some View {
        if conv.isGroup {
            Button { showGroupCall = true } label: { Image(systemName: "video") }
                .accessibilityLabel("Group video call")
        } else if let peer = conv.peerID.flatMap({ engine.contact($0) }), !peer.facetime.isEmpty {
            Menu {
                Button("FaceTime video", systemImage: "video") { FaceTime.call(peer.facetime, video: true) }
                Button("FaceTime audio", systemImage: "phone") { FaceTime.call(peer.facetime, video: false) }
            } label: { Image(systemName: "video") }
            .accessibilityLabel("Call")
        } else if !conv.isDemo, conv.peerID != nil {
            Button { askFaceTime = true } label: { Image(systemName: "video") }
                .accessibilityLabel("Call")
        }
    }

    /// Share one message: its text plus its files (downloaded and decrypted first).
    private func share(_ m: Message) async {
        var items: [Any] = []
        if !m.text.isEmpty { items.append(m.text) }
        for a in m.attachments {
            if let url = try? await Attachments.load(a) {
                // Share under the original file name, not the internal cache name.
                let named = FileManager.default.temporaryDirectory.appendingPathComponent(PDFMaker.safe(a.name))
                try? FileManager.default.removeItem(at: named)
                items.append((try? FileManager.default.copyItem(at: url, to: named)) != nil ? named : url)
            }
        }
        if !items.isEmpty { shareItems = ShareItems(items: items) }
    }

    private func sheets<V: View>(_ v: V, _ conv: Conversation) -> some View {
        v
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                if conv.isGroup { GroupInfoView(conv: conv) } else { ContactInfoView(conv: conv) }
            }
        }
        .sheet(item: $forwarding) { m in
            NavigationStack { ForwardSheet(messages: [m]) }
        }
        .shareSheet($shareItems)
        .sheet(isPresented: $showGroupCall) { NavigationStack { GroupCallSheet(conv: conv) } }
        .alert("\(conv.title) hasn't shared FaceTime", isPresented: $askFaceTime) {
            Button("Ask them") {
                engine.sendText("📹 I'd like to FaceTime you. Please turn on Settings → Profile → “Share my FaceTime with contacts” in iTeam.", in: conv)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Calls use Apple's FaceTime. They need to share their FaceTime phone or email with contacts first.")
        }
        .sheet(item: $aiSheet) { kind in
            NavigationStack {
                if kind == .summary {
                    AIResultView(title: "What did I miss?",
                                 instructions: "Summarise this chat for someone catching up: key points, decisions, questions waiting for an answer, and anything that should become a task. Mention who said what.",
                                 context: AIContext.chat(conv, engine: engine), postTo: conv)
                } else {
                    AIResultView(title: "Group report",
                                 instructions: "Write a short weekly report for the whole group: progress, what was completed and by whom, what's overdue, spending, and the next 3 priorities. Neutral and encouraging.",
                                 context: AIContext.groupReport(conv, engine: engine), postTo: conv)
                }
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
    }

    private func pickers<V: View>(_ v: V, _ conv: Conversation) -> some View {
        v
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
        .sheet(isPresented: $showPoll) {
            NavigationStack { PollComposer(conv: conv) }
        }
        .sheet(isPresented: $showGrievance) {
            NavigationStack { RaiseGrievanceView(group: conv) }
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
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 30, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { sendFiles(urls, conv: conv) }
        }
    }

    private func lifecycle<V: View>(_ v: V, _ conv: Conversation) -> some View {
        v
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPhotos(items, conv: conv) }
        }
        .photosPicker(isPresented: $showOnce, selection: $onceItems, maxSelectionCount: 1, matching: .any(of: [.images, .videos]))
        .onChange(of: onceItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPhotos(items, conv: conv, viewOnce: true); onceItems = [] }
        }
        .onAppear {
            engine.openConversation = conv.id
            engine.markRead(conv)
            if text.isEmpty { text = conv.draft }
            MagicMoments.tick(engine)
        }
        .onReceive(ticker) { _ in MagicMoments.tick(engine) }
        .task {
            // Live "online / last seen" while the chat is open (only when I share mine too).
            while !Task.isCancelled, !conv.isGroup, let peer = conv.peerID, peer != engine.me, !conv.isDemo {
                if MyDetails.lastSeenEveryone {
                    let seen = await engine.cloud.fetchSeen([peer])[peer]
                    lastSeen = seen
                    if let seen, let c = engine.contact(peer) { c.lastSeen = seen }
                }
                try? await Task.sleep(for: .seconds(40))
            }
        }
        .sheet(isPresented: $showCheckIn) { NavigationStack { CheckInSheet(conv: conv) } }
        .sheet(isPresented: $showEvent) { NavigationStack { EventEditor(conv: conv) } }
        .sheet(isPresented: $showMeeting) { NavigationStack { MeetingEditor(conv: conv) } }
        .sheet(isPresented: $showRx) {
            if let peer = conv.peerID {
                NavigationStack { PrescriptionEditor(conv: conv, patientID: peer, patientName: engine.name(of: peer)) }
            }
        }
        .sheet(isPresented: $magicOpen) {
            MagicMomentSheet(text: text) { body, refs, uploads, when in
                engine.sendText(body, in: conv, replyTo: replyTo?.id, attachments: refs, uploads: uploads, showAt: when)
                text = ""; replyTo = nil
            }
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
                HStack(spacing: 3) {
                    Text(conv.title).font(.headline).lineLimit(1)
                    if !conv.isGroup, let p = conv.peerID, engine.contact(p)?.plus == true { PlusBadge(size: 11) }
                }
                Text(subtitle(conv)).font(.caption2).foregroundStyle(look.textSecondary).lineLimit(1)
            }
        }
    }

    private func subtitle(_ conv: Conversation) -> String {
        switch engine.status {
        case .offline: return "Offline · messages wait on this device"
        case .syncing: return "Syncing…"
        default:
            let timer = conv.timer > 0 ? "⏱ \(MyDetails.timerName(conv.timer)) · " : ""
            if conv.isGroup { return timer + "\(conv.members.count) members · tap for info" }
            let contact = conv.peerID.flatMap { engine.contact($0) }
            var music = ""
            if let c = contact, !c.nowPlaying.isEmpty, Date.now.timeIntervalSince(c.nowPlayingAt ?? .distantPast) < 15 * 60 {
                music = "🎵 " + c.nowPlaying
            }
            let seenAt = [lastSeen, contact?.lastSeen].compactMap { $0 }.max()
            var presence = ""
            if let seen = seenAt {
                if Date.now.timeIntervalSince(seen) < 180 { presence = "online" }
                else {
                    presence = "last seen " + (Calendar.current.isDateInToday(seen) ? "today at \(seen.formatted(date: .omitted, time: .shortened))"
                                               : Calendar.current.isDateInYesterday(seen) ? "yesterday at \(seen.formatted(date: .omitted, time: .shortened))"
                                               : seen.formatted(date: .abbreviated, time: .shortened))
                }
            }
            let line = [presence, music].filter { !$0.isEmpty }.joined(separator: " · ")
            if !line.isEmpty { return timer + line }
            return timer + "End-to-end encrypted · tap for info"
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
                    Button("Photos & videos", systemImage: "photo.on.rectangle") { showPhotos = true }
                    Button("View-once photo or video", systemImage: "1.circle") { showOnce = true }
                    Toggle(isOn: Binding(get: { Attachments.sendOriginal }, set: { Attachments.sendOriginal = $0 })) {
                        Label("Original quality", systemImage: "photo.badge.checkmark")
                    }
                    Button("Document", systemImage: "doc") { showFiles = true }
                    Button("Link", systemImage: "link") { askLink = true }
                    Divider()
                    Button("New task", systemImage: "checklist") { newTaskInChat = true }
                    if conv.members.count > 1 {
                        Button("Poll", systemImage: "chart.bar") { showPoll = true }
                        Button("Meeting", systemImage: "person.3.fill") { showMeeting = true }
                        Button("Request approval", systemImage: "checkmark.seal") { showApproval = true }
                    }
                    if conv.isGroup && conv.members.count > 2 {
                        Button("Raise a grievance (private)", systemImage: "exclamationmark.bubble") { showGrievance = true }
                    }
                    Button("Recommend a contact", systemImage: "person.crop.circle.badge.plus") { showRecommend = true }
                    Button("Play X and O", systemImage: "gamecontroller") { showGames = true }
                    if conv.members.count > 1 { Button("Fluffy Fight", systemImage: "figure.boxing") { showFight = true } }
                    Button("Check In", systemImage: "location.circle") { showCheckIn = true }
                    Button("Event invite", systemImage: "party.popper") { showEvent = true }
                    Button("✨ Magic moment (send later)", systemImage: "sparkles") { magicOpen = true }
                } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .lookFloating(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Attach")

                if recorder.recording {
                    HStack(spacing: 10) {
                        Button { _ = recorder.stop(keep: false) } label: { Image(systemName: "trash").foregroundStyle(look.danger) }
                        Circle().fill(.red).frame(width: 10, height: 10).opacity(recorder.level > 0.3 ? 1 : 0.4)
                        Text(Clock.mmss(recorder.elapsed)).monospacedDigit()
                        Spacer()
                        Text("Recording…").font(.caption).foregroundStyle(look.textSecondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .lookFloating(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    TextField("Message", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .lookFloating(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !canSend && editing == nil {
                    Button {
                        if recorder.recording {
                            if let r = recorder.stop(keep: true), let p = try? Attachments.prepareVoice(r.0, duration: r.1) {
                                engine.sendText("", in: conv, replyTo: replyTo?.id, attachments: [p.ref], uploads: [p.upload.0: p.upload.1])
                                replyTo = nil
                            }
                        } else {
                            Task { if !(await recorder.start()) { sendError = "Allow the microphone for iTeam in iPhone Settings to record voice notes." } }
                        }
                    } label: {
                        Image(systemName: recorder.recording ? "arrow.up" : "mic.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(recorder.recording ? Color.white : Color.primary)
                            .frame(width: 40, height: 40)
                            .background(recorder.recording ? AnyShapeStyle(look.gradient) : AnyShapeStyle(Color.clear), in: Circle())
                            .lookFloating(in: Circle(), interactive: true)
                    }
                    .accessibilityLabel(recorder.recording ? "Send voice note" : "Record voice note")
                } else {
                Button { send(conv) } label: {
                    Image(systemName: editing != nil ? "checkmark" : "arrow.up")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(canSend ? Color.white : look.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(canSend ? AnyShapeStyle(look.gradient) : AnyShapeStyle(Color.clear), in: Circle())
                        .lookFloating(in: Circle(), interactive: true)
                }
                .disabled(!canSend)
                .contextMenu {
                    if editing == nil && canSend {
                        Button("✨ Magic moment (send later)", systemImage: "sparkles") { magicOpen = true }
                    }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: messages.count)
                .accessibilityLabel(editing != nil ? "Save edit" : "Send")
                }
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

    private func sendPhotos(_ items: [PhotosPickerItem], conv: Conversation, viewOnce: Bool = false) async {
        var refs: [AttachmentRef] = []
        var uploads: [String: String] = [:]
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try? await item.loadTransferable(type: MovieFile.self) else { continue }
                do {
                    let p = try await VideoPrep.prepare(movie.url, maxSeconds: VideoPrep.chatSeconds, original: Attachments.sendOriginal, rejectLonger: true)
                    try? FileManager.default.removeItem(at: movie.url)
                    refs.append(p.ref)
                    uploads[p.upload.0] = p.upload.1
                } catch {
                    sendError = error.localizedDescription
                }
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                let p = try await Attachments.prepareImageAsync(data, original: Attachments.sendOriginal)
                refs.append(p.ref)
                uploads[p.upload.0] = p.upload.1
            } catch {
                sendError = error.localizedDescription
            }
        }
        photoItems = []
        guard !refs.isEmpty else { return }
        engine.sendText(viewOnce ? "" : text, in: conv, replyTo: replyTo?.id, attachments: refs, uploads: uploads, viewOnce: viewOnce)
        if viewOnce { return }
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

/// Apple's FaceTime: free, end-to-end encrypted, up to 32 people.
enum FaceTime {
    static func call(_ handle: String, video: Bool) {
        let clean = handle.contains("@") ? handle : handle.filter { $0.isNumber || $0 == "+" }
        guard let enc = clean.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: (video ? "facetime://" : "facetime-audio://") + enc) else { return }
        UIApplication.shared.open(url)
    }

    static func isLink(_ text: String) -> URL? {
        guard let r = text.range(of: #"https://facetime\.apple\.com/join[^\s]*"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }
}

/// Group video call: make a FaceTime link and post it as a "Join call" card.
struct GroupCallSheet: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var link = ""

    var body: some View {
        Form {
            Section {
                Label("Open the FaceTime app", systemImage: "1.circle.fill")
                Label("Tap “Create Link”, then “Copy”", systemImage: "2.circle.fill")
                Label("Come back and tap Paste below", systemImage: "3.circle.fill")
                Button("Open FaceTime", systemImage: "video.fill") {
                    if let url = URL(string: "facetime://") { UIApplication.shared.open(url) }
                }
            } header: {
                Text("Start a group call — up to 32 people")
            } footer: {
                Text("Everyone in “\(conv.title)” gets a Join call card. FaceTime is free and end-to-end encrypted; people on Android or Windows can join from a browser.")
            }
            .lookRows()
            Section {
                TextField("https://facetime.apple.com/join#…", text: $link).textInputAutocapitalization(.never).keyboardType(.URL)
                Button("Paste", systemImage: "doc.on.clipboard") { link = UIPasteboard.general.string ?? link }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Group video call")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Post") {
                    engine.sendText("📹 Group video call — tap Join\n\(link.trimmingCharacters(in: .whitespaces))", in: conv)
                    Haptics.success()
                    dismiss()
                }
                .disabled(FaceTime.isLink(link) == nil)
            }
        }
    }
}


/// Someone not in my contacts messaged me: add (so they can be added to groups) or block.
struct ChatRequestBanner: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    var body: some View {
        if !conv.isGroup, let peer = SyncEngine.peer(inDirect: conv.id, me: engine.me), peer != engine.me,
           !peer.hasPrefix("demo_"), let c = engine.contact(peer), !c.saved, !c.blocked {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.title3)
                Text("\(c.name.isEmpty ? "This person" : c.name) isn't in your contacts").font(.footnote.weight(.semibold))
                Spacer()
                Button("Add") { engine.acceptRequest(c); Haptics.success() }.buttonStyle(.glassProminent).controlSize(.small)
                Button("Block", role: .destructive) { c.blocked = true; c.isRequest = false; engine.save() }.buttonStyle(.glass).controlSize(.small)
            }
            .padding(10)
            .lookFloating(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
        }
    }
}

/// Open tasks of this chat as tappable chips, so both people see new tasks right away.
struct ChatTasksStrip: View {
    let convID: String
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Query private var tasks: [TaskItem]

    init(convID: String) {
        self.convID = convID
        let cid: String? = convID
        _tasks = Query(filter: #Predicate<TaskItem> { $0.convID == cid && !$0.deleted }, sort: \TaskItem.createdAt, order: .reverse)
    }

    var body: some View {
        let open = tasks.filter { $0.status != .done }
        if !open.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(open.prefix(12)) { t in
                        Button { router.show(task: t.id) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "checklist")
                                Text(t.title).lineLimit(1)
                                if t.createdAt > .now.addingTimeInterval(-86400) { Text("NEW").font(.caption2.bold()).foregroundStyle(.orange) }
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .lookFloating(in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}


/// Pick a contact to recommend in this chat; they're told who you recommended them to.
struct RecommendContactView: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    var body: some View {
        NavigationStack {
            List(contacts.filter { c in !conv.members.contains { $0.id == c.userID } && !c.userID.hasPrefix("demo_") }) { c in
                Button {
                    engine.recommend(c, in: conv)
                    Haptics.success()
                    dismiss()
                } label: {
                    HStack {
                        AvatarView(name: c.name, imageData: c.avatar, size: 36)
                        Text(c.name).foregroundStyle(Color.primary)
                    }
                }
            }
            .navigationTitle("Recommend a contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
