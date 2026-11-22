import Foundation
import SwiftData

/// After the free year: professional modules stay readable and exportable, but the subscriber's own records
/// can't be created or changed without a subscription. Clients, members, flat owners and employees are never locked.
@MainActor
extension SyncEngine {
    /// The paid module this send would need, or nil if it's allowed.
    func paidLock(_ body: Event.Body) -> ModuleInfo? {
        let moduleID: String?
        switch body {
        case .biz(let p):
            let id = p.id
            let rec = try? context.fetch(FetchDescriptor<BizRecord>(predicate: #Predicate { $0.id == id })).first
            moduleID = (rec?.ownerID ?? me) == me ? p.module : nil
        case .gymMember(let g):
            moduleID = (gymMember(g.id)?.createdBy ?? me) == me ? "gym-training" : nil
        case .gymPlan(let p): moduleID = gymMember(p.memberID)?.createdBy == me ? "gym-training" : nil
        case .gymSession(let p): moduleID = gymMember(p.memberID)?.createdBy == me ? "gym-training" : nil
        case .gymPayment(let p): moduleID = gymMember(p.memberID)?.createdBy == me ? "gym-training" : nil
        case .gymPhoto(let p): moduleID = gymMember(p.memberID)?.createdBy == me ? "gym-training" : nil
        case .crmGroup: moduleID = "crm"
        case .crmLead(let p): moduleID = p.ownerID == me && p.clientCopy != true ? "crm" : nil
        case .crmActivity(let p): moduleID = crmLead(p.leadID)?.ownerID == me ? "crm" : nil
        case .society(let p):
            let sid = p.items.first?.societyID ?? ""
            let soc = p.items.first { $0.kind == "society" }.flatMap { try? JSONDecoder().decode(SocData.self, from: $0.data) } ?? socRecord(sid)?.society
            moduleID = (soc?.ownerID ?? me) == me ? "society" : nil
        default: moduleID = nil
        }
        guard let moduleID, let info = ModuleRegistry.all.first(where: { $0.id == moduleID }),
              info.availability == .paid, let pid = info.productID, !Store.shared.isUnlocked(pid) else { return nil }
        // Personal use of a module is never charged.
        return info
    }
}
