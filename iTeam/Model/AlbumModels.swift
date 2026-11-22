import Foundation
import SwiftData

/// A shared photo album for an event or a trip. Photos travel in that event's/trip's chat.
@Model final class AlbumItem {
    @Attribute(.unique) var id: String
    /// The event id or trip record id.
    var owner: String = ""
    var refData: Data = Data()
    var by: String = ""
    var at: Date = Date.now
    var deleted: Bool = false
    init(id: String) { self.id = id }
    var ref: AttachmentRef? { try? JSONDecoder().decode(AttachmentRef.self, from: refData) }
}

struct AlbumPayload: Codable {
    var id: String
    var owner: String
    var ref: AttachmentRef
    var deleted: Bool
    var at: Date
}
