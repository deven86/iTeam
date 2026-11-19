import Foundation
import AVFoundation
import UIKit

// MARK: - Voice notes

/// Records a voice note as AAC (.m4a) — small enough to send like any attachment.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    static let maxSeconds: TimeInterval = 300

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
                                           AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: Self.maxSeconds) else { return false }
            recorder = r
            self.url = url
            recording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    self.elapsed = r.currentTime
                    r.updateMeters()
                    self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
                    if !r.isRecording && self.recording { self.recording = false }
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Stops and returns the file and its length, or nil if cancelled or too short.
    func stop(keep: Bool) -> (URL, TimeInterval)? {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        recording = false
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard keep, let url, duration >= 0.7 else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return (url, max(duration, elapsed))
    }
}

/// Plays one voice note at a time.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    @Published private(set) var playingID: String?
    @Published private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(id: String, url: URL) {
        if playingID == id { stop(); return }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingID = id
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.player, p.duration > 0 else { return }
                    self.progress = p.currentTime / p.duration
                }
            }
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingID = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Short videos

enum VideoPrep {
    static let maxSeconds: Double = 30

    /// Trims to the first 30 seconds, re-encodes to 720p and returns a ready-to-send attachment.
    static func prepare(_ source: URL) async throws -> Attachments.Prepared {
        let asset = AVURLAsset(url: source)
        let total = try await asset.load(.duration).seconds
        let length = min(total, maxSeconds)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720)
                ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw Attachments.Failure.unreadable
        }
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: out, as: .mp4)
        defer { try? FileManager.default.removeItem(at: out) }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        var thumb: Data?
        var size = CGSize(width: 16, height: 9)
        if let cg = try? await gen.image(at: .zero).image {
            let img = UIImage(cgImage: cg)
            thumb = img.jpegData(compressionQuality: 0.6)
            size = img.size
        }
        let data = try Data(contentsOf: out)
        var p = try Attachments.prepare(data, name: "Video.mp4", mime: "video/mp4", kind: "video")
        p.ref.thumb = thumb
        p.ref.width = Double(size.width)
        p.ref.height = Double(size.height)
        p.ref.duration = length
        return p
    }
}

extension Attachments {
    static func prepareVoice(_ url: URL, duration: TimeInterval) throws -> Prepared {
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        var p = try prepare(data, name: "Voice note.m4a", mime: "audio/mp4", kind: "audio")
        p.ref.duration = duration
        return p
    }
}

enum Clock {
    static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
