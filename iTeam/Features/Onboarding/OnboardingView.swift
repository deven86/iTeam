import SwiftUI
import PhotosUI
import CloudKit
import UserNotifications
import AuthenticationServices

/// First run: iCloud check → your name and photo → notifications. No phone number, no sign-up:
/// your iCloud account is your identity, and your security key is created on this device.
struct OnboardingView: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Environment(\.colorScheme) private var colorScheme

    enum Step { case welcome, icloud, profile, appearance, addPeople, notifications }
    @State private var step: Step = .welcome
    @State private var userID = ""
    @State private var name = ""
    @State private var avatar: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var phone = MyDetails.phone
    @State private var showCamera = false
    @State private var busy = false
    @State private var error: String?
    /// iCloud already has a profile for this account but this device has no key yet.
    @State private var needsKey = false

    var body: some View {
        ZStack {
            LookBackdrop()
            ScrollView {
                VStack(spacing: 20) {
                    switch step {
                    case .welcome: welcome
                    case .icloud: icloud
                    case .profile: profile
                    case .appearance: appearanceStep
                    case .addPeople: addPeopleStep
                    case .notifications: notifications
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(look.danger)
                            .lookCard()
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            AppLogo(size: 84).padding(.top, 40).appear(0)
            Text("Welcome to iTeam").font(.largeTitle.bold()).appear(1)
            Text("Chat with your people. Turn any message into a task.").font(.title3)
                .foregroundStyle(look.textSecondary).multilineTextAlignment(.center).appear(2)
            feature("bubble.left.and.bubble.right.fill", .cyan, "Chats & groups", "One-to-one and group chats with photos and files.").appear(3)
            feature("checklist", .green, "Business Tasks", "Assign work from any message. Whole-group tasks, checklists, deadlines.").appear(4)
            feature("lock.shield.fill", .purple, "Private by design", "End-to-end encrypted. No servers, no phone number, no ads.").appear(5)
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let auth):
                    if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                        Owner.check(cred)
                        if let n = cred.fullName {
                            let full = PersonNameComponentsFormatter().string(from: n).trimmingCharacters(in: .whitespaces)
                            if !full.isEmpty { name = full }
                        }
                    }
                    withAnimation { step = .icloud }
                    Task { await checkICloud() }
                case .failure(let e):
                    if (e as? ASAuthorizationError)?.code != .canceled {
                        error = "Sign in with Apple didn't work: \(e.localizedDescription)"
                    }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52)
            .clipShape(Capsule())
            .padding(.top, 8)
            .appear(6)
            Text("Your Apple ID is your login. No phone number, no password.")
                .font(.caption).foregroundStyle(look.textSecondary).appear(7)
        }
    }

    private var icloud: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.fill").font(.system(size: 60)).foregroundStyle(look.gradient).padding(.top, 50)
            Text("Connecting to iCloud").font(.title2.bold())
            if needsKey {
                Text("This iCloud account already uses iTeam on another device. Your security key comes over through iCloud Keychain — make sure it's on (Settings → your name → iCloud → Passwords & Keychain), then try again.")
                    .font(.subheadline).foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await checkICloud() } }
                    .buttonStyle(.glassProminent).controlSize(.large)
                Button("Start fresh on this device", role: .destructive) {
                    E2E.createIdentity()
                    needsKey = false
                    step = .profile
                }
                Text("Starting fresh creates a new key. Messages sent to your old key can't be read here, and your contacts will see that your key changed.")
                    .font(.caption).foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
            } else if busy {
                ProgressView().controlSize(.large)
            } else {
                Text("iTeam uses your iCloud account as your identity and to deliver encrypted messages.")
                    .font(.subheadline).foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await checkICloud() } }.buttonStyle(.glassProminent).controlSize(.large)
            }
        }
    }

    private var profile: some View {
        VStack(spacing: 18) {
            Text("Your profile").font(.largeTitle.bold()).padding(.top, 40)
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: name.isEmpty ? "?" : name, imageData: avatar, size: 110)
                Menu {
                    Button("Take photo", systemImage: "camera") { showCamera = true }
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Choose from Photos", systemImage: "photo") }
                    if avatar != nil { Button("Remove photo", systemImage: "trash", role: .destructive) { avatar = nil } }
                } label: {
                    Image(systemName: "camera.circle.fill").font(.system(size: 32)).foregroundStyle(.white, look.accent)
                }
            }
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) { avatar = Self.avatarData(data) }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in
                    if let d = img.jpegData(compressionQuality: 0.9) { avatar = Self.avatarData(d) }
                }
                .ignoresSafeArea()
            }
            Text("Apple doesn't share your Apple ID photo with apps, so pick one here.")
                .font(.caption2).foregroundStyle(look.textSecondary)
            TextField("Your name", text: $name)
                .textContentType(.name)
                .font(.title3)
                .padding(14)
                .lookCard(cornerRadius: 16, padding: 0)
            if !MyDetails.email.isEmpty && !MyDetails.isRelay {
                Label(MyDetails.email, systemImage: "envelope.fill")
                    .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).lookCard(cornerRadius: 16, padding: 0)
            }
            TextField("Mobile number (optional)", text: $phone)
                .textContentType(.telephoneNumber).keyboardType(.phonePad)
                .padding(14)
                .lookCard(cornerRadius: 16, padding: 0)
            Text("People you chat with see your name and photo. Email and mobile stay on this device.")
                .font(.caption).foregroundStyle(look.textSecondary)
            Button {
                MyDetails.phone = phone.trimmingCharacters(in: .whitespaces)
                Task { await saveProfile() }
            } label: {
                Group { if busy { ProgressView() } else { Text("Continue") } }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }

    /// Pick a look now (can be changed any time in Settings → Appearance).
    private var appearanceStep: some View {
        VStack(spacing: 12) {
            Text("Make it yours").font(.title.bold()).padding(.top, 30)
            Text("Choose a style. You can change it any time in Settings → Appearance.")
                .font(.subheadline).foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
            AppearanceView().frame(minHeight: 420)
            Button { withAnimation { step = .addPeople } } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large)
        }
    }

    /// How to add people (iPhone and Android).
    private var addPeopleStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.plus").font(.system(size: 60)).foregroundStyle(look.gradient).padding(.top, 50)
            Text("Add your people").font(.title.bold())
            VStack(alignment: .leading, spacing: 12) {
                Label("Show your QR code — they scan it in iTeam (Chats → ＋)", systemImage: "qrcode")
                Label("Or share your invite link on WhatsApp, SMS or email", systemImage: "link")
                Label("Scan their QR, or paste the link they sent you", systemImage: "qrcode.viewfinder")
                Label("Find people and businesses nearby", systemImage: "location.fill")
                Label("Friends on Android: turn on Settings → Talk to Android users", systemImage: "candybarphone")
                Label("Create a group from Chats → ✏️ → New group", systemImage: "person.3.fill")
            }
            .font(.subheadline)
            .lookCard()
            Button { withAnimation { step = .notifications } } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large)
        }
    }

    private var notifications: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.badge.fill").font(.system(size: 60)).foregroundStyle(look.gradient).padding(.top, 50)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("Stay in the loop").font(.title.bold())
            VStack(alignment: .leading, spacing: 10) {
                Label("New messages — even when iTeam is closed", systemImage: "bubble.left.fill")
                Label("Tasks assigned to you", systemImage: "person.crop.circle.badge.checkmark")
                Label("Deadline reminders — work offline too", systemImage: "alarm.fill")
            }
            .font(.subheadline)
            .lookCard()
            Text("Message previews are decrypted on your iPhone. Apple only ever carries scrambled data.")
                .font(.caption).foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
            Button {
                Task { await finish(askPermission: true) }
            } label: {
                Group { if busy { ProgressView() } else { Text("Turn on notifications") } }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large).disabled(busy)
            Button("Not now") { Task { await finish(askPermission: false) } }.disabled(busy)
        }
    }

    private func feature(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.caption).foregroundStyle(look.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .lookCard()
    }

    // MARK: Logic

    private func checkICloud() async {
        busy = true
        error = nil
        defer { busy = false }
        let status = await engine.cloud.accountStatus()
        guard status == .available else {
            error = status == .noAccount
                ? "Sign in to iCloud in the Settings app, then come back."
                : "iCloud isn't available right now. Check your connection and that iCloud is on."
            return
        }
        do {
            userID = try await engine.cloud.currentUserID()
            if let remote = try await engine.cloud.fetchProfile(userID) {
                name = remote.name
                avatar = remote.avatar
                if let key = E2E.identity, E2E.publicKeyString(key) == remote.publicKey {
                    needsKey = false
                    step = .profile
                } else if E2E.identity == nil {
                    needsKey = true
                } else {
                    // A different key is on this device; the profile will be updated to it.
                    step = .profile
                }
            } else {
                if E2E.identity == nil { E2E.createIdentity() }
                step = .profile
            }
        } catch {
            self.error = "Couldn't reach iCloud: \(error.cloudMessage). If this is a TestFlight build, the iCloud schema may not be deployed yet."
        }
    }

    private func saveProfile() async {
        busy = true
        error = nil
        defer { busy = false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = E2E.identity ?? E2E.createIdentity()
        do {
            try await engine.cloud.saveProfile(userID: userID, name: clean, publicKey: E2E.publicKeyString(key), avatar: MyDetails.photoContactsOnly ? nil : avatar)
            name = clean
            step = .appearance
        } catch {
            self.error = "Couldn't save your profile: \(error.cloudMessage)"
        }
    }

    private func finish(askPermission: Bool) async {
        busy = true
        defer { busy = false }
        if askPermission { _ = await Reminders.shared.requestAuthorization() }
        UIApplication.shared.registerForRemoteNotifications()
        try? await engine.cloud.ensureSubscriptions(for: userID)
        UserDefaults.standard.set(true, forKey: "subscriptions.ok")
        engine.saveIdentity(id: userID, name: name, avatar: avatar)
        await engine.sync()
    }

    /// Profile photos are small (they're public in iCloud): 256 px JPEG.
    static func avatarData(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side = min(img.size.width, img.size.height)
        let crop = CGRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side)
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            img.draw(at: CGPoint(x: -crop.minX, y: -crop.minY))
        }
        return square.scaled(maxSide: 256).jpegData(compressionQuality: 0.7)
    }
}
