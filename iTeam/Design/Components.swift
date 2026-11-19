import SwiftUI
import UIKit

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func thump() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Press + entrance animations (from iLife)

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct AppearModifier: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.look) private var look

    func body(content: Content) -> some View {
        // The classic look stays still; the glass looks rise in.
        if look.style == .classic || reduceMotion {
            content
        } else {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18)
                .scaleEffect(shown ? 1 : 0.97)
                .onAppear {
                    guard !shown else { return }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(min(index, 10)) * 0.05)) { shown = true }
                }
        }
    }
}

extension View {
    func appear(_ index: Int = 0) -> some View { modifier(AppearModifier(index: index)) }
}

// MARK: - Logo

struct AppLogo: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x28BEE6), Color(hex: 0x3A5BD9), Color(hex: 0x7850F0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "checkmark.bubble.fill").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0x28BEE6).opacity(0.45), radius: size * 0.18)
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let name: String
    var imageData: Data? = nil
    var size: CGFloat = 44
    var isGroup = false

    var body: some View {
        Group {
            if let imageData, let img = UIImage(data: imageData) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(LinearGradient(colors: Self.colors(for: name), startPoint: .topLeading, endPoint: .bottomTrailing))
                    if isGroup {
                        Image(systemName: "person.3.fill").font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(.white)
                    } else {
                        Text(Self.initials(name)).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    /// Stable pair of colours per name.
    static func colors(for name: String) -> [Color] {
        let palettes: [[UInt32]] = [[0x28BEE6, 0x3A5BD9], [0xFF8A5B, 0xE5486B], [0x4CD38A, 0x1E9A6E], [0xB57CFF, 0x6F5BD6],
                                    [0xFFC94D, 0xF07B2C], [0x5FD3DC, 0x2F7FD0], [0xFF7BAC, 0xB04BD0], [0x8BD15C, 0x3E8E5A]]
        var h: UInt32 = 5381
        for b in name.utf8 { h = (h &* 33) &+ UInt32(b) }
        return palettes[Int(h % UInt32(palettes.count))].map { Color(hex: $0) }
    }
}

// MARK: - Small pieces

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.look) private var look

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(look.gradient)
                .symbolEffect(.pulse, options: .repeating.speed(0.4))
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(look.textSecondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent).controlSize(.large).padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}

struct ProgressRing: View {
    let progress: Double
    var color: Color = .green
    var lineWidth: CGFloat = 6
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: progress)
        }
    }
}

struct Chip: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: String? = nil
    @Environment(\.look) private var look
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(look.textSecondary) }
        }
    }
}

/// Count badge for unread chats.
struct CountBadge: View {
    let count: Int
    var muted = false
    @Environment(\.look) private var look
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.bold()).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(muted ? AnyShapeStyle(Color.gray) : AnyShapeStyle(look.accent), in: Capsule())
    }
}

// MARK: - Formatting

enum Fmt {
    /// "10:42", "Yesterday", "Mon", "12/11/26"
    static func chatTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func due(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
