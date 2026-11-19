import SwiftUI

/// Settings → Backup.
struct BackupView: View {
    @ObservedObject private var backup = Backup.shared
    @Environment(\.look) private var look
    @State private var found: [Backup.Found] = []
    @State private var restoring: Backup.Found?
    @State private var restartNote = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: backup.needsWarning ? "exclamationmark.icloud.fill" : "checkmark.icloud.fill")
                        .font(.largeTitle)
                        .foregroundStyle(backup.needsWarning ? look.warning : look.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        if let d = backup.lastDate {
                            Text("Last backup \(d.formatted(.relative(presentation: .named)))").font(.headline)
                            Text("\(Fmt.bytes(backup.lastSize)) · \(d.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(look.textSecondary)
                        } else {
                            Text("Not backed up yet").font(.headline)
                            Text("If you delete iTeam now, everything on this device is lost.")
                                .font(.caption).foregroundStyle(look.warning)
                        }
                    }
                }
                .padding(.vertical, 4)
                Button {
                    Task { await backup.backUpNow() }
                } label: {
                    HStack {
                        Label("Back up now", systemImage: "arrow.up.to.line.circle")
                        Spacer()
                        if backup.busy { ProgressView() }
                    }
                }
                .disabled(backup.busy)
                if let p = backup.progress { Text(p).font(.caption).foregroundStyle(look.textSecondary) }
                if let e = backup.lastError { Text(e).font(.caption).foregroundStyle(look.warning) }
                Toggle("Back up automatically (daily)", isOn: $backup.auto)
            } footer: {
                Text("Chats, tasks, every module, photos, files and settings are encrypted on this iPhone before upload and saved in your own private iCloud — it uses your iCloud storage. Only your devices, signed in to the same Apple ID with iCloud Keychain on, can open it.")
            }

            Section("Restore") {
                if found.isEmpty {
                    Text("No backup found in your iCloud yet.").foregroundStyle(look.textSecondary)
                }
                ForEach(found) { f in
                    Button {
                        restoring = f
                    } label: {
                        LabeledContent(f.id == "ipad" ? "iPad backup" : "iPhone backup",
                                       value: "\(f.date.formatted(date: .abbreviated, time: .shortened)) · \(Fmt.bytes(f.size))")
                    }
                }
            }
        }
        .lookScreen()
        .navigationTitle("Backup")
        .task { found = await backup.available() }
        .confirmationDialog("Replace everything on this device with this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                guard let f = restoring else { return }
                Task { if await backup.prepareRestore(f) { restartNote = true } }
            }
        } message: {
            Text("Anything on this device that isn't in the backup will be removed.")
        }
        .alert("Backup downloaded", isPresented: $restartNote) {
            Button("OK") {}
        } message: {
            Text(RestoreOfferView.restartText)
        }
    }
}

/// Shown once after a fresh install when an iCloud backup exists.
struct RestoreOfferView: View {
    let found: Backup.Found
    @ObservedObject private var backup = Backup.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var done = false

    static let restartText = "To finish, close iTeam completely (swipe it up from the app switcher) and open it again. Your chats, tasks and modules will be back."

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: done ? "checkmark.icloud.fill" : "icloud.and.arrow.down.fill")
                .font(.system(size: 56)).foregroundStyle(look.accent)
            Text(done ? "Almost done" : "Restore from iCloud?").font(.title2.bold())
            if done {
                Text(Self.restartText).multilineTextAlignment(.center).foregroundStyle(look.textSecondary)
            } else {
                Text("A backup from your \(found.id == "ipad" ? "iPad" : "iPhone") was found — \(found.date.formatted(date: .abbreviated, time: .shortened)), \(Fmt.bytes(found.size)).")
                    .multilineTextAlignment(.center).foregroundStyle(look.textSecondary)
                if let p = backup.progress { Text(p).font(.caption) }
                if let e = backup.lastError { Text(e).font(.caption).foregroundStyle(look.warning).multilineTextAlignment(.center) }
                Button {
                    Task { done = await backup.prepareRestore(found) }
                } label: {
                    HStack { if backup.busy { ProgressView() }; Text("Restore") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).disabled(backup.busy)
                Button("Skip — start fresh") { dismiss() }.disabled(backup.busy)
            }
        }
        .padding(28)
        .interactiveDismissDisabled(backup.busy || done)
        .presentationDetents([.medium])
    }
}
