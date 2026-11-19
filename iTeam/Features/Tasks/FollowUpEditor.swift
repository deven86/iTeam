import SwiftUI

/// Business Tasks Pro: the task creator sets how often iTeam follows up until the work is done.
struct FollowUpEditor: View {
    let task: TaskItem
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var look
    @State private var on = true
    @State private var times: [Date] = [AISettingsView.date(600)]
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var indefinite = true
    @State private var until = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var wholeGroup = false

    private static let dayNames = Calendar.current.veryShortWeekdaySymbols   // S M T W T F S

    static func summary(_ f: FollowUp) -> String {
        let days = f.weekdays.count == 7 ? "every day" : f.weekdays.count == 5 && !f.weekdays.contains(1) && !f.weekdays.contains(7)
            ? "weekdays" : "\(f.weekdays.count) days a week"
        let end = f.until.map { "till \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "until done"
        return "\(f.times.count)× a day, \(days), \(end)"
    }

    private var isGroupTask: Bool { task.convID.flatMap { engine.conversation($0)?.isGroup } ?? false }

    var body: some View {
        Form {
            Section {
                Toggle("Follow up on this task", isOn: $on)
            } footer: {
                Text("Everyone on the task gets a reminder asking if it's done, at the times below, until it's completed.")
            }
            .lookRows()
            if on {
                Section("How many times a day") {
                    ForEach(times.indices, id: \.self) { i in
                        HStack {
                            DatePicker("Time \(i + 1)", selection: $times[i], displayedComponents: .hourAndMinute)
                            if times.count > 1 {
                                Button { times.remove(at: i) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(look.danger) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if times.count < 4 {
                        Button("Add a time", systemImage: "plus") {
                            times.append(Calendar.current.date(byAdding: .hour, value: 4, to: times.last ?? .now) ?? .now)
                        }
                    }
                }
                .lookRows()
                Section("Which days") {
                    HStack {
                        ForEach(1...7, id: \.self) { d in
                            let sel = weekdays.contains(d)
                            Button {
                                if sel { if weekdays.count > 1 { weekdays.remove(d) } } else { weekdays.insert(d) }
                            } label: {
                                Text(Self.dayNames[d - 1]).font(.subheadline.bold())
                                    .frame(width: 36, height: 36)
                                    .background(sel ? AnyShapeStyle(look.gradient) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Circle())
                                    .foregroundStyle(sel ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .lookRows()
                Section("Until") {
                    Toggle("Until the work is completed", isOn: $indefinite)
                    if !indefinite { DatePicker("End date", selection: $until, in: Date.now..., displayedComponents: .date) }
                }
                .lookRows()
                if isGroupTask {
                    Section {
                        Toggle("Follow up with the whole group", isOn: $wholeGroup)
                    } footer: {
                        Text("Off: only the people assigned (and you). On: everyone in the group chat.")
                    }
                    .lookRows()
                }
            }
        }
        .lookScreen()
        .navigationTitle("Follow-up")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold() }
        }
        .onAppear {
            guard let f = task.followUp else { return }
            times = f.times.map { AISettingsView.date($0) }
            weekdays = Set(f.weekdays)
            indefinite = f.until == nil
            until = f.until ?? until
            wholeGroup = f.wholeGroup
        }
    }

    private func save() {
        let f: FollowUp? = on ? FollowUp(times: times.map(AISettingsView.minutes).sorted(), weekdays: weekdays.sorted(),
                                         until: indefinite ? nil : until, wholeGroup: wholeGroup) : nil
        engine.updateTask(task, fields: ["followUp"], change: on ? "set a follow-up: \(f.map(Self.summary) ?? "")" : "turned off the follow-up",
                          loud: on) { $0.followUp = f }
        engine.save()
        if let ctx = engine.context { Reminders.shared.reschedule(context: ctx, me: engine.me) }
        Haptics.success()
        dismiss()
    }
}
