import Foundation
import MediaPlayer
import SwiftData

/// 🎵 Now Playing: shares the Apple Music song you're playing with people you chat with — only when
/// turned on in Settings → Privacy. iPhone lets apps see Apple Music only (not Spotify / YouTube Music),
/// and only while iTeam is open or refreshing in the background.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()
    private var observing = false
    private var lastSent = ""
    private var lastSentAt = Date.distantPast

    var enabled: Bool { UserDefaults.standard.bool(forKey: "privacy.nowPlaying") }

    func start() {
        guard enabled else { stopSharing(); return }
        MPMediaLibrary.requestAuthorization { _ in Task { @MainActor in self.observe() } }
    }

    private func observe() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        if !observing {
            observing = true
            player.beginGeneratingPlaybackNotifications()
            for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
                NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { _ in
                    Task { @MainActor in NowPlaying.shared.check() }
                }
            }
        }
        check()
    }

    func check() {
        guard enabled else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        var text = ""
        if player.playbackState == .playing, let item = player.nowPlayingItem {
            text = [item.title, item.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        }
        guard text != lastSent, Date.now.timeIntervalSince(lastSentAt) > 45 || text.isEmpty else { return }
        lastSent = text
        lastSentAt = .now
        SyncEngine.shared.shareNowPlaying(text)
    }

    func stopSharing() {
        if !lastSent.isEmpty { SyncEngine.shared.shareNowPlaying("") }
        lastSent = ""
    }
}

extension SyncEngine {
    /// Sends to people I've chatted with in the last 30 days (not blocked, not demo).
    func shareNowPlaying(_ text: String) {
        let since = Date.now.addingTimeInterval(-30 * 86400)
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.kind == "direct" && !$0.left && $0.lastActivity > since }))) ?? []
        for c in convs where !c.isDemo {
            guard let peer = c.peerID, peer != me, contact(peer)?.blocked != true else { continue }
            send(.nowPlaying(text), in: c, loud: false)
        }
    }
}
