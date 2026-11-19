import Foundation
import SwiftData

/// One medicine line in a prescription.
struct RxItem: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var dose: String = ""
    var form: String = "Tablet"
    /// Minutes after midnight, e.g. 540 = 9:00
    var times: [Int] = [540]
    /// 0 = until the doctor says stop
    var days: Int = 5
    var instructions: String = ""
}

/// A prescription from a doctor to a patient (Doctor & Patient module — always free).
@Model final class Prescription {
    @Attribute(.unique) var id: String
    var convID: String = ""
    var doctorID: String = ""
    var patientID: String = ""
    var patientName: String = ""
    var diagnosis: String = ""
    var advice: String = ""
    var itemsData: Data = Data()
    var nextVisit: Date? = nil
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    /// "waiting", "accepted", "declined"
    var status: String = "waiting"
    var answerNote: String = ""
    var answeredAt: Date? = nil
    /// The patient's Care profile the medicines went into (on the patient's phone).
    var careProfileID: String = ""
    var deleted: Bool = false

    init(id: String) { self.id = id }

    var items: [RxItem] {
        get { (try? JSONDecoder().decode([RxItem].self, from: itemsData)) ?? [] }
        set { itemsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}
