import Foundation
import CryptoKit
import AuthenticationServices
import UIKit

/// Bridge to iTeam's own relay server (relay.iteamchat.in), used to talk to Android users.
/// iPhone ↔ iPhone stays on iCloud exactly as before; envelopes for Android people (IDs starting
/// "u_") go through the relay, and the relay mailbox is checked alongside iCloud.
/// The iPhone keeps its existing iTeam ID on the relay, proven with its identity key.
/// Everything sent is already end-to-end encrypted on this phone.
@MainActor
final class RelayClient {
    static let shared = RelayClient()
    static let base = URL(string: "https://relay.iteamchat.in")!

    enum RelayError: LocalizedError {
        case server(String), signIn
        var errorDescription: String? {
            switch self {
            case .server(let m): m
            case .signIn: "Apple sign-in didn't finish"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private var token: String {
        get { Keychain.get("relay.token").flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete("relay.token") }
            else { _ = Keychain.set(Data(newValue.utf8), account: "relay.token", sync: false) }
        }
    }
    private var deviceID: String {
        if let d = defaults.string(forKey: "relay.device") { return d }
        let d = UUID().uuidString; defaults.set(d, forKey: "relay.device"); return d
    }
    private var seq: Int64 {
        get { Int64(defaults.integer(forKey: "relay.seq")) }
        set { defaults.set(Int(newValue), forKey: "relay.seq") }
    }
    private var acked: Int64 {
        get { Int64(defaults.integer(forKey: "relay.acked")) }
        set { defaults.set(Int(newValue), forKey: "relay.acked") }
    }

    /// True once this iPhone has joined the Android bridge.
    var isOn: Bool { !token.isEmpty }

    static func isRelayID(_ id: String) -> Bool { id.hasPrefix("u_") }

    // MARK: HTTP

    private func call(_ method: String, _ path: String, json: Any? = nil, raw: Data? = nil, auth: Bool = true) async throws -> [String: Any] {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 60
        if auth { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let raw {
            req.httpBody = raw
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code == 401 && auth { token = "" }
        guard (200..<300).contains(code) else { throw RelayError.server(obj["error"] as? String ?? "Server error \(code)") }
        return obj
    }

    // MARK: Join

    /// Signs in with Apple and links this iPhone's existing iTeam ID to the relay.
    func join(me: String) async throws {
        guard let identity = E2E.identity else { throw RelayError.server("Set up iTeam first") }
        let idToken = try await AppleSignIn.identityToken()
        let start = try await call("POST", "v1/claim/start", json: ["legacyID": me], auth: false)
        guard let challengeID = start["challengeID"] as? String, let serverKeyB64 = start["serverKey"] as? String,
              let serverKeyData = Data(base64Encoded: serverKeyB64) else { throw RelayError.server("Unexpected reply") }
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverKeyData)
        let shared = try identity.sharedSecretFromKeyAgreement(with: serverKey).withUnsafeBytes { Data($0) }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("iteam-claim|\(challengeID)|\(me)".utf8), using: SymmetricKey(data: shared))
        let o = try await call("POST", "v1/login", json: [
            "provider": "apple", "idToken": idToken,
            "device": ["id": deviceID, "platform": "ios", "pushToken": defaults.string(forKey: "relay.push") ?? ""],
            "claim": ["challengeID": challengeID, "proof": Data(mac).base64EncodedString()],
        ], auth: false)
        guard let t = o["token"] as? String, (o["userID"] as? String) == me else { throw RelayError.server("Linking failed") }
        token = t
    }

    func leave() {
        let t = token
        token = ""
        Task { _ = try? await callWith(token: t, "POST", "v1/logout") }
    }

    private func callWith(token t: String, _ method: String, _ path: String) async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent(path)); req.httpMethod = method
        req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }

    /// Sends this iPhone's push token to the relay so Android messages notify instantly.
    func setPush(_ hex: String) async {
        guard isOn else { return }
        _ = try? await call("PUT", "v1/me/device", json: ["pushToken": hex, "sandbox": false])
    }

    // MARK: Profiles & presence

    func profiles(_ ids: [String], seenOnly: Bool = false) async throws -> [CloudService.RemoteProfile] {
        guard isOn, !ids.isEmpty else { return [] }
        let o = try await call("POST", "v1/profiles", json: ["ids": ids, "seenOnly": seenOnly])
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        return (o["profiles"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["userID"] as? String else { return nil }
            let seen = (p["seen"] as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) }
            return CloudService.RemoteProfile(userID: id, name: p["name"] as? String ?? "", publicKey: p["pubkey"] as? String ?? "",
                                              avatar: (p["pic"] as? String).flatMap { Data(base64Encoded: $0) }, seen: seen,
                                              plus: p["plus"] as? Bool ?? false, qrCode: p["qr"] as? String ?? "")
        }
    }

