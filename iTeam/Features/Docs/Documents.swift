import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Case file / document library (every module)
//
// Each document is one item filed in a folder of a record (a court matter, a project, a lead, a member…),
// with its own title and document date, so nothing piles up. Documents travel end-to-end encrypted in the
// record's chat and a permanent copy is kept on every phone that receives them (iCloud keeps files 45 days).

@Model final class DocItem {
    @Attribute(.unique) var id: String
    var module: String = ""
    var recordID: String = ""
    var recordOwner: String = ""
    var convID: String = ""
    var title: String = ""
    var folder: String = ""
    var docDate: Date? = nil
    var notes: String = ""
    var refData: Data = Data()
    var linkedID: String = ""
    var by: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false
    var deletedBy: String = ""
    init(id: String) { self.id = id }
    var ref: AttachmentRef? { try? JSONDecoder().decode(AttachmentRef.self, from: refData) }
    var sortDate: Date { docDate ?? createdAt }
}

struct DocPayload: Codable {
    var id: String
    var module: String
    var recordID: String
    var recordOwner: String
    var title: String
    var folder: String
    var date: Date?
    var notes: String
    var ref: AttachmentRef
    var linkedID: String?
    var deleted: Bool
    var at: Date
}

/// Ready-made folders per module (people can add their own).
enum DocFolders {
    static func defaults(_ module: String) -> [String] {
        switch module {
        case "legal": ["Pleadings & petitions", "Orders & judgments", "FIR & charge sheet", "Evidence & exhibits", "Applications",
                       "Affidavits", "Notices & correspondence", "Vakalatnama & authority", "Drafts", "Fees & receipts", "Other"]
        case "clinic", "care": ["Prescriptions", "Lab reports", "Scans & X-rays", "Discharge summaries", "Insurance", "Bills & receipts", "Other"]
        case "rent": ["Agreement", "Police verification", "ID proofs", "Rent receipts", "Meter & bills", "Photos", "Other"]
        case "khata": ["Bills & invoices", "Receipts", "Agreements", "Other"]
        case "tuition": ["Admission", "Fee receipts", "Report cards", "Assignments", "Other"]
        case "bills": ["Bills", "Receipts", "Warranty", "Policy documents", "Other"]
        case "kids": ["Birth & ID", "Vaccination", "School", "Medical", "Other"]
        case "travel": ["Tickets", "Hotel bookings", "Visa & passport", "Insurance", "Itinerary", "Other"]
        case "petcare": ["Vaccination", "Vet reports", "Registration", "Bills", "Other"]
        case "build": ["Title & land records", "Approvals & NOCs", "Plans & drawings", "RERA", "Agreements", "Contracts & work orders",
                       "Bills & invoices", "Test reports", "Site photos", "Legal & disputes", "Other"]
        case "crm": ["Quotes & proposals", "Agreements", "Invoices", "KYC", "Other"]
        case "society": ["Registration & bye-laws", "Minutes", "Notices", "Bills & receipts", "Insurance", "Audit", "Other"]
        case "gym": ["Medical & fitness", "Diet plans", "Receipts", "Photos", "Other"]
        case "attendance": ["ID & KYC", "Offer & appointment", "Salary slips", "Leave proofs", "Other"]
        case "task": ["Working files", "Drafts", "Final", "Other"]
        default: ["Documents", "Photos", "Receipts", "Other"]
        }
    }
    static func icon(_ folder: String) -> String {
        let f = folder.lowercased()
        if f.contains("order") || f.contains("judg") { return "building.columns" }
        if f.contains("photo") { return "photo.on.rectangle" }
        if f.contains("receipt") || f.contains("bill") || f.contains("fee") || f.contains("invoice") { return "indianrupeesign.circle" }
        if f.contains("draft") { return "pencil.and.scribble" }
        if f.contains("evidence") || f.contains("exhibit") { return "magnifyingglass" }
        if f.contains("fir") || f.contains("charge") { return "exclamationmark.shield" }
        if f.contains("notice") || f.contains("correspond") { return "envelope" }
        if f.contains("report") || f.contains("scan") { return "waveform.path.ecg.rectangle" }
        if f.contains("agreement") || f.contains("vakalat") || f.contains("contract") { return "signature" }
        return "folder"
    }
}

// MARK: Keeping files

