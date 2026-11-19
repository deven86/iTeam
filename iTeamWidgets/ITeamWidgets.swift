import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Timeline

struct SnapEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct SnapProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapEntry { SnapEntry(date: .now, snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapEntry) -> Void) {
        completion(SnapEntry(date: .now, snap: context.isPreview ? .sample : WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapEntry>) -> Void) {
        let entry = SnapEntry(date: .now, snap: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

extension WidgetSnapshot {
    static var sample: WidgetSnapshot {
        var s = WidgetSnapshot()
        s.name = "Devendra"; s.dueToday = 3; s.overdue = 1; s.awaitingMe = 1; s.unreadChats = 4; s.doneToday = 2
        s.tasks = [.init(title: "File reply in court", due: .now.addingTimeInterval(3600), overdue: false, chat: "Office", id: "1"),
                   .init(title: "Review draft agreement", due: .now.addingTimeInterval(-3600), overdue: true, chat: "Team", id: "2")]
        s.nextDoseName = "Metformin 500 mg"; s.nextDosePerson = "Aai"; s.nextDoseAt = .now.addingTimeInterval(5400); s.dosesLeftToday = 2
        s.gymName = "Gold's Gym"; s.gymDaysLeft = 25; s.trainingDaysMonth = 9
        s.mindMinutesToday = 12; s.mindStreak = 5
        s.hasCare = true; s.hasGym = true; s.hasMind = true
        return s
    }
}

private let brand = LinearGradient(colors: [Color(red: 1, green: 0.6, blue: 0.35), Color(red: 0.94, green: 0.34, blue: 0.48), Color(red: 0.48, green: 0.25, blue: 0.89)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

private func time(_ d: Date?) -> String { d.map { $0.formatted(date: .omitted, time: .shortened) } ?? "" }

// MARK: - My Day

struct MyDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "iteam.myday", provider: SnapProvider()) { e in
            MyDayView(s: e.snap).containerBackground(brand, for: .widget).widgetURL(URL(string: "iteam://open/myday"))
        }
        .configurationDisplayName("My Day")
        .description("What's due, overdue and waiting for you today.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct MyDayView: View {
    let s: WidgetSnapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        switch family {
        case .accessoryInline:
            Text("📋 \(s.dueToday) due · \(s.overdue) late")
        case .accessoryCircular:
            Gauge(value: Double(s.doneToday), in: 0...Double(max(1, s.doneToday + s.dueToday))) {
                Image(systemName: "checklist")
            } currentValueLabel: { Text("\(s.dueToday)") }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("iTeam · today", systemImage: "sun.max.fill").font(.caption2.bold())
                Text("\(s.dueToday) due · \(s.overdue) overdue").font(.caption)
                if let t = s.tasks.first { Text(t.title).font(.caption2).lineLimit(1) }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                Label("My Day", systemImage: "sun.max.fill").font(.caption.bold())
                Spacer(minLength: 0)
                Text("\(s.dueToday)").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("due today").font(.caption)
                HStack(spacing: 8) {
                    if s.overdue > 0 { Label("\(s.overdue)", systemImage: "exclamationmark.triangle.fill") }
                    if s.unreadChats > 0 { Label("\(s.unreadChats)", systemImage: "bubble.left.fill") }
                }
                .font(.caption2.bold())
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("My Day", systemImage: "sun.max.fill").font(.caption.bold())
                    Spacer()
                    Text("\(s.dueToday) due · \(s.overdue) late · \(s.unreadChats) chats").font(.caption2)
                }
                if s.awaitingMe > 0 { Label("\(s.awaitingMe) task\(s.awaitingMe == 1 ? "" : "s") to accept", systemImage: "hand.raised.fill").font(.caption.bold()) }
                ForEach(s.tasks.prefix(family == .systemLarge ? 8 : 3), id: \.self) { t in
                    Link(destination: URL(string: "iteam://task/\(t.id)")!) {
                        HStack {
                            Image(systemName: t.overdue ? "exclamationmark.circle.fill" : "circle")
                            Text(t.title).lineLimit(1)
                            Spacer()
                            Text(t.overdue ? "late" : time(t.due)).font(.caption2)
                        }
                        .font(.caption)
                    }
                }
                if s.tasks.isEmpty { Text("Nothing due. 🎉").font(.caption) }
                if family == .systemLarge, let dose = s.nextDoseName {
                    Divider().overlay(.white.opacity(0.5))
                    Label("\(s.nextDosePerson ?? ""): \(dose) at \(time(s.nextDoseAt))", systemImage: "pills.fill").font(.caption)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Care

struct CareWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "iteam.care", provider: SnapProvider()) { e in
            CareWidgetView(s: e.snap)
                .containerBackground(LinearGradient(colors: [Color(red: 1, green: 0.54, blue: 0.36), Color(red: 0.9, green: 0.28, blue: 0.42)], startPoint: .top, endPoint: .bottom), for: .widget)
                .widgetURL(URL(string: "iteam://open/care"))
        }
        .configurationDisplayName("Next medicine")
        .description("The next dose for the people you care for.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct CareWidgetView: View {
    let s: WidgetSnapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if !s.hasCare {
            Label("iLife Care", systemImage: "heart.text.square.fill").font(.caption).foregroundStyle(.white)
        } else {
            switch family {
            case .accessoryInline: Text("💊 \(s.nextDoseName ?? "No doses") \(time(s.nextDoseAt))")
            case .accessoryCircular:
                VStack(spacing: 0) { Image(systemName: "pills.fill"); Text("\(s.dosesLeftToday)").font(.headline) }
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label("Next dose", systemImage: "pills.fill").font(.caption2.bold())
                    Text(s.nextDoseName ?? "All done today").font(.caption).lineLimit(1)
                    if let at = s.nextDoseAt { Text("\(s.nextDosePerson ?? "") · \(time(at))").font(.caption2) }
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Care", systemImage: "heart.text.square.fill").font(.caption.bold())
                    Spacer(minLength: 0)
                    Text(s.nextDoseName ?? "All doses done 🎉").font(.headline).lineLimit(2)
                    if let at = s.nextDoseAt { Text("\(s.nextDosePerson ?? "") · \(time(at))").font(.caption) }
                    Text("\(s.dosesLeftToday) left today").font(.caption2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Gym & Mind

struct GymWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "iteam.gym", provider: SnapProvider()) { e in
            GymWidgetView(s: e.snap)
                .containerBackground(LinearGradient(colors: [Color(red: 0.31, green: 0.82, blue: 0.77), Color(red: 0.17, green: 0.42, blue: 0.69)], startPoint: .top, endPoint: .bottom), for: .widget)
                .widgetURL(URL(string: "iteam://open/gym"))
        }
        .configurationDisplayName("Gym")
        .description("Membership days left and training this month.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct GymWidgetView: View {
    let s: WidgetSnapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        switch family {
        case .accessoryInline: Text("🏋️ \(s.trainingDaysMonth) sessions · \(s.gymDaysLeft.map { "\($0)d left" } ?? "")")
        case .accessoryCircular:
            Gauge(value: Double(min(s.trainingDaysMonth, 20)), in: 0...20) { Image(systemName: "dumbbell.fill") } currentValueLabel: { Text("\(s.trainingDaysMonth)") }
                .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label(s.trainedToday ? "Trained today ✓" : "Not trained yet", systemImage: "dumbbell.fill").font(.caption2.bold())
                Text("\(s.trainingDaysMonth) sessions this month").font(.caption)
                if let d = s.gymDaysLeft { Text("\(s.gymName ?? "Gym"): \(d) days left").font(.caption2) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Gym", systemImage: "dumbbell.fill").font(.caption.bold())
                Spacer(minLength: 0)
                Text("\(s.trainingDaysMonth)").font(.system(size: 36, weight: .bold, design: .rounded))
                Text("sessions this month").font(.caption2)
                if let d = s.gymDaysLeft { Text("\(d) days left").font(.caption.bold()) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MindWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "iteam.mind", provider: SnapProvider()) { e in
            VStack(alignment: .leading, spacing: 4) {
                Label("Mindfulness", systemImage: "leaf.fill").font(.caption.bold())
                Spacer(minLength: 0)
                Text("\(e.snap.mindMinutesToday) min").font(.title.bold())
                Text("\(e.snap.mindStreak)🔥 day streak").font(.caption)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(LinearGradient(colors: [Color(red: 0.49, green: 0.84, blue: 0.7), Color(red: 0.23, green: 0.55, blue: 0.6)], startPoint: .top, endPoint: .bottom), for: .widget)
            .widgetURL(URL(string: "iteam://open/mind"))
        }
        .configurationDisplayName("Mindfulness")
        .description("Mindful minutes today and your streak.")
        .supportedFamilies([.systemSmall, .accessoryInline])
    }
}

// MARK: - Live Activity (Lock Screen + Dynamic Island)

struct ITeamLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ITeamActivityAttributes.self) { ctx in
            HStack(spacing: 12) {
                Image(systemName: ctx.attributes.icon).font(.title2).foregroundStyle(tint(ctx.attributes.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.state.title).font(.headline).lineLimit(1)
                    Text(ctx.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(timerInterval: Date.now...max(ctx.state.end, .now), countsDown: true)
                    .font(.title3.monospacedDigit().bold()).multilineTextAlignment(.trailing).frame(width: 80)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.35))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: ctx.attributes.icon).font(.title2).foregroundStyle(tint(ctx.attributes.tint))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date.now...max(ctx.state.end, .now), countsDown: true)
                        .font(.title3.monospacedDigit().bold()).frame(width: 72)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ctx.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        Text(ctx.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(timerInterval: ctx.state.progressStart...max(ctx.state.end, ctx.state.progressStart.addingTimeInterval(1)), countsDown: false)
                            .tint(tint(ctx.attributes.tint))
                    }
                }
            } compactLeading: {
                Image(systemName: ctx.attributes.icon).foregroundStyle(tint(ctx.attributes.tint))
            } compactTrailing: {
                Text(timerInterval: Date.now...max(ctx.state.end, .now), countsDown: true).monospacedDigit().frame(width: 48)
            } minimal: {
                Image(systemName: ctx.attributes.icon).foregroundStyle(tint(ctx.attributes.tint))
            }
            .widgetURL(URL(string: "iteam://open/\(ctx.attributes.kind)"))
        }
    }

    private func tint(_ hex: String) -> Color {
        let v = UInt32(hex, radix: 16) ?? 0xF0567A
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

@main
struct ITeamWidgetBundle: WidgetBundle {
    var body: some Widget {
        MyDayWidget()
        CareWidget()
        GymWidget()
        MindWidget()
        ITeamLiveActivity()
    }
}
