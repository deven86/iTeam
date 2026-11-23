import SwiftUI
import Vision
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Scan & fill
//
// Point the camera at a paper, pick a photo or a PDF → the phone reads it on-device (Vision) →
// Apple Intelligence (or the user's own AI key) puts each value in the right box → the user checks
// every value and taps "Use these". Nothing is saved without that tap. Without AI the phone still
// reads the text and fills what it can by simple rules (dates, amounts, "Label: value" lines).

enum ScanType { case text, long, number, money, date, phone, email, choice }

struct ScanField: Identifiable, Hashable {
    let key: String
    let label: String
    var type: ScanType = .text
    var options: [String] = []
    var id: String { key }
}

struct ScanSpec {
    /// Shown on the button and the sheet ("Scan a court paper").
    let title: String
    /// What the paper usually is, for the AI ("an Indian court paper: petition, order, notice or vakalatnama").
    let what: String
    var fields: [ScanField] = []
    /// When set, the paper holds many rows (medicines, bank transactions, agenda points).
    var rows: [ScanField] = []
    var rowsLabel = "Items"
    var hint = ""
}

struct ScanOutput {
    var values: [String: String] = [:]
    var rows: [[String: String]] = []
    var text = ""
    /// The scanned pages, ready to attach (only when the user keeps "Attach the scanned pages" on).
    var files: [Attachments.Prepared] = []

