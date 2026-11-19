import SwiftUI
import SwiftData

/// WhatsApp-style poll card inside a chat bubble.
struct PollCard: View {
    let pollID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var found: [Poll]
    @State private var showVotes = false

    init(pollID: String) {
        self.pollID = pollID
        _found = Query(filter: #Predicate<Poll> { $0.id == pollID })
    }

    var body: some View {
        if let poll = found.first {
            content(poll)
        } else {
            Label("Poll", systemImage: "chart.bar.fill")
        }
    }

    private func content(_ poll: Poll) -> some View {
        let total = max(poll.totalVoters, 1)
        let mine = Set(poll.votes[engine.me]?.options ?? [])
        let maxVotes = poll.options.map { poll.voters(for: $0.id).count }.max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Label("POLL", systemImage: "chart.bar.fill").font(.caption2.weight(.bold)).opacity(0.75)
            Text(poll.question).font(.headline)
            Text(poll.multiple ? "Select one or more" : "Select one").font(.caption2).opacity(0.7)
            ForEach(poll.options) { o in
                let voters = poll.voters(for: o.id)
                Button {
                    Haptics.tap()
                    var next = mine
                    if poll.multiple {
                        if next.contains(o.id) { next.remove(o.id) } else { next.insert(o.id) }
                    } else {
                        next = next.contains(o.id) ? [] : [o.id]
                    }
                    engine.vote(poll, options: poll.options.map(\.id).filter { next.contains($0) })
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: mine.contains(o.id) ? (poll.multiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                                                                  : (poll.multiple ? "square" : "circle"))
                            Text(o.text).font(.subheadline).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if !voters.isEmpty {
                                HStack(spacing: -6) {
                                    ForEach(voters.prefix(3), id: \.self) { v in
                                        AvatarView(name: engine.name(of: v), imageData: v == engine.me ? engine.myAvatar : engine.contact(v)?.avatar, size: 18)
                                    }
                                }
                            }
                            Text("\(voters.count)").font(.caption.bold()).monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.12))
                                Capsule().fill(voters.count == maxVotes && maxVotes > 0 ? look.success : look.accent)
                                    .frame(width: geo.size.width * CGFloat(voters.count) / CGFloat(total))
                                    .animation(.spring(duration: 0.5), value: voters.count)
                            }
                        }
                        .frame(height: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { showVotes = true } label: {
                Text(poll.totalVoters == 0 ? "No votes yet" : "View votes (\(poll.totalVoters))")
                    .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(minWidth: 240, alignment: .leading)
        .sheet(isPresented: $showVotes) {
            NavigationStack { PollVotesView(poll: poll) }.presentationDetents([.medium, .large])
        }
    }
}

struct PollVotesView: View {
    let poll: Poll
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look

    var body: some View {
        List {
            Section { Text(poll.question).font(.headline) }.lookRows()
            ForEach(poll.options) { o in
                let voters = poll.voters(for: o.id)
                Section("\(o.text) · \(voters.count) vote\(voters.count == 1 ? "" : "s")") {
                    if voters.isEmpty { Text("No votes").foregroundStyle(look.textSecondary) }
                    ForEach(voters, id: \.self) { v in
                        HStack {
                            AvatarView(name: engine.name(of: v), imageData: v == engine.me ? engine.myAvatar : engine.contact(v)?.avatar, size: 30)
                            Text(engine.name(of: v))
                            Spacer()
                            if let at = poll.votes[v]?.at { Text(Fmt.chatTime(at)).font(.caption).foregroundStyle(look.textSecondary) }
                        }
                    }
                }
                .lookRows()
            }
        }
        .lookScreen()
        .navigationTitle("Votes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct PollComposer: View {
    let conv: Conversation
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multiple = false

    private var valid: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty &&
        options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
    }

    var body: some View {
        Form {
            Section("Question") {
                TextField("Ask a question", text: $question, axis: .vertical).lineLimit(1...4)
            }
            .lookRows()
            Section {
                ForEach(options.indices, id: \.self) { i in
                    HStack {
                        TextField("Option \(i + 1)", text: $options[i])
                        if options.count > 2 {
                            Button { options.remove(at: i) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if options.count < 12 {
                    Button { options.append("") } label: { Label("Add option", systemImage: "plus.circle") }
                }
            } header: { Text("Options") }
            .lookRows()
            Section {
                Toggle("Allow multiple answers", isOn: $multiple)
            }
            .lookRows()
        }
        .lookScreen()
        .navigationTitle("Create poll")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    engine.createPoll(in: conv, question: question.trimmingCharacters(in: .whitespacesAndNewlines), options: options, multiple: multiple)
                    Haptics.success()
                    dismiss()
                }
                .bold()
                .disabled(!valid)
            }
        }
    }
}
