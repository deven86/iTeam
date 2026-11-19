import Foundation
import SwiftData

/// 📍 Check In: "I'm going to X, I'll be there by 10:30". The friend's phone alerts them if no
/// "arrived" comes by then (+15 min) — no server needed.
@Model final class CheckIn {
    @Attribute(.unique) var id: String
    var convID: String = ""
    var ownerID: String = ""
    var place: String = ""
    var lat: Double = 0
    var lon: Double = 0
    var eta: Date = Date.now
    /// "active", "arrived", "ended"
    var status: String = "active"
    var updatedAt: Date = Date.now
    var createdAt: Date = Date.now
    init(id: String) { self.id = id }
}

struct CheckInPayload: Codable {
    var id: String
    var place: String
    var lat: Double
    var lon: Double
    var eta: Date
    var status: String
    var at: Date
}
