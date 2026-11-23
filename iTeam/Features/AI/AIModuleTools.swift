import SwiftUI
import EventKit
import Vision
import PhotosUI

// MARK: - ✨ Suggestions button (the separate AI button for tips, plans and next steps)

/// AI advice inside a module. Hidden unless AI is on and "Suggestions & tips" is allowed. Always labelled as advice.
struct AISuggest: View {
    let title: String
    let instructions: String
    let context: () -> String
    var postTo: Conversation? = nil

    var body: some View {
        AIButton(title: title, feature: .advisor,
                 instructions: instructions + "\nThis is advice only: say what to check, never present guesses as facts. If the data is thin, say what's missing.",
                 context: context, postTo: postTo)
    }
}

// MARK: - Holidays (hearings, meetings, events)

@MainActor
enum HolidayCheck {
    private static let store = EKEventStore()
    private static let key = "holidays.mine"

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func ask() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }

    /// My own holiday list (e.g. court vacations from the High Court calendar): "yyyy-MM-dd" → name.
    static var mine: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func dayKey(_ d: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: d)
    }

    /// Public holidays from the phone's holiday calendar (Calendar app → Holidays), my own list, and Sundays.
    static func reasons(on day: Date) -> [String] {
        var out: [String] = []
        if let m = mine[dayKey(day)] { out.append(m) }
        if authorized {
            let cal = Calendar.current
            let start = cal.startOfDay(for: day), end = start.addingTimeInterval(86400)
            let hol = store.calendars(for: .event).filter { $0.type == .subscription || $0.title.lowercased().contains("holiday") }
            if !hol.isEmpty {
                let evs = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: hol))
                out += evs.filter(\.isAllDay).map(\.title)
            }
        }
        let wd = Calendar.current.component(.weekday, from: day)
        if wd == 1 { out.append("Sunday") }
        if wd == 7 { out.append("Saturday") }
        return Array(NSOrderedSet(array: out)).compactMap { $0 as? String }
    }
}

/// An orange line under a date picker when the day is a holiday or weekend.
struct HolidayWarning: View {
    let date: Date
    @State private var asked = HolidayCheck.authorized
    @State private var refresh = 0

    var body: some View {
        let r = HolidayCheck.reasons(on: date)
        VStack(alignment: .leading, spacing: 4) {
            if !r.isEmpty {
                Label("Holiday / weekend: " + r.joined(separator: ", "), systemImage: "calendar.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !asked {
                Button("Check public holidays from my calendar", systemImage: "calendar") {
                    Task { asked = await HolidayCheck.ask(); refresh += 1 }
                }
                .font(.caption)
            }
        }
        .id(refresh)
    }
}

/// My own holiday list (court vacations, office holidays), typed in or scanned from the printed holiday list.
struct MyHolidaysView: View {
    @State private var list: [(String, String)] = []
    @State private var date = Date.now
    @State private var name = ""

    private var scanSpec: ScanSpec {
        ScanSpec(title: "Scan a holiday list", what: "a printed holiday or vacation list (court, office or school)",
                 rows: [.date("date", "Date"), .text("name", "Holiday")], rowsLabel: "Holidays",
                 hint: "For a vacation spanning several days, give one row per day.")
    }

