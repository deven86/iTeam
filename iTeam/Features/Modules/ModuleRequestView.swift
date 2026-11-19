import SwiftUI
import AuthenticationServices

/// Request a module: anyone can describe a module their team needs.
struct ModuleRequestView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @State private var title = ""
    @State private var problem = ""
    @State private var details = ""
    @State private var users = ""
    @State private var willPay = 1
    @State private var contact = ""
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    @State private var mine = MyModuleRequests.all

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !problem.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Module name, e.g. Attendance, Inventory, Invoices", text: $title)
                TextField("What problem should it solve?", text: $problem, axis: .vertical).lineLimit(3...6)
                TextField("How should it work? Screens, fields, reports…", text: $details, axis: .vertical).lineLimit(3...8)
            } header: {
                Text("Your idea")
            }
            Section("Who would use it") {
                TextField("e.g. my office staff of 10, family, school teachers", text: $users)
                Picker("Would you pay for it?", selection: $willPay) {
                    ForEach(0..<3, id: \.self) { Text(ModuleRequestItem.payLabels[$0]).tag($0) }
                }
            }
            Section {
                TextField("Email or phone (optional)", text: $contact)
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress)
            } header: {
                Text("So we can ask you questions")
            } footer: {
                Text("Requests go to the iTeam team through iCloud. Unlike chats, they are not end-to-end encrypted, so don't include confidential details.")
            }
            Section {
                Button {
                    Task { await send() }
                } label: {
                    Group { if sending { ProgressView() } else { Text(sent ? "Sent — thank you!" : "Send request") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(!canSend || sending)
                .listRowBackground(Color.clear)
                if let error { Text(error).font(.caption).foregroundStyle(look.danger) }
            }
            if !mine.isEmpty {
                Section("Your requests") {
                    ForEach(mine) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.headline)
                            Text(r.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(look.textSecondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lookScreen()
        .navigationTitle("Request a module")
    }

    private func send() async {
        sending = true; error = nil
        defer { sending = false }
        let r = ModuleRequestItem(id: UUID().uuidString,
                                  title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                  problem: problem.trimmingCharacters(in: .whitespacesAndNewlines),
                                  details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                                  users: users, willPay: willPay, name: engine.myName,
                                  contact: contact.trimmingCharacters(in: .whitespaces), date: .now)
        do {
            try await CloudService.shared.submit(r)
            MyModuleRequests.add(r)
            mine = MyModuleRequests.all
            Haptics.success()
            sent = true
            title = ""; problem = ""; details = ""; users = ""
        } catch {
            self.error = "Couldn't send: \(error.localizedDescription). Check iCloud and try again."
        }
    }
}

/// Owner only: every module request, newest first.
struct OwnerRequestsView: View {
    @Environment(\.look) private var look
    @State private var items: [ModuleRequestItem] = []
    @State private var loading = true
    @State private var error: String?
    @AppStorage("owner.requestsDone") private var doneRaw = ""

    private var done: Set<String> { Set(doneRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        List {
            if loading && items.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).font(.caption).foregroundStyle(look.danger) }
            if !loading && items.isEmpty && error == nil {
                Text("No requests yet.").foregroundStyle(look.textSecondary)
            }
            ForEach(items) { r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(r.title).font(.headline).strikethrough(done.contains(r.id))
                        Spacer()
                        Chip(text: ModuleRequestItem.payLabels[min(max(r.willPay, 0), 2)], icon: "creditcard",
                             color: r.willPay == 2 ? look.success : look.textSecondary)
                    }
                    Text(r.problem).font(.subheadline)
                    if !r.details.isEmpty { Text(r.details).font(.caption).foregroundStyle(look.textSecondary) }
                    if !r.users.isEmpty { Label(r.users, systemImage: "person.3").font(.caption) }
                    HStack {
                        Text("\(r.name.isEmpty ? "Someone" : r.name) · \(r.date.formatted(date: .abbreviated, time: .shortened))")
                        if !r.contact.isEmpty { Text("· \(r.contact)").textSelection(.enabled) }
                    }
                    .font(.caption2).foregroundStyle(look.textSecondary)
                }
                .swipeActions {
                    Button(done.contains(r.id) ? "Reopen" : "Done") { toggle(r.id) }.tint(look.success)
                }
            }
            .lookRows()
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Module requests")
        .refreshable { await load() }
        .task {
            await load()
            try? await CloudService.shared.ensureOwnerRequestAlerts()
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { items = try await CloudService.shared.moduleRequests(); error = nil }
        catch { self.error = "Couldn't load requests: \(error.localizedDescription)" }
    }

    private func toggle(_ id: String) {
        var s = done
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        doneRaw = s.sorted().joined(separator: ",")
    }
}


/// Hidden owner check (tap the version number 5 times in Settings).
struct OwnerVerifyView: View {
    @ObservedObject private var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.look) private var look
    @State private var message: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: store.isOwner ? "crown.fill" : "person.badge.key.fill")
                .font(.system(size: 54)).foregroundStyle(look.gradient).padding(.top, 40)
            Text(store.isOwner ? "You're the owner" : "Verify app owner").font(.title2.bold())
            Text(store.isOwner ? "Every module is free on this Apple ID, on all your devices."
                               : "Sign in with the owner's Apple ID and choose “Share My Email”.")
                .multilineTextAlignment(.center).foregroundStyle(look.textSecondary)
            if !store.isOwner {
                SignInWithAppleButton(.continue) { req in
                    req.requestedScopes = [.email]
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
                        if Owner.check(cred) {
                            Haptics.success()
                            message = nil
                        } else if let mail = Owner.sharedEmail(cred) {
                            message = "Apple shared \(mail), which isn't the owner's email. If it ends in privaterelay.appleid.com, email was hidden: in iPhone Settings → your name → Sign in with Apple → iTeam, tap Stop Using, then try again and pick Share My Email."
                        } else {
                            message = "Apple didn't share an email. In iPhone Settings → your name → Sign in with Apple → iTeam, tap Stop Using, then try again and pick Share My Email."
                        }
                    case .failure(let e):
                        if (e as? ASAuthorizationError)?.code != .canceled { message = e.localizedDescription }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52).clipShape(Capsule())
            }
            if let message { Text(message).font(.caption).foregroundStyle(look.warning).multilineTextAlignment(.center) }
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.glass)
        }
        .padding(24)
        .lookScreen()
    }
}
