import Foundation
import SwiftData

/// Practice chats so one person can try everything: a "Notes to self" chat (syncs to your own iPad)
/// and a demo team with two simulated colleagues who reply. Demo chats never leave this device.
@MainActor
enum DemoChats {
    static let asha = "demo_asha"
    static let rahul = "demo_rahul"
    static let teamID = "g_demo-team"

    private static let replies = [
        "Got it 👍", "Sure, I'll check and update you.", "Can you share the file here?",
        "Done from my side.", "Let's discuss at 5 pm?", "Makes sense. Go ahead 🙂",
        "I'll need till tomorrow for this.", "Noted. Adding it to my list."
    ]

    /// "Notes to self": a private chat with yourself. Real (end-to-end encrypted), synced to your other devices.
    static func notesToSelf(_ engine: SyncEngine) -> Conversation {
        let id = engine.selfConversationID
        if let c = engine.conversation(id) { return c }
        let c = Conversation(id: id, kind: "direct", title: "Notes to self", ownerID: engine.me, peerID: engine.me,
                             members: [MemberInfo(id: engine.me, name: engine.myName, role: .owner)])
        engine.context.insert(c)
        engine.save()
        return c
    }

    /// Creates the demo team (and a one-to-one demo chat) with sample messages and tasks.
    @discardableResult
    static func create(_ engine: SyncEngine) -> Conversation {
        if let c = engine.conversation(teamID) { return c }
        let ctx = engine.context!
        let me = engine.me
        for (id, name) in [(asha, "Asha (demo)"), (rahul, "Rahul (demo)")] where engine.contact(id) == nil {
            ctx.insert(Contact(userID: id, name: name, publicKey: "", saved: false))
        }

        let team = Conversation(id: teamID, kind: "group", title: "Demo Team", ownerID: me,
                                members: [MemberInfo(id: me, name: engine.myName, role: .owner),
                                          MemberInfo(id: asha, name: "Asha (demo)", role: .admin),
                                          MemberInfo(id: rahul, name: "Rahul (demo)", role: .member)])
        team.isDemo = true
        ctx.insert(team)

        let direct = Conversation(id: SyncEngine.directID(me, asha), kind: "direct", title: "Asha (demo)", ownerID: me, peerID: asha,
                                  members: [MemberInfo(id: me, name: engine.myName, role: .member),
                                            MemberInfo(id: asha, name: "Asha (demo)", role: .member)])
        direct.isDemo = true
        ctx.insert(direct)

        let start = Date(timeIntervalSinceNow: -3 * 3600)
        func incoming(_ conv: Conversation, _ from: String, _ text: String, _ minutes: Double) {
            let e = Event(id: UUID().uuidString, conv: conv.id, from: from, at: start.addingTimeInterval(minutes * 60),
                          body: .message(MessagePayload(id: UUID().uuidString, text: text, replyTo: nil, attachments: [])))
            _ = EventApplier(engine: engine).apply(e, local: false)
        }
        ctx.insert(Message(id: UUID().uuidString, convID: team.id, senderID: "", text: "This is a demo team. Nothing here leaves your phone — try replies, reactions, tasks and themes.",
                           createdAt: start, status: .sent, isSystem: true))
        incoming(team, asha, "Good morning team ☀️ The client meeting moved to Friday.", 1)
        incoming(team, rahul, "Noted. I'll prepare the draft agreement by Thursday.", 4)
        incoming(team, asha, "@\(engine.myName.split(separator: " ").first ?? "") can you review the draft once Rahul shares it?", 6)
        incoming(direct, asha, "Hi! Long-press any message and choose “Create Business Task” to try tasks.", 2)

        // Sample tasks: one whole-group task where everyone finishes their part, one assigned to you.
        let stampNow = Date.now
        var stamps: [String: Date] = [:]
        for f in TaskItem.sharedFields { stamps[f] = stampNow }
        let groupTask = TaskPayload(id: UUID().uuidString, sourceMessageID: nil, title: "Prepare for Friday client meeting",
                                    notes: "Each person ticks off their own part.", status: .inProgress, priority: .high,
                                    dueAt: Calendar.current.date(byAdding: .day, value: 2, to: .now), policy: .all,
                                    assignees: [me, asha, rahul], createdBy: asha, createdAt: start, completedAt: nil, completedBy: nil,
                                    stamps: stamps, change: nil)
        let myTask = TaskPayload(id: UUID().uuidString, sourceMessageID: nil, title: "Review draft agreement",
                                 notes: "", status: .open, priority: .normal,
                                 dueAt: Date(timeIntervalSinceNow: 3 * 3600), policy: .any,
                                 assignees: [me], createdBy: rahul, createdAt: start, completedAt: nil, completedBy: nil,
                                 stamps: stamps, change: nil)
        for (p, from) in [(groupTask, asha), (myTask, rahul)] {
            let e = Event(id: UUID().uuidString, conv: team.id, from: from, at: start.addingTimeInterval(10 * 60), body: .task(p))
            _ = EventApplier(engine: engine).apply(e, local: false)
        }
        for (i, step) in ["Agenda", "Draft agreement", "Fee note"].enumerated() {
            let item = ChecklistItem(taskID: groupTask.id, title: step, position: Double(i), by: asha)
            item.done = i == 0
            ctx.insert(item)
        }
        var parts = [String: Date]()
        parts[asha] = start.addingTimeInterval(20 * 60)
        engine.task(groupTask.id)?.doneBy = parts

        team.unread = 3
        direct.unread = 1
        engine.save()
        Reminders.shared.reschedule(context: ctx, me: me)
        return team
    }

