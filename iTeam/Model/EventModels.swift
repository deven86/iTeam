import Foundation
import SwiftData

/// An invitation sent in a chat; everyone in that chat is invited and can RSVP.
@Model final class InviteEvent {
    @Attribute(.unique) var id: String
    var convID: String = ""
    var hostID: String = ""
    var title: String = ""
    var place: String = ""
    var start: Date = Date.now
    var end: Date = Date.now
    var notes: String = ""
    var deleted: Bool = false
    var updatedAt: Date = Date.now
    /// userID → "going" / "maybe" / "no"
    var rsvpData: Data = Data()

    init(id: String) { self.id = id }

    var rsvps: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: rsvpData)) ?? [:] }
        set { rsvpData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

struct InviteEventPayload: Codable {
    var id: String
    var title: String
    var place: String
    var start: Date
    var end: Date
    var notes: String
    var deleted: Bool
    var at: Date
}
