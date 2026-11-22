import SwiftUI
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI in iTeam, with no server and no cost to us:
///  • Apple Intelligence on-device model — free, private, no key (iPhone 15 Pro / M-series iPad and newer).
///  • Or the user's own OpenAI, Claude or Gemini key — stored only in their iCloud Keychain, sent only to that company.
/// Every use is switched on or off by the user in Settings → AI.
enum AIProvider: String, CaseIterable, Identifiable {
    case apple, openai, anthropic, gemini
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple Intelligence (free, on-device)"
        case .openai: "OpenAI (ChatGPT)"
        case .anthropic: "Anthropic (Claude)"
        case .gemini: "Google Gemini"
        }
    }
    var short: String {
        switch self {
        case .apple: "Apple"
        case .openai: "OpenAI"
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        }
    }
    var needsKey: Bool { self != .apple }
    var keyHint: String {
        switch self {
        case .apple: ""
        case .openai: "sk-…  (platform.openai.com → API keys)"
        case .anthropic: "sk-ant-…  (console.anthropic.com → API keys)"
        case .gemini: "AIza…  (aistudio.google.com → Get API key)"
        }
    }
}

/// Where AI may be used. Each one is off until the user turns it on.
enum AIFeature: String, CaseIterable, Identifiable {
    case myDay, chatSummary, taskReports, followUps, care, gym, groupReports, attendance, crm, build
    var id: String { rawValue }
    var title: String {
        switch self {
        case .myDay: "My Day brief & end-of-day review"
        case .chatSummary: "Chat summaries (“What did I miss?”)"
        case .taskReports: "Task & expense reports"
        case .followUps: "Smarter follow-up messages"
        case .care: "Health history summaries (Care)"
        case .gym: "Training & spend insights (Gym)"
        case .groupReports: "Group reports I post from my phone"
        case .attendance: "Attendance insights"
        case .crm: "CRM follow-up drafts & pipeline insights"
        case .build: "Builder project summaries & risks"
        }
    }
    var icon: String {
        switch self {
        case .myDay: "sun.max.fill"
        case .chatSummary: "text.bubble.fill"
        case .taskReports: "chart.bar.doc.horizontal.fill"
        case .followUps: "bell.badge.fill"
        case .care: "heart.text.square.fill"
        case .gym: "dumbbell.fill"
        case .groupReports: "person.3.fill"
        case .attendance: "person.badge.clock.fill"
        case .crm: "person.crop.circle.badge.checkmark"
        case .build: "building.columns.fill"
        }
    }
}

@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "ai.enabled") } }
    @Published var provider: AIProvider { didSet { d.set(provider.rawValue, forKey: "ai.provider") } }
    @Published var model: String { didSet { d.set(model, forKey: "ai.model.\(provider.rawValue)") } }
    @Published var features: Set<String> { didSet { d.set(Array(features), forKey: "ai.features") } }
    /// Groups whose AI reports run on this phone with this phone's key (the key never leaves it).
    @Published var groupAI: Set<String> { didSet { d.set(Array(groupAI), forKey: "ai.groups") } }

    private init() {
        enabled = d.bool(forKey: "ai.enabled")
        let p = AIProvider(rawValue: d.string(forKey: "ai.provider") ?? "") ?? .apple
        provider = p
        model = d.string(forKey: "ai.model.\(p.rawValue)") ?? ""
        features = Set(d.stringArray(forKey: "ai.features") ?? AIFeature.allCases.map(\.rawValue))
        groupAI = Set(d.stringArray(forKey: "ai.groups") ?? [])
    }

    func switchProvider(_ p: AIProvider) {
        provider = p
        model = d.string(forKey: "ai.model.\(p.rawValue)") ?? ""
    }

    func key(for p: AIProvider) -> String {
        Keychain.get("ai.key.\(p.rawValue)").flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func setKey(_ key: String, for p: AIProvider) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { Keychain.delete("ai.key.\(p.rawValue)") } else { _ = Keychain.set(Data(k.utf8), account: "ai.key.\(p.rawValue)") }
        objectWillChange.send()
    }

    /// AI is on, ready, and allowed for this use.
    func allows(_ f: AIFeature) -> Bool {
        enabled && features.contains(f.rawValue) && ready
    }

    var ready: Bool {
        provider == .apple ? AIService.appleAvailable : !key(for: provider).isEmpty && !model.isEmpty
    }

    var statusText: String {
        if !enabled { return "Off" }
        if provider == .apple { return AIService.appleAvailable ? "Apple Intelligence" : "Apple Intelligence not available on this device" }
        if key(for: provider).isEmpty { return "Add your \(provider.short) key" }
        if model.isEmpty { return "Pick a model" }
        return "\(provider.short) · \(model)"
    }
}

