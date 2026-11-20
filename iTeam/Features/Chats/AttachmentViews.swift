import SwiftUI
import QuickLook

/// A photo or file inside a bubble. Photos show their small preview at once and the full image after download.
struct AttachmentView: View {
    let ref: AttachmentRef
    var onOpen: (URL) -> Void
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Group {
            if ref.kind == "image" {
                photo
            } else if ref.kind == "audio" {
                VoiceNoteView(ref: ref)
            } else if ref.kind == "video" {
                video
            } else {
                file
            }
        }
        .task(id: ref.id) { await prepare() }
    }

    private var aspect: CGFloat {
        guard let w = ref.width, let h = ref.height, w > 0, h > 0 else { return 4 / 3 }
        return CGFloat(w / h)
    }

    private var photo: some View {
        Button { Task { await open() } } label: {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .overlay(alignment: .bottomLeading) {
                            if ref.name.hasPrefix("Original") {
                                Text("ORIGINAL").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(6)
                            }
                        }
                } else if let t = ref.thumb, let img = UIImage(data: t) {
                    Image(uiImage: img).resizable().scaledToFill().blur(radius: 6)
                } else {
                    Rectangle().fill(.gray.opacity(0.3))
                }
                if loading { ProgressView().tint(.white) }
                if failed { Image(systemName: "exclamationmark.icloud").font(.title).foregroundStyle(.white) }
            }
            .frame(width: 240, height: min(320, 240 / max(aspect, 0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo")
    }

    private var video: some View {
        Button { Task { await open() } } label: {
            ZStack {
                if let t = ref.thumb, let img = UIImage(data: t) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.black.opacity(0.4))
                }
                if loading { ProgressView().tint(.white) }
                else { Image(systemName: "play.circle.fill").font(.system(size: 46)).foregroundStyle(.white, .black.opacity(0.35)) }
                if let d = ref.duration {
                    Text(Clock.mmss(d)).font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.5), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
                }
            }
            .frame(width: 240, height: min(320, 240 / max(aspect, 0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Video")
    }

    private var file: some View {
        Button { Task { await open() } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(failed ? "Couldn't download — tap to retry" : Fmt.bytes(ref.size)).font(.caption2).opacity(0.8)
                }
                Spacer(minLength: 0)
                if loading { ProgressView() } else { Image(systemName: "arrow.down.circle").opacity(0.8) }
            }
            .padding(10)
            .frame(minWidth: 220)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        let m = ref.mime
        if m.contains("pdf") { return "doc.richtext.fill" }
        if m.hasPrefix("video") { return "film.fill" }
        if m.hasPrefix("audio") { return "waveform" }
        if m.contains("sheet") || m.contains("excel") || m.contains("csv") { return "tablecells.fill" }
        if m.contains("word") || m.contains("text") { return "doc.text.fill" }
        if m.contains("zip") { return "doc.zipper" }
        return "doc.fill"
    }

    private func prepare() async {
        guard ref.kind == "image" else { return }
        if let img = Attachments.cachedImage(ref) { image = img; return }
        await download()
    }

    private func download() async {
        guard !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let url = try await Attachments.load(ref)
            if ref.kind == "image" { image = UIImage(contentsOfFile: url.path) }
        } catch {
            failed = true
        }
    }

    private func open() async {
        if let _ = Attachments.cachedImage(ref), ref.kind == "image" {
            onOpen(Attachments.cacheURL(ref))
            return
        }
        if FileManager.default.fileExists(atPath: Attachments.cacheURL(ref).path) {
            onOpen(Attachments.cacheURL(ref))
            return
        }
        await download()
        if !failed { onOpen(Attachments.cacheURL(ref)) }
    }
}

/// A voice note: play/pause, progress and length. Downloads on first play.
struct VoiceNoteView: View {
    let ref: AttachmentRef
    @ObservedObject private var player = VoicePlayer.shared
    @State private var loading = false
    @State private var failed = false

