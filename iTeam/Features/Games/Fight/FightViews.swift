import SwiftUI
import SwiftData
import SpriteKit

/// Opens a game from a chat line: X and O or Fluffy Fight.
struct GameOpenView: View {
    let gameID: String
    @Query private var found: [GameMatch]
    init(gameID: String) {
        self.gameID = gameID
        _found = Query(filter: #Predicate<GameMatch> { $0.id == gameID })
    }
    var body: some View {
        if found.first?.kind == "fight" { FightLobbyView(gameID: gameID) } else { XOBoardView(gameID: gameID) }
    }
}

// MARK: - Challenge from a chat

struct FightInviteView: View {
    let convID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var opponent = ""
    @State private var stake = ""
    @State private var practice = false
    @State private var sent: String?

    private var conv: Conversation? { engine.conversation(convID) }
    private var others: [MemberInfo] { (conv?.members ?? []).filter { $0.id != engine.me } }
    private let ideas = ["Next task on the list", "Tomorrow's 9 am slot", "Writing the minutes", "The tea run"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: -18) {
                        ForEach(FightCharacter.all.prefix(6)) { c in
                            if let img = c.image("idle") { Image(uiImage: img).resizable().scaledToFit().frame(height: 64) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Text("A cute, real-time fight between two phones over Game Center. Knock-outs are stars and sparkles — never blood.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if others.count > 1 {
                    Picker("Challenge", selection: $opponent) {
                        ForEach(others, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    TextField("Loser takes… (optional)", text: $stake)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(ideas, id: \.self) { i in Button(i) { stake = i }.buttonStyle(.bordered).font(.caption) } }
                    }
                } header: { Text("Fight for something") } footer: {
                    Text("A task or a time slot only — never a person. The result is posted in this chat.")
                }
                Section {
                    Button { send() } label: { Label("Send challenge", systemImage: "figure.boxing") }
                        .disabled(opponent.isEmpty)
                    Button { practice = true } label: { Label("Practice against the computer", systemImage: "cpu") }
                }
            }
            .navigationTitle("Fluffy Fight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { if opponent.isEmpty { opponent = others.first?.id ?? "" } }
            .fullScreenCover(isPresented: $practice) { FightArenaView(game: nil, opponentName: "Computer") }
            .sheet(item: Binding(get: { sent.map { IDBox(id: $0) } }, set: { sent = $0?.id })) { b in FightLobbyView(gameID: b.id) }
        }
    }

    private func send() {
        guard let conv else { return }
        sent = engine.fightInvite(in: conv, opponent: opponent, stake: stake.trimmingCharacters(in: .whitespacesAndNewlines))
        Haptics.big()
    }
}

private struct IDBox: Identifiable { let id: String }

// MARK: - Lobby (from the chat line)

struct FightLobbyView: View {
    let gameID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Query private var found: [GameMatch]
    @State private var arena = false

