import Foundation
import AuthenticationServices

/// The app owner ("super user") gets every module free.
///
/// Recognised by the email inside Apple's Sign in with Apple identity token. me.com, icloud.com and
/// mac.com are aliases of the same Apple account. Once verified, the Apple user ID is kept in the
/// iCloud Keychain so the owner stays recognised on his other devices and after reinstalling.
enum Owner {
    static let emails: Set<String> = ["deven86@me.com", "deven86@icloud.com", "deven86@mac.com"]
    private static let keychainAccount = "owner.appleUser"

    /// The email claim from the identity token (a JWT signed by Apple).
    static func email(fromIdentityToken token: Data?) -> String? {
        guard let token, let jwt = String(data: token, encoding: .utf8) else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (claims["email"] as? String)?.lowercased()
    }

    /// Checks a fresh Sign in with Apple result. Returns true and remembers the owner when it matches.
    @MainActor @discardableResult
    static func check(_ credential: ASAuthorizationAppleIDCredential) -> Bool {
        UserDefaults.standard.set(credential.user, forKey: "apple.user")
        if let shared = sharedEmail(credential), MyDetails.email.isEmpty { MyDetails.email = shared }
        let mail = (credential.email ?? email(fromIdentityToken: credential.identityToken))?.lowercased()
        guard let mail, emails.contains(mail) else { return Store.shared.isOwner }
        _ = Keychain.set(Data(credential.user.utf8), account: keychainAccount)
        Store.shared.setOwner(true)
        return true
    }

    /// The email Apple shared, for showing why verification failed.
    static func sharedEmail(_ credential: ASAuthorizationAppleIDCredential) -> String? {
        credential.email ?? email(fromIdentityToken: credential.identityToken)
    }

    /// The owner was verified before on this Apple ID.
    static func storedMatch() -> Bool {
        guard let data = Keychain.get(keychainAccount), let owner = String(data: data, encoding: .utf8) else { return false }
        guard let user = UserDefaults.standard.string(forKey: "apple.user") else {
            // Signed in on this device before the owner check existed: trust the synced keychain item.
            return true
        }
        return user == owner
    }

    /// False if the owner stopped using Sign in with Apple for iTeam.
    static func stillAuthorized() async -> Bool {
        guard let data = Keychain.get(keychainAccount), let owner = String(data: data, encoding: .utf8) else { return false }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: owner)
        return state != .revoked && state != .transferred
    }

    @MainActor static func forget() {
        Keychain.delete(keychainAccount)
        Store.shared.setOwner(false)
    }
}

/// Your own contact details. Name comes from Sign in with Apple (first sign-in only — Apple sends it once),
/// email from Apple too; phone is optional. Kept on this device, never in the public profile.
enum MyDetails {
    static var email: String {
        get { UserDefaults.standard.string(forKey: "me.email") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "me.email") }
    }
    static var phone: String {
        get { UserDefaults.standard.string(forKey: "me.phone") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "me.phone") }
    }
    /// Phone or email used for FaceTime, and whether contacts may see it.
    static var facetime: String {
        get { UserDefaults.standard.string(forKey: "me.facetime") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "me.facetime") }
    }
    /// Who sees my profile photo: everyone who has my iTeam ID, or only people I chat with.
    static var photoContactsOnly: Bool {
        get { UserDefaults.standard.object(forKey: "me.photoContactsOnly") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "me.photoContactsOnly") }
    }
    static var shareFaceTime: Bool {
        get { UserDefaults.standard.bool(forKey: "me.shareFaceTime") }
        set { UserDefaults.standard.set(newValue, forKey: "me.shareFaceTime") }
    }
    /// Apple's private-relay addresses forward to the real inbox but aren't worth showing.
    static var isRelay: Bool { email.hasSuffix("privaterelay.appleid.com") }
}
