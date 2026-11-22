import Foundation
import SwiftData

/// Finance: income, expenses, refunds, cheques, recurring items, approvals and savings goals.
/// One record type; the details are a Codable blob so new fields never need a migration.
@Model final class FinRecord {
    @Attribute(.unique) var id: String
    /// "entry" or "goal"
    var kind: String = "entry"
    /// "personal" or a company id (from Attendance companies).
    var book: String = "personal"
    var date: Date = Date.now
    var amount: Double = 0
    /// in, out, refundIn, refundOut
    var direction: String = "out"
    /// paid, due (upcoming), pending (waiting approval), rejected
    var status: String = "paid"
    var category: String = ""
    var deleted: Bool = false
    var deletedBy: String = ""
    var by: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var data: Data = Data()

    init(id: String) { self.id = id }

    var d: FinData {
        get { (try? JSONDecoder().decode(FinData.self, from: data)) ?? FinData() }
        set { data = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var isIn: Bool { direction == "in" || direction == "refundIn" }
    var signed: Double { isIn ? amount : -amount }
}

struct FinData: Codable, Equatable {
    var title = ""
    var party = ""
    var note = ""
    /// Cash, UPI, Bank, Cheque, Card, RTGS, NEFT
    var mode = "Cash"
    var reference = ""
    var chequeNo = ""
    var chequeBank = ""
    /// issued, deposited, cleared, bounced
    var chequeStatus = ""
    /// none, weekly, monthly, quarterly, yearly
    var repeatRule = "none"
    var files: [AttachmentRef] = []
    var approver = ""
    var decidedBy = ""
    var decisionNote = ""
    var bankMatched = false
    /// Savings goal target (kind == "goal").
    var target: Double = 0
    var goalID = ""
}

struct FinItem: Codable {
    var id: String
    var kind: String
    var book: String
    var date: Date
    var amount: Double
    var direction: String
    var status: String
    var category: String
    var deleted: Bool
    var at: Date
    var data: Data
}

struct FinPayload: Codable { var items: [FinItem] }

/// A line shown in Finance: either my own entry or money recorded in another module (read-through bridge).
struct FinLine: Identifiable {
    let id: String
    let date: Date
    let amount: Double
    let isIn: Bool
    /// paid, due, pending, rejected
    let status: String
    let category: String
    let title: String
    let party: String
    let source: String
    /// Where tapping goes (nil = edit my own entry).
    let link: String?
    let record: FinRecord?
    var signed: Double { isIn ? amount : -amount }
}

enum Fin {
    static let incomeCategories = ["Sales", "Fees", "Salary", "Rent received", "Interest", "Refund", "Other income"]
    static let expenseCategories = ["Salary & wages", "Rent", "Electricity", "Phone & internet", "Fuel & travel", "Food", "Office supplies",
                                    "Professional fees", "Taxes & GST", "Bank charges", "Repairs", "Purchase", "Medical", "Education", "Savings", "Other"]
    static let modes = ["Cash", "UPI", "Bank", "Cheque", "Card", "RTGS", "NEFT"]
    static let repeats = ["none", "weekly", "monthly", "quarterly", "yearly"]

    static func money(_ v: Double) -> String { "₹" + abs(v).formatted(.number.precision(.fractionLength(0...2))) }

    static func next(_ d: Date, _ rule: String) -> Date {
        let cal = Calendar.current
        switch rule {
        case "weekly": return cal.date(byAdding: .day, value: 7, to: d) ?? d
        case "monthly": return cal.date(byAdding: .month, value: 1, to: d) ?? d
        case "quarterly": return cal.date(byAdding: .month, value: 3, to: d) ?? d
        case "yearly": return cal.date(byAdding: .year, value: 1, to: d) ?? d
        default: return d
        }
    }
}
