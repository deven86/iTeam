import SwiftUI
import SwiftData

/// Mentions, task updates, group changes and sync status in one place.
struct ActivityView: View {
    @EnvironmentObject var engine: SyncEngine
    @EnvironmentObject var router: Router
    @Environment(\.look) private var look
    @Query(sort: \ActivityItem.date, order: .reverse) private var items: [ActivityItem]

    var body: some View {
        NavigationStack {
            List {
                Section { SyncStatusCard().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }

                if items.isEmpty {
                    EmptyStateView(icon: "bell", title: "No activity yet",
                                   message: "Mentions, tasks assigned to you and group changes show up here.")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                ForEach(sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { a in
                            Button { open(a) } label: { row(a) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { engine.context.delete(a); engine.save() }
                                }
                        }
                    }
                    .lookRows()
                }
            }
            .listStyle(.insetGrouped)
            .lookScreen()
            .refreshable { await engine.sync() }
            .navigationTitle("Activity")
            .toolbar {
                if items.contains(where: { !$0.read }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Mark all read") {
                            for a in items where !a.read { a.read = true }
                            engine.save()
                        }
                    }
                }
            }
        }
    }

    private var sections: [(String, [ActivityItem])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: items) { a -> String in
            if cal.isDateInToday(a.date) { return "Today" }
            if cal.isDateInYesterday(a.date) { return "Yesterday" }
            return a.date.formatted(.dateTime.day().month(.wide).year())
        }
        return groups.map { ($0.key, $0.value) }.sorted { ($0.1.first?.date ?? .distantPast) > ($1.1.first?.date ?? .distantPast) }
    }

    private func row(_ a: ActivityItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: a.kind.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(LinearGradient(colors: AvatarView.colors(for: a.kindRaw), startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(a.text).font(.subheadline.weight(a.read ? .regular : .semibold))
                Text(a.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(look.textSecondary)
            }
            Spacer(minLength: 0)
            if !a.read { Circle().fill(look.accent).frame(width: 9, height: 9).padding(.top, 6) }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func open(_ a: ActivityItem) {
        a.read = true
        engine.save()
        if let t = a.taskID { router.show(task: t) }
        else if let c = a.convID { router.show(conversation: c) }
        else if a.kind == .contact { router.tab = .chats }
    }
}

/// Honest connectivity: what's synced, what's waiting, and what notifications can and can't do.
struct SyncStatusCard: View {
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).font(.title3).foregroundStyle(color)
                    .symbolEffect(.rotate, isActive: engine.status == .syncing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.status.label).font(.headline)
                    if let last = engine.lastSync {
                        Text("Last synced \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(look.textSecondary)
                    } else {
                        Text("Not synced yet").font(.caption).foregroundStyle(look.textSecondary)
                    }
                }
                Spacer()
                Button { Task { await engine.sync() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(engine.status == .syncing)
            }
            if engine.pendingUploads > 0 {
                Text("\(engine.pendingUploads) change\(engine.pendingUploads == 1 ? "" : "s") saved on this device, waiting to upload.")
                    .font(.caption).foregroundStyle(look.textSecondary)
            }
            if engine.failedUploads > 0 {
                Button("Retry \(engine.failedUploads) that couldn't be sent") { engine.retryFailed() }.font(.caption.bold())
            }
        }
        .lookCard()
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch engine.status {
        case .idle: "checkmark.icloud.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "icloud.slash"
        case .noAccount, .failed: "exclamationmark.icloud.fill"
        }
    }

    private var color: Color {
        switch engine.status {
        case .idle: look.success
        case .syncing: look.accent
        default: look.warning
        }
    }
}
