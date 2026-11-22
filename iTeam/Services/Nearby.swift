import Foundation
import CloudKit
import CoreLocation

/// Nearby search: people and businesses who chose to be findable, within a few kilometres.
/// Opt-in only. The public "Nearby" record holds a display name, a short line, a category, the iTeam
/// public key and an approximate position (≈1 km grid + a 5 km geohash cell). It expires and is deleted
/// when the user turns it off. Messages are still end-to-end encrypted as always.
@MainActor
final class Nearby: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Nearby()

    struct Listing: Identifiable, Equatable {
        var id: String           // userID
        var name: String
        var kind: String         // person, business, professional
        var category: String
        var about: String
        var publicKey: String
        var lat: Double
        var lon: Double
        var until: Date
        var km: Double = 0
    }

    static let categories = ["Shop / store", "Restaurant / food", "Doctor / clinic", "Lawyer / advocate", "Builder / contractor", "Gym / trainer",
                             "Tutor / classes", "Plumber / electrician", "Salon / beauty", "Society / apartment", "Office / company", "Other"]

    @Published var results: [Listing] = []
    @Published var busy = false
    @Published var error: String?
    @Published var mine: Listing?
    @Published var here: CLLocation?

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    private var db: CKDatabase { CloudService.shared.db }
    private func recordID(_ user: String) -> CKRecord.ID { CKRecord.ID(recordName: "N" + user) }

    // MARK: Location

    func locate() async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            error = "Location is off for iTeam. Turn it on in Settings → iTeam → Location."
            return nil
        }
        return await withCheckedContinuation { c in
            waiters.append(c)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.finish(loc) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways, !self.waiters.isEmpty { manager.requestLocation() }
            if manager.authorizationStatus == .denied { self.finish(nil) }
        }
    }
    private func finish(_ loc: CLLocation?) {
        if let loc { here = loc }
        let w = waiters; waiters = []
        w.forEach { $0.resume(returning: loc) }
    }

    // MARK: Publish / remove

    /// Makes me findable for `hours`. Position is rounded to about 1 km.
    func publish(userID: String, publicKey: String, name: String, kind: String, category: String, about: String, hours: Int) async -> Bool {
        busy = true; error = nil
        defer { busy = false }
        guard let loc = await locate() else { if error == nil { error = "Couldn't get your location." }; return false }
        let lat = (loc.coordinate.latitude * 100).rounded() / 100, lon = (loc.coordinate.longitude * 100).rounded() / 100
        let r = CKRecord(recordType: "Nearby", recordID: recordID(userID))
        r["uid"] = userID as CKRecordValue
        r["name"] = String(name.prefix(60)) as CKRecordValue
        r["kind"] = kind as CKRecordValue
        r["cat"] = category as CKRecordValue
        r["about"] = String(about.prefix(160)) as CKRecordValue
        r["pubkey"] = publicKey as CKRecordValue
        r["cell"] = Geohash.encode(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, length: 5) as CKRecordValue
        r["lat"] = lat as CKRecordValue
        r["lon"] = lon as CKRecordValue
        let until = Date.now.addingTimeInterval(Double(hours) * 3600)
        r["until"] = until as CKRecordValue
        do {
            _ = try await db.modifyRecords(saving: [r], deleting: [], savePolicy: .allKeys, atomically: true)
            mine = Listing(id: userID, name: name, kind: kind, category: category, about: about, publicKey: publicKey, lat: lat, lon: lon, until: until)
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: "nearby.until")
            return true
        } catch {
            self.error = error.cloudMessage
            return false
        }
    }

    func remove(userID: String) async {
        _ = try? await db.modifyRecords(saving: [], deleting: [recordID(userID)])
        mine = nil
        UserDefaults.standard.removeObject(forKey: "nearby.until")
    }

    var visibleUntil: Date? {
        let t = UserDefaults.standard.double(forKey: "nearby.until")
        return t > Date.now.timeIntervalSince1970 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: Search

    func search(me: String, blocked: Set<String>, radiusKm: Double) async {
        busy = true; error = nil
        defer { busy = false }
        guard let loc = await locate() else { if error == nil { error = "Couldn't get your location." }; return }
        let cells = Geohash.neighbours(Geohash.encode(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, length: 5))
        let q = CKQuery(recordType: "Nearby", predicate: NSPredicate(format: "cell IN %@ AND until > %@", cells, Date.now as NSDate))
        do {
            let page = try await db.records(matching: q, desiredKeys: ["uid", "name", "kind", "cat", "about", "pubkey", "lat", "lon", "until"], resultsLimit: 200)
            var out: [Listing] = []
            for (_, res) in page.matchResults {
                guard let r = try? res.get(), let uid = r["uid"] as? String, uid != me, !blocked.contains(uid),
                      let lat = r["lat"] as? Double, let lon = r["lon"] as? Double else { continue }
                var l = Listing(id: uid, name: r["name"] as? String ?? "", kind: r["kind"] as? String ?? "person", category: r["cat"] as? String ?? "",
                                about: r["about"] as? String ?? "", publicKey: r["pubkey"] as? String ?? "", lat: lat, lon: lon,
                                until: r["until"] as? Date ?? .now)
                l.km = loc.distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000
                if l.km <= radiusKm { out.append(l) }
            }
            results = out.sorted { $0.km < $1.km }
        } catch {
            self.error = error.cloudMessage
        }
    }
}

/// Standard base-32 geohash, used only to narrow the CloudKit query to nearby cells.
enum Geohash {
    private static let chars = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    static func encode(lat: Double, lon: Double, length: Int) -> String {
        var latR = (-90.0, 90.0), lonR = (-180.0, 180.0)
        var out = "", bit = 0, ch = 0, even = true
        while out.count < length {
            if even {
                let mid = (lonR.0 + lonR.1) / 2
                if lon >= mid { ch |= 1 << (4 - bit); lonR.0 = mid } else { lonR.1 = mid }
            } else {
                let mid = (latR.0 + latR.1) / 2
                if lat >= mid { ch |= 1 << (4 - bit); latR.0 = mid } else { latR.1 = mid }
            }
            even.toggle()
            if bit < 4 { bit += 1 } else { out.append(chars[ch]); bit = 0; ch = 0 }
        }
        return out
    }

    static func decode(_ hash: String) -> (lat: Double, lon: Double, dLat: Double, dLon: Double) {
        var latR = (-90.0, 90.0), lonR = (-180.0, 180.0), even = true
        for c in hash {
            guard let v = chars.firstIndex(of: c) else { continue }
            for b in (0..<5).reversed() {
                let on = (v >> b) & 1 == 1
                if even { let m = (lonR.0 + lonR.1) / 2; if on { lonR.0 = m } else { lonR.1 = m } }
                else { let m = (latR.0 + latR.1) / 2; if on { latR.0 = m } else { latR.1 = m } }
                even.toggle()
            }
        }
        return ((latR.0 + latR.1) / 2, (lonR.0 + lonR.1) / 2, latR.1 - latR.0, lonR.1 - lonR.0)
    }

    /// The cell and its 8 neighbours.
    static func neighbours(_ hash: String) -> [String] {
        let c = decode(hash)
        var out: [String] = []
        for dy in [-1.0, 0, 1] {
            for dx in [-1.0, 0, 1] {
                let lat = max(-89.99, min(89.99, c.lat + dy * c.dLat))
                var lon = c.lon + dx * c.dLon
                if lon > 180 { lon -= 360 }; if lon < -180 { lon += 360 }
                let h = encode(lat: lat, lon: lon, length: hash.count)
                if !out.contains(h) { out.append(h) }
            }
        }
        return out
    }
}
