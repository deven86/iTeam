import SwiftUI
import SwiftData
import PhotosUI

/// Compose: pick a contact for a one-to-one chat, or build a group.
struct NewChatView: View {
    var onOpen: (Conversation) -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var showAdd = false
    @State private var search = ""

    private var filtered: [Contact] {
        search.isEmpty ? contacts : contacts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        NewGroupView { conv in dismiss(); onOpen(conv) }
                    } label: {
                        Label("New group", systemImage: "person.3.fill").font(.headline)
                    }
                    NavigationLink { BroadcastView() } label: {
                        Label("New broadcast", systemImage: "megaphone.fill").font(.headline)
                    }
                    Button { showAdd = true } label: {
                        Label("Add contact (QR code)", systemImage: "qrcode.viewfinder").font(.headline)
                    }
                }
                .lookRows()

                Section {
                    Button {
                        let conv = DemoChats.notesToSelf(engine)
                        dismiss()
                        onOpen(conv)
                    } label: {
                        Label("Notes to self", systemImage: "note.text")
                    }
                    Button {
                        let conv = DemoChats.create(engine)
                        dismiss()
                        onOpen(conv)
                    } label: {
                        Label("Demo team chat (practice)", systemImage: "sparkles")
                    }
                } header: {
                    Text("Try it out")
                } footer: {
                    Text("Notes to self is a real encrypted chat with yourself — it syncs to your iPad. The demo team has two pretend colleagues who reply; it never leaves this phone.")
                }
                .lookRows()

                Section(contacts.isEmpty ? "" : "Contacts") {
                    if contacts.isEmpty {
                        Text("No contacts yet. Scan someone's iTeam QR code, or share yours from Settings → My QR code.")
                            .font(.subheadline).foregroundStyle(look.textSecondary)
                    }
                    ForEach(filtered) { c in
                        Button {
                            let conv = engine.directConversation(with: c)
                            dismiss()
                            onOpen(conv)
                        } label: {
                            ContactRow(contact: c)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .lookRows()
            }
            .lookScreen()
            .searchable(text: $search)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showAdd) { AddContactView() }
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    var trailing: AnyView? = nil
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: contact.name, imageData: contact.avatar, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(.body.weight(.medium))
                if contact.verified {
                    Label("Verified by QR", systemImage: "checkmark.shield.fill").font(.caption2).foregroundStyle(look.success)
                }
            }
            Spacer()
            if let trailing { trailing }
        }
        .contentShape(Rectangle())
    }
}

struct NewGroupView: View {
    var onCreate: (Conversation) -> Void
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @State private var title = ""
    @State private var picked: Set<String> = []
    @State private var avatar: Data?
    @State private var photo: PhotosPickerItem?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        AvatarView(name: title.isEmpty ? "Group" : title, imageData: avatar, size: 64, isGroup: avatar == nil)
                    }
                    TextField("Group name", text: $title).font(.title3)
                }
            }
            .lookRows()
            Section("Members · \(picked.count) of \(SyncEngine.maxGroupSize - 1) max") {
                ForEach(contacts) { c in
                    Button {
                        if picked.contains(c.userID) { picked.remove(c.userID) } else if picked.count < SyncEngine.maxGroupSize - 1 { picked.insert(c.userID) }
                    } label: {
                        ContactRow(contact: c, trailing: AnyView(
                            Image(systemName: picked.contains(c.userID) ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(picked.contains(c.userID) ? look.accent : look.textSecondary)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("New group")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    let members = contacts.filter { picked.contains($0.userID) }
                    let conv = engine.createGroup(title: title.trimmingCharacters(in: .whitespaces), members: members, avatar: avatar)
                    Haptics.success()
                    onCreate(conv)
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
            }
        }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = OnboardingView.avatarData(d) } }
        }
    }
}


/// Broadcast: one message delivered privately to many people. Each person gets it in their own
/// one-to-one chat and replies only to you — like WhatsApp broadcast lists.
struct BroadcastView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @Query(filter: #Predicate<Contact> { $0.saved && !$0.blocked }, sort: \Contact.name) private var contacts: [Contact]
    @AppStorage("broadcast.lastList") private var lastList = ""
    @State private var picked: Set<String> = []
    @State private var text = ""
    @State private var sent = false

    var body: some View {
        List {
            Section {
                TextField("Message", text: $text, axis: .vertical).lineLimit(3...8)
            } footer: {
                Text("Each person receives it in your private chat with them. They can't see who else got it.")
            }
            Section {
                ForEach(contacts) { c in
                    Button {
                        if picked.contains(c.userID) { picked.remove(c.userID) } else { picked.insert(c.userID) }
                    } label: {
                        HStack {
                            AvatarView(name: c.name, imageData: c.avatar, size: 34)
                            Text(c.name).foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: picked.contains(c.userID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(c.userID) ? look.accent : look.textSecondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Send to \(picked.count)")
                    Spacer()
                    Button(picked.count == contacts.count ? "None" : "All") {
                        picked = picked.count == contacts.count ? [] : Set(contacts.map(\.userID))
                    }.font(.caption)
                }
            }
        }
        .lookScreen()
        .navigationTitle("Broadcast")
        .toolbar {
            Button("Send") {
                for c in contacts where picked.contains(c.userID) {
                    engine.sendText(text, in: engine.directConversation(with: c))
                }
                lastList = picked.sorted().joined(separator: ",")
                Haptics.success()
                dismiss()
            }
            .disabled(picked.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { if picked.isEmpty && !lastList.isEmpty { picked = Set(lastList.split(separator: ",").map(String.init)) } }
    }
}