    init(gameID: String) {
        self.gameID = gameID
        _found = Query(filter: #Predicate<GameMatch> { $0.id == gameID })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let g = found.first { content(g) } else { ContentUnavailableView("Fight not found", systemImage: "figure.boxing") }
            }
            .navigationTitle("Fluffy Fight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    @ViewBuilder private func content(_ g: GameMatch) -> some View {
        let me = engine.me
        let other = g.xPlayer == me ? g.oPlayer : g.xPlayer
        let otherName = engine.name(of: other)
        List {
            Section {
                HStack {
                    VStack { Text("You").font(.headline); Text(engine.myName).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
                    Text("VS").font(.title.weight(.black)).foregroundStyle(.purple)
                    VStack { Text(otherName).font(.headline); Text(g.involves(me) ? "Opponent" : "").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
                }
                if !g.stake.isEmpty { Label("Loser takes “\(g.stake)”", systemImage: "checklist").font(.subheadline) }
            }
            Section {
                switch g.status {
                case "invite" where g.createdBy != me:
                    Button { engine.fightAct(g, "accept"); Haptics.big() } label: { Label("Accept the challenge", systemImage: "hand.thumbsup.fill") }
                    Button(role: .destructive) { engine.fightAct(g, "decline") } label: { Label("Not now", systemImage: "xmark") }
                case "invite", "playing":
                    Button { arena = true } label: { Label("Enter the arena", systemImage: "figure.boxing") }
                    Text(g.status == "invite" ? "Waiting for \(otherName) to accept. You can already wait in the arena." :
                            "Both of you tap Enter the arena — Game Center connects your phones.")
                        .font(.footnote).foregroundStyle(.secondary)
                case "won":
                    Label(g.winner == me ? "You won! 🏆" : "\(engine.name(of: g.winner)) won", systemImage: "trophy.fill").font(.headline)
                    if let conv = engine.conversation(g.convID) {
                        Button { _ = engine.fightInvite(in: conv, opponent: other, stake: g.stake); dismiss() } label: { Label("Rematch", systemImage: "arrow.clockwise") }
                    }
                default:
                    Text("This fight was declined.").foregroundStyle(.secondary)
                }
            }
            Section {
                Button { FightNet.showLeaderboard() } label: { Label("Game Center leaderboard", systemImage: "list.number") }
            }
        }
        .fullScreenCover(isPresented: $arena) { FightArenaView(game: g, opponentName: otherName) }
    }
}

// MARK: - Character select + arena

struct FightArenaView: View {
    /// nil = practice against the computer.
    let game: GameMatch?
    let opponentName: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var net = FightNet.shared
    @State private var pick = FightCharacter.favourite
    @State private var phase: Phase = .pick
    @State private var scene: FightScene?
    @State private var status = ""
    @State private var opponentChar = ""
    @State private var opponentID = ""
    @State private var result: Bool?? = nil

    enum Phase { case pick, waiting, fighting, done }

    private var vsComputer: Bool {
        guard let game else { return true }
        let other = game.xPlayer == engine.me ? game.oPlayer : game.xPlayer
        return other.hasPrefix("demo_")
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.86, green: 0.84, blue: 1), Color(red: 1, green: 0.9, blue: 0.94)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            switch phase {
            case .pick: picker
            case .waiting: waiting
            case .fighting, .done: arena
            }
        }
        .onDisappear { if !vsComputer { FightNet.shared.cancel() } }
    }

    // Character select

    private var picker: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Text("Choose your fighter").font(.headline)
                Spacer()
                Button("Close") {}.hidden()
            }.padding(.horizontal)
            let c = FightCharacter.find(pick)
            if let img = c.image("idle") { Image(uiImage: img).resizable().scaledToFit().frame(height: 190).id(pick).transition(.scale) }
            Text(c.name).font(.title2.weight(.heavy))
            HStack(spacing: 14) {
                stat("Speed", c.speed); stat("Power", c.power); stat("Guard", c.guardStrength)
            }
            Text("Kick: \(c.kick) · Shield: \(c.shield) · Special: \(c.punch)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(FightCharacter.all) { f in
                        Button { withAnimation(.spring) { pick = f.id }; Haptics.tap() } label: {
                            VStack(spacing: 2) {
                                if let img = f.image("idle") { Image(uiImage: img).resizable().scaledToFit().frame(height: 62) }
                                Text(f.name).font(.caption2).lineLimit(1)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 14).fill(pick == f.id ? Color.purple.opacity(0.18) : Color.white.opacity(0.55)))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(pick == f.id ? Color.purple : .clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
            Button { start() } label: {
                Text(vsComputer ? "Fight!" : "Find \(opponentName)").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent).tint(.purple).padding(.horizontal)
            if case .failed(let e) = net.auth { Text("Game Center: \(e)").font(.caption).foregroundStyle(.red) }
            if net.auth == .signedOut { Text("Sign in to Game Center in Settings to fight friends. You can still practise.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical)
        .onAppear { if !vsComputer { net.authenticate() } }
    }

    private func stat(_ t: String, _ v: CGFloat) -> some View {
        VStack(spacing: 3) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Gauge(value: Double(v), in: 0.7...1.3) {}.gaugeStyle(.accessoryLinearCapacity).tint(.purple).frame(width: 70)
        }
    }

    private var waiting: some View {
        VStack(spacing: 18) {
            ProgressView().scaleEffect(1.4)
            Text(status).multilineTextAlignment(.center).padding(.horizontal)
            Button("Cancel") { FightNet.shared.cancel(); phase = .pick }.buttonStyle(.bordered)
            Button("Practice against the computer instead") { FightNet.shared.cancel(); startCPU() }.font(.footnote)
        }
    }

    private func start() {
        FightCharacter.favourite = pick
        if vsComputer { startCPU(); return }
        guard let game else { return }
        guard net.auth == .signedIn else {
            net.authenticate()
            status = "Signing in to Game Center…"
            return
        }
        phase = .waiting
        status = "Waiting for \(opponentName) to enter the arena…\nThey just got a notification."
        engine.fightAct(game, "arena")
        Task {
            do {
                _ = try await FightNet.shared.find(code: game.code)
                await MainActor.run { connected() }
            } catch {
                await MainActor.run { status = "Couldn't connect: \(error.localizedDescription)"; phase = .pick }
            }
        }
    }

    private func startCPU() {
        let foe = FightCharacter.all.filter { $0.id != pick }.randomElement() ?? FightCharacter.all[1]
        let s = FightScene(mode: .cpu, mine: FightCharacter.find(pick), theirs: foe, myName: "You", theirName: opponentName)
        wire(s)
        scene = s
        phase = .fighting
        s.begin()
    }

    /// Both phones say hello (who I am + my fighter); the host then starts the round.
    private func connected() {
        let net = FightNet.shared
        status = "Connected! Getting ready…"
        net.onMessage = { m in
            if m.t == "hi" {
                opponentChar = m.c ?? "bee"; opponentID = m.u ?? ""
                if scene == nil {
                    let s = FightScene(mode: .online, mine: FightCharacter.find(pick), theirs: FightCharacter.find(opponentChar),
                                       myName: "You", theirName: m.n ?? opponentName)
                    s.isHost = net.isHost
                    s.send = { msg, reliable in net.send(msg, reliable: reliable) }
                    wire(s)
                    scene = s
                    phase = .fighting
                    net.send(FightMsg(t: "hi", u: engine.me, c: pick, n: engine.myName), reliable: true)
                }
            } else if m.t == "go" {
                scene?.begin()
            } else {
                if m.t == "s", let s = scene, !s.started { s.begin() }
                scene?.receive(m)
            }
        }
        net.onDisconnect = {
            guard phase == .fighting, scene?.finished == false else { return }
            status = "\(opponentName) left the fight — you win by default."
            report(iWon: true)
            phase = .done
        }
        // Handshake: keep saying hello (and, as host, "go") until the other phone answers — the first
        // messages can arrive before the other side is listening.
        Task { @MainActor in
            var goSent = 0
            for _ in 0..<40 {
                if phase == .done || FightNet.shared.match == nil { return }
                net.send(FightMsg(t: "hi", u: engine.me, c: pick, n: engine.myName), reliable: true)
                if let s = scene {
                    if net.isHost && goSent < 4 { net.send(FightMsg(t: "go"), reliable: true); goSent += 1; s.begin() }
                    if s.started && goSent >= 4 { return }
                    if !net.isHost && s.started { return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            if scene == nil { status = "Couldn't reach \(opponentName). Ask them to open the fight again." }
        }
    }

    private func wire(_ s: FightScene) {
        s.onHaptic = { big in big ? Haptics.big() : Haptics.thump() }
        s.onEnd = { iWon in
            report(iWon: iWon)
            phase = .done
        }
    }

    private func report(iWon: Bool?) {
        result = .some(iWon)
        if iWon == true { FightNet.recordWin() }
        guard let game, let iWon, game.status != "won" else { return }
        let other = game.xPlayer == engine.me ? game.oPlayer : game.xPlayer
        engine.fightAct(game, "result", winner: iWon ? engine.me : other)
    }

    // Arena + controls

    private var arena: some View {
        VStack(spacing: 10) {
            HStack {
                Button { FightNet.shared.cancel(); dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                Spacer()
                Text("Fluffy Fight").font(.headline)
                Spacer()
                Image(systemName: "xmark.circle.fill").font(.title2).hidden()
            }.padding(.horizontal)
            if let scene {
                SpriteView(scene: scene, preferredFramesPerSecond: 60)
                    .aspectRatio(1000.0 / 700.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 8)
            }
            if phase == .done {
                VStack(spacing: 10) {
                    Text(resultText).font(.title3.weight(.heavy))
                    if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    HStack {
                        Button("Fight again") { scene = nil; phase = .pick; FightNet.shared.cancel() }.buttonStyle(.glassProminent).tint(.purple)
                        Button("Done") { FightNet.shared.cancel(); dismiss() }.buttonStyle(.glass)
                    }
                }.padding()
            } else {
                controls
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var resultText: String {
        switch result {
        case .some(.some(true)): "You win! 🏆"
        case .some(.some(false)): "\(opponentName) wins — so close!"
        case .some(.none): "Double flop — a draw!"
        default: ""
        }
    }

    private var controls: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 10) {
                hold("arrow.left") { scene?.left = $0 }
                hold("arrow.right") { scene?.right = $0 }
            }
            Spacer()
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    tap("Jump", "arrow.up", .teal) { scene?.jump() }
                    tap("Special", "sparkles", .purple) { scene?.special() }
                }
                HStack(spacing: 10) {
                    tap("Punch", "hand.raised.fill", .pink) { scene?.punch() }
                    tap("Kick", "figure.kickboxing", .orange) { scene?.kick() }
                    hold("shield.fill", label: "Block") { scene?.blockHeld = $0 }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func tap(_ label: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon).font(.title2); Text(label).font(.caption2.weight(.bold)) }
                .foregroundStyle(.white).frame(width: 66, height: 66)
                .background(Circle().fill(color.gradient))
        }.buttonStyle(.plain)
    }

    private func hold(_ icon: String, label: String? = nil, _ set: @escaping (Bool) -> Void) -> some View {
        HoldButton(icon: icon, label: label, onChange: set)
    }
}

/// A button that reports press and release (for walking and blocking).
private struct HoldButton: View {
    let icon: String
    let label: String?
    let onChange: (Bool) -> Void
    @State private var down = false
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.title)
            if let label { Text(label).font(.caption2.weight(.bold)) }
        }
        .foregroundStyle(.white)
        .frame(width: 70, height: 70)
        .background(Circle().fill((label == nil ? Color.indigo : Color.blue).gradient).opacity(down ? 0.7 : 1))
        .scaleEffect(down ? 0.92 : 1)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !down { down = true; onChange(true) } }
            .onEnded { _ in down = false; onChange(false) })
    }
}