    func updateProfile(_ fields: [String: Any]) async {
        guard isOn else { return }
        _ = try? await call("PUT", "v1/me/profile", json: fields)
    }

    func touchSeen(_ at: Date?) async {
        guard isOn else { return }
        let value: Any = at.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        _ = try? await call("PUT", "v1/me/seen", json: ["seen": value])
    }

    // MARK: Mailbox

    struct OutEnvelope { var id, rcpt, conv: String; var kind: Int; var loud: Bool; var body: Data; var hint: String? }

    /// Sends envelopes; returns the ids the relay refused.
    func send(_ envs: [OutEnvelope]) async throws -> [String: Error] {
        var failed: [String: Error] = [:]
        for chunk in stride(from: 0, to: envs.count, by: 300).map({ Array(envs[$0..<min($0 + 300, envs.count)]) }) {
            let list: [[String: Any]] = chunk.map { e in
                var d: [String: Any] = ["id": e.id, "rcpt": e.rcpt, "conv": e.conv, "kind": e.kind, "loud": e.loud,
                                        "body": e.body.base64EncodedString()]
                if let h = e.hint { d["hint"] = Data(h.utf8).base64EncodedString() }
                return d
            }
            let o = try await call("POST", "v1/send", json: ["envelopes": list])
            for (id, why) in o["failed"] as? [String: String] ?? [:] { failed[id] = RelayError.server(why) }
        }
        return failed
    }

    /// New envelopes from the relay. The previous batch is acknowledged first (it has been processed by then).
    func inbox(me: String) async throws -> [CloudService.Incoming] {
        guard isOn else { return [] }
        if seq > acked { _ = try await call("POST", "v1/ack", json: ["upTo": seq]); acked = seq }
        var out: [CloudService.Incoming] = []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        var more = false
        var comps = URLComponents(url: Self.base.appendingPathComponent("v1/inbox"), resolvingAgainstBaseURL: false)!
        repeat {
            comps.queryItems = [URLQueryItem(name: "after", value: String(seq)), URLQueryItem(name: "limit", value: "200")]
            var req = URLRequest(url: comps.url!); req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 401 { token = ""; return out }
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            for e in o["envelopes"] as? [[String: Any]] ?? [] {
                guard let id = e["id"] as? String, let from = e["sndr"] as? String, let b = e["body"] as? String,
                      let body = Data(base64Encoded: b) else { continue }
                let created = (e["created"] as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) } ?? .now
                out.append(CloudService.Incoming(recordName: id, from: from, creator: from, conv: e["conv"] as? String ?? "",
                                                 kind: e["kind"] as? Int ?? 0, body: body, created: created))
                if let s = (e["seq"] as? NSNumber)?.int64Value { seq = max(seq, s) }
            }
            more = o["more"] as? Bool ?? false
        } while more && out.count < 2000
        return out
    }

    // MARK: Files

    func putBlob(_ id: String, fileURL: URL) async throws {
        _ = try await call("PUT", "v1/blobs/\(id)", raw: try Data(contentsOf: fileURL))
    }

    func getBlob(_ id: String) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent("v1/blobs/\(id)"))
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RelayError.server("File not found (files are kept 45 days)") }
        return data
    }
}

/// Sign in with Apple, returning the identity token (a short-lived JWT the relay verifies with Apple).
@MainActor
enum AppleSignIn {
    private final class Delegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        var done: ((Result<String, Error>) -> Void)?
        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization a: ASAuthorization) {
            if let c = a.credential as? ASAuthorizationAppleIDCredential, let t = c.identityToken, let s = String(data: t, encoding: .utf8) {
                done?(.success(s))
            } else { done?(.failure(RelayClient.RelayError.signIn)) }
            done = nil
        }
        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            done?(.failure(error)); done = nil
        }
        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
    private static var current: Delegate?

    static func identityToken() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let d = Delegate()
            d.done = { cont.resume(with: $0); current = nil }
            current = d
            let req = ASAuthorizationAppleIDProvider().createRequest()
            req.requestedScopes = []
            let c = ASAuthorizationController(authorizationRequests: [req])
            c.delegate = d
            c.presentationContextProvider = d
            c.performRequests()
        }
    }
}
