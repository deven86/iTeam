import SwiftUI
import SwiftData
import LocalAuthentication
import PhotosUI
import UserNotifications
import UniformTypeIdentifiers

/// Personal Wallet: important documents (Aadhaar, PAN, passport, licence…) kept only on this
/// device, behind Face ID, and included in the encrypted iCloud Backup. Never sent to anyone
/// unless you share a document yourself.
@Model
final class WalletDoc {
    var id: String = UUID().uuidString
    var kind: String = "other"
    var title: String = ""
    var number: String = ""
    var holder: String = ""
    var issued: Date? = nil
    var expires: Date? = nil
    var notes: String = ""
    @Attribute(.externalStorage) var front: Data? = nil
    @Attribute(.externalStorage) var back: Data? = nil
    @Attribute(.externalStorage) var pdf: Data? = nil
    var createdAt: Date = Date.now
    var deleted: Bool = false
    var deletedAt: Date? = nil

    init(kind: String) { self.kind = kind }
}

enum WalletKind: String, CaseIterable, Identifiable {
    case aadhaar, pan, passport, licence, voter, vehicle, insurance, health, bank, education, property, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aadhaar: "Aadhaar"; case .pan: "PAN card"; case .passport: "Passport"; case .licence: "Driving licence"
        case .voter: "Voter ID"; case .vehicle: "Vehicle RC"; case .insurance: "Insurance"; case .health: "Health card"
        case .bank: "Bank / cheque"; case .education: "Certificate"; case .property: "Property paper"; case .other: "Other"
        }
    }
    var icon: String {
        switch self {
        case .aadhaar: "person.text.rectangle"; case .pan: "creditcard"; case .passport: "globe.asia.australia"
        case .licence: "car"; case .voter: "checkmark.seal"; case .vehicle: "car.side"; case .insurance: "shield.lefthalf.filled"
        case .health: "cross.case"; case .bank: "building.columns"; case .education: "graduationcap"; case .property: "house"
        case .other: "doc.text"
        }
    }
    var colors: [Color] {
        switch self {
        case .aadhaar: [Color(hex: 0xFF9933), Color(hex: 0x138808)]
        case .pan: [Color(hex: 0x2F80ED), Color(hex: 0x56CCF2)]
        case .passport: [Color(hex: 0x1D2B64), Color(hex: 0x4A569D)]
        case .licence, .vehicle: [Color(hex: 0x11998E), Color(hex: 0x38EF7D)]
        case .insurance, .health: [Color(hex: 0xE53935), Color(hex: 0xE35D5B)]
        default: [Color(hex: 0x8E2DE2), Color(hex: 0x4A00E0)]
        }
    }
}

