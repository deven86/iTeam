import SwiftUI
import SwiftData
import PhotosUI

extension EventApplier {
    func applyAlbum(_ p: AlbumPayload, _ e: Event) -> Result {
        let id = p.id
        if let ex = try? ctx.fetch(FetchDescriptor<AlbumItem>(predicate: #Predicate { $0.id == id })).first {
            guard ex.by == e.from, p.deleted else { return .ignored }   // only the person who added it removes it
            ex.deleted = true
            return .applied
        }
        guard !p.deleted else { return .ignored }
        let a = AlbumItem(id: p.id)
        a.owner = p.owner; a.by = e.from; a.at = p.at
        a.refData = (try? JSONEncoder().encode(p.ref)) ?? Data()
        ctx.insert(a)
        return .applied
    }
}

@MainActor
extension SyncEngine {
    func albumAdd(_ refs: [AttachmentRef], owner: String, convID: String, uploads: [String: String]) {
        for (i, r) in refs.enumerated() {
            let body = Event.Body.album(AlbumPayload(id: "al_" + UUID().uuidString, owner: owner, ref: r, deleted: false, at: .now))
            let up = uploads.filter { $0.key == r.blob }
            if let conv = conversation(convID), !conv.left {
                send(body, in: conv, loud: i == 0, preview: i == 0 ? "📸 \(myName) added \(refs.count) photo\(refs.count == 1 ? "" : "s") to the album" : nil, uploads: up)
            } else {
                send(body, convID: selfConversationID, recipients: [], keyVersion: 0, loud: false, uploads: up)
            }
        }
    }

    func albumRemove(_ a: AlbumItem, convID: String) {
        guard let ref = a.ref else { return }
        let body = Event.Body.album(AlbumPayload(id: a.id, owner: a.owner, ref: ref, deleted: true, at: .now))
        if let conv = conversation(convID) { send(body, in: conv, loud: false) } else { sendPersonal(body) }
    }
}

/// Everyone in the event's or trip's chat can add photos and videos; each person can remove their own.
struct AlbumView: View {
    let owner: String
    let convID: String
    let title: String
    @EnvironmentObject var engine: SyncEngine
    @Query private var items: [AlbumItem]
    @State private var picks: [PhotosPickerItem] = []
    @State private var busy = false
    @State private var error: String?
    private let cols = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    init(owner: String, convID: String, title: String) {
        self.owner = owner; self.convID = convID; self.title = title
        _items = Query(filter: #Predicate<AlbumItem> { $0.owner == owner && !$0.deleted }, sort: \AlbumItem.at, order: .reverse)
    }

    var body: some View {
        ScrollView {
            if items.isEmpty && !busy {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle.angled", description: Text("Add photos and videos — everyone in this \(convID.isEmpty ? "album" : "chat") sees them."))
            }
            if busy { ProgressView("Adding…").padding() }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(items) { a in tile(a) }
            }
            .padding(4)
        }
        .lookScreen()
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PhotosPicker(selection: $picks, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) { Image(systemName: "plus") }
            }
        }
        .onChange(of: picks) { _, sel in
            guard !sel.isEmpty else { return }
            busy = true
            Task { @MainActor in
                var refs: [AttachmentRef] = [], ups: [String: String] = [:]
                for item in sel {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let m = try? await item.loadTransferable(type: MovieFile.self) {
                        do { let p = try await VideoPrep.prepare(m.url, maxSeconds: 180); refs.append(p.ref); ups[p.upload.0] = p.upload.1 } catch { self.error = error.localizedDescription }
                    } else if let d = try? await item.loadTransferable(type: Data.self), let p = try? Attachments.prepareImage(d) {
                        refs.append(p.ref); ups[p.upload.0] = p.upload.1
                    }
                }
                engine.albumAdd(refs, owner: owner, convID: convID, uploads: ups)
                picks = []; busy = false
                Haptics.success()
            }
        }
        .refreshable { await engine.sync() }
    }

    private func tile(_ a: AlbumItem) -> some View {
        let ref = a.ref
        return Button {
            guard let ref else { return }
            Task { @MainActor in if let u = try? await Attachments.load(ref) { Presenter.preview(u) } }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let t = ref?.thumb, let img = UIImage(data: t) { Image(uiImage: img).resizable().scaledToFill() }
                    else { Color.secondary.opacity(0.2).overlay(Image(systemName: "photo")) }
                }
                .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fill).clipped()
                if ref?.kind == "video" { Image(systemName: "play.circle.fill").foregroundStyle(.white).padding(4) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Text("Added by \(a.by == engine.me ? "you" : engine.name(of: a.by))")
            if a.by == engine.me { Button("Remove", systemImage: "trash", role: .destructive) { engine.albumRemove(a, convID: convID) } }
        }
    }
}
