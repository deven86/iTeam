import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import LinkPresentation

/// Attachments chosen in a form but not yet sent (already encrypted and waiting in the outbox folder).
struct PendingAttachments {
    var refs: [AttachmentRef] = []
    var uploads: [String: String] = [:]

    mutating func add(_ p: Attachments.Prepared) {
        refs.append(p.ref)
        uploads[p.upload.0] = p.upload.1
    }

    mutating func remove(_ ref: AttachmentRef) {
        refs.removeAll { $0.id == ref.id }
        uploads.removeValue(forKey: ref.blob)
    }

    var isEmpty: Bool { refs.isEmpty }
}

/// The iPhone camera.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// "+ Add photo / bill / file" button for forms (expenses, approvals, task files).
struct AttachmentAdder: View {
    @Binding var pending: PendingAttachments
    var title = "Add photo, bill or file"
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var items: [PhotosPickerItem] = []
    @State private var error: String?
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button("Camera", systemImage: "camera") { showCamera = true }
                Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                Button("Files (PDF, Word, Excel…)", systemImage: "doc") { showFiles = true }
            } label: {
                Label(title, systemImage: "paperclip")
            }
            if !pending.isEmpty { PendingAttachmentsRow(pending: $pending) }
            if let error { Text(error).font(.caption).foregroundStyle(look.danger) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in addImage(img.jpegData(compressionQuality: 0.9)) }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $items, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                do { pending.add(try Attachments.prepareFile(url)) } catch { self.error = error.localizedDescription }
            }
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for item in picked { addImage(try? await item.loadTransferable(type: Data.self)) }
                items = []
            }
        }
    }

    private func addImage(_ data: Data?) {
        guard let data else { return }
        do { pending.add(try Attachments.prepareImage(data)) } catch { self.error = error.localizedDescription }
    }
}

/// Thumbnails of chosen attachments, each with a remove button.
struct PendingAttachmentsRow: View {
    @Binding var pending: PendingAttachments
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pending.refs) { ref in
                    AttachmentThumb(ref: ref)
                        .overlay(alignment: .topTrailing) {
                            Button { pending.remove(ref) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 4, y: -4)
                        }
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Small square preview of an attachment (photo thumbnail or file icon). Tap opens it.
struct AttachmentThumb: View {
    let ref: AttachmentRef
    var size: CGFloat = 64
    @State private var openURL: URL?

    var body: some View {
        Button {
            Task { if let url = try? await Attachments.load(ref) { openURL = url } }
        } label: {
            Group {
                if ref.kind == "image", let t = ref.thumb, let img = UIImage(data: t) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: ref.mime.contains("pdf") ? "doc.richtext.fill" : "doc.fill").font(.title2)
                        Text((ref.name as NSString).pathExtension.uppercased()).font(.caption2.bold())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.25))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(item: Binding(get: { openURL.map(PreviewItem.init) }, set: { openURL = $0?.url })) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
    }
}

// MARK: - Link previews

/// Title, site and image of a link, fetched on this device with Apple's LinkPresentation (no server).
@MainActor
final class LinkPreviewStore: ObservableObject {
    static let shared = LinkPreviewStore()
    struct Preview { var title: String; var host: String; var image: UIImage? }
    @Published private(set) var previews: [URL: Preview] = [:]
    private var loading: Set<URL> = []

    func load(_ url: URL) {
        guard previews[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        Task {
            let provider = LPMetadataProvider()
            provider.timeout = 8
            if let meta = try? await provider.startFetchingMetadata(for: url) {
                var image: UIImage?
                if let ip = meta.imageProvider ?? meta.iconProvider {
                    image = await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
                        _ = ip.loadObject(ofClass: UIImage.self) { obj, _ in c.resume(returning: obj as? UIImage) }
                    }
                }
                previews[url] = Preview(title: meta.title ?? url.absoluteString, host: url.host() ?? "", image: image)
            } else {
                previews[url] = Preview(title: url.absoluteString, host: url.host() ?? "", image: nil)
            }
            loading.remove(url)
        }
    }

    static func firstURL(in text: String) -> URL? {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return d.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.url
    }

    static func allURLs(in text: String) -> [URL] {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return d.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap(\.url)
    }
}

struct LinkPreviewCard: View {
    let url: URL
    @ObservedObject private var store = LinkPreviewStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        let p = store.previews[url]
        Button { openURL(url) } label: {
            HStack(spacing: 10) {
                Group {
                    if let img = p?.image {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "link").font(.title3).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.gray.opacity(0.2))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p?.title ?? url.absoluteString).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(p?.host ?? url.host() ?? "").font(.caption2).opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onAppear { store.load(url) }
    }
}
