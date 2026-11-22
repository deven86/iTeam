import Foundation
import SwiftData

extension EventApplier {
    func applyGame(_ p: GamePayload, _ e: Event, conv: Conversation?) -> Result {
        guard let conv else { return .needsConversation }
        let gid = p.id
        let existing = try? ctx.fetch(FetchDescriptor<GameMatch>(predicate: #Predicate { $0.id == gid })).first
        let who = e.from == me ? "You" : engine.name(of: e.from)
        let g: GameMatch
        if let existing { g = existing } else {
            guard p.action == "invite", e.from == p.xPlayer || e.from == p.oPlayer, p.xPlayer != p.oPlayer else { return .ignored }
            g = GameMatch(id: p.id)
            g.convID = conv.id; g.kind = p.kind; g.createdBy = e.from; g.xPlayer = p.xPlayer; g.oPlayer = p.oPlayer; g.createdAt = e.at
            ctx.insert(g)
        }
        guard g.involves(e.from), p.at >= g.updatedAt else { return .ignored }
        let other = e.from == g.xPlayer ? g.oPlayer : g.xPlayer
        var line = ""
        switch p.action {
        case "invite":
            line = "🎮 \(who) challenged \(other == me ? "you" : engine.name(of: other)) to X and O"
        case "accept":
            guard g.status == "invite", e.from != g.createdBy else { return .ignored }
            g.status = "playing"
            line = "🎮 \(who) accepted — \(g.turn == me ? "your" : engine.name(of: g.turn) + "'s") move"
        case "decline":
            guard g.status == "invite" else { return .ignored }
            g.status = "declined"; line = "🎮 \(who) declined the X and O game"
        case "move":
            guard g.status == "playing", let c = p.cell, (0..<9).contains(c), g.turn == e.from else { return .ignored }
            var b = g.cells
            guard b[c] == "-" else { return .ignored }
            b[c] = g.mark(e.from)
            g.board = String(b)
            if let w = GameMatch.winner(b) {
                g.status = "won"; g.winner = w == "X" ? g.xPlayer : g.oPlayer
                line = "🏆 \(who) won X and O against \(other == me ? "you" : engine.name(of: other))!"
            } else if !b.contains("-") {
                g.status = "draw"; line = "🤝 X and O ended in a draw"
            }
        case "resign":
            guard g.status == "playing" else { return .ignored }
            g.status = "won"; g.winner = other
            line = "🏳️ \(who) resigned — \(other == me ? "you win" : engine.name(of: other) + " wins")"
        default:
            return .ignored
        }
        g.updatedAt = p.at
        if !line.isEmpty { system(conv, line + " — tap to open", at: e.at, gameID: g.id) }
        if e.from != me && g.involves(me) && (p.action == "invite" || (p.action == "move" && g.turn == me && g.status == "playing")) {
            ctx.insert(ActivityItem(kind: .mention, text: p.action == "invite" ? line : "🎮 Your move in X and O with \(who)", convID: conv.id, actorID: e.from, date: e.at))
        }
        return .applied
    }
}

@MainActor
extension SyncEngine {
    func gameInvite(in conv: Conversation, opponent: String) -> String {
        let id = "xo_" + UUID().uuidString
        // The person challenged plays X and starts — a friendly gesture.
        send(.game(GamePayload(id: id, kind: "xo", xPlayer: opponent, oPlayer: me, board: "---------", action: "invite", at: .now)),
             in: conv, loud: true, preview: "🎮 \(myName) challenged you to X and O")
        if conv.isDemo, opponent.hasPrefix("demo_") { demoGame(id, as: opponent, action: "accept") }
        return id
    }

    func gameAct(_ g: GameMatch, _ action: String, cell: Int? = nil) {
        guard let conv = conversation(g.convID) else { return }
        send(.game(GamePayload(id: g.id, kind: g.kind, xPlayer: g.xPlayer, oPlayer: g.oPlayer, board: g.board, action: action, cell: cell, at: .now)),
             in: conv, loud: true, preview: action == "move" ? (g.status == "playing" ? "🎮 \(myName) played — your move" : "🎮 X and O: game over") : action == "accept" ? "🎮 \(myName) accepted — X and O" : nil)
        if conv.isDemo, let bot = [g.xPlayer, g.oPlayer].first(where: { $0.hasPrefix("demo_") }), g.status == "playing", g.turn == bot {
            demoGame(g.id, as: bot, action: "move")
        }
    }

    /// Demo friend: accepts and plays a sensible move after a moment.
    private func demoGame(_ id: String, as bot: String, action: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard let g = try? context.fetch(FetchDescriptor<GameMatch>(predicate: #Predicate { $0.id == id })).first else { return }
            var cell: Int?
            if action == "move" {
                guard g.status == "playing", g.turn == bot else { return }
                cell = Self.botMove(g.cells, me: g.mark(bot))
            }
            let e = Event(id: UUID().uuidString, conv: g.convID, from: bot, at: .now,
                          body: .game(GamePayload(id: id, kind: "xo", xPlayer: g.xPlayer, oPlayer: g.oPlayer, board: g.board, action: action, cell: cell, at: .now)))
            _ = EventApplier(engine: self).apply(e, local: false)
            save()
            if action == "accept", g.turn == bot { demoGame(id, as: bot, action: "move") }
        }
    }

    static func botMove(_ b: [Character], me: Character) -> Int? {
        let them: Character = me == "X" ? "O" : "X"
        let free = b.indices.filter { b[$0] == "-" }
        for who in [me, them] {
            for i in free { var t = b; t[i] = who; if GameMatch.winner(t) == who { return i } }
        }
        if free.contains(4) { return 4 }
        return [0, 2, 6, 8].filter(free.contains).randomElement() ?? free.randomElement()
    }
}
