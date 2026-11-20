import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// iTeam ⇄ iLife: export everything health-related to one file, import a file made by iLife (or iTeam).
@MainActor
enum HealthExchangeIO {
    static func export(_ engine: SyncEngine) throws -> URL {
        let ctx: ModelContext = engine.context
        var x = HealthExchange(source: "iTeam", person: engine.myName)
        x.addFitness(from: ctx)
        let profiles = ((try? ctx.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { !$0.deleted }))) ?? [])
        func person(_ id: String) -> String {
            guard let p = profiles.first(where: { $0.id == id }) else { return "Me" }
            return p.relation == "Me" || p.name == engine.myName ? "Me" : p.name
        }
        let meds = (try? ctx.fetch(FetchDescriptor<Medicine>(predicate: #Predicate { !$0.deleted }))) ?? []
        x.medicines = meds.filter { m in profiles.contains { $0.id == m.profileID } }.map { m in
            HealthExchange.ExMedicine(uid: m.id, person: person(m.profileID), name: m.name, strength: "", form: m.form, dose: m.dose,
                                      times: m.times, weekdays: [], start: m.startDate, end: m.endDate, instructions: m.instructions,
                                      doctor: "", notes: "", paused: !m.active)
        }
        let events = (try? ctx.fetch(FetchDescriptor<HealthEvent>(predicate: #Predicate { !$0.deleted }))) ?? []
        x.healthEvents = events.filter { e in profiles.contains { $0.id == e.profileID } }.map { e in
            HealthExchange.ExHealthEvent(uid: e.id, person: person(e.profileID), kind: HealthEventKind(rawValue: e.kind)?.title ?? "Other",
                                         title: e.title, date: e.date, endDate: nil, details: e.details, doctor: "", hospital: "", status: e.status)
        }
        return try x.write()
    }

    /// Returns a short summary of what was added.
    static func importFile(_ url: URL, engine: SyncEngine) throws -> String {
        let x = try HealthExchange.read(url)
        let ctx: ModelContext = engine.context
        var added = x.importFitness(into: ctx)

        var profiles = ((try? ctx.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { !$0.deleted }))) ?? [])
        func profile(for person: String) -> CareProfile? {
            let me = person == "Me" || person == engine.myName || person.isEmpty
            if let p = profiles.first(where: { me ? ($0.relation == "Me" || $0.name == engine.myName) : $0.name == person }) { return p }
            let id = engine.saveCareProfile(in: DemoChats.notesToSelf(engine), name: me ? engine.myName : person, relation: me ? "Me" : "Family",
                                            bloodGroup: "", allergies: "", conditions: "", emergencyContact: "", notes: "", avatar: nil)
            profiles = ((try? ctx.fetch(FetchDescriptor<CareProfile>(predicate: #Predicate { !$0.deleted }))) ?? [])
            return profiles.first { $0.id == id }
        }
        let haveMeds = Set(((try? ctx.fetch(FetchDescriptor<Medicine>())) ?? []).map(\.id))
        for m in x.medicines where !haveMeds.contains(m.uid) {
            guard let p = profile(for: m.person) else { continue }
            let note = [m.instructions, m.doctor.isEmpty ? "" : "Dr. " + m.doctor, m.notes].filter { !$0.isEmpty }.joined(separator: " · ")
            engine.saveMedicine(p, id: m.uid, name: [m.name, m.strength].filter { !$0.isEmpty }.joined(separator: " "), dose: m.dose, form: m.form,
                                times: m.times.isEmpty ? [540] : m.times, instructions: note, startDate: m.start, endDate: m.end, stock: nil, active: !m.paused)
            added += 1
        }
        let haveEvents = Set(((try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? []).map { "\($0.title)|\(Int($0.date.timeIntervalSince1970 / 3600))" })
        for e in x.healthEvents where !haveEvents.contains("\(e.title)|\(Int(e.date.timeIntervalSince1970 / 3600))") {
            guard let p = profile(for: e.person) else { continue }
            let kind: String = switch e.kind.lowercased() {
            case let k where k.contains("injur"): "injury"
            case let k where k.contains("surg") || k.contains("operation"): "surgery"
            case let k where k.contains("hospital"): "hospital"
            case let k where k.contains("ill") || k.contains("disease"): "illness"
            case let k where k.contains("check"): "checkup"
            default: "other"
            }
            let details = [e.details, e.doctor.isEmpty ? "" : "Dr. " + e.doctor, e.hospital].filter { !$0.isEmpty }.joined(separator: " · ")
            let recovered = e.status.lowercased().contains("recover") || e.status.lowercased().contains("heal")
            engine.saveHealthEvent(p, kind: kind, title: e.title, details: details, date: e.date, severity: 1,
                                   status: recovered ? "recovered" : "active", recovery: recovered ? 100 : 0)
            added += 1
        }
        engine.save()
        return "Added \(added) item(s) from \(x.source) — \(x.summary). Anything already here was skipped."
    }
}

/// Settings → iLife ⇄ iTeam
struct HealthExchangeView: View {
    @EnvironmentObject var engine: SyncEngine
    @State private var shareItems: ShareItems?
    @State private var importing = false
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                Button("Export to iLife", systemImage: "square.and.arrow.up") {
                    do { shareItems = ShareItems(items: [try HealthExchangeIO.export(engine)]) } catch { result = error.localizedDescription }
                }
                Button("Import from iLife", systemImage: "square.and.arrow.down") { importing = true }
                if let result { Text(result).font(.callout) }
            } footer: {
                Text("Workouts, plans, meals, water, body measurements, supplements, meditation, medicines and health events move between iLife and iTeam in one file. Export here → save to Files or AirDrop → in iLife tap Import (and the other way round). Nothing already present is duplicated.")
            }
        }
        .navigationTitle("iLife ⇄ iTeam")
        .shareSheet($shareItems)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            switch r {
            case .success(let url):
                do { result = try HealthExchangeIO.importFile(url, engine: engine) } catch { result = "Couldn't read that file. Export it again from iLife and retry." }
            case .failure(let e): result = e.localizedDescription
            }
        }
    }
}