    var body: some View {
        Form {
            AIScanSection(spec: scanSpec) { out in
                var m = HolidayCheck.mine
                for r in out.rows { if let d = r["date"].flatMap(ScanFill.date) { m[HolidayCheck.dayKey(d)] = r["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Holiday" } }
                HolidayCheck.mine = m; load()
            }
            Section {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Name (e.g. Diwali vacation)", text: $name)
                Button("Add", systemImage: "plus") {
                    var m = HolidayCheck.mine; m[HolidayCheck.dayKey(date)] = name.isEmpty ? "Holiday" : name
                    HolidayCheck.mine = m; name = ""; load()
                }
            } footer: { Text("Used to warn you when a hearing, meeting or event falls on a holiday. Public holidays also come from the Holidays calendar in your iPhone's Calendar app. Stays on this phone.") }
            Section("My holidays (\(list.count))") {
                ForEach(list, id: \.0) { item in LabeledContent(item.1, value: item.0) }
                    .onDelete { idx in
                        var m = HolidayCheck.mine
                        for i in idx { m.removeValue(forKey: list[i].0) }
                        HolidayCheck.mine = m; load()
                    }
            }
        }
        .navigationTitle("Holidays")
        .onAppear(perform: load)
    }

    private func load() { list = HolidayCheck.mine.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
}

// MARK: - Property: commission calculator

struct CommissionCalculatorView: View {
    @State private var deal = ""
    @State private var rate = "2"
    @State private var share = "100"
    @State private var gst = true
    @State private var tds = false

    private var value: Double { ScanFill.number(deal) ?? 0 }
    private var gross: Double { value * (Double(rate) ?? 0) / 100 }
    private var mine: Double { gross * (Double(share) ?? 100) / 100 }
    private var gstAmt: Double { gst ? mine * 0.18 : 0 }
    private var tdsAmt: Double { tds ? mine * 0.05 : 0 }

    var body: some View {
        Form {
            Section("Deal") {
                TextField("Deal value / rent (₹)", text: $deal).keyboardType(.decimalPad)
                TextField("Commission %", text: $rate).keyboardType(.decimalPad)
                TextField("My share of commission % (co-broker split)", text: $share).keyboardType(.decimalPad)
                Toggle("Add GST 18%", isOn: $gst)
                Toggle("TDS deducted 5% (sec. 194H)", isOn: $tds)
            }
            Section("Result") {
                LabeledContent("Total commission", value: BizSpecs.money(gross))
                LabeledContent("My commission", value: BizSpecs.money(mine))
                if gst { LabeledContent("GST to collect", value: BizSpecs.money(gstAmt)) }
                if tds { LabeledContent("TDS (claim in ITR)", value: "− " + BizSpecs.money(tdsAmt)) }
                LabeledContent("Bill to client", value: BizSpecs.money(mine + gstAmt)).bold()
                LabeledContent("Cash I receive", value: BizSpecs.money(mine + gstAmt - tdsAmt)).bold()
            }
            Section {
                ShareMenu(title: "Commission", text: { summary }, module: "Property & Rent", icon: "house.and.flag.fill")
            } footer: { Text("Rates are what you enter. Check GST and TDS rules with your CA.") }
        }
        .navigationTitle("Commission")
    }

    private var summary: String {
        "Deal value: \(BizSpecs.money(value))\nCommission \(rate)%: \(BizSpecs.money(gross))\nMy share (\(share)%): \(BizSpecs.money(mine))"
        + (gst ? "\nGST 18%: \(BizSpecs.money(gstAmt))" : "") + "\nBill: \(BizSpecs.money(mine + gstAmt))"
    }
}

// MARK: - Property: photo quality (on-device)

struct PhotoQualityView: View {
    @State private var pick: [PhotosPickerItem] = []
    @State private var results: [(UIImage, Float, Bool)] = []
    @State private var busy = false

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $pick, maxSelectionCount: 12, matching: .images) { Label("Choose listing photos", systemImage: "photo.on.rectangle") }
            } footer: { Text("The phone scores each photo (−1 poor … +1 excellent) on-device for sharpness, light and framing. Use the best 6–8 for the listing; reshoot anything below 0.") }
            if busy { ProgressView() }
            ForEach(results.indices, id: \.self) { i in
                let r = results[i]
                HStack(spacing: 12) {
                    Image(uiImage: r.0).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "Score %.2f", r.1)).font(.headline).foregroundStyle(r.1 >= 0.3 ? .green : r.1 >= 0 ? .orange : .red)
                        Text(advice(r.1, r.2)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Photo quality")
        .onChange(of: pick) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in
                busy = true; results = []
                for it in items {
                    guard let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d),
                          let cg = DocReader.upright(img, maxSide: 1600).cgImage else { continue }
                    if let o = try? await CalculateImageAestheticsScoresRequest().perform(on: cg) { results.append((img, o.overallScore, o.isUtility)) }
                }
                results.sort { $0.1 > $1.1 }
                busy = false; pick = []
            }
        }
    }

    private func advice(_ s: Float, _ utility: Bool) -> String {
        if utility { return "Looks like a document or screenshot — fine for papers, not as a listing photo." }
        if s >= 0.5 { return "Excellent — use as the cover photo." }
        if s >= 0.2 { return "Good — keep it." }
        if s >= 0 { return "Average — try more light, hold level, shoot from a corner." }
        return "Poor — reshoot in daylight, lights on, wide angle, no blur."
    }
}

