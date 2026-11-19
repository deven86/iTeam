import SwiftUI
import SwiftData

/// "Media, links and docs" for one chat, like WhatsApp.
struct ChatMediaView: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var messages: [Message]
    @State private var tab = 0
    @State private var preview: URL?

    init(conv: Conversation) {
        self.conv = conv
        let id = conv.id
        _messages = Query(filter: #Predicate<Message> { $0.convID == id && !$0.deleted }, sort: \Message.createdAt, order: .reverse)
    }

    private var media: [AttachmentRef] { messages.flatMap(\.attachments).filter { $0.kind == "image" } }
    private var docs: [(AttachmentRef, Message)] { messages.flatMap { m in m.attachments.filter { $0.kind != "image" }.map { ($0, m) } } }
    private var links: [(URL, Message)] { messages.flatMap { m in LinkPreviewStore.allURLs(in: m.text).map { ($0, m) } } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Media (\(media.count))").tag(0)
                Text("Docs (\(docs.count))").tag(1)
                Text("Links (\(links.count))").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            switch tab {
            case 0:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], spacing: 4) {
                        ForEach(media) { AttachmentThumb(ref: $0, size: 110) }
                    }
                    .padding(.horizontal, 4)
                    if media.isEmpty { empty("No photos yet") }
                }
            case 1:
                List {
                    ForEach(docs, id: \.0.id) { pair in
                        HStack(spacing: 12) {
                            AttachmentThumb(ref: pair.0, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.0.name).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text("\(Fmt.bytes(pair.0.size)) · \(engine.name(of: pair.1.senderID)) · \(Fmt.chatTime(pair.1.createdAt))")
                                    .font(.caption2).foregroundStyle(look.textSecondary)
                            }
                        }
                    }
                    .lookRows()
                    if docs.isEmpty { empty("No documents yet").listRowBackground(Color.clear) }
                }
                .lookScreen()
            default:
                List {
                    ForEach(links, id: \.1.id) { pair in
                        VStack(alignment: .leading, spacing: 4) {
                            LinkPreviewCard(url: pair.0)
                            Text("\(engine.name(of: pair.1.senderID)) · \(Fmt.chatTime(pair.1.createdAt))")
                                .font(.caption2).foregroundStyle(look.textSecondary)
                        }
                    }
                    .lookRows()
                    if links.isEmpty { empty("No links yet").listRowBackground(Color.clear) }
                }
                .lookScreen()
            }
        }
        .background { if look.style != .classic { LookBackdrop() } }
        .navigationTitle("Media, links & docs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(look.textSecondary).frame(maxWidth: .infinity).padding(40)
    }
}
