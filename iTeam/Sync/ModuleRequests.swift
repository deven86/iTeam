import Foundation
import CloudKit

/// "Request a module": ideas users send to the iTeam owner.
///
/// Stored as ModuleRequest records in the same CloudKit public database (no server, no cost).
/// Not end-to-end encrypted — the form says so — so people should not put confidential details in it.
struct ModuleRequestItem: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var problem: String
    var details: String
    var users: String
    var willPay: Int          // 0 no, 1 maybe, 2 yes
    var name: String
    var contact: String
    var date: Date

    static let payLabels = ["Free only", "Maybe", "Yes, I'd pay"]
}

extension CloudService {
    func submit(_ r: ModuleRequestItem) async throws {
        let rec = CKRecord(recordType: "ModuleRequest", recordID: CKRecord.ID(recordName: "R" + r.id))
        rec["title"] = r.title
        rec["problem"] = r.problem
        rec["details"] = r.details
        rec["users"] = r.users
        rec["pay"] = r.willPay as NSNumber
        rec["name"] = r.name
        rec["contact"] = r.contact
        rec["ver"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        _ = try await db.save(rec)
    }

    /// Owner inbox: newest first.
    func moduleRequests() async throws -> [ModuleRequestItem] {
        let query = CKQuery(recordType: "ModuleRequest", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let page = try await db.records(matching: query, inZoneWith: nil, desiredKeys: nil, resultsLimit: 200)
        return page.matchResults.compactMap { _, result in
            guard let r = try? result.get() else { return nil }
            return ModuleRequestItem(id: String(r.recordID.recordName.dropFirst()),
                                     title: r["title"] as? String ?? "",
                                     problem: r["problem"] as? String ?? "",
                                     details: r["details"] as? String ?? "",
                                     users: r["users"] as? String ?? "",
                                     willPay: (r["pay"] as? Int) ?? 0,
                                     name: r["name"] as? String ?? "",
                                     contact: r["contact"] as? String ?? "",
                                     date: r.creationDate ?? .now)
        }
    }

    /// Owner only: an alert on his devices when someone sends a request.
    func ensureOwnerRequestAlerts() async throws {
        let id = "module-requests-v1"
        let existing = Set((try? await db.allSubscriptions())?.map(\.subscriptionID) ?? [])
        guard !existing.contains(id) else { return }
        let sub = CKQuerySubscription(recordType: "ModuleRequest", predicate: NSPredicate(value: true),
                                      subscriptionID: id, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.title = "New module request"
        info.alertBody = "Someone asked for a new iTeam module."
        info.soundName = "default"
        info.desiredKeys = ["title"]
        sub.notificationInfo = info
        _ = try await db.save(sub)
    }
}

/// Requests this device sent, kept locally so the sender can see them.
enum MyModuleRequests {
    private static let key = "moduleRequests.mine"
    static var all: [ModuleRequestItem] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ModuleRequestItem].self, from: d)) ?? []
    }
    static func add(_ r: ModuleRequestItem) {
        let list = [r] + all
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
}
