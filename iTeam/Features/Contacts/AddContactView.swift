import SwiftUI
import CoreImage.CIFilterBuiltins
import VisionKit

/// Contacts are added face to face (scan their QR) or by pasting their invite link.
/// The key in the code is checked against their iCloud profile, so nobody can slip in a fake key.
struct AddContactView: View {
    @State private var confirmReset = false
    @State private var qrVersion = 0
    var invite: SyncEngine.Invite? = nil
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look

    enum Mode: String, CaseIterable, Identifiable {
        case myCode = "My code", scan = "Scan", nearby = "Nearby", paste = "Paste link"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .myCode
    @State private var pasted = ""
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?
    @State private var added: Contact?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .myCode: myCode
                    case .scan: scanner
                    case .nearby: NearbyView()
                    case .paste: paste
                    }

                    if busy { ProgressView("Checking with iCloud…") }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(look.danger).font(.subheadline).lookCard()
                    }
                    if let added {
                        VStack(spacing: 10) {
                            AvatarView(name: added.name, imageData: added.avatar, size: 72)
                            Text("\(added.name) added").font(.title3.bold())
                            Label("Key verified with iCloud", systemImage: "checkmark.shield.fill").foregroundStyle(look.success).font(.caption)
                            Button("Done") { dismiss() }.buttonStyle(.glassProminent)
                        }
                        .lookCard()
                    }
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .lookScreen()
            .navigationTitle("Add contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                if let invite { await add(invite) }
            }
        }
    }

    private var myCode: some View {
        let _ = qrVersion
        let inv = engine.myInvite
        return VStack(spacing: 14) {
            if let img = QRCode.image(inv.url.absoluteString) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 260)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            Text(engine.myName).font(.title3.bold())
            Text("Security code \(E2E.fingerprint(engine.myPublicKey))").font(.caption.monospaced()).foregroundStyle(look.textSecondary)
            Button("Change my QR code", systemImage: "arrow.triangle.2.circlepath") { confirmReset = true }
                .font(.footnote)
                .confirmationDialog("Change your QR code?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Change QR code", role: .destructive) { Task { await engine.resetMyQRCode(); qrVersion += 1 } }
                } message: { Text("Old copies (screenshots, prints) stop working. People already in your contacts aren't affected.") }
            Text("Let the other person scan this in iTeam → Add contact → Scan.").font(.footnote)
                .foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
            ShareLink(item: "Add me on iTeam: \(inv.url.absoluteString)\n\nDon't have iTeam yet? Get it here: https://deven86.github.io/iteam-web/") {
                Label("Share my invite link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).controlSize(.large)
        }
        .lookCard()
    }

    @ViewBuilder
    private var scanner: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            QRScanner { text in
                guard !busy, added == nil else { return }
                if let inv = SyncEngine.Invite(text: text) { Task { await add(inv) } }
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Point the camera at their iTeam QR code.").font(.footnote).foregroundStyle(look.textSecondary)
        } else {
            Text("The camera scanner isn't available on this device. Ask them to share their invite link and paste it instead.")
                .font(.subheadline).lookCard()
        }
    }

    private var paste: some View {
        VStack(spacing: 12) {
            TextField("Paste the invite link", text: $pasted, axis: .vertical)
                .lineLimit(2...5)
                .padding(12)
                .lookCard(cornerRadius: 14, padding: 0)
            HStack {
                Button("Paste from clipboard", systemImage: "doc.on.clipboard") { pasted = UIPasteboard.general.string ?? "" }
                    .buttonStyle(.glass)
                Spacer()
                Button("Add") {
                    guard let inv = SyncEngine.Invite(text: pasted) else { error = "That doesn't look like an iTeam invite link."; return }
                    Task { await add(inv) }
                }
                .buttonStyle(.glassProminent)
                .disabled(pasted.isEmpty || busy)
            }
            Text("Links can be forwarded by anyone, so a scanned QR code is the safest way to add someone.")
                .font(.caption).foregroundStyle(look.textSecondary)
        }
    }

    private func add(_ inv: SyncEngine.Invite) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let c = try await engine.addContact(inv)
            if mode == .paste { c.verified = false }
            added = c
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.warning()
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// VisionKit's live QR scanner.
struct QRScanner: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, recognizesMultipleItems: false,
                                           isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    onFound(text)
                }
            }
        }
    }
}
