import Foundation
import GameKit
import UIKit

/// Game Center: sign-in, finding the friend from the chat (both phones use the same private match code),
/// and the live data channel during a fight. No server of ours.
final class FightNet: NSObject, ObservableObject, GKMatchDelegate {
    static let shared = FightNet()
    static let leaderboard = "iteam.fight.wins"

    enum Auth: Equatable { case unknown, signedIn, signedOut, failed(String) }
    @Published var auth: Auth = .unknown
    private(set) var match: GKMatch?
    var onMessage: ((FightMsg) -> Void)?
    var onDisconnect: (() -> Void)?

    var alias: String { GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName : "" }

    @MainActor func authenticate() {
        if GKLocalPlayer.local.isAuthenticated { auth = .signedIn; return }
        GKLocalPlayer.local.authenticateHandler = { [weak self] vc, error in
            DispatchQueue.main.async {
                if let vc { Self.present(vc); return }
                if GKLocalPlayer.local.isAuthenticated { self?.auth = .signedIn }
                else if let error { self?.auth = .failed(error.localizedDescription) }
                else { self?.auth = .signedOut }
            }
        }
    }

    @MainActor static func present(_ vc: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        top.present(vc, animated: true)
    }

    /// Finds the other player: with a chat code only the two people in that fight are matched; code 0 = anyone.
    func find(code: Int) async throws -> GKMatch {
        let r = GKMatchRequest()
        r.minPlayers = 2
        r.maxPlayers = 2
        if code != 0 { r.playerGroup = code }
        let m = try await GKMatchmaker.shared().findMatch(for: r)
        m.delegate = self
        match = m
        return m
    }

    func cancel() {
        GKMatchmaker.shared().cancel()
        match?.disconnect()
        match = nil
    }

    /// The host (smaller player ID) keeps time and starts the round.
    var isHost: Bool {
        guard let other = match?.players.first else { return false }
        return GKLocalPlayer.local.gamePlayerID < other.gamePlayerID
    }

    var opponentAlias: String { match?.players.first?.displayName ?? "Friend" }

    func send(_ m: FightMsg, reliable: Bool) {
        guard let match, let data = try? JSONEncoder().encode(m) else { return }
        try? match.sendData(toAllPlayers: data, with: reliable ? .reliable : .unreliable)
    }

    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        guard let m = try? JSONDecoder().decode(FightMsg.self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in self?.onMessage?(m) }
    }

    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        if state == .disconnected { DispatchQueue.main.async { [weak self] in self?.onDisconnect?() } }
    }

    /// Counts my wins and posts them to the Game Center leaderboard (quietly skipped if the board isn't set up yet).
    static func recordWin() {
        let wins = UserDefaults.standard.integer(forKey: "fight.wins") + 1
        UserDefaults.standard.set(wins, forKey: "fight.wins")
        guard GKLocalPlayer.local.isAuthenticated else { return }
        GKLeaderboard.submitScore(wins, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [leaderboard]) { _ in }
    }

    @MainActor static func showLeaderboard() {
        let vc = GKGameCenterViewController(leaderboardID: leaderboard, playerScope: .global, timeScope: .allTime)
        vc.gameCenterDelegate = Dismisser.shared
        present(vc)
    }

    final class Dismisser: NSObject, GKGameCenterControllerDelegate {
        static let shared = Dismisser()
        func gameCenterViewControllerDidFinish(_ vc: GKGameCenterViewController) { vc.dismiss(animated: true) }
    }
}
