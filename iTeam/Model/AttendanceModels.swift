import Foundation
import SwiftData
import CryptoKit

/// Attendance: one stored record type for everything (company, member, entry, leave, holiday,
/// change request). The indexed fields are columns; the rest is a Codable blob, so new fields
/// can be added to the structs below (as optionals) without a database migration.
@Model final class AttRecord {
    @Attribute(.unique) var id: String
    /// "company", "member", "entry", "leave", "holiday", "change"
    var kind: String = ""
    var companyID: String = ""
    var memberID: String = ""
    /// yyyy-MM-dd — the entry's day, the holiday's date, the leave's first day.
    var day: String = ""
    /// member: role · entry: status override · leave/holiday/change: pending/approved/rejected
    var status: String = ""
    var deleted: Bool = false
    var deletedBy: String = ""
    var by: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var data: Data = Data()

    init(id: String, kind: String) { self.id = id; self.kind = kind }

    private func load<T: Decodable>(_ t: T.Type) -> T? { try? JSONDecoder().decode(T.self, from: data) }
    private func store<T: Encodable>(_ v: T) { data = (try? JSONEncoder().encode(v)) ?? Data() }

    var company: AttCompanyData { get { load(AttCompanyData.self) ?? AttCompanyData() } set { store(newValue) } }
    var member: AttMemberData { get { load(AttMemberData.self) ?? AttMemberData() } set { store(newValue) } }
    var entry: AttEntryData { get { load(AttEntryData.self) ?? AttEntryData() } set { store(newValue) } }
    var leave: AttLeaveData { get { load(AttLeaveData.self) ?? AttLeaveData() } set { store(newValue) } }
    var holiday: AttHolidayData { get { load(AttHolidayData.self) ?? AttHolidayData() } set { store(newValue) } }
    var change: AttChangeData { get { load(AttChangeData.self) ?? AttChangeData() } set { store(newValue) } }
}

struct AttCompanyData: Codable, Equatable {
    var name = ""
    var ownerID = ""
    /// Group chat with the owner and admins, where all attendance travels.
    var adminConvID = ""
    var admins: [String] = []
    /// Minutes after midnight.
    var dutyStart = 570
    var dutyEnd = 1110
    var grace = 15
    /// Minutes after duty start after which a punch-in counts as half day.
    var halfDayAfter = 60
    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    var weeklyOff: [Int] = [1]
    /// Employees on iTeam punch on their own phones.
    var selfPunch = true
    var needPhoto = false
    var needGeo = false
    var needQR = false
    var kiosk = true
    var lat = 0.0
    var lon = 0.0
    var radius = 200.0
    /// Only on the owner's and admins' phones — never sent to employees.
    var qrSecret = ""
    var leaveTypes: [String] = ["Casual", "Sick", "Earned"]
    var currency: String? = nil

    var hasOffice: Bool { lat != 0 || lon != 0 }
    func isStaff(_ user: String) -> Bool { user == ownerID || admins.contains(user) }
}

struct AttField: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var label = ""
    var value = ""
}

struct AttMemberData: Codable, Equatable {
    /// "" for people who aren't on iTeam (marked by kiosk, owner or admin).
    var userID = ""
    var first = ""
    var last = ""
    var photo: Data? = nil
    var age: Int? = nil
    var sex = ""
    var department = ""
    var designation = ""
    var mobile = ""
    var email = ""
    var fields: [AttField] = []
    /// Own timings (minutes after midnight) — nil uses the company's.
    var dutyStart: Int? = nil
    var dutyEnd: Int? = nil
    /// SHA-256 of the kiosk PIN ("" = no PIN).
    var pinHash = ""
    /// iTeam users accept being added; nil = waiting.
    var accepted: Bool? = nil
    var active = true
    var joined: Date? = nil

