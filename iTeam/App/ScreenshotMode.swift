import Foundation
import SwiftData

/// `-uiScreenshots -screen <name>`: App Store screenshots from sample data held in memory only.
/// No iCloud, no sync, no real data — used only by the screenshots workflow on the simulator.
@MainActor
enum ScreenshotMode {
    static let on = CommandLine.arguments.contains("-uiScreenshots")
    static var screen: String {
        guard let i = CommandLine.arguments.firstIndex(of: "-screen"), i + 1 < CommandLine.arguments.count else { return "chats" }
        return CommandLine.arguments[i + 1]
    }

    static func prepare(_ engine: SyncEngine) {
        guard on else { return }
        let d = UserDefaults.standard
        d.set(true, forKey: "onboard.tour.done")
        if E2E.identity == nil { _ = E2E.createIdentity() }
        engine.saveIdentity(id: "shot_me", name: "Devendra Jondhale", avatar: nil)
        let team = DemoChats.create(engine)
        AttDemo.create(engine)
        SurveyDemo.create(engine)
        let modules = ModuleRegistry.shared
        for m in [ModuleRegistry.legal, ModuleRegistry.survey, ModuleRegistry.financePro, ModuleRegistry.petCare] { modules.setOn(m, true) }
        if let legal = BizSpecs.spec("legal") { BizDemo.create(legal, engine: engine) }
        // A month of money for Finance.
        let cal = Calendar.current
        let sample: [(String, String, Double, String, Int)] = [("in", "Fees", 45000, "Consultation fees", 2), ("in", "Sales", 28000, "Project payment", 6),
                                                               ("out", "Rent", 18000, "Office rent", 1), ("out", "Salary & wages", 22000, "Staff salary", 3),
                                                               ("out", "Electricity", 2140, "Electricity bill", 5), ("out", "Fuel & travel", 3600, "Site visits", 7),
                                                               ("out", "Office supplies", 1250, "Stationery", 9), ("in", "Fees", 12000, "Retainer", 10)]
        for s in sample {
            var fd = FinData(); fd.title = s.3; fd.mode = s.0 == "in" ? "UPI" : "Bank"
            engine.finSave(nil, book: "personal", date: cal.date(byAdding: .day, value: -s.4, to: .now) ?? .now, amount: s.2, direction: s.0,
                           status: "paid", category: s.1, data: fd)
        }
        var due = FinData(); due.title = "Office rent — December"; due.repeatRule = "monthly"
        engine.finSave(nil, book: "personal", date: cal.date(byAdding: .day, value: 4, to: .now) ?? .now, amount: 18000, direction: "out", status: "due", category: "Rent", data: due)
        engine.save()
        let router = Router.shared
        switch screen {
        case "chat": router.show(conversation: team.id)
        case "tasks": router.go(.tasks)
        case "attendance": router.go(.attendance)
        case "finance": router.go(.finance)
        case "legal": router.go(.legal)
        case "survey": router.go(.survey)
        case "hub": router.go(.hub)
        default: router.go(.chats)
        }
    }
}
