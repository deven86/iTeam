import SwiftUI
import SwiftData

/// X and O games in one chat: start one, continue, or see results.
struct XOGamesView: View {
    let convID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var games: [GameMatch]
    @State private var open: GameMatch?

    init(convID: String) {
        self.convID = convID
        _games = Query(filter: #Predicate<GameMatch> { $0.convID == convID && !$0.deleted && $0.kind == "xo" }, sort: \GameMatch.createdAt, order: .reverse)
    }

    private var conv: Conversation? { engine.conversation(convID) }
    private var opponents: [MemberInfo] { (conv?.members ?? []).filter { $0.id != engine.me } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if opponents.count == 1, let o = opponents.first {
                        Button("Challenge \(o.name)", systemImage: "gamecontroller.fill") { start(o.id) }
                    } else {
                        Menu {
                            ForEach(opponents, id: \.id) { o in Button(o.name) { start(o.id) } }
                        } label: { Label("Challenge someone", systemImage: "gamecontroller.fill") }
                    }
                } footer: { Text("Free. You play turn by turn — each move arrives like a message, so you can be anywhere.") }
                if !games.isEmpty {
                    Section("Games") {
                        ForEach(games) { g in
                            Button { open = g } label: { row(g) }.foregroundStyle(Color.primary)
                        }
                    }
                    if engine.conversation(convID)?.isGroup == true { leaderboard }
                    Section("Score") {
                        let me = engine.me
                        let done = games.filter { $0.status == "won" || $0.status == "draw" }
                        LabeledContent("Won", value: "\(done.filter { $0.winner == me }.count)")
                        LabeledContent("Lost", value: "\(done.filter { $0.status == "won" && $0.winner != me && $0.involves(me) }.count)")
                        LabeledContent("Draws", value: "\(done.filter { $0.status == "draw" }.count)")
                    }
                }
            }
            .lookScreen()
            .navigationTitle("X and O")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $open) { g in XOBoardView(gameID: g.id) }
        }
    }

    private func start(_ opponent: String) {
        guard let conv else { return }
        let id = engine.gameInvite(in: conv, opponent: opponent)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            open = games.first { $0.id == id }
        }
    }

    private func row(_ g: GameMatch) -> some View {
        let other = g.xPlayer == engine.me ? g.oPlayer : g.xPlayer
        let state: String = switch g.status {
        case "invite": g.createdBy == engine.me ? "Waiting for them to accept" : "Challenge — tap to answer"
        case "playing": g.turn == engine.me ? "Your move" : "Their move"
        case "won": g.winner == engine.me ? "You won 🏆" : "\(engine.name(of: g.winner)) won"
        case "draw": "Draw"
        default: "Declined"
        }
        return HStack {
            Image(systemName: "number.square.fill").font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading) {
                Text("vs \(engine.name(of: other))").font(.headline)
                Text(state).font(.caption).foregroundStyle(g.status == "playing" && g.turn == engine.me ? .orange : .secondary)
            }
            Spacer()
            Text(g.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}


extension XOGamesView {
    /// Group leaderboard: wins in this group's X and O games.
    @ViewBuilder var leaderboard: some View {
        let done = games.filter { $0.status == "won" }
        let tally = Dictionary(grouping: done, by: \.winner).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        if !tally.isEmpty {
            Section("Leaderboard 🏆") {
                ForEach(Array(tally.enumerated()), id: \.offset) { idx, row in
                    HStack {
                        Text(["🥇", "🥈", "🥉"].indices.contains(idx) ? ["🥇", "🥈", "🥉"][idx] : "\(idx + 1).")
                        Text(row.0 == engine.me ? "You" : engine.name(of: row.0)).fontWeight(idx == 0 ? .bold : .regular)
                        Spacer()
                        Text("\(row.1) win\(row.1 == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct XOBoardView: View {
    let gameID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [GameMatch]

    init(gameID: String) {
        self.gameID = gameID
        _found = Query(filter: #Predicate<GameMatch> { $0.id == gameID })
    }

    var body: some View {
        NavigationStack {
            if let g = found.first { board(g) } else { ProgressView() }
        }
        .presentationDetents([.large])
    }

    private func board(_ g: GameMatch) -> some View {
        let me = engine.me
        let myTurn = g.status == "playing" && g.turn == me
        return VStack(spacing: 20) {
            HStack(spacing: 18) {
                player(g.xPlayer, "X", active: g.status == "playing" && g.turn == g.xPlayer)
                Text("vs").foregroundStyle(.secondary)
                player(g.oPlayer, "O", active: g.status == "playing" && g.turn == g.oPlayer)
            }
            Text(status(g)).font(.headline).foregroundStyle(myTurn ? .orange : .primary)
            grid(g, myTurn: myTurn)
            actions(g)
            Spacer()
        }
        .padding()
        .overlay { if g.status == "won" { WinnerBlast(title: g.winner == me ? "You win! 🏆" : "\(engine.name(of: g.winner)) wins! 🏆").id(g.id + g.winner) } }
        .lookScreen()
        .navigationTitle("X and O")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .refreshable { await engine.sync() }
        .task {
            // While the board is open, check for the other player's move every 2 seconds.
            while !Task.isCancelled {
                await engine.sync()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func grid(_ g: GameMatch, myTurn: Bool) -> some View {
        let win = Set(g.winningLine ?? [])
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(0..<9, id: \.self) { i in
                let c = g.cells[i]
                Button {
                    Haptics.thump()
                    GameSound.play("fx_pop")
                    engine.gameAct(g, "move", cell: i)
                } label: {
                    Text(c == "-" ? " " : String(c))
                        .font(.system(size: 54, weight: .heavy, design: .rounded))
                        .foregroundStyle(c == "X" ? Color(hex: 0xF0567A) : Color(hex: 0x5B8DEF))
                        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                        .background(win.contains(i) ? Color.yellow.opacity(0.35) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PressStyle())
                .disabled(!myTurn || c != "-")
            }
        }
        .frame(maxWidth: 380)
        .animation(.snappy, value: g.board)
        .onChange(of: g.status) { _, s in
            if s == "won" {
                if g.winner == engine.me { Haptics.success() } else { Haptics.warning(); GameSound.play("fx_lose") }
            }
        }
        .onChange(of: g.board) { old, new in if old != new { GameSound.play("fx_pop", volume: 0.6) } }
    }

    @ViewBuilder
    private func actions(_ g: GameMatch) -> some View {
        let me = engine.me
        if g.status == "invite" && g.createdBy != me {
            HStack {
                Button("Accept") { engine.gameAct(g, "accept") }.buttonStyle(.glassProminent)
                Button("Decline", role: .destructive) { engine.gameAct(g, "decline"); dismiss() }.buttonStyle(.glass)
            }
        } else if g.status == "playing" {
            Button("Resign", role: .destructive) { engine.gameAct(g, "resign") }.buttonStyle(.glass)
        } else if g.status == "won" || g.status == "draw", let conv = engine.conversation(g.convID) {
            Button("Rematch", systemImage: "arrow.counterclockwise") {
                _ = engine.gameInvite(in: conv, opponent: g.xPlayer == me ? g.oPlayer : g.xPlayer)
                dismiss()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func player(_ id: String, _ mark: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Text(mark).font(.title.bold()).foregroundStyle(mark == "X" ? Color(hex: 0xF0567A) : Color(hex: 0x5B8DEF))
            Text(id == engine.me ? "You" : engine.name(of: id)).font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(active ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private func status(_ g: GameMatch) -> String {
        let me = engine.me
        switch g.status {
        case "invite": return g.createdBy == me ? "Waiting for \(engine.name(of: g.xPlayer == me ? g.oPlayer : g.xPlayer)) to accept" : "You've been challenged!"
        case "playing": return g.turn == me ? "Your move" : "Waiting for \(engine.name(of: g.turn))…"
        case "won": return g.winner == me ? "You won! 🏆" : "\(engine.name(of: g.winner)) won"
        case "draw": return "It's a draw 🤝"
        default: return "Declined"
        }
    }
}