struct WalletView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.look) private var look
    @Query(filter: #Predicate<WalletDoc> { !$0.deleted }, sort: \WalletDoc.createdAt, order: .reverse) private var docs: [WalletDoc]
    @State private var unlocked = false
    @State private var adding: WalletKind?

    var body: some View {
        Group {
            if unlocked {
                List {
                    if docs.isEmpty {
                        EmptyStateView(icon: "wallet.pass", title: "Your documents, safe",
                                       message: "Add Aadhaar, PAN, passport, licence and more. They stay on this iPhone behind Face ID and in your encrypted iCloud Backup.")
                            .listRowBackground(Color.clear)
                    }
                    ForEach(docs) { d in
                        NavigationLink { WalletDocView(doc: d) } label: { WalletCard(doc: d) }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onDelete { idx in idx.map { docs[$0] }.forEach { WalletReminders.cancel($0); $0.deleted = true; $0.deletedAt = .now }; try? ctx.save() }
                }
                .listStyle(.plain)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(look.accent)
                    Text("Wallet is locked").font(.title3.bold())
                    Button("Unlock") { Task { await unlock() } }.buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .lookScreen()
        .navigationTitle("Personal Wallet")
        .toolbar {
            if unlocked {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(WalletKind.allCases) { k in Button(k.title, systemImage: k.icon) { adding = k } }
                    } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(item: $adding) { k in NavigationStack { WalletEditor(doc: nil, kind: k) } }
        .task { await unlock() }
    }

    private func unlock() async {
        let c = LAContext()
        var err: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { unlocked = true; return }
        unlocked = (try? await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open your Personal Wallet")) == true
    }
}

struct WalletCard: View {
    let doc: WalletDoc
    var body: some View {
        let k = WalletKind(rawValue: doc.kind) ?? .other
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: k.icon).font(.title2)
                Text(doc.title.isEmpty ? k.title : doc.title).font(.headline)
                Spacer()
                if let e = doc.expires {
                    Text(e < .now ? "Expired" : "Exp \(e.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(e < .now ? 0.4 : 0.22), in: Capsule())
                }
            }
            Text(WalletDocView.masked(doc.number)).font(.title3.monospaced())
            if !doc.holder.isEmpty { Text(doc.holder.uppercased()).font(.caption.weight(.semibold)).opacity(0.85) }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(LinearGradient(colors: k.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.vertical, 4)
    }
}

struct WalletDocView: View {
    @Bindable var doc: WalletDoc
    @Environment(\.look) private var look
    @State private var showNumber = false
    @State private var editing = false
    @State private var shareItems: ShareItems?

    static func masked(_ n: String) -> String {
        let clean = n.replacingOccurrences(of: " ", with: "")
        guard clean.count > 4 else { return n.isEmpty ? "—" : n }
        return String(repeating: "•", count: min(8, clean.count - 4)) + " " + clean.suffix(4)
    }

    var body: some View {
        List {
            Section { WalletCard(doc: doc).listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
            Section {
                HStack {
                    Text(showNumber ? (doc.number.isEmpty ? "—" : doc.number) : Self.masked(doc.number)).font(.body.monospaced())
                    Spacer()
                    Button { showNumber.toggle() } label: { Image(systemName: showNumber ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                    Button { UIPasteboard.general.setItems([[UTType.plainText.identifier: doc.number]], options: [.expirationDate: Date(timeIntervalSinceNow: 60)]); Haptics.success() } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                }
                if !doc.holder.isEmpty { LabeledContent("Name", value: doc.holder) }
                if let d = doc.issued { LabeledContent("Issued", value: d.formatted(date: .abbreviated, time: .omitted)) }
                if let d = doc.expires { LabeledContent("Expires", value: d.formatted(date: .abbreviated, time: .omitted)) }
                if !doc.notes.isEmpty { Text(doc.notes).font(.callout) }
            } footer: { Text("Copied numbers are removed from the clipboard after 1 minute.") }
            if doc.front != nil || doc.back != nil || doc.pdf != nil {
                Section("Copies") {
                    ForEach(Array([doc.front, doc.back].compactMap { $0 }.enumerated()), id: \.offset) { i, data in
                        if let img = UIImage(data: data) {
                            Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { Presenter.preview(data: data, name: "\(doc.title)-\(i + 1)", ext: "jpg") }
                        }
                    }
                    if let pdf = doc.pdf {
                        Button("Open PDF", systemImage: "doc.richtext") { Presenter.preview(data: pdf, name: doc.title, ext: "pdf") }
                    }
                }
            }
            Section {
                Button("Share…", systemImage: "square.and.arrow.up") { shareItems = ShareItems(items: shareFiles()) }
            } footer: { Text("Shares a copy you choose to send. iTeam never sends your documents anywhere by itself.") }
        }
        .lookScreen()
        .navigationTitle(doc.title.isEmpty ? (WalletKind(rawValue: doc.kind) ?? .other).title : doc.title)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { NavigationStack { WalletEditor(doc: doc, kind: WalletKind(rawValue: doc.kind) ?? .other) } }
        .shareSheet($shareItems)
    }

    private func shareFiles() -> [Any] {
        var out: [Any] = []
        let dir = FileManager.default.temporaryDirectory
        let base = PDFMaker.safe(doc.title.isEmpty ? doc.kind : doc.title)
        for (i, d) in [doc.front, doc.back].compactMap({ $0 }).enumerated() {
            let u = dir.appendingPathComponent("\(base)-\(i + 1).jpg"); try? d.write(to: u); out.append(u)
        }
        if let p = doc.pdf { let u = dir.appendingPathComponent("\(base).pdf"); try? p.write(to: u); out.append(u) }
        if out.isEmpty { out.append("\(doc.title): \(doc.number)") }
        return out
    }
}

struct WalletEditor: View {
    let doc: WalletDoc?
    let kind: WalletKind
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var number = ""
    @State private var holder = ""
    @State private var hasIssued = false
    @State private var issued = Date.now
    @State private var hasExpiry = false
    @State private var expires = Date.now.addingTimeInterval(365 * 86400)
    @State private var notes = ""
    @State private var front: Data?
    @State private var back: Data?
    @State private var pdf: Data?
    @State private var pickFront: PhotosPickerItem?
    @State private var pickBack: PhotosPickerItem?

    var body: some View {
        Form {
            Section(kind.title) {
                TextField("Title (e.g. My passport)", text: $title)
                TextField("Document number", text: $number).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Name on document", text: $holder)
                Toggle("Issue date", isOn: $hasIssued)
                if hasIssued { DatePicker("Issued", selection: $issued, displayedComponents: .date) }
                Toggle("Expiry date", isOn: $hasExpiry)
                if hasExpiry { DatePicker("Expires", selection: $expires, displayedComponents: .date) }
            }
            Section {
                if Presenter.canScan {
                    Button("Scan document", systemImage: "doc.viewfinder") {
                        Presenter.scan { pages in
                            front = pages.first?.jpegData(compressionQuality: 0.8)
                            if pages.count > 1 { back = pages[1].jpegData(compressionQuality: 0.8) }
                        }
                    }
                }
                PhotosPicker(selection: $pickFront, matching: .images) { Label(front == nil ? "Front photo" : "Change front", systemImage: "rectangle.portrait") }
                PhotosPicker(selection: $pickBack, matching: .images) { Label(back == nil ? "Back photo" : "Change back", systemImage: "rectangle.portrait.on.rectangle.portrait") }
                Button(pdf == nil ? "Attach PDF" : "Replace PDF", systemImage: "doc.richtext") {
                    Presenter.file(types: [.pdf]) { url in pdf = try? Data(contentsOf: url) }
                }
                HStack {
                    ForEach([front, back].compactMap { $0 }, id: \.self) { d in
                        if let i = UIImage(data: d) { Image(uiImage: i).resizable().scaledToFill().frame(width: 80, height: 54).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    }
                    if pdf != nil { Image(systemName: "doc.richtext.fill").font(.largeTitle) }
                }
            } header: { Text("Copies") }
            Section("Notes") { TextField("Notes", text: $notes, axis: .vertical) }
        }
        .navigationTitle(doc == nil ? "Add \(kind.title)" : "Edit")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
        .onChange(of: pickFront) { _, i in Task { if let d = try? await i?.loadTransferable(type: Data.self) { front = d } } }
        .onChange(of: pickBack) { _, i in Task { if let d = try? await i?.loadTransferable(type: Data.self) { back = d } } }
        .onAppear {
            guard let doc else { return }
            title = doc.title; number = doc.number; holder = doc.holder; notes = doc.notes
            if let d = doc.issued { hasIssued = true; issued = d }
            if let d = doc.expires { hasExpiry = true; expires = d }
            front = doc.front; back = doc.back; pdf = doc.pdf
        }
    }

    private func save() {
        let d = doc ?? WalletDoc(kind: kind.rawValue)
        if doc == nil { ctx.insert(d) }
        d.title = title.trimmingCharacters(in: .whitespaces); d.number = number.trimmingCharacters(in: .whitespaces)
        d.holder = holder; d.notes = notes
        d.issued = hasIssued ? issued : nil; d.expires = hasExpiry ? expires : nil
        d.front = front; d.back = back; d.pdf = pdf
        try? ctx.save()
        WalletReminders.schedule(d)
        dismiss()
    }
}

/// Reminds 30 days and 7 days before a document expires.
enum WalletReminders {
    static func schedule(_ d: WalletDoc) {
        cancel(d)
        guard let exp = d.expires else { return }
        let name = d.title.isEmpty ? (WalletKind(rawValue: d.kind) ?? .other).title : d.title
        for days in [30, 7] {
            guard let fire = Calendar.current.date(byAdding: .day, value: -days, to: exp), fire > .now else { continue }
            let c = UNMutableNotificationContent()
            c.title = "\(name) expires in \(days) days"
            c.body = "Renew it before \(exp.formatted(date: .abbreviated, time: .omitted))."
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: fire); comps.hour = 10
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wallet.\(d.id).\(days)", content: c,
                                                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
    static func cancel(_ d: WalletDoc) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["wallet.\(d.id).30", "wallet.\(d.id).7"])
    }
}
