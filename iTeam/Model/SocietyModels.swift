import Foundation
import SwiftData

// MARK: - Society & Apartment Manager (blueprint v3)
//
// One stored record type (like Attendance): society, unit, bill, complaint, visitor, notice.
// Indexed fields are columns; details live in a Codable blob, so fields can be added without migrations.
// Committee ↔ committee group chat; each flat owner (must be on iTeam) gets only their own records
// in their one-to-one chat with the committee. Staff attendance uses the society's Attendance company.

@Model final class SocietyRecord {
    @Attribute(.unique) var id: String
    /// society, unit, bill, complaint, visitor, notice
    var kind: String = ""
    var societyID: String = ""
    var unitID: String = ""
    /// bill: due/verifying/paid · complaint: open/in progress/resolved · visitor: waiting/approved/denied/left
    var status: String = ""
    var deleted: Bool = false
    var by: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var data: Data = Data()

    init(id: String, kind: String) { self.id = id; self.kind = kind }

    private func load<T: Decodable>(_ t: T.Type) -> T? { try? JSONDecoder().decode(T.self, from: data) }
    private func store<T: Encodable>(_ v: T) { data = (try? JSONEncoder().encode(v)) ?? Data() }

    var society: SocData { get { load(SocData.self) ?? SocData() } set { store(newValue) } }
    var unit: SocUnitData { get { load(SocUnitData.self) ?? SocUnitData() } set { store(newValue) } }
    var bill: SocBillData { get { load(SocBillData.self) ?? SocBillData() } set { store(newValue) } }
    var complaint: SocComplaintData { get { load(SocComplaintData.self) ?? SocComplaintData() } set { store(newValue) } }
    var visitor: SocVisitorData { get { load(SocVisitorData.self) ?? SocVisitorData() } set { store(newValue) } }
    var notice: SocNoticeData { get { load(SocNoticeData.self) ?? SocNoticeData() } set { store(newValue) } }
}

struct SocData: Codable, Equatable {
    var name = ""
    var address = ""
    var ownerID = ""
    var committee: [String] = []
    /// Group chat with the committee, where everything travels.
    var committeeConvID = ""
    /// Attendance company for guards, housekeeping and reception staff.
    var attCompanyID = ""
    var defaultMaintenance = 0.0
    var dueDay = 10
    var upi = ""
    func isCommittee(_ u: String) -> Bool { u == ownerID || committee.contains(u) }
}

struct SocUnitData: Codable, Equatable {
    var flat = ""
    var wing = ""
    var floor = ""
    /// Required: the flat owner on iTeam.
    var ownerUserID = ""
    var ownerName = ""
    var tenantName = ""
    var phone = ""
    var members = 0
    var parking = ""
    var maintenance = 0.0
    var label: String { [wing, flat].filter { !$0.isEmpty }.joined(separator: "-") }
}

struct SocBillData: Codable, Equatable {
    var title = ""
    var month = ""
    var amount = 0.0
    var due = Date.now
    var paidOn: Date? = nil
    var method = ""
    var reference = ""
    var receipts: [AttachmentRef] = []
    var verifiedBy = ""
}

struct SocComplaintData: Codable, Equatable {
    var title = ""
    var category = "Maintenance"
    var detail = ""
    var photos: [AttachmentRef] = []
    var reply = ""
    var assignedTo = ""
}

struct SocVisitorData: Codable, Equatable {
    var name = ""
    /// Guest, Delivery, Cab, Service
    var purpose = "Guest"
    var vehicle = ""
    var phone = ""
    var photo: Data? = nil
    var at = Date.now
    var answeredBy = ""
    var answeredAt: Date? = nil
    var note = ""
    var gateBy = ""
}

struct SocNoticeData: Codable, Equatable {
    var title = ""
    var body = ""
    var pinned = false
    var files: [AttachmentRef] = []
}

struct SocItem: Codable {
    var id: String
    var kind: String
    var societyID: String
    var unitID: String = ""
    var status: String = ""
    var deleted: Bool = false
    var data: Data
    var at: Date = .now
    static func enc<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data() }
}

struct SocietyPayload: Codable { var items: [SocItem] }
