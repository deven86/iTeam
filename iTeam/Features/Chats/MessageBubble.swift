import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: Message
    let conv: Conversation
    let showSender: Bool
    let all: [Message]
    var onReply: () -> Void
    var onEdit: () -> Void
    var onTask: () -> Void
    var onOpen: (URL) -> Void
    var onForward: () -> Void = {}
    var onShare: () -> Void = {}

    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look

    private var mine: Bool { message.senderID == engine.me }
    private static let quickReactions = ["👍", "❤️", "😂", "😮", "🙏", "✅"]

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(look.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .lookFloating(in: Capsule())
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom) {
                if mine { Spacer(minLength: 50) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                    if showSender {
                        Text(engine.name(of: message.senderID)).font(.caption.bold())
                            .foregroundStyle(AvatarView.colors(for: engine.name(of: message.senderID)).first ?? look.accent)
                            .padding(.horizontal, 12)
                    }
                    bubble
                    if !message.reactions.isEmpty { reactionRow }
                }
                if !mine { Spacer(minLength: 50) }
            }
            .padding(.top, showSender ? 6 : 0)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyID = message.replyToID, let original = all.first(where: { $0.id == replyID }) {
                HStack(spacing: 6) {
                    Rectangle().fill(mine ? look.bubbleOutText.opacity(0.7) : look.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(engine.name(of: original.senderID)).font(.caption.bold())
                        Text(original.preview).font(.caption).lineLimit(2)
                    }
                    .opacity(0.85)
                }
                .padding(6)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            if let at = message.showAt, !message.deleted {
                Label(at > .now ? "Magic moment · appears \(at.formatted(date: .abbreviated, time: .shortened))" : "Magic moment",
                      systemImage: "sparkles")
                    .font(.caption2.weight(.semibold)).opacity(0.85)
            }
            if message.expiresAt != nil && !message.deleted {
                Image(systemName: "timer").font(.caption2).opacity(0.6).accessibilityLabel("Disappearing message")
            }
            if message.forwarded && !message.deleted {
                Label("Forwarded", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.caption2.italic()).opacity(0.75)
            }
            if message.deleted {
                Label("This message was deleted", systemImage: "nosign").font(.subheadline.italic()).opacity(0.7)
            } else if let approvalID = message.approvalID {
                ApprovalCard(approvalID: approvalID)
            } else if let pollID = message.pollID {
                PollCard(pollID: pollID)
            } else {
                let visual = message.attachments.filter { $0.kind == "image" || $0.kind == "video" }
                if visual.count > 1 {
                    PhotoStackView(refs: visual, onOpen: onOpen)
                    ForEach(message.attachments.filter { $0.kind != "image" && $0.kind != "video" }) { a in
                        AttachmentView(ref: a, onOpen: onOpen)
                    }
                } else {
                    ForEach(message.attachments) { a in
                        AttachmentView(ref: a, onOpen: onOpen)
                    }
                }
                if !message.text.isEmpty {
                    if let call = FaceTime.isLink(message.text) {
                        Button { UIApplication.shared.open(call) } label: {
                            Label("Join video call", systemImage: "video.fill").font(.headline)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Color.green, in: Capsule()).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    } else if let url = LinkPreviewStore.firstURL(in: message.text) {
                        LinkPreviewCard(url: url).frame(maxWidth: 280)
                    }
                    Text(linkified(message.text))
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            if let taskID = message.taskID, let t = engine.task(taskID) {
                Button { router.show(task: taskID) } label: {
                    Label(t.deleted ? "Task deleted: \(t.title)" : t.isDone ? "Task done: \(t.title)" : "Task: \(t.title)",
                          systemImage: t.deleted ? "trash" : t.status.icon)
                        .strikethrough(t.deleted)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            footer
        }
        .foregroundStyle(mine ? look.bubbleOutText : look.bubbleInText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { background }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu { menu }
        .onTapGesture(count: 2) {
            Haptics.tap()
            engine.react(message, "👍")
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: mine ? 18 : 6,
                                           bottomTrailingRadius: mine ? 6 : 18, topTrailingRadius: 18, style: .continuous)
        if mine {
            shape.fill(look.bubbleOut)
        } else if look.glassCards {
            Color.clear.glassEffect(look.glassClear ? .clear : .regular, in: shape)
        } else {
            shape.fill(look.bubbleIn)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if message.editedAt != nil && !message.deleted { Text("edited") }
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            if mine { statusIcon }
        }
        .font(.caption2)
        .opacity(0.75)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Honest status: a clock until iCloud has it; ticks only after the other side acknowledged.
    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .queued:
            Image(systemName: "clock").accessibilityLabel("Saved on this device — waiting to sync")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Not sent")
        case .sent:
            let others = conv.members.map(\.id).filter { $0 != engine.me }
            let marks = conv.receipts
            let read = !others.isEmpty && others.allSatisfy { (marks[$0]?.read ?? .distantPast) >= message.createdAt }
            let delivered = !others.isEmpty && others.allSatisfy { (marks[$0]?.delivered ?? .distantPast) >= message.createdAt }
            if read {
                Image(systemName: "checkmark.circle.fill").accessibilityLabel("Read")
            } else if delivered {
                Image(systemName: "checkmark.circle").accessibilityLabel("Delivered")
            } else {
                Image(systemName: "checkmark").accessibilityLabel("Sent")
            }
        }
    }

    private var reactionRow: some View {
        let counts = Dictionary(grouping: message.reactions.values, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        return HStack(spacing: 4) {
            ForEach(counts, id: \.0) { pair in
                Text(pair.1 > 1 ? "\(pair.0) \(pair.1)" : pair.0).font(.caption)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .lookFloating(in: Capsule())
        .offset(y: -4)
        .onTapGesture { engine.react(message, message.reactions[engine.me] ?? "👍") }
    }

    @ViewBuilder
    private var menu: some View {
        if !message.deleted {
            ControlGroup {
                ForEach(Self.quickReactions, id: \.self) { e in
                    Button(e) { engine.react(message, e) }
                }
            }
            .controlGroupStyle(.compactMenu)
            Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply() }
            if !message.text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            }
            if message.approvalID == nil && message.pollID == nil && (!message.text.isEmpty || !message.attachments.isEmpty) {
                Button("Forward", systemImage: "arrowshape.turn.up.right") { onForward() }
                Button("Share…", systemImage: "square.and.arrow.up") { onShare() }
            }
            Button("Create Business Task", systemImage: "checklist") { onTask() }
            if mine && !message.text.isEmpty && message.approvalID == nil && message.pollID == nil {
                Button("Edit", systemImage: "pencil") { onEdit() }
            }
            if message.status == .failed {
                Button("Retry sending", systemImage: "arrow.clockwise") { engine.retryFailed() }
            }
            if mine {
                Button("Delete for everyone", systemImage: "trash", role: .destructive) { engine.unsend(message) }
            }
        }
    }

    private func linkified(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return a }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: a),
                  let upper = AttributedString.Index(range.upperBound, within: a) else { continue }
            a[lower..<upper].link = url
            a[lower..<upper].underlineStyle = .single
        }
        return a
    }
}