enum AIError: LocalizedError {
    case notReady, http(Int, String), empty, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "AI isn't set up. Open Settings → AI."
        case .http(let code, let msg): "The AI service answered \(code): \(msg)"
        case .empty: "The AI returned nothing. Try again."
        case .unavailable(let why): why
        }
    }
}

@MainActor
enum AIService {
    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static var appleUnavailableReason: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return ""
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This device doesn't support Apple Intelligence (needs iPhone 15 Pro or newer). Use your own key instead."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in iPhone Settings → Apple Intelligence & Siri."
            case .modelNotReady: return "Apple Intelligence is still downloading. Try again later."
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
        #else
        return "Apple Intelligence isn't available in this build."
        #endif
    }

    static let houseRules = """
    You are the assistant inside iTeam, a private chat and work app. Be brief, practical and friendly. \
    Use short bullet points. Use the people's names as given. Never invent tasks, numbers or facts that are not in the data. \
    Dates and times are local to the user. If something needs a decision, say so plainly.
    """

    /// One answer from the chosen AI.
    static func complete(_ prompt: String, instructions: String = "") async throws -> String {
        let s = AISettings.shared
        let system = houseRules + (instructions.isEmpty ? "" : "\n\n" + instructions)
        switch s.provider {
        case .apple:
            #if canImport(FoundationModels)
            guard appleAvailable else { throw AIError.unavailable(appleUnavailableReason) }
            let session = LanguageModelSession(instructions: system)
            // The on-device model has a small context window: keep the newest part of long inputs.
            let trimmed = prompt.count > 9000 ? String(prompt.suffix(9000)) : prompt
            let out = try await session.respond(to: trimmed).content
            guard !out.isEmpty else { throw AIError.empty }
            return out
            #else
            throw AIError.unavailable(appleUnavailableReason)
            #endif
        case .openai, .anthropic, .gemini:
            let key = s.key(for: s.provider)
            guard !key.isEmpty, !s.model.isEmpty else { throw AIError.notReady }
            return try await remote(s.provider, key: key, model: s.model, system: system, prompt: prompt)
        }
    }

    private static func remote(_ p: AIProvider, key: String, model: String, system: String, prompt: String) async throws -> String {
        var req: URLRequest
        var body: [String: Any]
        switch p {
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 1500, "system": system, "messages": [["role": "user", "content": prompt]]]
        case .gemini:
            let name = model.hasPrefix("models/") ? model : "models/" + model
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name):generateContent")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": prompt]]]]]
        case .apple:
            throw AIError.notReady
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw AIError.http(code, msg)
        }
        var text = ""
        switch p {
        case .openai:
            text = (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        case .anthropic:
            text = ((json["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        case .gemini:
            let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            text = parts.compactMap { $0["text"] as? String }.joined()
        case .apple: break
        }
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    /// Models the key can use, fetched from the provider.
    static func fetchModels(_ p: AIProvider, key: String) async throws -> [String] {
        var req: URLRequest
        switch p {
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .apple:
            return ["on-device"]
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw AIError.http(code, ((json["error"] as? [String: Any])?["message"] as? String) ?? "Check the key.")
        }
        switch p {
        case .openai:
            let skip = ["embedding", "tts", "whisper", "dall-e", "moderation", "transcribe", "audio", "realtime", "image", "search", "babbage", "davinci"]
            return ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                .filter { id in !skip.contains { id.contains($0) } }.sorted(by: >)
        case .anthropic:
            return ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        case .gemini:
            return ((json["models"] as? [[String: Any]]) ?? []).filter {
                (($0["supportedGenerationMethods"] as? [String]) ?? []).contains("generateContent")
            }.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        case .apple:
            return []
        }
    }
}

/// My Day: a morning brief and an end-of-day review, at times the user picks.
enum MyDaySettings {
    private static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.bool(forKey: "myday.enabled") }
        set { d.set(newValue, forKey: "myday.enabled") }
    }
    /// Minutes after midnight.
    static var morning: Int {
        get { d.object(forKey: "myday.morning") as? Int ?? 8 * 60 }
        set { d.set(newValue, forKey: "myday.morning") }
    }
    static var evening: Int {
        get { d.object(forKey: "myday.evening") as? Int ?? 21 * 60 }
        set { d.set(newValue, forKey: "myday.evening") }
    }
    /// Move unfinished tasks to tomorrow without asking (only tasks you can move).
    static var autoShift: Bool {
        get { d.bool(forKey: "myday.autoShift") }
        set { d.set(newValue, forKey: "myday.autoShift") }
    }
}
