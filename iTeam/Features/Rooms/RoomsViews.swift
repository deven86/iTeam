import SwiftUI
import PhotosUI
import Combine

/// Rooms tab: my rooms, private chats, and public rooms to discover.
struct RoomsHomeView: View {
    @ObservedObject private var rooms = Rooms.shared
    @Environment(\.look) private var look
    @AppStorage("rooms.termsAccepted") private var accepted = false
    @State private var search = ""
    @State private var creating = false
    @State private var joining: Rooms.Room?
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var found: [Rooms.Room] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rooms.discover.filter { rooms.joined[$0.id] == nil && (q.isEmpty || $0.name.lowercased().contains(q) || $0.about.lowercased().contains(q)) }
    }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 10) {
                    stat("\(rooms.myRooms.count)", "My rooms", "person.3.sequence.fill")
                    stat("\(rooms.threads.count)", "Private chats", "lock.fill")
                    stat("\(rooms.unreadTotal)", "Unread", "envelope.badge")
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                if !rooms.myRooms.isEmpty {
                    Section("My rooms") {
                        ForEach(rooms.myRooms) { r in
                            NavigationLink { RoomChatView(room: r) } label: { RoomRow(room: r) }
                        }
                    }
                }
                if !rooms.threads.isEmpty {
                    Section("Private chats") {
                        ForEach(rooms.threads) { t in
                            NavigationLink { RoomDMView(thread: t) } label: { ThreadRow(thread: t) }
                                .swipeActions { Button("Delete", role: .destructive) { rooms.deleteThread(t) } }
                        }
                    }
                }
                Section {
                    if found.isEmpty {
                        Text(rooms.discover.isEmpty ? "No public rooms yet — create the first one." : "No rooms match.")
                            .foregroundStyle(look.textSecondary)
                    }
                    ForEach(found) { r in
                        Button { joining = r } label: { RoomRow(room: r) }.buttonStyle(.plain)
                    }
                } header: { Text("Discover rooms") } footer: {
                    Text("In rooms you appear only by your room name, gender and picture. Your iTeam name, number and profile stay hidden until you and the other person both tap Reveal in a private chat.")
                }
            }
            .lookScreen()
            .searchable(text: $search, prompt: "Search rooms")
            .navigationTitle("Rooms")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus.bubble") }.accessibilityLabel("Create room")
                }
            }
            .refreshable { await rooms.refreshDiscover(); await rooms.refreshInbox() }
            .task { await rooms.refreshDiscover(); await rooms.refreshInbox() }
            .onReceive(tick) { _ in Task { await rooms.refreshInbox() } }
            .sheet(isPresented: $creating) { NavigationStack { CreateRoomView() } }
            .sheet(item: $joining) { r in NavigationStack { PersonaSetupView(room: r) } }
            .sheet(isPresented: Binding(get: { !accepted }, set: { _ in })) { RoomRulesView { accepted = true } }
        }
    }
}

extension RoomsHomeView {
    func stat(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(Color(hex: 0x7F7FD5))
            Text(v).font(.title3.bold())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).lookCard(padding: 6)
    }
}

struct RoomRow: View {
    let room: Rooms.Room
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: room.name, imageData: room.photo, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.headline)
                if !room.about.isEmpty { Text(room.about).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }
}

