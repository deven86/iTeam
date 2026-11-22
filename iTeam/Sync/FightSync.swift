import Foundation
import SwiftData

/// Fluffy Fight invitations and results travel through the chat like any other event (end-to-end encrypted).
/// The fight itself runs live over Game Center between the two phones.
extension EventApplier {
    func applyFight(_ p: GamePayload, _ e: Event, conv: Conversation) -> Result {
        let gid = p.id
        let existing = try? ctx.fetch(FetchDescriptor<GameMatch>(predicate: #Predicate { $0.id == gid })).first
        let who = e.from == me ? "You" : engine.name(of: e.from)
        let g: GameMatch
        if let existing { g = existing } else {
            guard p.action == "invite", e.from == p.xPlayer || e.from == p.oPlayer, p.xPlayer != p.oPlayer else { return .ignored }
            g = GameMatch(id: p.id)
            g.convID = conv.id; g.kind = "fight"; g.createdBy = e.from; g.xPlayer = p.xPlayer; g.oPlayer = p.oPlayer
            g.createdAt = e.at; g.stake = p.stake ?? ""; g.code = p.cell ?? 0
            ctx.insert(g)
        }
        guard g.involves(e.from), p.at >= g.updatedAt else { return .ignored }
        let other = e.from == g.xPlayer ? g.oPlayer : g.xPlayer
        let otherName = other == me ? "you" : engine.name(of: other)
        let stakeText = g.stake.isEmpty ? "" : " · loser takes “\(g.stake)”"
        var line = ""
        switch p.action {
        case "invite":
            line = "🥊 \(who) challenged \(otherName) to a Fluffy Fight\(stakeText)"
        case "accept":
            guard g.status == "invite", e.from != g.createdBy else { return .ignored }
            g.status = "playing"; line = "🥊 \(who) accepted the Fluffy Fight — enter the arena"
        case "decline":
            guard g.status == "invite" else { return .ignored }
            g.status = "declined"; line = "🥊 \(who) declined the Fluffy Fight"
        case "arena":
            guard g.status == "playing" || g.status == "invite" else { return .ignored }
            if g.status == "invite" && e.from != g.createdBy { g.status = "playing" }
            line = "🥊 \(who) entered the arena — join now!"
        case "result":
            guard g.status == "playing", let w = p.winner, g.involves(w) else { return .ignored }
            g.status = "won"; g.winner = w
            let loser = w == g.xPlayer ? g.oPlayer : g.xPlayer
            let wn = w == me ? "You" : engine.name(of: w)
            let ln = loser == me ? "you" : engine.name(of: loser)
            line = "🏆 \(wn) won the Fluffy Fight against \(ln)" + (g.stake.isEmpty ? "" : " — \(ln) takes “\(g.stake)”")
        default:
            return .ignored
        }
        g.updatedAt = p.at
        system(conv, line + " — tap to open", at: e.at, gameID: g.id)
        if e.from != me && g.involves(me) && ["invite", "arena", "result"].contains(p.action) {
            ctx.insert(ActivityItem(kind: .mention, text: line, convID: conv.id, actorID: e.from, date: e.at))
        }
        return .applied
    }
}

@MainActor
extension SyncEngine {
    func fightInvite(in conv: Conversation, opponent: String, stake: String) -> String {
        let id = "fight_" + UUID().uuidString
        let code = Int.random(in: 100_000...2_000_000_000)
        send(.game(GamePayload(id: id, kind: "fight", xPlayer: opponent, oPlayer: me, board: "", action: "invite", cell: code, at: .now,
                               stake: stake.isEmpty ? nil : stake)),
             in: conv, loud: true, preview: "🥊 \(myName) challenged you to a Fluffy Fight")
        if conv.isDemo, opponent.hasPrefix("demo_") { demoFight(id, as: opponent) }
        return id
    }

    func fightAct(_ g: GameMatch, _ action: String, winner: String? = nil) {
        guard let conv = conversation(g.convID) else { return }
        let preview: String? = switch action {
        case "accept": "🥊 \(myName) accepted your Fluffy Fight"
        case "arena": "🥊 \(myName) is in the arena — join the fight now!"
        case "result": "🏆 Fluffy Fight result"
        default: nil
        }
        send(.game(GamePayload(id: g.id, kind: "fight", xPlayer: g.xPlayer, oPlayer: g.oPlayer, board: "", action: action, cell: g.code, at: .now,
                               stake: g.stake.isEmpty ? nil : g.stake, winner: winner)),
             in: conv, loud: action != "decline", preview: preview)
    }

    /// Demo friend accepts at once; the fight against them is played against the computer.
    private func demoFight(_ id: String, as bot: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard let g = try? context.fetch(FetchDescriptor<GameMatch>(predicate: #Predicate { $0.id == id })).first else { return }
            let e = Event(id: UUID().uuidString, conv: g.convID, from: bot, at: .now,
                          body: .game(GamePayload(id: id, kind: "fight", xPlayer: g.xPlayer, oPlayer: g.oPlayer, board: "", action: "accept", cell: g.code, at: .now)))
            _ = EventApplier(engine: self).apply(e, local: false)
            save()
        }
    }

    /// Records a finished demo fight locally (the bot can't send events).
    func demoFightResult(_ g: GameMatch, winner: String) {
        let e = Event(id: UUID().uuidString, conv: g.convID, from: me, at: .now,
                      body: .game(GamePayload(id: g.id, kind: "fight", xPlayer: g.xPlayer, oPlayer: g.oPlayer, board: "", action: "result", cell: g.code, at: .now, winner: winner)))
        _ = EventApplier(engine: self).apply(e, local: true)
        save()
    }
}
