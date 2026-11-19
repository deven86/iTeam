import Foundation
import CloudKit
import CryptoKit
import SwiftUI
import UIKit

/// iCloud Backup, like WhatsApp: everything iTeam keeps on this device (chats, tasks, module data,
/// photos, settings) is packed into one file, encrypted on the device with a key kept in iCloud
/// Keychain, and saved in the user's own PRIVATE iCloud database (uses their iCloud storage).
/// Restore happens on the next launch, before the database opens.
@MainActor
final class Backup: ObservableObject {
    static let shared = Backup()

    @Published var auto: Bool = UserDefaults.standard.object(forKey: "backup.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "backup.auto") }
    }
    @Published var busy = false
    @Published var progress: String?
    @Published var lastError: String?
    @Published var lastDate: Date? = UserDefaults.standard.object(forKey: "backup.lastDate") as? Date
    @Published var lastSize: Int64 = Int64(UserDefaults.standard.integer(forKey: "backup.lastSize"))

    private var db: CKDatabase { CKContainer(identifier: CloudService.containerID).privateCloudDatabase }
    private static let keyAccount = "backup.key.v1"
    nonisolated private static let chunk = 4 * 1024 * 1024
    nonisolated private static let skip: Set<String> = ["tts", "RestoreStaging", "BackupWork"]

    static var deviceKind: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    private static func recordID(_ kind: String) -> CKRecord.ID { CKRecord.ID(recordName: "backup-\(kind)") }

    /// "Not backed up" warning when auto backup is off or the last one is older than 3 days.
    var needsWarning: Bool {
        guard let lastDate else { return true }
        return Date.now.timeIntervalSince(lastDate) > 3 * 86400
    }

    struct Found: Identifiable {
        let id: String       // device kind
        let date: Date
        let size: Int64
    }

    // MARK: - Key

    private static func key(create: Bool) -> SymmetricKey? {
        if let d = Keychain.get(keyAccount) { return SymmetricKey(data: d) }
        guard create else { return nil }
        let k = SymmetricKey(size: .bits256)
        _ = Keychain.set(k.withUnsafeBytes { Data($0) }, account: keyAccount, sync: true)
        return k
    }

    // MARK: - Back up

    func runIfDue() {
        guard auto, !busy else { return }
        if let lastDate, Date.now.timeIntervalSince(lastDate) < 20 * 3600 { return }
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = app.beginBackgroundTask(withName: "iTeam backup") { app.endBackgroundTask(task) }
        Task {
            await backUpNow()
            app.endBackgroundTask(task)
        }
    }