    /// Demo chats: apply locally, mark as delivered/read, and let a simulated colleague answer.
    static func localSend(_ body: Event.Body, in conv: Conversation, engine: SyncEngine) -> Event {
        let e = Event(id: UUID().uuidString, conv: conv.id, from: engine.me, at: .now, body: body)
        _ = EventApplier(engine: engine).apply(e, local: true)
        if case .approval(let a) = body {
            engine.message(a.messageID)?.status = .sent
            engine.save()
            // A pretend approver answers, so the whole approval flow can be tried alone.
            if let approver = a.approvers.first(where: { $0.hasPrefix("demo_") }) {
                let convID = conv.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    let partial = a.amount.map { ($0 * 0.4).rounded() }
                    let note = partial != nil ? "Only this much for now — share the bills after." : "Approved for 3 days only."
                    let d = Event(id: UUID().uuidString, conv: convID, from: approver, at: .now,
                                  body: .decision(DecisionPayload(approvalID: a.id, approved: true, note: note, amount: partial)))
                    _ = EventApplier(engine: engine).apply(d, local: false)
                    engine.save()
                }
            }
            return e
        }
        if case .poll(let poll) = body {
            engine.message(poll.messageID)?.status = .sent
            engine.save()
            let voters = conv.members.map(\.id).filter { $0.hasPrefix("demo_") }
            let convID = conv.id
            Task { @MainActor in
                for v in voters {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let pick = poll.options.randomElement() else { return }
                    let ev = Event(id: UUID().uuidString, conv: convID, from: v, at: .now,
                                   body: .vote(VotePayload(pollID: poll.id, optionIDs: [pick.id])))
                    _ = EventApplier(engine: engine).apply(ev, local: false)
                    engine.save()
                }
            }
            return e
        }
        guard case .message(let p) = body else { engine.save(); return e }
        engine.message(p.id)?.status = .sent
        engine.save()

        let others = conv.members.map(\.id).filter { $0 != engine.me }
        let convID = conv.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let c = engine.conversation(convID) else { return }
            var marks = c.receipts
            for o in others { marks[o] = ReceiptMark(delivered: .now, read: .now) }
            c.receipts = marks
            engine.save()

            try? await Task.sleep(for: .seconds(1.5))
            guard let replier = others.randomElement() else { return }
            let lower = p.text.lowercased()
            let text: String
            if lower.contains("task") { text = "On it — I'll mark my part done when finished ✅" }
            else if lower.contains("?") { text = "Good question. Let me check and get back in 10 minutes." }
            else if !p.attachments.isEmpty { text = "Thanks for the file 📎" }
            else { text = replies.randomElement() ?? "👍" }
            let reply = Event(id: UUID().uuidString, conv: convID, from: replier, at: .now,
                              body: .message(MessagePayload(id: UUID().uuidString, text: text, replyTo: p.id, attachments: [])))
            _ = EventApplier(engine: engine).apply(reply, local: false)
            engine.save()
        }
        return e
    }

    /// Removes all demo chats and their tasks from this device.
    static func remove(_ engine: SyncEngine) {
        let ctx = engine.context!
        for c in (try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.isDemo }))) ?? [] {
            let id: String? = c.id
            for t in (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.convID == id }))) ?? [] { ctx.delete(t) }
            for a in (try? ctx.fetch(FetchDescriptor<ActivityItem>(predicate: #Predicate { $0.convID == id }))) ?? [] { ctx.delete(a) }
            engine.deleteLocally(c)
        }
        engine.save()
    }
}
