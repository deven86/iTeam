import Foundation
import SwiftData

/// One record in a business module (Khata, Tuition, Rent, Legal, Clinic, Bills).
/// Records are event-sourced like everything else: kept on this device, synced to my other
/// devices, and — when linked to an iTeam contact — shared in my direct chat with that person
/// so they see only their own records ("Managed by X").
@Model final class BizRecord {
    @Attribute(.unique) var id: String
    var module: String = ""
    var kind: String = ""
    /// Parent record (e.g. a payment's customer). "" = top level.
    var parentID: String = ""
    /// Direct chat it's shared in ("" = only me).
    var convID: String = ""
    var ownerID: String = ""
    /// The iTeam user this record is about (customer, parent, tenant, client, patient) — "" if not on iTeam.
    var subjectID: String = ""
    var title: String = ""
    var subtitle: String = ""
    var phone: String = ""
    var amount: Double = 0
    var date: Date? = nil
    var due: Date? = nil
    var status: String = ""
    var notes: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var deleted: Bool = false
    var deletedBy: String = ""

    init(id: String) { self.id = id }
}

struct BizPayload: Codable {
    var id: String
    var module: String
    var kind: String
    var parentID: String
    var subjectID: String
    var title: String
    var subtitle: String
    var phone: String
    var amount: Double
    var date: Date?
    var due: Date?
    var status: String
    var notes: String
    var deleted: Bool
    var at: Date

    init(_ r: BizRecord) {
        id = r.id; module = r.module; kind = r.kind; parentID = r.parentID; subjectID = r.subjectID
        title = r.title; subtitle = r.subtitle; phone = r.phone; amount = r.amount; date = r.date; due = r.due
        status = r.status; notes = r.notes; deleted = r.deleted; at = .now
    }
}
