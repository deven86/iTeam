import SwiftUI
import LocalAuthentication

/// Optional Face ID / Touch ID lock (Settings → Privacy). Off by default.
@MainActor
final class AppLock: ObservableObject {
    @Published var isUnlocked = false
    @Published var lockEnabled = UserDefaults.standard.bool(forKey: "lockEnabled") {
        didSet {
            UserDefaults.standard.set(lockEnabled, forKey: "lockEnabled")
            if !lockEnabled { isUnlocked = true }
        }
    }

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func lock() { if lockEnabled { isUnlocked = false } }

    private var inProgress = false

    func unlock() async {
        guard lockEnabled else { isUnlocked = true; return }
        guard !inProgress, !isUnlocked, UIApplication.shared.applicationState == .active else { return }
        inProgress = true
        defer { inProgress = false }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { isUnlocked = true; return }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock iTeam")) == true {
            isUnlocked = true
        }
    }
}

struct LockScreenView: View {
    @EnvironmentObject var lock: AppLock
    var body: some View {
        ZStack {
            LookBackdrop()
            VStack(spacing: 18) {
                AppLogo(size: 72)
                Text("iTeam is locked").font(.title2.bold())
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(lock.biometryName)", systemImage: "faceid")
                }
                .buttonStyle(.glassProminent).controlSize(.large)
            }
        }
        .task { await lock.unlock() }
    }
}
