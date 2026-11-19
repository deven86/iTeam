import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UserNotifications

// MARK: - Alerts on the friend's phone

@MainActor
enum CheckInAlerts {
    /// If the person hasn't arrived 15 minutes after their ETA, this phone alerts the friend.
    static func update(_ ci: CheckIn, name: String) {
        let id = "checkin." + ci.id
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        guard ci.status == "active" else { return }
        let fire = ci.eta.addingTimeInterval(15 * 60)
        guard fire > .now else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(name) hasn't arrived yet"
        c.body = "They expected to reach \(ci.place) by \(ci.eta.formatted(date: .omitted, time: .shortened)). Check on them."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["conv": ci.convID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)))
    }
}

// MARK: - Arrival detection on my phone

/// Watches the destination with a geofence (works in the background with "Always" location),
/// and tells the friend "arrived" automatically.
@MainActor
final class CheckInMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = CheckInMonitor()
    private let manager = CLLocationManager()
    @Published var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestAlways() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        manager.requestLocation()
    }

    var hasAlways: Bool { manager.authorizationStatus == .authorizedAlways }

    func watch(_ ci: CheckIn) {
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: ci.lat, longitude: ci.lon), radius: 150, identifier: ci.id)
        region.notifyOnEntry = true
        region.notifyOnExit = false
        manager.startMonitoring(for: region)
    }

    func stop(_ id: String) {
        for r in manager.monitoredRegions where r.identifier == id { manager.stopMonitoring(for: r) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in
            let engine = SyncEngine.shared
            guard let ci = try? engine.context.fetch(FetchDescriptor<CheckIn>(predicate: #Predicate { $0.id == id })).first,
                  ci.status == "active", ci.ownerID == engine.me else { return }
            engine.updateCheckIn(ci, status: "arrived")
            self.stop(id)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let l = locations.last
        Task { @MainActor in self.lastLocation = l }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        }
    }
}

extension SyncEngine {
    func startCheckIn(place: String, coordinate: CLLocationCoordinate2D, eta: Date, in conv: Conversation) {
        let p = CheckInPayload(id: "ci_" + UUID().uuidString, place: place, lat: coordinate.latitude, lon: coordinate.longitude,
                               eta: eta, status: "active", at: .now)
        send(.checkIn(p), in: conv, loud: true, preview: "📍 Check In to \(place) — by \(eta.formatted(date: .omitted, time: .shortened))")
        let id = p.id
        if let ci = try? context.fetch(FetchDescriptor<CheckIn>(predicate: #Predicate { $0.id == id })).first {
            CheckInMonitor.shared.watch(ci)
        }
    }

    func updateCheckIn(_ ci: CheckIn, status: String, eta: Date? = nil) {
        guard let conv = conversation(ci.convID) else { return }
        let p = CheckInPayload(id: ci.id, place: ci.place, lat: ci.lat, lon: ci.lon, eta: eta ?? ci.eta, status: status, at: .now)
        send(.checkIn(p), in: conv, loud: status == "arrived", preview: status == "arrived" ? "✅ Arrived at \(ci.place)" : nil)
        if status != "active" { CheckInMonitor.shared.stop(ci.id) }
    }
}

// MARK: - Start sheet

struct CheckInSheet: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = CheckInMonitor.shared
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var picked: MKMapItem?
    @State private var eta = Date.now.addingTimeInterval(30 * 60)
    @State private var travel: TimeInterval?

    var body: some View {
        Form {
            Section {
                TextField("Search a place (home, office, address…)", text: $query)
                    .onSubmit { Task { await search() } }
                ForEach(results, id: \.self) { item in
                    Button { pick(item) } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Place").foregroundStyle(Color.primary)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } header: { Text("Where are you going?") }

            if let picked {
                Section {
                    Label(picked.name ?? "Destination", systemImage: "mappin.circle.fill")
                    if let travel { Text("About \(Int(travel / 60)) min by car from here").font(.caption).foregroundStyle(.secondary) }
                    DatePicker("I'll be there by", selection: $eta, in: Date.now..., displayedComponents: [.hourAndMinute, .date])
                } footer: {
                    Text(monitor.hasAlways
                         ? "When you arrive, \(conv.title) is told automatically. If you're not there 15 minutes after this time, their phone alerts them."
                         : "Allow location \"Always\" so iTeam can tell them you arrived even when it's closed. Their phone still alerts them if you're late.")
                }
            }
        }
        .navigationTitle("Check In")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    guard let p = picked else { return }
                    engine.startCheckIn(place: p.name ?? "destination", coordinate: p.placemark.coordinate, eta: eta, in: conv)
                    dismiss()
                }.disabled(picked == nil)
            }
        }
        .onAppear { monitor.requestAlways() }
    }

    private func search() async {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = query
        if let l = monitor.lastLocation { r.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        results = (try? await MKLocalSearch(request: r).start().mapItems) ?? []
    }

    private func pick(_ item: MKMapItem) {
        picked = item
        results = []
        Task {
            let r = MKDirections.Request()
            r.source = .forCurrentLocation()
            r.destination = item
            r.transportType = .automobile
            if let t = try? await MKDirections(request: r).calculateETA().expectedTravelTime {
                travel = t
                eta = Date.now.addingTimeInterval(t + 5 * 60)
            }
        }
    }
}

// MARK: - Banner in the chat

struct CheckInBanner: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var checks: [CheckIn]

    init(conv: Conversation) {
        self.conv = conv
        let id = conv.id
        _checks = Query(filter: #Predicate<CheckIn> { $0.convID == id && $0.status == "active" }, sort: \CheckIn.createdAt, order: .reverse)
    }

    var body: some View {
        if let ci = checks.first {
            let mine = ci.ownerID == engine.me
            VStack(alignment: .leading, spacing: 8) {
                Label("\(mine ? "You're" : engine.name(of: ci.ownerID) + " is") heading to \(ci.place)", systemImage: "location.circle.fill")
                    .font(.subheadline.bold())
                Text("Expected by \(ci.eta.formatted(date: .omitted, time: .shortened))\(ci.eta < .now ? " · late" : "")")
                    .font(.caption).foregroundStyle(ci.eta < .now ? look.warning : look.textSecondary)
                HStack {
                    Menu("Directions") {
                        Button("Apple Maps") { MapsLink.apple(ci) }
                        Button("Google Maps") { MapsLink.google(ci) }
                    }
                    Spacer()
                    if mine {
                        Button("+15 min") { engine.updateCheckIn(ci, status: "active", eta: ci.eta.addingTimeInterval(900)) }
                        Button("I'm here") { engine.updateCheckIn(ci, status: "arrived") }
                        Button("End", role: .destructive) { engine.updateCheckIn(ci, status: "ended") }
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
            .padding(12)
            .lookCard(padding: 0)
            .padding(.horizontal, 10)
        }
    }
}

enum MapsLink {
    static func apple(_ ci: CheckIn) {
        if let u = URL(string: "https://maps.apple.com/?daddr=\(ci.lat),\(ci.lon)") { UIApplication.shared.open(u) }
    }
    static func google(_ ci: CheckIn) {
        let app = URL(string: "comgooglemaps://?daddr=\(ci.lat),\(ci.lon)&directionsmode=driving")!
        let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(ci.lat),\(ci.lon)")!
        UIApplication.shared.open(app) { ok in if !ok { UIApplication.shared.open(web) } }
    }
}