    var name: String { [first, last].filter { !$0.isEmpty }.joined(separator: " ") }
    var isUser: Bool { !userID.isEmpty }
    var canPunch: Bool { active && (!isUser || accepted == true) }
    static func hashPIN(_ pin: String) -> String {
        pin.isEmpty ? "" : SHA256.hash(data: Data(("att.pin." + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct AttEntryData: Codable, Equatable {
    var inAt: Date? = nil
    var outAt: Date? = nil
    /// manual, photo, geo, qr, kiosk, edit
    var method = "manual"
    var lat: Double? = nil
    var lon: Double? = nil
    /// Metres from the office when punched (nil = no location).
    var distance: Double? = nil
    var photoIn: Data? = nil
    var photoOut: Data? = nil
    var qrIn = ""
    var qrOut = ""
    var note = ""
    /// Who punched (the person themselves, or the owner/admin/kiosk phone).
    var markedBy = ""
}

struct AttLeaveData: Codable, Equatable {
    var from = Date.now
    var to = Date.now
    var halfDay = false
    var type = "Casual"
    var paid = true
    var reason = ""
    var files: [AttachmentRef] = []
    var decidedBy = ""
    var note = ""

    var days: Double {
        if halfDay { return 0.5 }
        let cal = Calendar.current
        let n = (cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: to)).day ?? 0) + 1
        return Double(max(n, 1))
    }
    func covers(_ day: Date) -> Bool {
        let cal = Calendar.current
        let d = cal.startOfDay(for: day)
        return d >= cal.startOfDay(for: from) && d <= cal.startOfDay(for: to)
    }
}

struct AttHolidayData: Codable, Equatable {
    var name = ""
    /// "govt" or "other"
    var type = "govt"
}

struct AttChangeData: Codable, Equatable {
    var entryID = ""
    var proposed = AttEntryData()
    var proposedStatus = ""
    var reason = ""
    var deleteEntry = false
    var decidedBy = ""
    var note = ""
}

/// What travels in an event: a batch of records (one for normal changes, many when catching up a new admin).
struct AttItem: Codable {
    var id: String
    var kind: String
    var companyID: String
    var memberID: String
    var day: String
    var status: String
    var deleted: Bool
    var at: Date
    var data: Data
    var by: String? = nil

    init(_ r: AttRecord) {
        id = r.id; kind = r.kind; companyID = r.companyID; memberID = r.memberID; day = r.day; status = r.status
        deleted = r.deleted; at = r.updatedAt; data = r.data; by = r.by
    }
}

struct AttPayload: Codable {
    var items: [AttItem]
    /// Catch-up of many records — one summary line in the chat.
    var bulk: Bool? = nil
}

// MARK: - Rules

/// Statuses: present, grace, late, halfday, absent, leave (paid), unpaid, holiday, off, open (today, not yet).
enum Att {
    static let statuses = ["present", "grace", "late", "halfday", "absent", "leave", "unpaid", "holiday", "off"]

    static func label(_ s: String) -> String {
        switch s {
        case "present": "Present"
        case "grace": "Present (grace)"
        case "late": "Late"
        case "halfday": "Half day"
        case "absent": "Absent"
        case "leave": "Paid leave"
        case "unpaid": "Unpaid leave"
        case "holiday": "Holiday"
        case "off": "Weekly off"
        case "open": "Not marked yet"
        default: s.capitalized
        }
    }
    static func code(_ s: String) -> String {
        switch s {
        case "present": "P"
        case "grace": "G"
        case "late": "L"
        case "halfday": "H"
        case "absent": "A"
        case "leave": "PL"
        case "unpaid": "UL"
        case "holiday": "HO"
        case "off": "WO"
        default: "·"
        }
    }
    static func color(_ s: String) -> UInt32 {
        switch s {
        case "present": 0x34C759
        case "grace": 0x30B0C7
        case "late": 0xFF9500
        case "halfday": 0xFFCC00
        case "absent": 0xFF3B30
        case "leave": 0x5856D6
        case "unpaid": 0xAF52DE
        case "holiday": 0x007AFF
        case "off": 0x8E8E93
        default: 0xC7C7CC
        }
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func key(_ d: Date) -> String { keyFormatter.string(from: d) }
    static func date(_ key: String) -> Date { keyFormatter.date(from: key) ?? .now }

    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static func at(_ minutes: Int, on day: Date) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }
    static func clock(_ minutes: Int) -> String { at(minutes, on: .now).formatted(date: .omitted, time: .shortened) }

    /// Before duty time or on it = present; within grace = grace; after grace = late; after the half-day limit = half day.
    static func auto(inAt: Date, start: Int, company c: AttCompanyData) -> String {
        let m = minutes(inAt)
        if m <= start { return "present" }
        if m <= start + c.grace { return "grace" }
        if m <= start + c.halfDayAfter { return "late" }
        return "halfday"
    }

    static func dutyStart(_ m: AttMemberData, _ c: AttCompanyData) -> Int { m.dutyStart ?? c.dutyStart }
    static func dutyEnd(_ m: AttMemberData, _ c: AttCompanyData) -> Int { m.dutyEnd ?? c.dutyEnd }

    /// The status of one person on one day.
    static func status(member: AttRecord, company: AttCompanyData, day: Date, entry: AttRecord?,
                       leaves: [AttRecord], holidays: [AttRecord]) -> String {
        let md = member.member
        if let entry, !entry.deleted {
            if !entry.status.isEmpty { return entry.status }
            if let i = entry.entry.inAt { return auto(inAt: i, start: dutyStart(md, company), company: company) }
        }
        let k = key(day)
        if let l = leaves.first(where: { $0.memberID == member.id && $0.status == "approved" && !$0.deleted && $0.leave.covers(day) }) {
            return l.leave.paid ? "leave" : "unpaid"
        }
        if holidays.contains(where: { $0.day == k && $0.status == "approved" && !$0.deleted }) { return "holiday" }
        if company.weeklyOff.contains(Calendar.current.component(.weekday, from: day)) { return "off" }
        if let j = md.joined, Calendar.current.startOfDay(for: day) < Calendar.current.startOfDay(for: j) { return "none" }
        let cal = Calendar.current
        if cal.isDateInToday(day) {
            return minutes(.now) > dutyEnd(md, company) ? "absent" : "open"
        }
        return day < .now ? "absent" : "none"
    }

    struct Summary {
        var counts: [String: Int] = [:]
        var halfLeaveDays = 0.0
        var minutesWorked = 0
        func n(_ s: String) -> Int { counts[s] ?? 0 }
        var present: Int { n("present") + n("grace") + n("late") }
        /// Days to pay for: present (incl. grace/late) + half of half days + paid leave + holidays + weekly offs.
        var payable: Double { Double(present) + Double(n("halfday")) * 0.5 + Double(n("leave")) + Double(n("holiday")) + Double(n("off")) }
        var workingDays: Int { present + n("halfday") + n("absent") + n("leave") + n("unpaid") }
    }

    static func monthDays(_ month: Date) -> [Date] {
        let cal = Calendar.current
        guard let r = cal.range(of: .day, in: .month, for: month),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) else { return [] }
        return r.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    static func summary(member: AttRecord, company: AttCompanyData, days: [Date], entries: [AttRecord],
                        leaves: [AttRecord], holidays: [AttRecord]) -> Summary {
        var s = Summary()
        let byDay = Dictionary(entries.filter { $0.memberID == member.id && !$0.deleted }.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for d in days where d <= .now || Calendar.current.isDateInToday(d) {
            let e = byDay[key(d)]
            let st = status(member: member, company: company, day: d, entry: e, leaves: leaves, holidays: holidays)
            s.counts[st, default: 0] += 1
            if let e, let i = e.entry.inAt, let o = e.entry.outAt, o > i { s.minutesWorked += Int(o.timeIntervalSince(i) / 60) }
        }
        return s
    }

    // MARK: Rotating QR (HMAC of a 30-second slot with the company secret)

    static let qrSlot: TimeInterval = 30
    static func slot(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / qrSlot) }
    static func qrToken(companyID: String, secret: String, at d: Date = .now) -> String {
        let s = slot(d)
        return "iTeamAtt|\(companyID)|\(s)|\(sign(companyID, s, secret))"
    }
    private static func sign(_ cid: String, _ slot: Int, _ secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(cid)|\(slot)".utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return mac.prefix(5).map { String(format: "%02x", $0) }.joined()
    }
    static func qrCompany(_ token: String) -> String? {
        let p = token.split(separator: "|")
        return p.count == 4 && p[0] == "iTeamAtt" ? String(p[1]) : nil
    }
    /// Valid if signed with the secret and scanned within ±90 s of being shown.
    static func qrValid(_ token: String, secret: String, at d: Date) -> Bool {
        let p = token.split(separator: "|")
        guard p.count == 4, !secret.isEmpty, let s = Int(p[2]) else { return false }
        return abs(s - slot(d)) <= 3 && sign(String(p[1]), s, secret) == String(p[3])
    }

    static func newSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }
}