// MARK: - Links & Maps (no AI: live info comes from official sites)

struct HelpfulLinks: View {
    let title: String
    let links: [(String, String, String)]   // label, icon, URL
    var footer = ""
    var body: some View {
        Section {
            ForEach(links, id: \.0) { l in
                if let u = URL(string: l.2) { Link(destination: u) { Label(l.0, systemImage: l.1) } }
            }
        } header: { Text(title) } footer: { if !footer.isEmpty { Text(footer) } }
    }
}

enum MapsSearch {
    /// Opens Apple Maps searching near the user ("veterinary clinic", "vaccination centre").
    static func url(_ q: String) -> String { "maps://?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q) }
}

// MARK: - Attendance photo check (on-device)

enum PhotoCheck {
    /// How many faces Vision sees in a selfie (0 = no face, >1 = someone else in frame).
    static func faces(_ img: UIImage) async -> Int {
        guard let cg = DocReader.upright(img, maxSide: 1200).cgImage else { return 0 }
        return (try? await DetectFaceRectanglesRequest().perform(on: cg).count) ?? 0
    }
}

// MARK: - Medicine timing words on Indian prescriptions → minutes after midnight

enum RxTiming {
    /// "1-0-1", "1-1-1", "BD", "TDS", "OD", "HS", "morning & night", "after breakfast" → [540, 1260] etc.
    static func minutes(_ s: String) -> [Int] {
        let low = s.lowercased()
        if let r = low.range(of: #"(\d)\s*[-–]\s*(\d)\s*[-–]\s*(\d)"#, options: .regularExpression) {
            let d = low[r].compactMap { $0.wholeNumberValue }
            if d.count == 3 {
                var out: [Int] = []
                if d[0] > 0 { out.append(540) }
                if d[1] > 0 { out.append(840) }
                if d[2] > 0 { out.append(1260) }
                if !out.isEmpty { return out }
            }
        }
        func has(_ w: [String]) -> Bool { w.contains { low.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil } }
        if has(["tds", "tid", "thrice", "three times", "tds."]) { return [540, 840, 1260] }
        if has(["qid", "four times"]) { return [480, 720, 1020, 1260] }
        if has(["bd", "bid", "twice", "two times"]) { return [540, 1260] }
        var out: [Int] = []
        if has(["morning", "breakfast", "am"]) { out.append(540) }
        if has(["afternoon", "lunch", "noon"]) { out.append(840) }
        if has(["evening"]) { out.append(1140) }
        if has(["night", "bedtime", "hs", "dinner", "pm"]) { out.append(1260) }
        if out.isEmpty && has(["od", "once", "daily"]) { out = [540] }
        return Array(Set(out)).sorted()
    }

    /// "for 5 days", "x 7 days", "1 week" → days.
    static func days(_ s: String) -> Int? {
        let low = s.lowercased()
        if let r = low.range(of: #"(\d+)\s*(days?|d\b)"#, options: .regularExpression), let n = Int(low[r].filter(\.isNumber)) { return n }
        if let r = low.range(of: #"(\d+)\s*weeks?"#, options: .regularExpression), let n = Int(low[r].filter(\.isNumber)) { return n * 7 }
        if let r = low.range(of: #"(\d+)\s*months?"#, options: .regularExpression), let n = Int(low[r].filter(\.isNumber)) { return n * 30 }
        return nil
    }

    static func date(_ minutes: Int) -> Date { Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(minutes) * 60) }
}