@MainActor
enum DocStore {
    /// Permanent copy (not removed by "Clear downloaded files"), so case papers outlive iCloud's 45 days.
    static func keptURL(_ ref: AttachmentRef) -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CaseFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let ext = (ref.name as NSString).pathExtension
        return d.appendingPathComponent(ext.isEmpty ? ref.id : "\(ref.id).\(ext)")
    }
    static func isKept(_ ref: AttachmentRef) -> Bool { FileManager.default.fileExists(atPath: keptURL(ref).path) }

    static func open(_ ref: AttachmentRef) async throws -> URL {
        let kept = keptURL(ref)
        if FileManager.default.fileExists(atPath: kept.path) { return kept }
        let url = try await Attachments.load(ref)
        try? FileManager.default.copyItem(at: url, to: kept)
        return FileManager.default.fileExists(atPath: kept.path) ? kept : url
    }

    /// Download and keep right away (called when a document arrives).
    static func keep(_ ref: AttachmentRef) { Task { _ = try? await open(ref) } }

    /// A nicely named copy for sharing / printing.
    static func shareURL(_ d: DocItem) async throws -> URL? {
        guard let ref = d.ref else { return nil }
        let src = try await open(ref)
        let ext = (ref.name as NSString).pathExtension
        let name = PDFMaker.safe(d.title.isEmpty ? ref.name : d.title) + (ext.isEmpty ? "" : ".\(ext)")
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// Scanned pages → one PDF.
    static func pdf(from pages: [UIImage]) -> Data {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: a4).pdfData { ctx in
            for img in pages {
                ctx.beginPage()
                let s = min(a4.width / img.size.width, a4.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: (a4.width - w) / 2, y: (a4.height - h) / 2, width: w, height: h))
            }
        }
    }
}

// MARK: Sync

@MainActor
extension SyncEngine {
    func docSave(_ existing: DocItem?, module: String, recordID: String, recordOwner: String, convID: String, title: String, folder: String,
                 date: Date?, notes: String, ref: AttachmentRef, linkedID: String? = nil, deleted: Bool = false, uploads: [String: String] = [:]) {
        let p = DocPayload(id: existing?.id ?? "doc_" + UUID().uuidString, module: module, recordID: recordID, recordOwner: recordOwner,
                           title: title, folder: folder, date: date, notes: notes, ref: ref, linkedID: linkedID, deleted: deleted, at: .now)
        if let conv = conversation(convID), !conv.left {
            send(.doc(p), in: conv, loud: existing == nil && !deleted, preview: existing == nil ? "📁 \(myName) filed “\(title)” in \(folder)" : nil, uploads: uploads)
        } else {
            send(.doc(p), convID: selfConversationID, recipients: [], keyVersion: 0, loud: false, uploads: uploads)
        }
    }

    func docDelete(_ d: DocItem) {
        guard let ref = d.ref else { return }
        docSave(d, module: d.module, recordID: d.recordID, recordOwner: d.recordOwner, convID: d.convID, title: d.title, folder: d.folder,
                date: d.docDate, notes: d.notes, ref: ref, linkedID: d.linkedID.isEmpty ? nil : d.linkedID, deleted: true)
    }
}