struct ThreadRow: View {
    let thread: Rooms.Thread
    @ObservedObject private var rooms = Rooms.shared
    var body: some View {
        let m = rooms.member(thread.other)
        HStack(spacing: 12) {
            PersonaAvatar(member: m, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(m?.alias ?? "Guest") \(Rooms.symbol(m?.gender ?? ""))").font(.headline)
                Text("in \(rooms.room(thread.room)?.name ?? "a room")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if rooms.unread(thread) > 0 { CountBadge(count: rooms.unread(thread)) }
        }
    }
}

struct PersonaAvatar: View {
    let member: Rooms.Member?
    var size: CGFloat = 36
    var body: some View {
        if let p = member?.photo {
            AvatarView(name: member?.alias ?? "?", imageData: p, size: size)
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: AvatarView.colors(for: member?.id ?? "?"), startPoint: .top, endPoint: .bottom))
                Text(Rooms.symbol(member?.gender ?? "")).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Rules

struct RoomRulesView: View {
    let accept: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "person.3.sequence.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("Room rules").font(.title.bold())
            VStack(alignment: .leading, spacing: 8) {
                Label("Rooms are public. Anyone in a room can read its chat.", systemImage: "globe")
                Label("No abuse, harassment, hate, nudity, scams or spam — zero tolerance.", systemImage: "hand.raised.fill")
                Label("Long-press any message to report or block. Reported people disappear for you at once.", systemImage: "exclamationmark.bubble")
                Label("Never share money, OTPs or your address with strangers.", systemImage: "lock.shield")
                Label("You must be 18 or older to use rooms.", systemImage: "person.badge.shield.checkmark")
            }
            .font(.callout)
            Spacer()
            Button("I agree") { accept() }.buttonStyle(.glassProminent).frame(maxWidth: .infinity)
        }
        .padding(26)
        .interactiveDismissDisabled()
    }
}

// MARK: - Create / join

struct CreateRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rooms = Rooms.shared
    @State private var name = ""
    @State private var about = ""
    @State private var photo: Data?
    @State private var pick: PhotosPickerItem?
    @AppStorage("rooms.alias") private var alias = ""
    @AppStorage("rooms.gender") private var gender = "Prefer not to say"
    @State private var myPhoto: Data?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Room") {
                HStack {
                    PhotosPicker(selection: $pick, matching: .images) {
                        AvatarView(name: name.isEmpty ? "Room" : name, imageData: photo, size: 64)
                            .overlay(alignment: .bottomTrailing) { Image(systemName: "camera.circle.fill").font(.title3) }
                    }
                    TextField("Room name", text: $name)
                }
                TextField("What is it about?", text: $about, axis: .vertical)
            }
            PersonaFields(alias: $alias, gender: $gender, photo: $myPhoto)
            if let e = rooms.error { Text(e).foregroundStyle(.red).font(.caption) }
        }
        .navigationTitle("New room")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    busy = true
                    Task {
                        let p = Rooms.newPersona(alias: alias.trimmingCharacters(in: .whitespaces), gender: gender, photo: myPhoto)
                        if await rooms.create(name: name.trimmingCharacters(in: .whitespaces), about: about, photo: photo, as: p) != nil { dismiss() }
                        busy = false
                    }
                }
                .disabled(busy || name.trimmingCharacters(in: .whitespaces).count < 3 || !PersonaFields.valid(alias))
            }
        }
        .onChange(of: pick) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { photo = ImageShrink.jpeg(d) } }
        }
    }
}

struct PersonaSetupView: View {
    let room: Rooms.Room
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rooms = Rooms.shared
    @AppStorage("rooms.alias") private var alias = ""
    @AppStorage("rooms.gender") private var gender = "Prefer not to say"
    @State private var myPhoto: Data?
    @State private var busy = false

    var body: some View {
        Form {
            Section { RoomRow(room: room) }
            PersonaFields(alias: $alias, gender: $gender, photo: $myPhoto)
            if let e = rooms.error { Text(e).foregroundStyle(.red).font(.caption) }
        }
        .navigationTitle("Join room")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Join") {
                    busy = true
                    Task {
                        let p = Rooms.newPersona(alias: alias.trimmingCharacters(in: .whitespaces), gender: gender, photo: myPhoto)
                        if await rooms.join(room, as: p) { dismiss() }
                        busy = false
                    }
                }
                .disabled(busy || !PersonaFields.valid(alias))
            }
        }
    }
}

/// Room name, gender and optional picture fields.
struct PersonaFields: View {
    @Binding var alias: String
    @Binding var gender: String
    @Binding var photo: Data?
    @State private var pick: PhotosPickerItem?

    static func valid(_ alias: String) -> Bool { alias.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        Section {
            TextField("Your room name (not your real name)", text: $alias)
            Picker("Gender", selection: $gender) { ForEach(Rooms.genders, id: \.self) { Text($0) } }
            PhotosPicker(selection: $pick, matching: .images) {
                Label(photo == nil ? "Add a room picture (optional)" : "Change room picture", systemImage: "photo")
            }
            .onChange(of: pick) { _, item in
                Task { if let d = try? await item?.loadTransferable(type: Data.self) { photo = ImageShrink.jpeg(d) } }
            }
        } header: { Text("How others see you") } footer: {
            Text("Use a picture that doesn't show your face if you want to stay anonymous.")
        }
    }
}

// MARK: - Room chat

