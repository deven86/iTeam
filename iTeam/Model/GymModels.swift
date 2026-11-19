import Foundation
import SwiftData

// MARK: - Gym & Training module
//
// Ported from iLife's Gym section and made shareable: each person (you, family or a client) lives in one
// chat, so a trainer and the client — or the whole family — see the same memberships, sessions and payments.
// Personal-training sessions are counted per training day.

@Model final class GymMember {
    @Attribute(.unique) var id: String
    var convID: String
    var name: String
    var relation: String = ""
    var phone: String = ""
    var goal: String = ""
    var trainer: String = ""
    var feePerSession: Double = 0
    var avatar: Data?
    var createdBy: String
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false

    init(id: String, convID: String, name: String, createdBy: String) {
        self.id = id; self.convID = convID; self.name = name; self.createdBy = createdBy
    }
}

@Model final class GymPlan {
    @Attribute(.unique) var id: String
    var memberID: String
    var gymName: String = ""
    var branch: String = ""
    var planName: String = ""
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var fee: Double = 0
    var notes: String = ""
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false

    init(id: String, memberID: String) { self.id = id; self.memberID = memberID }

    var daysLeft: Int { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: endDate).day ?? 0 }
    var isActive: Bool { endDate >= Calendar.current.startOfDay(for: .now) }
    var progress: Double {
        let total = max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 1)
        return min(1, max(0, Double(total - daysLeft) / Double(total)))
    }
}

@Model final class GymSession {
    @Attribute(.unique) var id: String
    var memberID: String
    var date: Date = Date.now
    var trainer: String = ""
    var workout: String = ""
    var notes: String = ""
    var by: String = ""
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false

    init(id: String, memberID: String) { self.id = id; self.memberID = memberID }
}

enum GymPaymentKind: String, CaseIterable, Identifiable {
    case membership, training, supplements, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .membership: "Gym membership"
        case .training: "Personal training"
        case .supplements: "Supplements & diet"
        case .other: "Other"
        }
    }
    var icon: String {
        switch self {
        case .membership: "building.2.fill"
        case .training: "figure.strengthtraining.traditional"
        case .supplements: "takeoutbag.and.cup.and.straw.fill"
        case .other: "indianrupeesign.circle.fill"
        }
    }
}

@Model final class GymPayment {
    @Attribute(.unique) var id: String
    var memberID: String
    var kind: String = GymPaymentKind.membership.rawValue
    var amount: Double = 0
    var date: Date = Date.now
    var method: String = "UPI"
    /// Personal-training package size.
    var sessions: Int = 0
    var notes: String = ""
    var receiptsData: Data?
    var by: String = ""
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false

    init(id: String, memberID: String) { self.id = id; self.memberID = memberID }

    var paymentKind: GymPaymentKind { GymPaymentKind(rawValue: kind) ?? .other }
    var receipts: [AttachmentRef] {
        get { Packed.decode([AttachmentRef].self, receiptsData) ?? [] }
        set { receiptsData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }
}

/// Relations offered when adding a person (care profiles, gym members). "Custom" lets you type your own.
enum Relations {
    static let all = ["Self", "Client", "Wife", "Husband", "Daughter", "Son", "Mother", "Father", "Sister", "Brother",
                      "Grandmother", "Grandfather", "Mother-in-law", "Father-in-law", "Aunt", "Uncle", "Cousin",
                      "Friend", "Team member", "Employee", "Student"]
    static let custom = "Custom…"
}
