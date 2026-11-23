import Foundation
import CloudKit

/// The only "server" iTeam uses: Apple's CloudKit public database in the iTeam iCloud container.
/// It never sees readable content — only encrypted envelopes, encrypted files and public profiles
/// (display name, public key, small photo).
///
/// Record types (see cloudkit/schema.ckdb):
///   Profile   recordName "P<userID>": name, pubkey, pic
///   Envelope  rcpt, sndr, conv, kind (0 event / 1 key share), loud (1 = alert), body (encrypted), hint (encrypted preview)
///   Blob      data (encrypted file as CKAsset)
@MainActor
final class CloudService {
    static let shared = CloudService()
    static let containerID = "iCloud.com.jondhale.iteam"

    lazy var container = CKContainer(identifier: CloudService.containerID)
    var db: CKDatabase { container.publicCloudDatabase }

    struct RemoteProfile {
        var userID: String
        var name: String
        var publicKey: String
        var avatar: Data?
        var seen: Date? = nil
        var plus: Bool = false
        var qrCode: String = ""
    }

    // MARK: Account

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func currentUserID() async throws -> String {
        try await container.userRecordID().recordName
    }

    // MARK: Profiles

    private func profileID(_ userID: String) -> CKRecord.ID { CKRecord.ID(recordName: "P" + userID) }

    func saveProfile(userID: String, name: String, publicKey: String, avatar: Data?) async throws {
        let record = CKRecord(recordType: "Profile", recordID: profileID(userID))
        record["name"] = name as CKRecordValue
        record["pubkey"] = publicKey as CKRecordValue
        if let avatar { record["pic"] = avatar as CKRecordValue }
        _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
    }

    /// Updates only the "last seen" time on my public profile (nil removes it).
    func touchSeen(userID: String, at: Date?) async {
        let record = CKRecord(recordType: "Profile", recordID: profileID(userID))
        record["seen"] = at as CKRecordValue?
        _ = try? await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
    }

    /// Publishes whether I have the iTeam Plus badge.
    func setPlus(userID: String, _ on: Bool) async {
        let record = CKRecord(recordType: "Profile", recordID: profileID(userID))
        record["plus"] = (on ? 1 : 0) as Int64 as CKRecordValue
        _ = try? await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
    }

    /// Publishes my current QR code; codes made before this stop working.
    func setQRCode(userID: String, _ code: String) async {
        let record = CKRecord(recordType: "Profile", recordID: profileID(userID))
        record["qr"] = code as CKRecordValue
        _ = try? await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
    }

    func fetchProfile(_ userID: String) async throws -> RemoteProfile? {
        do {
            let r = try await db.record(for: profileID(userID))
            guard let name = r["name"] as? String, let key = r["pubkey"] as? String else { return nil }
            return RemoteProfile(userID: userID, name: name, publicKey: key, avatar: r["pic"] as? Data, seen: r["seen"] as? Date,
                                 plus: (r["plus"] as? Int64 ?? 0) == 1, qrCode: r["qr"] as? String ?? "")
        } catch let e as CKError where e.code == .unknownItem {
            return nil
        }
    }

    // MARK: Envelopes

    struct Incoming {
        var recordName: String
        var from: String
        var creator: String
        var conv: String
        var kind: Int
        var body: Data
        var created: Date
    }

    func makeEnvelope(to: String, from: String, conv: String, kind: Int, loud: Bool, body: Data, hint: String?) -> CKRecord {
        let r = CKRecord(recordType: "Envelope", recordID: CKRecord.ID(recordName: "E" + UUID().uuidString))
        r["rcpt"] = to as CKRecordValue
        r["sndr"] = from as CKRecordValue
        r["conv"] = conv as CKRecordValue
        r["kind"] = kind as CKRecordValue
        r["loud"] = (loud ? 1 : 0) as CKRecordValue
        r["body"] = body as CKRecordValue
        if let hint { r["hint"] = hint as CKRecordValue }
        return r
    }