    func str(_ k: String) -> String? {
        let v = (values[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    func number(_ k: String) -> Double? { str(k).flatMap(ScanFill.number) }
    func date(_ k: String) -> Date? { str(k).flatMap(ScanFill.date) }
    /// A number formatted for a text box ("1250" not "1250.0").
    func amountText(_ k: String) -> String? {
        number(k).map { $0.rounded() == $0 ? String(Int($0)) : String($0) }
    }
}

// MARK: - Reading the paper (on-device)

enum DocReader {
    /// Languages this phone can read in documents (shown so the user knows, e.g. whether Marathi works).
    static var languages: String {
        let names = RecognizeDocumentsRequest().supportedRecognitionLanguages.compactMap { l -> String? in
            guard let code = l.languageCode?.identifier else { return nil }
            return Locale.current.localizedString(forLanguageCode: code)
        }
        return Array(NSOrderedSet(array: names)).compactMap { $0 as? String }.joined(separator: ", ")
    }

    static func read(images: [UIImage]) async -> String {
        var pages: [String] = []
        for img in images.prefix(12) {
            guard let cg = upright(img).cgImage else { continue }
            pages.append(await read(cg))
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n--- next page ---\n\n")
    }

    static func read(pdf url: URL) async -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var pages: [String] = []
        for i in 0..<min(doc.pageCount, 12) {
            guard let page = doc.page(at: i) else { continue }
            let typed = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if typed.count > 40 { pages.append(typed); continue }
            // A scanned PDF: draw the page and read the picture.
            let img = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
            if let cg = img.cgImage { pages.append(await read(cg)) }
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n--- next page ---\n\n")
    }

    /// Text plus any tables ("a | b | c" rows), read with Vision's document reader; plain text reading as a fallback.
    static func read(_ cg: CGImage) async -> String {
        do {
            var req = RecognizeDocumentsRequest()
            req.textRecognitionOptions.automaticallyDetectLanguage = true
            req.textRecognitionOptions.useLanguageCorrection = true
            let obs = try await req.perform(on: cg)
            guard let doc = obs.first?.document else { return try await plain(cg) }
            var s = doc.text.transcript
            for t in doc.tables {
                let rows = t.rows.map { row in
                    row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ")
                }
                s += "\n\nTABLE:\n" + rows.joined(separator: "\n")
            }
            return s
        } catch {
            return (try? await plain(cg)) ?? ""
        }
    }

    private static func plain(_ cg: CGImage) async throws -> String {
        var req = RecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let obs = try await req.perform(on: cg)
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Camera photos carry a rotation flag; Vision wants the pixels the right way up (and not huge).
    static func upright(_ img: UIImage, maxSide: CGFloat = 2600) -> UIImage {
        let side = max(img.size.width, img.size.height)
        let scale = side > maxSide ? maxSide / side : 1
        if img.imageOrientation == .up && scale == 1 { return img }
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let f = UIGraphicsImageRendererFormat.default(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - Putting values into the boxes

@MainActor
enum ScanFill {
    static var aiReady: Bool { AISettings.shared.enabled && AISettings.shared.ready }

    static func fill(_ text: String, spec: ScanSpec) async -> (ScanOutput, usedAI: Bool, note: String?) {
        var out = ScanOutput(text: text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (out, false, "Couldn't read any text. Try a sharper, well-lit photo.") }
        if aiReady {
            do {
                let raw = try await AIService.complete(prompt(text, spec), instructions: rules)
                if let obj = json(raw) {
                    for f in spec.fields { out.values[f.key] = clean(obj[f.key], f) }
                    if !spec.rows.isEmpty, let list = obj["rows"] as? [[String: Any]] {
                        out.rows = list.map { r in Dictionary(uniqueKeysWithValues: spec.rows.map { ($0.key, clean(r[$0.key], $0)) }) }
                            .filter { r in r.values.contains { !$0.isEmpty } }
                    }
                    return (out, true, nil)
                }
            } catch {
                let basic = heuristics(text, spec)
                return (basic, false, "AI couldn't help this time (\(error.localizedDescription)). Filled what the phone could read.")
            }
        }
        return (heuristics(text, spec), false, aiReady ? "AI gave no usable answer. Filled what the phone could read." : nil)
    }

    private static let rules = """
    You turn the text of a scanned paper into form values. Reply with ONE JSON object and nothing else. \
    Copy values exactly as written on the paper; never guess or invent. Use "" when a value isn't on the paper.
    """

    private static func prompt(_ text: String, _ spec: ScanSpec) -> String {
        func describe(_ f: ScanField) -> String {
            var t: String
            switch f.type {
            case .date: t = "date as YYYY-MM-DD (add HH:mm if a time is written)"
            case .number, .money: t = "number, digits only, no commas or currency"
            case .phone: t = "phone number"
            case .email: t = "email"
            case .long: t = "text, may be several lines"
            case .choice: t = "one of: " + f.options.joined(separator: " / ")
            case .text: t = "short text"
            }
            return "\"\(f.key)\": \(f.label) — \(t)"
        }
        var p = "The paper is \(spec.what).\n"
        if !spec.hint.isEmpty { p += spec.hint + "\n" }
        p += "JSON keys:\n" + spec.fields.map(describe).joined(separator: "\n")
        if !spec.rows.isEmpty {
            p += "\n\"rows\": a list of \(spec.rowsLabel.lowercased()), each an object with keys:\n" + spec.rows.map { "  " + describe($0) }.joined(separator: "\n")
        }
        // The on-device model has a small window: the start of a paper matters most.
        let body = text.count > 6500 ? String(text.prefix(6500)) : text
        return p + "\n\nTEXT OF THE PAPER:\n\"\"\"\n\(body)\n\"\"\""
    }

    static func json(_ raw: String) -> [String: Any]? {
        guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"), a < b,
              let d = String(raw[a...b]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func clean(_ v: Any?, _ f: ScanField) -> String {
        var s: String
        switch v {
        case let x as String: s = x
        case let x as NSNumber: s = x.stringValue
        case let x as [Any]: s = x.map { "\($0)" }.joined(separator: ", ")
        default: s = ""
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["null", "n/a", "na", "none", "-"].contains(s.lowercased()) { s = "" }
        switch f.type {
        case .number, .money: return number(s).map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? ""
        case .choice:
            if let m = f.options.first(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return m }
            return f.options.first(where: { !s.isEmpty && ($0.lowercased().contains(s.lowercased()) || s.lowercased().contains($0.lowercased())) }) ?? ""
        default: return s
        }
    }

    // MARK: Without AI

    static func heuristics(_ text: String, _ spec: ScanSpec) -> ScanOutput {
        var out = ScanOutput(text: text)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let dates = detect(text, .date).compactMap(\.date)
        let phones = detect(text, .phoneNumber).compactMap(\.phoneNumber)
        var usedDate = 0
        for f in spec.fields {
            var v = labelled(f.label, in: lines) ?? ""
            switch f.type {
            case .date:
                if let d = date(v) { v = iso(d) }
                else if usedDate < dates.count { v = iso(dates[usedDate]); usedDate += 1 } else { v = "" }
            case .money, .number:
                v = number(v).map { String($0) } ?? (f.type == .money ? bestAmount(lines).map { String($0) } ?? "" : "")
                if let n = number(v) { v = n.rounded() == n ? String(Int(n)) : String(n) }
            case .phone: if v.isEmpty { v = phones.first ?? "" }
            case .email:
                if v.isEmpty, let r = text.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]) { v = String(text[r]) }
            case .choice:
                v = f.options.first { o in text.lowercased().contains(o.lowercased()) } ?? ""
            case .long:
                if v.isEmpty && f.key == spec.fields.last(where: { $0.type == .long })?.key { v = String(text.prefix(1500)) }
            case .text:
                if v.isEmpty && f.key == spec.fields.first?.key { v = lines.first ?? "" }
            }
            out.values[f.key] = v
        }
        if !spec.rows.isEmpty { out.rows = rowsByRules(lines, spec.rows) }
        return out
    }

    /// "Label: value" or "Label - value" on the same line.
    private static func labelled(_ label: String, in lines: [String]) -> String? {
        let words = label.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        guard let key = words.first else { return nil }
        for l in lines {
            let low = l.lowercased()
            guard low.contains(key), let sep = l.firstIndex(where: { $0 == ":" || $0 == "-" || $0 == "–" }) else { continue }
            let v = l[l.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
    }

    private static func bestAmount(_ lines: [String]) -> Double? {
        let keyed = lines.filter { l in ["total", "amount", "grand", "net", "₹", "rs", "inr", "payable"].contains { l.lowercased().contains($0) } }
        let nums = (keyed.isEmpty ? lines : keyed).flatMap(numbers)
        return nums.max()
    }

    private static func numbers(_ l: String) -> [Double] {
        let re = try? NSRegularExpression(pattern: #"\d[\d,]*(\.\d{1,2})?"#)
        let ns = l as NSString
        return (re?.matches(in: l, range: NSRange(location: 0, length: ns.length)) ?? []).compactMap { number(ns.substring(with: $0.range)) }
    }

    /// Bank statements and lists: each line with a date and an amount becomes a row.
    private static func rowsByRules(_ lines: [String], _ fields: [ScanField]) -> [[String: String]] {
        guard let dateKey = fields.first(where: { $0.type == .date })?.key,
              let amtKey = fields.first(where: { $0.type == .money || $0.type == .number })?.key else {
            // A plain list (agenda, medicines): one row per line.
            guard let k = fields.first?.key else { return [] }
            return lines.prefix(30).map { [k: $0] }
        }
        let textKey = fields.first(where: { $0.type == .text || $0.type == .long })?.key
        var out: [[String: String]] = []
        for l in lines {
            guard let d = detect(l, .date).first?.date, let a = numbers(l).last, a > 0 else { continue }
            var r = [dateKey: iso(d), amtKey: a.rounded() == a ? String(Int(a)) : String(a)]
            if let textKey { r[textKey] = l }
            if let dir = fields.first(where: { $0.key == "dir" }) {
                let low = l.lowercased()
                r[dir.key] = low.contains("cr") && !low.contains("dr") ? (dir.options.first ?? "in") : (dir.options.last ?? "out")
            }
            out.append(r)
        }
        return out
    }

    private static func detect(_ s: String, _ t: NSTextCheckingResult.CheckingType) -> [NSTextCheckingResult] {
        guard let d = try? NSDataDetector(types: t.rawValue) else { return [] }
        return d.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    // MARK: Parsing helpers

    nonisolated static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: "Rs.", with: "").replacingOccurrences(of: "Rs", with: "").replacingOccurrences(of: "INR", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let d = Double(t) { return d }
        // "1250.00 Dr" or "kg 72.4" → first number in the string.
        if let r = t.range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression) { return Double(t[r]) }
        return nil
    }

    nonisolated static func date(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for f in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "dd/MM/yyyy", "dd-MM-yyyy", "dd.MM.yyyy", "dd/MM/yy", "dd-MMM-yyyy", "dd MMM yyyy", "d MMMM yyyy", "MMMM d, yyyy"] {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_IN"); df.dateFormat = f
            if let d = df.date(from: t) { return d }
        }
        if let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
            .firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length))?.date { return d }
        return nil
    }

    nonisolated static func iso(_ d: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        df.dateFormat = (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return df.string(from: d)
    }
}

// MARK: - The ✨ button and sheet

/// The separate AI button: hidden unless AI is on and "Scan & fill" is allowed in Settings → AI.
struct AIScanButton: View {
    let spec: ScanSpec
    var onApply: (ScanOutput) -> Void
    @ObservedObject private var ai = AISettings.shared
    @State private var show = false

    static var visible: Bool { AISettings.shared.enabled && AISettings.shared.features.contains(AIFeature.scan.rawValue) }

    var body: some View {
        if ai.enabled && ai.features.contains(AIFeature.scan.rawValue) {
            Button { show = true } label: {
                Label { VStack(alignment: .leading, spacing: 1) {
                    Text("✨ " + spec.title)
                    Text("Camera, photo or PDF — you check before saving").font(.caption2).foregroundStyle(.secondary)
                } } icon: { Image(systemName: "doc.viewfinder") }
            }
            .sheet(isPresented: $show) {
                NavigationStack { AIScanSheet(spec: spec, onApply: onApply) }
            }
        }
    }
}

/// A form section holding just the scan button (so editors stay tidy).
struct AIScanSection: View {
    let spec: ScanSpec
    var onApply: (ScanOutput) -> Void
    var body: some View {
        if AIScanButton.visible {
            Section { AIScanButton(spec: spec, onApply: onApply) }
        }
    }
}

struct AIScanSheet: View {
    let spec: ScanSpec
    var onApply: (ScanOutput) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var stage = 0          // 0 pick · 1 working · 2 review
    @State private var status = ""
    @State private var out = ScanOutput()
    @State private var include: [Bool] = []
    @State private var attach = true
    @State private var images: [UIImage] = []
    @State private var pdf: URL?
    @State private var usedAI = false
    @State private var note: String?
    @State private var pick: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false

    var body: some View {
        Form {
            switch stage {
            case 0: picker
            case 1: Section { HStack { ProgressView(); Text(status).foregroundStyle(look.textSecondary) } }
            default: review
            }
        }
        .navigationTitle(spec.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if stage == 2 { ToolbarItem(placement: .confirmationAction) { Button("Use these") { apply() }.bold() } }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pick, maxSelectionCount: 8, matching: .images)
        .onChange(of: pick) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in
                var imgs: [UIImage] = []
                for i in items { if let d = try? await i.loadTransferable(type: Data.self), let u = UIImage(data: d) { imgs.append(u) } }
                pick = []
                if !imgs.isEmpty { await run(images: imgs) }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image]) { r in
            guard case .success(let url) = r else { return }
            Task { @MainActor in await run(file: url) }
        }
    }

    private var picker: some View {
        Group {
            Section {
                if Presenter.canScan {
                    Button("Scan with camera", systemImage: "doc.viewfinder") {
                        Presenter.scan { imgs in Task { @MainActor in await run(images: imgs) } }
                    }
                } else if Presenter.hasCamera {
                    Button("Take a photo", systemImage: "camera") {
                        Presenter.camera { img in Task { @MainActor in await run(images: [img]) } }
                    }
                }
                Button("Choose photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                Button("Choose a PDF or image file", systemImage: "doc") { showFiles = true }
            } header: { Text(spec.what.prefix(1).uppercased() + spec.what.dropFirst()) } footer: {
                Text(ScanFill.aiReady
                     ? "Read on this phone, then \(AISettings.shared.provider == .apple ? "Apple Intelligence (on-device)" : AISettings.shared.provider.short) fills the boxes. You check every value before it's used."
                     : "Read on this phone. Without Apple Intelligence (Settings → AI), only simple values — dates, amounts, phone numbers, “Label: value” lines — are filled.")
            }
            let langs = DocReader.languages
            if !langs.isEmpty {
                Section { Text(langs).font(.caption) } header: { Text("Languages this phone can read") }
            }
        }
    }

    @ViewBuilder
    private var review: some View {
        Section {
            Label(usedAI ? "Filled by \(AISettings.shared.provider == .apple ? "Apple Intelligence" : AISettings.shared.provider.short) — check each value"
                         : "Filled by the phone's text reader — check each value",
                  systemImage: "checkmark.shield")
                .font(.footnote).foregroundStyle(look.textSecondary)
            if let note { Text(note).font(.caption).foregroundStyle(look.warning) }
        }
        if !spec.fields.isEmpty {
            Section("Values") {
                ForEach(spec.fields) { f in fieldRow(f, binding: Binding(get: { out.values[f.key] ?? "" }, set: { out.values[f.key] = $0 })) }
            }
        }
        if !spec.rows.isEmpty {
            Section {
                if out.rows.isEmpty { Text("No \(spec.rowsLabel.lowercased()) found.").foregroundStyle(look.textSecondary) }
                ForEach(out.rows.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Keep", isOn: Binding(get: { i < include.count ? include[i] : true }, set: { if i < include.count { include[i] = $0 } }))
                            .font(.caption.bold())
                        ForEach(spec.rows) { f in
                            fieldRow(f, binding: Binding(get: { out.rows[i][f.key] ?? "" }, set: { out.rows[i][f.key] = $0 }))
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Add a row", systemImage: "plus") { out.rows.append([:]); include.append(true) }
            } header: { Text("\(spec.rowsLabel) (\(out.rows.count))") }
        }
        if !images.isEmpty || pdf != nil {
            Section { Toggle("Attach the scanned pages", isOn: $attach) }
        }
        Section {
            DisclosureGroup("Text the phone read") { Text(out.text).font(.caption).textSelection(.enabled) }
            Button("Scan again", systemImage: "arrow.counterclockwise") { stage = 0 }
        }
    }

    @ViewBuilder
    private func fieldRow(_ f: ScanField, binding: Binding<String>) -> some View {
        switch f.type {
        case .long: VStack(alignment: .leading) { Text(f.label).font(.caption).foregroundStyle(.secondary); TextField(f.label, text: binding, axis: .vertical).lineLimit(2...8) }
        case .choice:
            Picker(f.label, selection: binding) { Text("—").tag(""); ForEach(f.options, id: \.self) { Text($0).tag($0) } }
        case .date:
            LabeledContent(f.label) {
                TextField("YYYY-MM-DD", text: binding).multilineTextAlignment(.trailing)
                    .foregroundStyle(binding.wrappedValue.isEmpty || ScanFill.date(binding.wrappedValue) != nil ? Color.primary : Color.red)
            }
        default:
            LabeledContent(f.label) {
                TextField(f.label, text: binding).multilineTextAlignment(.trailing)
                    .keyboardType(f.type == .money || f.type == .number ? .decimalPad : f.type == .phone ? .phonePad : f.type == .email ? .emailAddress : .default)
            }
        }
    }

    private func run(images imgs: [UIImage]) async {
        images = imgs; pdf = nil
        stage = 1; status = "Reading \(imgs.count) page\(imgs.count == 1 ? "" : "s")…"
        let text = await DocReader.read(images: imgs)
        await finish(text)
    }

    private func run(file url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        // Keep our own copy (the picked file can vanish).
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        try? FileManager.default.copyItem(at: url, to: copy)
        stage = 1; status = "Reading the file…"
        if url.pathExtension.lowercased() == "pdf" {
            pdf = copy; images = []
            await finish(await DocReader.read(pdf: copy))
        } else if let d = try? Data(contentsOf: copy), let img = UIImage(data: d) {
            await run(images: [img])
        } else {
            stage = 0
        }
    }

    private func finish(_ text: String) async {
        status = ScanFill.aiReady ? "Filling the boxes with AI…" : "Filling the boxes…"
        let r = await ScanFill.fill(text, spec: spec)
        out = r.0; usedAI = r.usedAI; note = r.note
        include = Array(repeating: true, count: out.rows.count)
        stage = 2
        Haptics.success()
    }

    private func apply() {
        var o = out
        o.rows = o.rows.enumerated().filter { $0.offset < include.count ? include[$0.offset] : true }.map { $0.element }
        if attach {
            for img in images {
                if let d = DocReader.upright(img, maxSide: 2200).jpegData(compressionQuality: 0.8), let p = try? Attachments.prepareImage(d) { o.files.append(p) }
            }
            if let pdf, let p = try? Attachments.prepareFile(pdf) { o.files.append(p) }
        }
        onApply(o)
        dismiss()
    }
}

// MARK: - Small helpers used by modules

extension ScanField {
    static func text(_ k: String, _ l: String) -> ScanField { .init(key: k, label: l) }
    static func long(_ k: String, _ l: String) -> ScanField { .init(key: k, label: l, type: .long) }
    static func money(_ k: String, _ l: String) -> ScanField { .init(key: k, label: l, type: .money) }
    static func number(_ k: String, _ l: String) -> ScanField { .init(key: k, label: l, type: .number) }
    static func date(_ k: String, _ l: String) -> ScanField { .init(key: k, label: l, type: .date) }
    static func phone(_ k: String, _ l: String) -> ScanField { .init(key: k, label: l, type: .phone) }
    static func choice(_ k: String, _ l: String, _ o: [String]) -> ScanField { .init(key: k, label: l, type: .choice, options: o) }
}