struct RoomChatView: View {
    let room: Rooms.Room
    @EnvironmentObject var engine: SyncEngine
    @ObservedObject private var rooms = Rooms.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var dm: Rooms.Thread?
    @State private var confirmLeave = false
    private let tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var me: String { rooms.joined[room.id]?.id ?? "" }
    private var isOwner: Bool { room.owner == me }
    private var messages: [Rooms.Message] {
        (rooms.roomMessages[room.id] ?? []).filter { $0.kind == .text && !rooms.isBlocked($0.sndr) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("Say hello 👋").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(messages) { m in bubble(m).id(m.id) }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Message the room", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines); text = ""
                    Task { await rooms.send(t, in: room) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10).background(.bar)
        }
        .lookScreen()
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let p = rooms.joined[room.id] { Text("You are \(p.alias) \(Rooms.symbol(p.gender))") }
                    ShareLink(item: "Join my room \"\(room.name)\" on iTeam → Rooms") { Label("Invite people", systemImage: "square.and.arrow.up") }
                    Button("Leave room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await rooms.refresh(room: room) }
        .onReceive(tick) { _ in Task { await rooms.refresh(room: room) } }
        .navigationDestination(item: $dm) { t in RoomDMView(thread: t) }
        .confirmationDialog("Leave \(room.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await rooms.leave(room); dismiss() } }
        }
    }

    private func bubble(_ m: Rooms.Message) -> some View {
        let mine = m.sndr == me
        let member = rooms.member(m.sndr)
        return HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 40) } else { PersonaAvatar(member: member, size: 32) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine {
                    Text("\(member?.alias ?? "Guest") \(Rooms.symbol(member?.gender ?? ""))\(m.sndr == room.owner ? " · host" : "")")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
                Text(m.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.regularMaterial),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(mine ? .white : .primary)
                Text(m.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
            .contextMenu {
                if !mine {
                    Button("Private chat", systemImage: "lock.bubble") { dm = Rooms.Thread(room: room.id, other: m.sndr) }
                    Button("Report", systemImage: "exclamationmark.bubble") { Task { await rooms.report(m, reason: "room message") } }
                    Button("Block", systemImage: "hand.raised", role: .destructive) { rooms.block(m.sndr) }
                }
                if !mine, let c = m.creator, Admin.shared.isAdmin(SyncEngine.shared.me) {
                    Button(Admin.shared.isBanned(c) ? "Unban from all Rooms" : "Ban from all Rooms", systemImage: "nosign", role: .destructive) {
                        Task { await Admin.shared.setBanned(c, !Admin.shared.isBanned(c)); await rooms.refresh(room: room) }
                    }
                }
                if isOwner || mine {
                    Button("Remove for everyone", systemImage: "trash", role: .destructive) { Task { await rooms.remove(m, in: room) } }
                }
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = m.text }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Private chat with reveal

struct RoomDMView: View {
    let thread: Rooms.Thread
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @ObservedObject private var rooms = Rooms.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var confirmReveal = false
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var me: String { rooms.joined[thread.room]?.id ?? "" }
    private var other: Rooms.Member? { rooms.member(thread.other) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    revealCard
                    ForEach(rooms.dms(thread)) { m in row(m).id(m.id) }
                }
                .padding()
            }
            .onChange(of: rooms.dms(thread).count) { _, _ in
                if let l = rooms.dms(thread).last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } }
                rooms.markRead(thread)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Private message", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines); text = ""
                    Task { await rooms.send(t, to: thread) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rooms.isBlocked(thread.other))
            }
            .padding(10).background(.bar)
        }
        .lookScreen()
        .navigationTitle("\(other?.alias ?? "Guest") \(Rooms.symbol(other?.gender ?? ""))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Block", systemImage: "hand.raised", role: .destructive) { rooms.block(thread.other); dismiss() }
                    if let last = rooms.dms(thread).last(where: { $0.sndr == thread.other }) {
                        Button("Report", systemImage: "exclamationmark.bubble") { Task { await rooms.report(last, reason: "private chat"); dismiss() } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { rooms.markRead(thread); await rooms.refreshInbox() }
        .onReceive(tick) { _ in Task { await rooms.refreshInbox() } }
        .confirmationDialog("Reveal your iTeam profile?", isPresented: $confirmReveal, titleVisibility: .visible) {
            Button("Reveal") { Task { await rooms.reveal(thread, invite: engine.myInvite) } }
        } message: {
            Text("They will see your iTeam name and can add you — but only after they reveal theirs too.")
        }
    }

    @ViewBuilder
    private var revealCard: some View {
        VStack(spacing: 8) {
            PersonaAvatar(member: other, size: 64)
            if let invite = rooms.revealedInvite(thread) {
                Text("You both revealed").font(.headline)
                Text("This is \(invite.name).").foregroundStyle(.secondary)
                Button("Add \(invite.name) to iTeam", systemImage: "person.badge.plus") {
                    router.pendingInvite = invite
                    router.tab = .chats
                }
                .buttonStyle(.glassProminent)
            } else if rooms.iRevealed(thread) {
                Label("You revealed. Waiting for \(other?.alias ?? "them") to reveal too.", systemImage: "hourglass").font(.callout)
            } else {
                Text(rooms.theyRevealed(thread) ? "\(other?.alias ?? "They") revealed. Reveal yours to connect on iTeam." : "Only your room name, gender and picture are visible.")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Reveal myself", systemImage: "eye") { confirmReveal = true }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity).padding().lookCard()
    }

    private func row(_ m: Rooms.Message) -> some View {
        let mine = m.sndr == me
        return HStack {
            if mine { Spacer(minLength: 40) }
            if m.kind == .reveal {
                Label(mine ? "You revealed your profile" : "\(other?.alias ?? "They") revealed their profile", systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                Text(m.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.regularMaterial),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(mine ? .white : .primary)
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}