    func backUpNow() async {
        guard !busy else { return }
        busy = true; lastError = nil; progress = "Preparing…"
        defer { busy = false; progress = nil }
        SyncEngine.shared.save()
        do {
            guard let key = Self.key(create: true) else { throw BackupError.noKey }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("BackupWork", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let plain = work.appendingPathComponent("plain.bin")
            let sealed = work.appendingPathComponent("iteam.backup")
            let defaults = Self.exportDefaults()
            try await Task.detached(priority: .utility) {
                try Self.pack(root: URL.applicationSupportDirectory, defaults: defaults, to: plain)
                try Self.encrypt(plain, to: sealed, key: key)
                try? FileManager.default.removeItem(at: plain)
            }.value
            let size = (try? FileManager.default.attributesOfItem(atPath: sealed.path)[.size] as? Int64) ?? 0
            progress = "Uploading \(Fmt.bytes(size))…"
            let id = Self.recordID(Self.deviceKind)
            let record = (try? await db.record(for: id)) ?? CKRecord(recordType: "Backup", recordID: id)
            record["archive"] = CKAsset(fileURL: sealed)
            record["device"] = Self.deviceKind
            record["size"] = size
            record["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let (saved, _) = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if case .failure(let e)? = saved[id] { throw e }
            lastDate = .now; lastSize = size
            UserDefaults.standard.set(lastDate, forKey: "backup.lastDate")
            UserDefaults.standard.set(Int(size), forKey: "backup.lastSize")
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: - Restore

    /// Backups saved from this Apple ID (one per iPhone / iPad).
    func available() async -> [Found] {
        let ids = [Self.recordID("iphone"), Self.recordID("ipad")]
        guard let results = try? await db.records(for: ids, desiredKeys: ["size", "device"]) else { return [] }
        return results.compactMap { id, r in
            guard case .success(let rec) = r else { return nil }
            return Found(id: rec["device"] as? String ?? id.recordName,
                         date: rec.modificationDate ?? rec.creationDate ?? .now,
                         size: rec["size"] as? Int64 ?? 0)
        }.sorted { $0.date > $1.date }
    }

    /// Downloads and decrypts a backup into a staging folder; it replaces the data on the next launch.
    func prepareRestore(_ found: Found) async -> Bool {
        busy = true; lastError = nil; progress = "Downloading backup…"
        defer { busy = false; progress = nil }
        do {
            guard let key = Self.key(create: false) else { throw BackupError.noKey }
            let rec = try await db.record(for: Self.recordID(found.id))
            guard let url = (rec["archive"] as? CKAsset)?.fileURL else { throw BackupError.empty }
            progress = "Decrypting…"
            try await Task.detached(priority: .userInitiated) {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("restore.bin")
                try? FileManager.default.removeItem(at: work)
                try Self.decrypt(url, to: work, key: key)
                let staging = Self.stagingDir
                try? FileManager.default.removeItem(at: staging)
                try Self.unpack(work, into: staging)
                try? FileManager.default.removeItem(at: work)
            }.value
            UserDefaults.standard.set(true, forKey: "backup.restorePending")
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    nonisolated static var stagingDir: URL {
        URL.libraryDirectory.appendingPathComponent("RestoreStaging", isDirectory: true)
    }

    /// Called from `iTeamApp.init` before the database opens.
    nonisolated static func applyPendingRestore() {
        let fm = FileManager.default
        let staging = stagingDir
        guard UserDefaults.standard.bool(forKey: "backup.restorePending"),
              fm.fileExists(atPath: staging.path) else { return }
        let root = URL.applicationSupportDirectory
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
        for item in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
            if item.lastPathComponent == "__defaults.plist" {
                if let d = try? Data(contentsOf: item),
                   let dict = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                    for (k, v) in dict where !k.hasPrefix("backup.") { UserDefaults.standard.set(v, forKey: k) }
                }
                continue
            }
            try? fm.moveItem(at: item, to: root.appendingPathComponent(item.lastPathComponent))
        }
        try? fm.removeItem(at: staging)
        UserDefaults.standard.set(false, forKey: "backup.restorePending")
        UserDefaults.standard.set(true, forKey: "backup.restoreOffered")
    }

    // MARK: - File format
    // Archive: repeated [u32 path length][path utf8][u64 size][bytes].
    // Encrypted: repeated [u32 sealed length][AES-GCM sealed box of ≤4 MB].

    private static func exportDefaults() -> Data? {
        guard let id = Bundle.main.bundleIdentifier,
              let dict = UserDefaults.standard.persistentDomain(forName: id) else { return nil }
        let clean = dict.filter { PropertyListSerialization.propertyList($0.value, isValidFor: .binary) }
        return try? PropertyListSerialization.data(fromPropertyList: clean, format: .binary, options: 0)
    }

    nonisolated private static func pack(root: URL, defaults: Data?, to out: URL) throws {
        let fm = FileManager.default
        fm.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        func write(_ rel: String, size: UInt64, body: (FileHandle) throws -> Void) throws {
            let name = Data(rel.utf8)
            var n = UInt32(name.count).littleEndian
            var s = size.littleEndian
            try h.write(contentsOf: Data(bytes: &n, count: 4))
            try h.write(contentsOf: name)
            try h.write(contentsOf: Data(bytes: &s, count: 8))
            try body(h)
        }
        if let defaults { try write("__defaults.plist", size: UInt64(defaults.count)) { try $0.write(contentsOf: defaults) } }
        let base = root.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
        for case let url as URL in walker {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let rel = String(full.dropFirst(base.count + 1))
            if let top = rel.split(separator: "/").first, skip.contains(String(top)) { walker.skipDescendants(); continue }
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v.isRegularFile == true else { continue }
            let src = try FileHandle(forReadingFrom: url)
            defer { try? src.close() }
            try write(rel, size: UInt64(v.fileSize ?? 0)) { dst in
                var left = UInt64(v.fileSize ?? 0)
                while left > 0, let d = try src.read(upToCount: Int(min(left, UInt64(chunk)))), !d.isEmpty {
                    try dst.write(contentsOf: d); left -= UInt64(d.count)
                }
                // File shrank while copying: pad so the archive stays readable.
                if left > 0 { try dst.write(contentsOf: Data(count: Int(left))) }
            }
        }
    }

    nonisolated private static func unpack(_ file: URL, into dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        while let lenData = try h.read(upToCount: 4), lenData.count == 4 {
            let n = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            guard let nameData = try h.read(upToCount: Int(n)), let rel = String(data: nameData, encoding: .utf8),
                  let sizeData = try h.read(upToCount: 8), sizeData.count == 8 else { throw BackupError.damaged }
            guard !rel.contains("..") else { throw BackupError.damaged }
            var left = sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
            let dst = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: dst.path, contents: nil)
            let w = try FileHandle(forWritingTo: dst)
            while left > 0, let d = try h.read(upToCount: Int(min(left, UInt64(chunk)))), !d.isEmpty {
                try w.write(contentsOf: d); left -= UInt64(d.count)
            }
            try w.close()
            if left > 0 { throw BackupError.damaged }
        }
    }

    nonisolated private static func encrypt(_ src: URL, to dst: URL, key: SymmetricKey) throws {
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let r = try FileHandle(forReadingFrom: src), w = try FileHandle(forWritingTo: dst)
        defer { try? r.close(); try? w.close() }
        while let d = try r.read(upToCount: chunk), !d.isEmpty {
            guard let box = try AES.GCM.seal(d, using: key).combined else { throw BackupError.damaged }
            var n = UInt32(box.count).littleEndian
            try w.write(contentsOf: Data(bytes: &n, count: 4))
            try w.write(contentsOf: box)
        }
    }

    nonisolated private static func decrypt(_ src: URL, to dst: URL, key: SymmetricKey) throws {
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let r = try FileHandle(forReadingFrom: src), w = try FileHandle(forWritingTo: dst)
        defer { try? r.close(); try? w.close() }
        while let lenData = try r.read(upToCount: 4), lenData.count == 4 {
            let n = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard let box = try r.read(upToCount: n), box.count == n else { throw BackupError.damaged }
            do { try w.write(contentsOf: try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key)) }
            catch { throw BackupError.wrongKey }
        }
    }

    enum BackupError: LocalizedError {
        case noKey, empty, damaged, wrongKey
        var errorDescription: String? {
            switch self {
            case .noKey: "The backup key isn't on this device. Turn on iCloud Keychain (Settings → your name → iCloud → Passwords and Keychain) and try again."
            case .empty: "The backup in iCloud is empty."
            case .damaged: "The backup file is damaged."
            case .wrongKey: "This backup was locked with a different key, so it can't be opened here."
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .quotaExceeded: return "Your iCloud storage is full. Free some space or upgrade iCloud+."
            case .notAuthenticated: return "Sign in to iCloud in iPhone Settings to use backup."
            case .networkUnavailable, .networkFailure: return "No internet connection. Backup will try again later."
            default: return error.cloudMessage
            }
        }
        return error.localizedDescription
    }
}