extension EventApplier {
    func applyDoc(_ p: DocPayload, _ e: Event, conv: Conversation?, personal: Bool) -> Result {
        let id = p.id
        let ex = try? ctx.fetch(FetchDescriptor<DocItem>(predicate: #Predicate { $0.id == id })).first
        if let ex {
            // Only the person who filed it, or the record's owner, changes or removes it.
            guard ex.by == e.from || ex.recordOwner == e.from, p.at >= ex.updatedAt else { return .ignored }
        }
        let d = ex ?? { let x = DocItem(id: id); x.by = e.from; x.createdAt = e.at; ctx.insert(x); return x }()
        let wasDeleted = d.deleted
        let oldFolder = d.folder
        d.module = p.module; d.recordID = p.recordID; d.recordOwner = ex?.recordOwner ?? p.recordOwner
        d.title = p.title; d.folder = p.folder; d.docDate = p.date; d.notes = p.notes; d.linkedID = p.linkedID ?? ""
        d.refData = (try? JSONEncoder().encode(p.ref)) ?? Data(); d.updatedAt = p.at
        if !personal, let conv, d.convID.isEmpty { d.convID = conv.id }
        if p.deleted && !wasDeleted { d.deleted = true; d.deletedBy = e.from }
        if !d.deleted { DocStore.keep(p.ref) }
        if let conv, !personal {
            let who = e.from == me ? "You" : engine.name(of: e.from)
            if d.deleted && !wasDeleted { system(conv, "🗑 \(who) removed the document “\(p.title)”", at: e.at) }
            else if ex == nil { system(conv, "📁 \(who) filed “\(p.title)” in \(p.folder)", at: e.at) }
            else if oldFolder != p.folder { system(conv, "📁 \(who) moved “\(p.title)” to \(p.folder)", at: e.at) }
        }
        return .applied
    }
}

// MARK: - Section shown inside any record

/// Drop-in section: folder summary, "Add document", "Open case file", and loose attachments to file.
struct DocumentsSection: View {
    let module: String
    let recordID: String
    let recordOwner: String
    let convID: String
    let title: String
    var canAdd: Bool = true
    /// Older attachments saved on the record itself, shown so they can be filed into folders.
    var loose: [AttachmentRef] = []
    @EnvironmentObject var engine: SyncEngine
    @Query private var docs: [DocItem]
    @State private var adding = false
    @State private var filing: AttachmentRef?

    init(module: String, recordID: String, recordOwner: String, convID: String, title: String, canAdd: Bool = true, loose: [AttachmentRef] = []) {
        self.module = module; self.recordID = recordID; self.recordOwner = recordOwner; self.convID = convID; self.title = title
        self.canAdd = canAdd; self.loose = loose
        _docs = Query(filter: #Predicate<DocItem> { $0.recordID == recordID && !$0.deleted }, sort: \DocItem.createdAt)
    }

    var body: some View {
        let filed = Set(docs.compactMap { $0.ref?.blob })
        let unfiled = loose.filter { !filed.contains($0.blob) }
        let folders = Dictionary(grouping: docs, by: \.folder)
        Section {
            NavigationLink {
                DocumentLibraryView(module: module, recordID: recordID, recordOwner: recordOwner, convID: convID, title: title, canAdd: canAdd, loose: unfiled)
            } label: {
                Label { VStack(alignment: .leading) {
                    Text(module == "legal" ? "Open case file" : "Open documents").font(.headline)
                    Text(docs.isEmpty ? "No documents filed yet" : "\(docs.count) document\(docs.count == 1 ? "" : "s") in \(folders.count) folder\(folders.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                } } icon: { Image(systemName: "folder.fill").foregroundStyle(.tint) }
            }
            ForEach(folders.keys.sorted(by: { order($0) < order($1) }), id: \.self) { f in
                Label("\(f) · \(folders[f]?.count ?? 0)", systemImage: DocFolders.icon(f)).font(.subheadline)
            }
            ForEach(unfiled) { r in
                HStack {
                    Label(r.name, systemImage: r.kind == "image" ? "photo" : "doc").lineLimit(1)
                    Spacer()
                    if canAdd { Button("File it") { filing = r }.buttonStyle(.bordered).controlSize(.small) }
                    else { Button("Open") { Task { if let u = try? await DocStore.open(r) { Presenter.preview(u) } } }.controlSize(.small) }
                }
            }
            if canAdd { Button("Add document", systemImage: "doc.badge.plus") { adding = true } }
        } header: { Text("Documents") } footer: {
            if !unfiled.isEmpty { Text("Attachments not yet in a folder — tap File it to give each one a title, date and folder.") }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { DocumentEditor(module: module, recordID: recordID, recordOwner: recordOwner, convID: convID, existing: nil, preset: nil) }
        }
        .sheet(item: $filing) { r in
            NavigationStack { DocumentEditor(module: module, recordID: recordID, recordOwner: recordOwner, convID: convID, existing: nil, preset: r) }
        }
    }

    private func order(_ f: String) -> Int { DocFolders.defaults(module).firstIndex(of: f) ?? 99 }
}

// MARK: - Full library

struct DocumentLibraryView: View {
    let module: String
    let recordID: String
    let recordOwner: String
    let convID: String
    let title: String
    var canAdd: Bool
    var loose: [AttachmentRef]
    @EnvironmentObject var engine: SyncEngine
    @Query private var docs: [DocItem]
    @State private var search = ""
    @State private var folder: String? = nil
    @State private var adding = false
    @State private var editing: DocItem?
    @State private var filing: AttachmentRef?
    @State private var share: ShareItems?
    @State private var error: String?
    @State private var newestFirst = true

    init(module: String, recordID: String, recordOwner: String, convID: String, title: String, canAdd: Bool, loose: [AttachmentRef]) {
        self.module = module; self.recordID = recordID; self.recordOwner = recordOwner; self.convID = convID; self.title = title
        self.canAdd = canAdd; self.loose = loose
        _docs = Query(filter: #Predicate<DocItem> { $0.recordID == recordID && !$0.deleted }, sort: \DocItem.createdAt)
    }

    /// Serial numbers follow document date, oldest first — like a court index (D-1, D-2 …).
    private var numbered: [(Int, DocItem)] {
        docs.sorted { ($0.sortDate, $0.createdAt) < ($1.sortDate, $1.createdAt) }.enumerated().map { ($0.offset + 1, $0.element) }
    }

    private var shown: [(Int, DocItem)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = numbered.filter { item in
            let d = item.1
            return (folder == nil || d.folder == folder) &&
            (q.isEmpty || d.title.lowercased().contains(q) || d.notes.lowercased().contains(q) || d.folder.lowercased().contains(q) || (d.ref?.name.lowercased().contains(q) ?? false))
        }
        return newestFirst ? list.reversed() : list
    }

    private var folders: [String] {
        let used = Set(docs.map(\.folder))
        return DocFolders.defaults(module).filter { used.contains($0) } + used.subtracting(DocFolders.defaults(module)).sorted()
    }

    var body: some View {
        List {
            if !folders.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            chip("All · \(docs.count)", folder == nil) { folder = nil }
                            ForEach(folders, id: \.self) { f in chip("\(f) · \(docs.filter { $0.folder == f }.count)", folder == f) { folder = f } }
                        }
                    }
                }.listRowBackground(Color.clear)
            }
            if !loose.isEmpty && canAdd {
                Section("Not in a folder yet") {
                    ForEach(loose) { r in Button { filing = r } label: { Label("File “\(r.name)”", systemImage: "tray.and.arrow.down") } }
                }.lookRows()
            }
            if docs.isEmpty {
                ContentUnavailableView("No documents yet", systemImage: "folder",
                                       description: Text("Add each paper once — with a title, its date and a folder — and find it in seconds, even in court."))
            }
            let groups = Dictionary(grouping: shown, by: { $0.1.folder })
            ForEach(groups.keys.sorted(by: { order($0) < order($1) }), id: \.self) { f in
                Section {
                    ForEach(groups[f] ?? [], id: \.1.id) { item in row(item.0, item.1) }
                } header: { Label(f, systemImage: DocFolders.icon(f)) }
                .lookRows()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .lookScreen()
        .searchable(text: $search, prompt: "Search title, notes, folder")
        .navigationTitle(module == "legal" ? "Case file" : "Documents")
        .toolbar {
            if canAdd { ToolbarItem(placement: .primaryAction) { Button("Add", systemImage: "plus") { adding = true } } }
            ToolbarItem(placement: .secondaryAction) {
                Button(newestFirst ? "Oldest first" : "Newest first", systemImage: "arrow.up.arrow.down") { newestFirst.toggle() }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Index of documents (PDF)", systemImage: "list.number") {
                    if let u = PDFMaker.make(title: "Index of documents — \(title)", bodyHTML: indexHTML(), fileName: "Index - \(title)",
                                             module: moduleName, icon: "folder") { share = ShareItems(items: [u]) }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Share whole folder…", systemImage: "square.and.arrow.up.on.square") { Task { await shareAll() } }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { DocumentEditor(module: module, recordID: recordID, recordOwner: recordOwner, convID: convID, existing: nil, preset: nil, folder: folder) }
        }
        .sheet(item: $editing) { d in
            NavigationStack { DocumentEditor(module: module, recordID: recordID, recordOwner: recordOwner, convID: convID, existing: d, preset: nil) }
        }
        .sheet(item: $filing) { r in
            NavigationStack { DocumentEditor(module: module, recordID: recordID, recordOwner: recordOwner, convID: convID, existing: nil, preset: r) }
        }
        .shareSheet($share)
        .refreshable { await engine.sync() }
    }

    private var moduleName: String { ModuleRegistry.all.first { $0.id == module }?.title ?? (module == "legal" ? "Legal" : "iTeam") }
    private func order(_ f: String) -> Int { DocFolders.defaults(module).firstIndex(of: f) ?? 99 }

    private func chip(_ t: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(t, action: tap).buttonStyle(.bordered).tint(on ? .accentColor : .secondary).controlSize(.small)
    }

    private func row(_ n: Int, _ d: DocItem) -> some View {
        let mine = d.by == engine.me || d.recordOwner == engine.me
        return Button {
            Task { @MainActor in
                guard let r = d.ref else { return }
                do { Presenter.preview(try await DocStore.open(r)) } catch { self.error = "Couldn't open “\(d.title)” — ask \(engine.name(of: d.by)) to file it again (iCloud keeps files 45 days)." }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("D-\(n)").font(.caption.monospacedDigit().bold()).frame(width: 40, alignment: .leading).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text([d.docDate.map { $0.formatted(date: .abbreviated, time: .omitted) }, d.ref.map { ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) },
                          d.by == engine.me ? nil : engine.name(of: d.by)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if !d.notes.isEmpty { Text(d.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                if let r = d.ref, !DocStore.isKept(r) { Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .swipeActions {
            if mine { Button("Delete", role: .destructive) { engine.docDelete(d) } }
            if mine { Button("Edit") { editing = d }.tint(.blue) }
            Button("Share") { Task { if let u = try? await DocStore.shareURL(d) { share = ShareItems(items: [u]) } } }.tint(.green)
        }
        .contextMenu {
            Button("Open", systemImage: "eye") { Task { if let r = d.ref, let u = try? await DocStore.open(r) { Presenter.preview(u) } } }
            Button("Share", systemImage: "square.and.arrow.up") { Task { if let u = try? await DocStore.shareURL(d) { share = ShareItems(items: [u]) } } }
            if mine { Button("Edit / move folder", systemImage: "folder") { editing = d } }
            if mine { Button("Delete", systemImage: "trash", role: .destructive) { engine.docDelete(d) } }
        }
    }

    private func indexHTML() -> String {
        var h = "<p class=\"muted\">\(docs.count) documents · folders: \(folders.map(PDFMaker.esc).joined(separator: ", "))</p>"
        for f in folders {
            h += "<h2>\(PDFMaker.esc(f))</h2><table><tr><th>No.</th><th>Particulars</th><th>Date</th><th>File</th></tr>"
            for item in numbered where item.1.folder == f {
                let n = item.0, d = item.1
                h += "<tr><td>D-\(n)</td><td>\(PDFMaker.esc(d.title))\(d.notes.isEmpty ? "" : "<br><span class=\"muted\">\(PDFMaker.esc(d.notes))</span>")</td>"
                h += "<td>\(d.docDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")</td><td class=\"muted\">\(PDFMaker.esc(d.ref?.name ?? ""))</td></tr>"
            }
            h += "</table>"
        }
        return h
    }

    private func shareAll() async {
        var urls: [URL] = []
        for item in shown { let d = item.1; if let u = try? await DocStore.shareURL(d) { urls.append(u) } }
        if urls.isEmpty { error = "Nothing to share yet." } else { share = ShareItems(items: urls) }
    }
}

// MARK: - Add / edit one document

struct DocumentEditor: View {
    let module: String
    let recordID: String
    let recordOwner: String
    let convID: String
    let existing: DocItem?
    /// An attachment already on the record, filed without uploading it again.
    let preset: AttachmentRef?
    var folder: String? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var chosenFolder = ""
    @State private var newFolder = ""
    @State private var hasDate = true
    @State private var date = Date.now
    @State private var notes = ""
    @State private var files: [AttachmentRef] = []
    @State private var uploads: [String: String] = [:]
    @State private var picks: [PhotosPickerItem] = []
    @State private var busy = false

    private var scanSpec: ScanSpec {
        ScanSpec(title: "Read the paper to fill title, folder & date", what: module == "legal" ? "an Indian court or legal document" : "a document for the \(module) records",
                 fields: [.text("title", "Short title with the document type and date (e.g. 'Bail order dt. 12.03.2026')"),
                          .choice("folder", "Folder", DocFolders.defaults(module)), .date("date", "Date of the document"),
                          .long("notes", "One-line summary, plus exhibit / page numbers if printed")])
    }

    var body: some View {
        Form {
            AIScanSection(spec: scanSpec) { o in
                if let v = o.str("title") { title = v }
                if let v = o.str("folder"), DocFolders.defaults(module).contains(v) { chosenFolder = v }
                if let v = o.date("date") { hasDate = true; date = v }
                if let v = o.str("notes") { notes = notes.isEmpty ? v : notes + "\n" + v }
                if existing == nil && preset == nil { for p in o.files { files.append(p.ref); uploads[p.upload.0] = p.upload.1 } }
            }
            Section("Document") {
                TextField(module == "legal" ? "Title (e.g. Bail order dt. 12.03.2026)" : "Title", text: $title)
                Picker("Folder", selection: $chosenFolder) {
                    ForEach(DocFolders.defaults(module), id: \.self) { Text($0).tag($0) }
                    if !DocFolders.defaults(module).contains(chosenFolder) && !chosenFolder.isEmpty { Text(chosenFolder).tag(chosenFolder) }
                    Text("New folder…").tag("+")
                }
                if chosenFolder == "+" { TextField("Folder name", text: $newFolder) }
                Toggle("Document date", isOn: $hasDate)
                if hasDate { DatePicker("Dated", selection: $date, displayedComponents: .date) }
                TextField("Notes (page nos., exhibit no., remarks)", text: $notes, axis: .vertical).lineLimit(1...4)
            }
            Section {
                ForEach(files) { f in Label(f.name, systemImage: f.kind == "image" ? "photo" : f.kind == "video" ? "video" : "doc") }
                    .onDelete { if existing == nil && preset == nil { files.remove(atOffsets: $0) } }
                if existing == nil && preset == nil {
                    if Presenter.canScan {
                        Button("Scan paper (multi-page → one PDF)", systemImage: "doc.viewfinder") {
                            Presenter.scan { pages in
                                guard !pages.isEmpty, let p = try? Attachments.prepare(DocStore.pdf(from: pages), name: (title.isEmpty ? "Scan" : PDFMaker.safe(title)) + ".pdf",
                                                                                      mime: "application/pdf", kind: "file") else { return }
                                files.append(p.ref); uploads[p.upload.0] = p.upload.1
                            }
                        }
                    }
                    Button("Choose a file (PDF, Word…)", systemImage: "doc.badge.plus") {
                        Presenter.file(types: [.pdf, .image, .data, .content]) { url in
                            if let p = try? Attachments.prepareFile(url) {
                                files.append(p.ref); uploads[p.upload.0] = p.upload.1
                                if title.isEmpty { title = (url.lastPathComponent as NSString).deletingPathExtension }
                            }
                        }
                    }
                    PhotosPicker(selection: $picks, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) { Label("Photos or videos", systemImage: "photo.on.rectangle") }
                    if Presenter.hasCamera {
                        Button("Take a photo", systemImage: "camera") {
                            Presenter.camera { img in
                                if let d = img.jpegData(compressionQuality: 0.85), let p = try? Attachments.prepareImage(d) { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                            }
                        }
                    }
                }
            } header: { Text("File") } footer: {
                Text(files.count > 1 ? "Each file is filed as its own document in this folder, numbered by date." :
                        "Scan several pages of one paper into a single PDF. Files are end-to-end encrypted and a copy stays on every phone that receives them.")
            }
            if busy { ProgressView() }
        }
        .navigationTitle(existing == nil ? "File a document" : "Edit document")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(files.isEmpty || folderName.isEmpty || (title.trimmingCharacters(in: .whitespaces).isEmpty && files.count == 1)) }
        }
        .onChange(of: picks) { _, sel in
            guard !sel.isEmpty else { return }
            busy = true
            Task { @MainActor in
                for item in sel {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let m = try? await item.loadTransferable(type: MovieFile.self),
                       let p = try? await VideoPrep.prepare(m.url, maxSeconds: 180) { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                    else if let d = try? await item.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(d) { files.append(p.ref); uploads[p.upload.0] = p.upload.1 }
                }
                picks = []; busy = false
            }
        }
        .onAppear {
            if let d = existing {
                title = d.title; chosenFolder = d.folder; notes = d.notes
                hasDate = d.docDate != nil; date = d.docDate ?? .now
                if let r = d.ref { files = [r] }
            } else {
                chosenFolder = folder ?? DocFolders.defaults(module).first ?? "Documents"
                if let preset { files = [preset]; title = (preset.name as NSString).deletingPathExtension }
            }
        }
    }

    private var folderName: String { chosenFolder == "+" ? newFolder.trimmingCharacters(in: .whitespaces) : chosenFolder }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        for (i, f) in files.enumerated() {
            let name = files.count == 1 ? t : (t.isEmpty ? (f.name as NSString).deletingPathExtension : "\(t) (\(i + 1))")
            engine.docSave(i == 0 ? existing : nil, module: module, recordID: recordID, recordOwner: existing?.recordOwner ?? recordOwner, convID: existing?.convID ?? convID,
                           title: name, folder: folderName, date: hasDate ? date : nil, notes: notes, ref: f,
                           uploads: uploads.filter { $0.key == f.blob })
        }
        Haptics.success()
        dismiss()
    }
}
