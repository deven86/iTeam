import Foundation
import SwiftData

struct MeetingPoll: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var question: String = ""
    var options: [String] = ["Yes", "No"]
}

/// A meeting in a chat (direct or group), optionally attached to a task.
@Model final class Meeting {
    @Attribute(.unique) var id: String
    var convID: String = ""
    var taskID: String = ""
    var createdBy: String = ""
    var title: String = ""
    var online: Bool = false
    var link: String = ""
    var place: String = ""
    var start: Date = Date.now
    var end: Date = Date.now
    var notes: String = ""
    var minutes: String = ""
    /// "scheduled", "done", "cancelled"
    var status: String = "scheduled"
    var deleted: Bool = false
    var updatedAt: Date = Date.now
    var agendaData: Data = Data()
    var expectedData: Data = Data()
    var attendedData: Data = Data()
    var adminsData: Data = Data()
    var pollsData: Data = Data()
    var votesData: Data = Data()
    var filesData: Data = Data()

    init(id: String) { self.id = id }

    private static func get<T: Decodable>(_ d: Data, _ fallback: T) -> T { (try? JSONDecoder().decode(T.self, from: d)) ?? fallback }
    private static func put<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data() }

    var agenda: [String] { get { Self.get(agendaData, []) } set { agendaData = Self.put(newValue) } }
    var expected: [String] { get { Self.get(expectedData, []) } set { expectedData = Self.put(newValue) } }
    var attended: [String] { get { Self.get(attendedData, []) } set { attendedData = Self.put(newValue) } }
    var admins: [String] { get { Self.get(adminsData, []) } set { adminsData = Self.put(newValue) } }
    var polls: [MeetingPoll] { get { Self.get(pollsData, []) } set { pollsData = Self.put(newValue) } }
    /// pollID → (userID → option index)
    var votes: [String: [String: Int]] { get { Self.get(votesData, [:]) } set { votesData = Self.put(newValue) } }
    var files: [AttachmentRef] { get { Self.get(filesData, []) } set { filesData = Self.put(newValue) } }

    func isAdmin(_ user: String) -> Bool { user == createdBy || admins.contains(user) }
}

struct MeetingPayload: Codable {
    var id: String
    var taskID: String
    var title: String
    var online: Bool
    var link: String
    var place: String
    var start: Date
    var end: Date
    var notes: String
    var minutes: String
    var status: String
    var agenda: [String]
    var expected: [String]
    var attended: [String]
    var admins: [String]
    var polls: [MeetingPoll]
    var files: [AttachmentRef]
    var deleted: Bool
    var at: Date

    init(_ m: Meeting) {
        id = m.id; taskID = m.taskID; title = m.title; online = m.online; link = m.link; place = m.place
        start = m.start; end = m.end; notes = m.notes; minutes = m.minutes; status = m.status
        agenda = m.agenda; expected = m.expected; attended = m.attended; admins = m.admins; polls = m.polls; files = m.files
        deleted = m.deleted; at = .now
    }
}
