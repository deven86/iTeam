import Foundation
import SwiftData

/// A two-player game inside a chat (X and O). Free for everyone.
@Model final class GameMatch {
    @Attribute(.unique) var id: String
    var convID: String = ""
    var kind: String = "xo"
    var createdBy: String = ""
    var xPlayer: String = ""
    var oPlayer: String = ""
    /// 9 characters: "X", "O" or "-".
    var board: String = "---------"
    /// "invite", "playing", "won", "draw", "declined"
    var status: String = "invite"
    var winner: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.distantPast
    var deleted: Bool = false

    init(id: String) { self.id = id }

    var cells: [Character] { Array(board) }
    var moves: Int { cells.filter { $0 != "-" }.count }
    /// X always starts.
    var turn: String { moves % 2 == 0 ? xPlayer : oPlayer }
    func mark(_ user: String) -> Character { user == xPlayer ? "X" : "O" }
    func involves(_ u: String) -> Bool { u == xPlayer || u == oPlayer }

    static let lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]
    static func winner(_ b: [Character]) -> Character? {
        for l in lines where b[l[0]] != "-" && b[l[0]] == b[l[1]] && b[l[1]] == b[l[2]] { return b[l[0]] }
        return nil
    }
    var winningLine: [Int]? { Self.lines.first { l in cells[l[0]] != "-" && cells[l[0]] == cells[l[1]] && cells[l[1]] == cells[l[2]] } }
}

struct GamePayload: Codable {
    var id: String
    var kind: String
    var xPlayer: String
    var oPlayer: String
    var board: String
    /// "invite", "accept", "decline", "move", "resign", "rematch"
    var action: String
    var cell: Int? = nil
    var at: Date
}
