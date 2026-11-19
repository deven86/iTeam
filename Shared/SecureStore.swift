import Foundation
import CryptoKit
import Security

// Shared by the app and the notification extension.

enum AppGroup {
    static let id = "group.com.jondhale.iteam"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    /// Conversation IDs the user muted (the extension delivers them silently).
    static let mutedKey = "mutedConversations"
    /// Show message text on the Lock Screen (false = "New message" only).
    static let previewsKey = "notificationPreviews"
    /// The conversation open on screen right now (no banner for it).
    static let openConversationKey = "openConversation"

    static var mutedConversations: Set<String> {
        get { Set(defaults.stringArray(forKey: mutedKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: mutedKey) }
    }

    static var showPreviews: Bool {
        get { defaults.object(forKey: previewsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: previewsKey) }
    }
}

/// Keychain items shared with the notification extension through the app group.
/// Identity and conversation keys are synchronizable, so iCloud Keychain brings them to your iPad.
enum Keychain {
    private static let service = "com.jondhale.iteam"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: AppGroup.id]
    }

    @discardableResult
    static func set(_ data: Data, account: String, sync: Bool = true) -> Bool {
        delete(account)
        var q = base(account)
        q[kSecValueData as String] = data
        q[kSecAttrSynchronizable as String] = sync ? kCFBooleanTrue : kCFBooleanFalse
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> Data? {
        var q = base(account)
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ account: String) {
        var q = base(account)
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(q as CFDictionary)
    }
}

/// End-to-end encryption with Apple CryptoKit (Curve25519 + HKDF-SHA256 + ChaChaPoly).
/// Nothing here is home-made cryptography: only Apple's vetted primitives are combined.
enum E2E {
    enum Failure: Error { case noIdentity, badKey, badData }

    private static let identityAccount = "identity.v1"

    // MARK: Identity

    static var identity: Curve25519.KeyAgreement.PrivateKey? {
        guard let raw = Keychain.get(identityAccount) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    @discardableResult
    static func createIdentity() -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        Keychain.set(key.rawRepresentation, account: identityAccount)
        return key
    }

    static func publicKeyString(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Short, human-checkable fingerprint of a public key ("4F2A 9C1B 77D0").
    static func fingerprint(_ publicKey: String) -> String {
        guard let data = Data(base64Encoded: publicKey) else { return "—" }
        let hex = SHA256.hash(data: data).prefix(6).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: min(4, hex.count - i))
            return String(hex[s..<e])
        }.joined(separator: " ")
    }

    // MARK: Keys

    /// A key both sides can compute: my private key × their public key, bound to a context string.
    static func pairwiseKey(theirPublicKey: String, context: String) throws -> SymmetricKey {
        guard let me = identity else { throw Failure.noIdentity }
        guard let raw = Data(base64Encoded: theirPublicKey),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { throw Failure.badKey }
        let secret = try me.sharedSecretFromKeyAgreement(with: theirs)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: Data(context.utf8),
                                              sharedInfo: Data("iteam-e2e-v1".utf8),
                                              outputByteCount: 32)
    }

    static func newConversationKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func storeConversationKey(_ key: SymmetricKey, conv: String, version: Int) {
        let data = key.withUnsafeBytes { Data($0) }
        Keychain.set(data, account: "conv.\(conv).\(version)")
    }

    static func conversationKey(conv: String, version: Int) -> SymmetricKey? {
        guard let data = Keychain.get("conv.\(conv).\(version)") else { return nil }
        return SymmetricKey(data: data)
    }

    static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    // MARK: Sealing

    static func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(plain, using: key).combined
    }

    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed) else { throw Failure.badData }
        return try ChaChaPoly.open(box, using: key)
    }

    /// [version byte] + sealed box — the format of every envelope body and hint.
    static func sealVersioned(_ plain: Data, key: SymmetricKey, version: Int) throws -> Data {
        var out = Data([UInt8(clamping: version)])
        out.append(try seal(plain, key: key))
        return out
    }

    /// Splits a versioned blob into (version, sealed box).
    static func splitVersioned(_ data: Data) -> (Int, Data)? {
        guard data.count > 1, let first = data.first else { return nil }
        return (Int(first), Data(data.dropFirst()))
    }
}

/// What the notification extension may show: encrypted with the conversation key.
struct NotificationHint: Codable {
    /// Sender display name.
    var n: String
    /// Group title (nil for one-to-one chats).
    var t: String?
    /// Short preview text.
    var b: String
}
