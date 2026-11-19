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
