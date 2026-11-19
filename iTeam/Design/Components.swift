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

/// The iTeam "iT" mark: a clear glass tile with a bold rounded i and T, and a mint "done" badge.
/// Drawn in a 1024-unit grid so it matches the app icon exactly.
struct AppLogo: View {
    var size: CGFloat = 40

    var body: some View {
        let k = size / 1024
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0xFF9A5A), Color(hex: 0xF0567A), Color(hex: 0x7B3FE4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.38), .clear], center: UnitPoint(x: 0.3, y: 0.18), startRadius: 0, endRadius: size * 0.85)
            // Glass tile
            RoundedRectangle(cornerRadius: 160 * k, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 160 * k, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.25), .white.opacity(0.7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(0.8, 9 * k)))
                .frame(width: 644 * k, height: 564 * k)
                .offset(x: 190 * k, y: 230 * k)
                .shadow(color: Color(hex: 0x30104A).opacity(0.35), radius: 24 * k, y: 20 * k)
            // i
            Circle().fill(.white).frame(width: 104 * k, height: 104 * k).offset(x: 293 * k, y: 308 * k)
            Capsule().fill(.white).frame(width: 84 * k, height: 270 * k).offset(x: 303 * k, y: 440 * k)
            // T
            Capsule().fill(.white).frame(width: 300 * k, height: 84 * k).offset(x: 450 * k, y: 340 * k)
            Capsule().fill(.white).frame(width: 84 * k, height: 370 * k).offset(x: 558 * k, y: 340 * k)
            // Done badge
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x7CF5E0), Color(hex: 0x19C2A0)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(.white, lineWidth: max(0.6, 6 * k)))
                .overlay(
                    Image(systemName: "checkmark").font(.system(size: 62 * k, weight: .heavy)).foregroundStyle(.white)
                )
                .frame(width: 140 * k, height: 140 * k)
                .offset(x: 650 * k, y: 610 * k)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .shadow(color: Color(hex: 0xF0567A).opacity(0.35), radius: size * 0.12)
        .accessibilityLabel("iTeam")
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
