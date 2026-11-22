import Foundation
import SwiftData

// MARK: - CRM (Customer Relationship Manager)
//
// Multi-company and group CRM (blueprint v2). Companies are the same company records Attendance uses,
// so a company made in either module appears in both. A lead lives in one chat: a CRM team group,
// the assignees' one-to-one chats, or Notes to self. A linked client gets a client-safe copy in their
// one-to-one chat and answers quotes there.

@Model final class CRMGroup {
    @Attribute(.unique) var id: String
    var companyID: String = ""
    var convID: String = ""
    var name: String = ""
    var createdBy: String = ""
    var memberIDsData: Data?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false

    init(id: String) { self.id = id }
    var memberIDs: [String] {
        get { Packed.decode([String].self, memberIDsData) ?? [] }
        set { memberIDsData = Packed.encode(newValue) }
    }
}

@Model final class CRMLead {
    @Attribute(.unique) var id: String
    var companyID: String = ""
    var groupConvID: String = ""
    var ownerID: String = ""
    var assigneesData: Data?
    var clientID: String = ""
    var name: String = ""
    var company: String = ""
    var phone: String = ""
    var email: String = ""
    var source: String = ""
    var stage: String = "new"
    var dealValue: Double = 0
    var probability: Int = 20
    var nextFollowUp: Date?
    var notes: String = ""
    /// True on the client's phone: a client-safe copy managed by someone else.
    var clientCopy: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false
    var deletedBy: String = ""

    init(id: String) { self.id = id }
    var assignees: [String] {
        get { Packed.decode([String].self, assigneesData) ?? [] }
        set { assigneesData = Packed.encode(newValue) }
    }
    var isOpen: Bool { stage != "won" && stage != "lost" && !deleted }
    var followUpDue: Bool { isOpen && (nextFollowUp.map { $0 < Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400) } ?? false) }
}

@Model final class CRMActivity {
    @Attribute(.unique) var id: String
    var leadID: String = ""
    var companyID: String = ""
    var authorID: String = ""
    /// call, meeting, visit, note, quote, stage
    var kind: String = "note"
    var title: String = ""
    var detail: String = ""
    var amount: Double = 0
    var at: Date = Date.now
    var needsAcceptance: Bool = false
    /// "", "accepted", "declined"
    var acceptance: String = ""
    var declineReason: String = ""
    var filesData: Data?
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false

    init(id: String) { self.id = id }
    var files: [AttachmentRef] {
        get { Packed.decode([AttachmentRef].self, filesData) ?? [] }
        set { filesData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }
}

enum CRMStage: String, CaseIterable, Identifiable {
    case new, contacted, proposal, negotiation, won, lost
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .new: "sparkle"
        case .contacted: "phone.fill"
        case .proposal: "doc.text.fill"
        case .negotiation: "arrow.left.arrow.right"
        case .won: "trophy.fill"
        case .lost: "xmark.circle.fill"
        }
    }
    var color: UInt32 {
        switch self {
        case .new: 0x5B8DEF
        case .contacted: 0x30B0C7
        case .proposal: 0xAF52DE
        case .negotiation: 0xFF9500
        case .won: 0x34C759
        case .lost: 0x8E8E93
        }
    }
    static func of(_ s: String) -> CRMStage { CRMStage(rawValue: s) ?? .new }
}

struct CRMGroupPayload: Codable {
    var id: String
    var companyID: String
    var name: String
    var memberIDs: [String]
    var deleted: Bool
    var at: Date
}

struct CRMLeadPayload: Codable {
    var id: String
    var companyID: String
    var groupConvID: String
    var ownerID: String
    var assignees: [String]
    var clientID: String
    var name: String
    var company: String
    var phone: String
    var email: String
    var source: String
    var stage: String
    var dealValue: Double
    var probability: Int
    var nextFollowUp: Date?
    var notes: String
    var deleted: Bool
    var at: Date
    /// Client-safe copy sent to the linked client.
    var clientCopy: Bool? = nil
}

struct CRMActivityPayload: Codable {
    var id: String
    var leadID: String
    var companyID: String
    var kind: String
    var title: String
    var detail: String
    var amount: Double
    var date: Date
    var needsAcceptance: Bool
    var acceptance: String
    var declineReason: String
    var files: [AttachmentRef]
    var deleted: Bool
    var at: Date
}