    /// Saves records in batches of up to 300. Throws on the first batch that fails as a whole;
    /// returns the names of records CloudKit rejected individually.
    func save(_ records: [CKRecord]) async throws -> [String: Error] {
        var failed: [String: Error] = [:]
        var i = 0
        while i < records.count {
            let batch = Array(records[i..<min(i + 300, records.count)])
            let result = try await db.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys, atomically: false)
            for (id, r) in result.saveResults {
                if case .failure(let e) = r { failed[id.recordName] = e }
            }
            i += 300
        }
        return failed
    }

    /// Envelopes addressed to me, newer than `since` (server time), oldest first.
    func inbox(for me: String, since: Date) async throws -> [Incoming] {
        let predicate = NSPredicate(format: "rcpt == %@ AND creationDate > %@", me, since as NSDate)
        let query = CKQuery(recordType: "Envelope", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let keys = ["sndr", "conv", "kind", "body"]

        var out: [Incoming] = []
        var page = try await db.records(matching: query, inZoneWith: nil, desiredKeys: keys, resultsLimit: 200)
        while true {
            for (_, result) in page.matchResults {
                guard case .success(let r) = result else { continue }
                guard let from = r["sndr"] as? String, let conv = r["conv"] as? String,
                      let kind = r["kind"] as? Int, let body = r["body"] as? Data else { continue }
                var creator = r.creatorUserRecordID?.recordName ?? ""
                if creator == CKCurrentUserDefaultName { creator = me }
                out.append(Incoming(recordName: r.recordID.recordName, from: from, creator: creator, conv: conv,
                                    kind: kind, body: body, created: r.creationDate ?? .now))
            }
            guard let cursor = page.queryCursor, out.count < 2000 else { break }
            page = try await db.records(continuingMatchFrom: cursor, desiredKeys: keys, resultsLimit: 200)
        }
        return out
    }

    func delete(_ recordNames: [String]) async throws {
        var i = 0
        while i < recordNames.count {
            let ids = recordNames[i..<min(i + 300, recordNames.count)].map { CKRecord.ID(recordName: $0) }
            _ = try await db.modifyRecords(saving: [], deleting: Array(ids), savePolicy: .allKeys, atomically: false)
            i += 300
        }
    }

    // MARK: Files

    func makeBlob(id: String, fileURL: URL) -> CKRecord {
        let r = CKRecord(recordType: "Blob", recordID: CKRecord.ID(recordName: id))
        r["data"] = CKAsset(fileURL: fileURL)
        return r
    }

    /// Downloads an encrypted file and returns its bytes.
    func fetchBlob(_ id: String) async throws -> Data {
        let r = try await db.record(for: CKRecord.ID(recordName: id))
        guard let asset = r["data"] as? CKAsset, let url = asset.fileURL else { throw CKError(.unknownItem) }
        return try Data(contentsOf: url)
    }

    // MARK: Push subscriptions

    /// Two subscriptions per user:
    ///  • loud  — a visible notification (decrypted on the device by the notification extension)
    ///  • quiet — a silent push that lets iTeam fetch receipts and echoes in the background
    func ensureSubscriptions(for me: String) async throws {
        let existing = Set((try? await db.allSubscriptions())?.map(\.subscriptionID) ?? [])
        let loudID = "loud-v1-" + me
        let quietID = "quiet-v1-" + me

        if !existing.contains(loudID) {
            let sub = CKQuerySubscription(recordType: "Envelope",
                                          predicate: NSPredicate(format: "rcpt == %@ AND loud == 1", me),
                                          subscriptionID: loudID,
                                          options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.title = "iTeam"
            info.alertBody = "New message"
            info.soundName = "default"
            info.shouldSendMutableContent = true
            info.shouldSendContentAvailable = true
            info.desiredKeys = ["conv", "hint", "sndr"]
            sub.notificationInfo = info
            try await saveSubscription(sub)
        }
        if !existing.contains(quietID) {
            let sub = CKQuerySubscription(recordType: "Envelope",
                                          predicate: NSPredicate(format: "rcpt == %@ AND loud == 0", me),
                                          subscriptionID: quietID,
                                          options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            sub.notificationInfo = info
            try await saveSubscription(sub)
        }
    }

    /// "Already exists" is success: the list fetch can fail on a weak network, and then we try to save again.
    private func saveSubscription(_ sub: CKSubscription) async throws {
        do { _ = try await db.save(sub) }
        catch let e as CKError where e.code == .serverRejectedRequest || e.code == .serverRecordChanged || e.code == .constraintViolation {
            if (try? await db.subscription(for: sub.subscriptionID)) == nil { throw e }
        }
    }
}

extension Error {
    /// Network / iCloud availability problems that mean "try again later", not "this data is bad".
    var isTransientCloudError: Bool {
        guard let e = self as? CKError else { return (self as NSError).domain == NSURLErrorDomain }
        switch e.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
            return true
        case .partialFailure:
            return true
        default:
            return false
        }
    }

    var cloudMessage: String {
        guard let e = self as? CKError else { return localizedDescription }
        switch e.code {
        case .networkUnavailable, .networkFailure: return "No internet connection"
        case .notAuthenticated: return "Sign in to iCloud in Settings"
        case .quotaExceeded: return "iCloud storage is full"
        case .requestRateLimited, .serviceUnavailable, .zoneBusy: return "iCloud is busy — will retry"
        default: return e.localizedDescription
        }
    }
}
