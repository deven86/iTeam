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

/// The iTeam mark, drawn from one family of circles whose radii shrink by the golden ratio
/// (r, r/φ, r/φ², …) — the same construction idea behind classic logo grids. A clear glass
/// "chat" bubble with a solid "done" bubble in front: talk, then get it done.
struct LogoGeometry {
    static let phi: CGFloat = (1 + CGFloat(5).squareRoot()) / 2
    static let r1: CGFloat = 0.30
    static var r2: CGFloat { r1 / phi }
    static var r3: CGFloat { r2 / phi }
    static var r4: CGFloat { r3 / phi }
    static var r5: CGFloat { r4 / phi }
    static let c1 = CGPoint(x: 0.43, y: 0.44)
    static let c2 = CGPoint(x: 0.645, y: 0.625)
    static let t1 = CGPoint(x: 0.215, y: 0.735)
    static let t2 = CGPoint(x: 0.835, y: 0.845)
    /// Construction circles shown on the "Our logo" screen.
    static var grid: [(CGPoint, CGFloat)] {
        [(c1, r1), (c2, r2), (t1, r4), (t2, r5),
         (CGPoint(x: c1.x + r1 - r3, y: c1.y), r3), (CGPoint(x: c2.x, y: c2.y - r2 + r4), r4)]
    }
}

struct AppLogo: View {
    var size: CGFloat = 40
    var showGrid = false
    var rounded = true

    var body: some View {
        let s = size
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0x1FB6E8), Color(hex: 0x3A5BD9), Color(hex: 0x6E3FE0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: s * 0.8)
            glass(LogoGeometry.c1, LogoGeometry.r1, rim: max(1, s * 0.009))
            glass(LogoGeometry.t1, LogoGeometry.r4, rim: max(0.7, s * 0.006))
            solid(LogoGeometry.c2, LogoGeometry.r2)
                .shadow(color: Color(hex: 0x0B1A5C).opacity(0.35), radius: s * 0.02, y: s * 0.03)
            solid(LogoGeometry.t2, LogoGeometry.r5)
            CheckShape()
                .stroke(.white, style: StrokeStyle(lineWidth: s * 0.042, lineCap: .round, lineJoin: .round))
                .frame(width: s, height: s)
            if showGrid {
                ForEach(Array(LogoGeometry.grid.enumerated()), id: \.offset) { _, g in
                    Circle().stroke(Color(hex: 0xFFE066), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .frame(width: g.1 * 2 * s, height: g.1 * 2 * s)
                        .offset(x: (g.0.x - g.1) * s, y: (g.0.y - g.1) * s)
                }
            }
        }
        .frame(width: s, height: s)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? s * 0.225 : 0, style: .continuous))
        .shadow(color: Color(hex: 0x28BEE6).opacity(0.35), radius: s * 0.12)
        .accessibilityLabel("iTeam")
    }

    private func glass(_ c: CGPoint, _ r: CGFloat, rim: CGFloat) -> some View {
        Circle()
            .fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.25), .white.opacity(0.7)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: rim))
            .overlay(alignment: .topLeading) {
                Ellipse().fill(.white.opacity(0.5)).blur(radius: r * size * 0.12)
                    .frame(width: r * size * 0.85, height: r * size * 0.33)
                    .rotationEffect(.degrees(-32))
                    .offset(x: r * size * 0.3, y: r * size * 0.35)
            }
            .frame(width: r * 2 * size, height: r * 2 * size)
            .offset(x: (c.x - r) * size, y: (c.y - r) * size)
    }

    private func solid(_ c: CGPoint, _ r: CGFloat) -> some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hex: 0x7CF5E0), Color(hex: 0x19C2A0)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: max(0.8, size * 0.007)))
            .frame(width: r * 2 * size, height: r * 2 * size)
            .offset(x: (c.x - r) * size, y: (c.y - r) * size)
    }

    /// The tick inside the "done" bubble.
    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            let c = LogoGeometry.c2, w = rect.width
            var p = Path()
            p.move(to: CGPoint(x: (c.x - 0.085) * w, y: (c.y + 0.005) * w))
            p.addLine(to: CGPoint(x: (c.x - 0.022) * w, y: (c.y + 0.065) * w))
            p.addLine(to: CGPoint(x: (c.x + 0.095) * w, y: (c.y - 0.06) * w))
            return p
        }
    }
}

/// Settings → About → Our logo: the golden-ratio construction behind the icon.
struct LogoStoryView: View {
    @State private var grid = true
    @Environment(\.look) private var look

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AppLogo(size: 260, showGrid: grid).padding(.top, 20)
                Toggle("Show construction circles", isOn: $grid.animation()).lookCard()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Built on the golden ratio").font(.headline)
                    Text("Every circle in the mark comes from one family: each is the previous one divided by φ ≈ 1.618. The big clear bubble is the conversation, the smaller solid bubble is the work that comes out of it, and the two tiny bubbles are the tails that make them speech bubbles.")
                        .font(.subheadline).foregroundStyle(look.textSecondary)
                    Text("Glass on top, colour underneath — the same Liquid Glass idea as iOS itself.")
                        .font(.subheadline).foregroundStyle(look.textSecondary)
                }
                .lookCard()
            }
            .padding()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .lookScreen()
        .navigationTitle("Our logo")
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