    private var playing: Bool { player.playingID == ref.id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    loading = true
                    defer { loading = false }
                    do {
                        let url = try await Attachments.load(ref)
                        failed = false
                        player.toggle(id: ref.id, url: url)
                    } catch { failed = true }
                }
            } label: {
                Group {
                    if loading { ProgressView() }
                    else { Image(systemName: failed ? "exclamationmark.icloud" : playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)) }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { g in
                    let bars = 28
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<bars, id: \.self) { i in
                            let h = 6 + CGFloat(abs((ref.id.hashValue >> (i % 16)) % 14))
                            Capsule()
                                .fill(Double(i) / Double(bars) < (playing ? player.progress : 0) ? Color.primary : Color.primary.opacity(0.35))
                                .frame(width: max(2, (g.size.width - CGFloat(bars) * 2) / CGFloat(bars)), height: h)
                        }
                    }
                    .frame(height: g.size.height)
                }
                .frame(height: 22)
                Text(Clock.mmss(ref.duration ?? 0)).font(.caption2).opacity(0.75)
            }
        }
        .frame(width: 220)
        .accessibilityLabel("Voice note, \(Clock.mmss(ref.duration ?? 0))")
    }
}

/// Apple's Quick Look: photos, PDFs, Office files, with share and markup.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        ql.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak ql] _ in
            ql?.dismiss(animated: true)
        })
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}


/// Several photos in one message, like iMessage: a fanned stack of cards with no bubble behind.
/// Swipe the top card left or right and it goes to the back; tap opens it full screen.
struct PhotoStackView: View {
    let refs: [AttachmentRef]
    var onOpen: (URL) -> Void
    @State private var order: [Int]
    @State private var drag: CGSize = .zero
    @State private var showGrid = false

    init(refs: [AttachmentRef], onOpen: @escaping (URL) -> Void) {
        self.refs = refs
        self.onOpen = onOpen
        _order = State(initialValue: Array(refs.indices))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { showGrid = true } label: {
                Label("\(refs.count) items", systemImage: "square.grid.2x2.fill").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            ZStack {
                ForEach(Array(order.prefix(4).enumerated().reversed()), id: \.element) { depth, idx in
                    StackCard(ref: refs[idx])
                        .rotationEffect(.degrees(depth == 0 ? Double(drag.width / 18) : [0, -5, 4, -2][min(depth, 3)]))
                        .offset(x: depth == 0 ? drag.width : CGFloat(depth) * 7, y: depth == 0 ? drag.height * 0.15 : CGFloat(depth) * -5)
                        .scaleEffect(depth == 0 ? 1 : 1 - CGFloat(depth) * 0.035)
                        .zIndex(Double(10 - depth))
                        .allowsHitTesting(depth == 0)
                        .onTapGesture { open(refs[idx]) }
                        .highPriorityGesture(depth == 0 ? swipe : nil)
                }
            }
            .frame(width: 250, height: 310)
        }
        .sheet(isPresented: $showGrid) { PhotoGridSheet(refs: refs, onOpen: onOpen) }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                if abs(v.translation.width) > 60 || abs(v.predictedEndTranslation.width) > 160 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        order.append(order.removeFirst())
                        drag = .zero
                    }
                    Haptics.tap()
                } else {
                    withAnimation(.spring(response: 0.3)) { drag = .zero }
                }
            }
    }

    private func open(_ ref: AttachmentRef) {
        Task { if let url = try? await Attachments.load(ref) { onOpen(url) } }
    }
}

/// One card: the photo at full quality (sharp, never blurred), rounded with a soft shadow.
private struct StackCard: View {
    let ref: AttachmentRef
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let t = ref.thumb, let img = UIImage(data: t) {
                Image(uiImage: img).resizable().scaledToFill().overlay(ProgressView())
            } else {
                Rectangle().fill(.quaternary).overlay(ProgressView())
            }
            if ref.kind == "video" {
                Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white).shadow(radius: 4)
            }
        }
        .frame(width: 230, height: 290)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        .contentShape(Rectangle())
        .task(id: ref.id) { await load() }
    }

    private func load() async {
        if ref.kind == "image" {
            let full = Attachments.cachedImage(ref) ?? ((try? await Attachments.load(ref)).flatMap { UIImage(contentsOfFile: $0.path) })
            // Decode at screen size (sharp but light on memory).
            image = await full?.byPreparingThumbnail(ofSize: CGSize(width: 690, height: 870)) ?? full
        } else if let t = ref.thumb {
            image = UIImage(data: t)
        }
    }
}

struct PhotoGridSheet: View {
    let refs: [AttachmentRef]
    var onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    private let cols = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(refs) { r in
                        AttachmentView(ref: r) { url in dismiss(); onOpen(url) }
                            .frame(width: 110, height: 110).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding()
            }
            .navigationTitle("\(refs.count) items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
