import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import Charts

// Glue that lets the Mindfulness module (ported from iLife's Mind section) run inside iTeam.

// MARK: - Data

@Model final class MeditationLog {
    var date: Date = Date.now
    var sessionID: String = ""
    var title: String = ""
    var category: String = ""
    var minutes: Double = 0
    var language: String = "en"
    var soundscape: String = ""
    var moodBefore: Int = 0          // 1…5, 0 = not given
    var moodAfter: Int = 0
    var completed: Bool = true
    var note: String = ""
    init(date: Date = .now, sessionID: String, title: String, minutes: Double) {
        self.date = date; self.sessionID = sessionID; self.title = title; self.minutes = minutes
    }
}

/// A session the AI wrote for you and you chose to keep.
@Model final class CustomMeditation {
    var uid: String = UUID().uuidString
    var title: String = ""
    var language: String = "en"
    var created: Date = Date.now
    var stepsJSON: String = ""
    init(title: String, language: String, stepsJSON: String) { self.title = title; self.language = language; self.stepsJSON = stepsJSON }

    var steps: [CustomStep] { (try? JSONDecoder().decode([CustomStep].self, from: Data(stepsJSON.utf8))) ?? [] }
    var script: MeditationScript { MeditationLibrary.custom(id: "custom-" + uid, title: title, steps: steps, lang: MLang(rawValue: language) ?? .english) }
}

// MARK: - Home

/// The Mindfulness tab.
struct MindHomeView: View {
    @ObservedObject private var store = Store.shared
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                MindSection()
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            .lookScreen()
            .navigationTitle("Mindfulness")
        }
    }
}

enum MindStats {
    static func streak(_ dates: [Date], now: Date = .now) -> Int {
        let cal = Calendar.current
        let days = Set(dates.map { cal.startOfDay(for: $0) })
        var d = cal.startOfDay(for: now)
        if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        var n = 0
        while days.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        return n
    }
}

// MARK: - AI

@MainActor
enum MindAI {
    struct MeditationAI: Codable { var title: String; var steps: [CustomStep] }

    static func makeMeditation(feeling: String, minutes: Int, language: MLang, context: String) async throws -> MeditationAI {
        let langName = language == .english ? "simple, warm Indian English" : "simple, warm Hindi in Devanagari script"
        let system = """
        You write guided meditation scripts that an iPhone voice will read aloud, slowly, in \(langName).
        Return ONLY one JSON object: {"title": "short title", "steps": [{"say": "one or two calm sentences", "pauseAfter": seconds of silence after}]}.
        Total length should be about \(minutes) minutes: roughly 13 characters of text per second of speech, plus all pauseAfter values.
        Structure: settle and close the eyes; a few slow breaths with counts; the main practice tailored to how they feel; a gentle return; open the eyes.
        Use pauses of 5-40 seconds; longer pauses in the middle. Short sentences. No emojis, no stage directions, no headings, no music cues.
        Never mention medical treatment or diagnose anything.
        """
        let prompt = "How I feel / what I need: \(feeling.isEmpty ? "just a calm reset" : feeling)\n\nContext: \(context)"
        let reply = try await AIService.complete(prompt, instructions: system)
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"), s < e,
              let out = try? JSONDecoder().decode(MeditationAI.self, from: Data(String(reply[s...e]).utf8)) else { throw AIError.empty }
        return out
    }
}

// MARK: - Keychain, files, music

enum KeychainStore {
    static func get(_ key: String) -> String {
        Keychain.get("mind." + key).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func set(_ value: String, for key: String) {
        if value.isEmpty { Keychain.delete("mind." + key) } else { _ = Keychain.set(Data(value.utf8), account: "mind." + key) }
    }
}

/// Picks an audio file with the system document picker.
@MainActor
enum MindFilePicker {
    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let done: (URL) -> Void
        init(_ done: @escaping (URL) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            done(url)
        }
    }
    private static var keep: Delegate?

    static func present(_ done: @escaping (URL) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        let d = Delegate(done)
        keep = d
        picker.delegate = d
        guard var top = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        top.present(picker, animated: true)
    }
}

/// Apple Music isn't offered in iTeam (it needs a separate Apple service); this keeps the shared engine code simple.
final class MusicController: ObservableObject {
    static let shared = MusicController()
    enum Status { case notDetermined, authorized }
    struct Playlist { let name: String }
    @Published var authorization: Status = .notDetermined
    var selectedPlaylist: Playlist? { nil }
    func requestAccess() async {}
    func startWorkoutMusic(force: Bool) async {}
    func pauseIfPlaying() {}
    func togglePlayPause() async {}
    func stop() {}
}

extension View {
    /// iLife's glass card, drawn with iTeam's look.
    func glassCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        lookCard(cornerRadius: cornerRadius, padding: padding)
    }
}

/// Mindful minutes for the last 14 days.
struct MindDaysChart: View {
    let values: [(Date, Double)]
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { _, v in
            BarMark(x: .value("Day", v.0, unit: .day), y: .value("Minutes", v.1))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x7ED6B2), Color(hex: 0x3B8D99)], startPoint: .top, endPoint: .bottom))
                .cornerRadius(4)
            RuleMark(y: .value("Goal", 10)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day()) } }
        .frame(height: 140)
    }
}
