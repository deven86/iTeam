import Foundation
import SwiftData

/// Surveys (land, building, online, poll) and their responses. Details live in a Codable blob.
@Model final class SurveyRecord {
    @Attribute(.unique) var id: String
    /// "survey" or "response"
    var kind: String = "survey"
    var surveyID: String = ""
    var ownerID: String = ""
    var convID: String = ""
    var by: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false
    var data: Data = Data()
    init(id: String) { self.id = id }

    var survey: SurveyData {
        get { (try? JSONDecoder().decode(SurveyData.self, from: data)) ?? SurveyData() }
        set { data = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var response: SurveyResponse {
        get { (try? JSONDecoder().decode(SurveyResponse.self, from: data)) ?? SurveyResponse() }
        set { data = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

struct SurveyQuestion: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    /// text, number, choice, multi, rating, yesno, photo, video, location, date
    var type = "text"
    var text = ""
    var options: [String] = []
    var required = false
}

struct SurveyData: Codable, Equatable {
    var title = ""
    /// land, building, online, poll, other
    var type = "online"
    var about = ""
    var questions: [SurveyQuestion] = []
    var open = true
    var deadline: Date? = nil
}

struct SurveyAnswer: Codable, Hashable {
    var text = ""
    var number: Double? = nil
    var choices: [String] = []
    var files: [AttachmentRef] = []
    var lat: Double? = nil
    var lon: Double? = nil
    var date: Date? = nil
}

struct SurveyResponse: Codable, Equatable {
    /// Offline collection: who was surveyed (e.g. plot owner, resident).
    var respondent = ""
    var answers: [String: SurveyAnswer] = [:]
    var lat: Double? = nil
    var lon: Double? = nil
}

struct SurveyItem: Codable {
    var id: String
    var kind: String
    var surveyID: String
    var deleted: Bool
    var at: Date
    var data: Data
}

struct SurveyPayload: Codable { var items: [SurveyItem] }

enum SurveyKinds {
    static let types: [(String, String, String)] = [("land", "Land survey", "map"), ("building", "Building survey", "building.2"),
                                                    ("online", "Online survey", "globe"), ("poll", "Poll survey", "chart.bar"), ("other", "Other", "list.clipboard")]
    static let questionTypes: [(String, String)] = [("text", "Text"), ("number", "Number"), ("choice", "One choice"), ("multi", "Several choices"),
                                                    ("yesno", "Yes / No"), ("rating", "Rating 1–5"), ("photo", "Photos"), ("video", "Video"),
                                                    ("location", "GPS location"), ("date", "Date")]
    /// Ready-made questions for each survey type.
    static func template(_ type: String) -> [SurveyQuestion] {
        func q(_ t: String, _ k: String, _ o: [String] = [], _ r: Bool = false) -> SurveyQuestion { SurveyQuestion(type: k, text: t, options: o, required: r) }
        switch type {
        case "land": return [q("Survey / Gat / CTS no.", "text", [], true), q("Owner name", "text"), q("Area", "number"), q("Land use", "choice", ["Agricultural", "Residential", "Commercial", "Open", "Other"]),
                             q("Boundaries & access road", "text"), q("Encroachment seen?", "yesno"), q("GPS location", "location", [], true), q("Site photos", "photo"), q("Notes", "text")]
        case "building": return [q("Building / flat", "text", [], true), q("Floors", "number"), q("Structure condition", "rating"), q("Cracks / leakage", "multi", ["None", "Cracks", "Leakage", "Seepage", "Rusted steel"]),
                                 q("Occupancy", "choice", ["Owner", "Tenant", "Vacant"]), q("Photos", "photo"), q("Video walk-through", "video"), q("GPS location", "location"), q("Remarks", "text")]
        case "poll": return [q("Your choice", "choice", ["Option A", "Option B", "Option C"], true)]
        default: return [q("Your name", "text"), q("How satisfied are you?", "rating", [], true), q("Comments", "text")]
        }
    }
}
