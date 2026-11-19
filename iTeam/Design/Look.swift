import SwiftUI
import UIKit

/// The three looks the user can choose in Settings → Appearance.
enum UIStyle: String, CaseIterable, Identifiable {
    /// iLife: animated wallpapers, glass everywhere, vivid gradients.
    case vivid
    /// Third Eye: calm palettes, optional glass, Winamp-style skins.
    case calm
    /// Plain iOS look with a soft pastel accent.
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vivid: "iLife Glass"
        case .calm: "Third Eye Calm"
        case .classic: "Classic Pastel"
        }
    }

    var subtitle: String {
        switch self {
        case .vivid: "Animated wallpapers, glass cards, colourful"
        case .calm: "Quiet colours, low glare, skins"
        case .classic: "Regular iOS look, soft pastel colours"
        }
    }

    var icon: String {
        switch self {
        case .vivid: "sparkles"
        case .calm: "eye"
        case .classic: "paintpalette"
        }
    }
}

/// Everything a screen needs to draw itself in the chosen look.
struct Look {
    var style: UIStyle = .classic
    var accent: Color = .blue
    var accent2: Color = .cyan
    var colorScheme: ColorScheme? = nil
    /// Cards and rows are glass (otherwise solid surfaces).
    var glassCards = false
    var glassClear = false
    /// A wallpaper sits behind screens (iLife look, or a Third Eye skin).
    var hasWallpaper = false
    var surface: Color = Color(.secondarySystemGroupedBackground)
    var separator: Color = Color(.separator)
    var textSecondary: Color = .secondary
    var success: Color = .green
    var warning: Color = .orange
    var danger: Color = .red
    /// Outgoing chat bubble.
    var bubbleOut: AnyShapeStyle = AnyShapeStyle(Color.blue)
    var bubbleOutText: Color = .white
    /// Incoming chat bubble (ignored when `glassCards` is on: incoming bubbles are glass).
    var bubbleIn: Color = Color(.secondarySystemBackground)
    var bubbleInText: Color = .primary

    var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension EnvironmentValues {
    @Entry var look: Look = Look()
}

/// Stores the appearance settings and turns them into a `Look`.
@MainActor
final class LookManager: ObservableObject {
    static let shared = LookManager()
    private let d = UserDefaults.standard

    @Published var style: UIStyle { didSet { d.set(style.rawValue, forKey: "look.style") } }

    // iLife look
    @Published var vivid: VividTheme { didSet { d.set(vivid.rawValue, forKey: "look.vivid") } }
    @Published var vividAuto: Bool { didSet { d.set(vividAuto, forKey: "look.vividAuto") } }
    @Published var vividPhoto: Bool { didSet { d.set(vividPhoto, forKey: "look.vividPhoto") } }

    // Third Eye look
    @Published var calm: CalmTheme { didSet { d.set(calm.rawValue, forKey: "look.calm") } }
    @Published var skin: Skin { didSet { d.set(skin.rawValue, forKey: "look.skin") } }
    @Published var skinDim: Double { didSet { d.set(skinDim, forKey: "look.skinDim") } }
    @Published var glassLook: GlassLook { didSet { d.set(glassLook.rawValue, forKey: "look.glass") } }

    // Classic look
    @Published var pastel: PastelAccent { didSet { d.set(pastel.rawValue, forKey: "look.pastel") } }
    /// 0 = system, 1 = light, 2 = dark
    @Published var classicAppearance: Int { didSet { d.set(classicAppearance, forKey: "look.classicAppearance") } }

    /// Bumped whenever a wallpaper photo changes, so cached images reload.
    @Published var photoVersion = 0

    private init() {
        style = UIStyle(rawValue: d.string(forKey: "look.style") ?? "") ?? .vivid
        vivid = VividTheme(rawValue: d.string(forKey: "look.vivid") ?? "") ?? .natureGlass
        vividAuto = d.bool(forKey: "look.vividAuto")
        vividPhoto = d.bool(forKey: "look.vividPhoto")
        calm = CalmTheme(rawValue: d.string(forKey: "look.calm") ?? "") ?? .liquidGlass
        skin = Skin(rawValue: d.string(forKey: "look.skin") ?? "") ?? .none
        skinDim = d.object(forKey: "look.skinDim") as? Double ?? 0.3
        glassLook = GlassLook(rawValue: d.string(forKey: "look.glass") ?? "") ?? .frosted
        pastel = PastelAccent(rawValue: d.string(forKey: "look.pastel") ?? "") ?? .sky
        classicAppearance = d.object(forKey: "look.classicAppearance") as? Int ?? 0
    }

    /// The iLife theme on screen right now.
    var currentVivid: VividTheme { vividAuto ? VividTheme.forNow() : vivid }

    func resolve(systemScheme: ColorScheme, reduceTransparency: Bool) -> Look {
        var l = Look()
        l.style = style
        switch style {
        case .vivid:
            let t = currentVivid
            l.accent = t.accent
            l.accent2 = t.accent2
            l.colorScheme = t.colorScheme
            l.glassCards = !reduceTransparency
            l.hasWallpaper = true
            l.surface = t.colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.7)
            l.separator = Color.white.opacity(0.15)
            l.bubbleOut = AnyShapeStyle(t.gradient)
            l.bubbleOutText = t.colorScheme == .dark ? .black : .white
            l.bubbleIn = t.colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.8)
            l.bubbleInText = .primary

        case .calm:
            let skinOn = skin != .none
            var p = (skinOn ? (calm == .highContrast ? CalmTheme.highContrast : CalmTheme.liquidGlass) : calm)
                .palette(systemScheme: skinOn ? .dark : systemScheme)
            if skinOn {
                // Over a wallpaper the calm colours are too faint: brighter versions, same meaning.
                p.accent = Color(hex: 0x5FD3DC)
                p.success = Color(hex: 0x5BD08F)
                p.danger = Color(hex: 0xFF7B73)
                p.warning = Color(hex: 0xFFB36B)
                p.textSecondary = Color.white.opacity(0.78)
            }
            let glassOK = calm.allowsGlass && !reduceTransparency
            l.accent = p.accent
            l.accent2 = p.accent.opacity(0.7)
            l.colorScheme = skinOn ? .dark : calm.colorScheme
            l.glassCards = glassOK && (skinOn || glassLook != .off)
            l.glassClear = glassLook == .clear
            l.hasWallpaper = skinOn
            l.surface = p.surface
            l.separator = p.separator
            l.textSecondary = p.textSecondary
            l.success = p.success
            l.warning = p.warning
            l.danger = p.danger
            l.bubbleOut = AnyShapeStyle(p.accent)
            l.bubbleOutText = .white
            l.bubbleIn = p.surface
            l.bubbleInText = p.textPrimary

        case .classic:
            let scheme: ColorScheme? = classicAppearance == 1 ? .light : (classicAppearance == 2 ? .dark : nil)
            let dark = (scheme ?? systemScheme) == .dark
            l.accent = pastel.strong
            l.accent2 = pastel.soft
            l.colorScheme = scheme
            l.glassCards = false
            l.hasWallpaper = false
            l.bubbleOut = AnyShapeStyle(dark ? pastel.softDark : pastel.soft)
            l.bubbleOutText = .primary
            l.bubbleIn = Color(.secondarySystemBackground)
            l.bubbleInText = .primary
        }
        return l
    }
}

/// Applies the chosen look to the whole app.
struct LookHost<Content: View>: View {
    @ObservedObject private var manager = LookManager.shared
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: Content

    var body: some View {
        let look = manager.resolve(systemScheme: systemScheme, reduceTransparency: reduceTransparency)
        content
            .environment(\.look, look)
            .tint(look.accent)
            .preferredColorScheme(look.colorScheme)
    }
}

// MARK: - Wallpaper photos

/// The user's own wallpaper photos (app-wide, or per chat), downscaled and saved once.
enum WallpaperStore {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var cache: [String: UIImage] = [:]

    static func url(_ key: String) -> URL { dir.appendingPathComponent("\(key).jpg") }

    static func image(_ key: String, version: Int) -> UIImage? {
        let k = "\(key)#\(version)"
        if let img = cache[k] { return img }
        guard let img = UIImage(contentsOfFile: url(key).path) else { return nil }
        cache[k] = img
        return img
    }

    @discardableResult
    static func save(_ data: Data, key: String) -> Bool {
        guard let src = UIImage(data: data) else { return false }
        let maxSide: CGFloat = 2400
        let scale = min(1, maxSide / max(src.size.width, src.size.height))
        let size = CGSize(width: src.size.width * scale, height: src.size.height * scale)
        let img = UIGraphicsImageRenderer(size: size).image { _ in src.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = img.jpegData(compressionQuality: 0.85) else { return false }
        do { try jpg.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } catch { return false }
        cache = [:]
        return true
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(key))
        cache = [:]
    }
}

// MARK: - Backdrops

/// What sits behind every screen, for the chosen look.
struct LookBackdrop: View {
    @ObservedObject private var manager = LookManager.shared
    @Environment(\.look) private var look
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch manager.style {
            case .vivid:
                if manager.vividPhoto, let img = WallpaperStore.image("app", version: manager.photoVersion) {
                    PhotoWallpaper(image: img, dim: manager.currentVivid.colorScheme == .dark ? 0.35 : 0.05)
                } else {
                    VividWallpaper(theme: manager.currentVivid)
                }
            case .calm:
                if manager.skin != .none {
                    SkinArt(skin: manager.skin, photoVersion: manager.photoVersion)
                        .overlay(Color.black.opacity(manager.skinDim))
                } else if look.glassCards {
                    AmbientBackdrop(base: manager.calm.palette(systemScheme: scheme).background, accent: look.accent)
                } else {
                    manager.calm.palette(systemScheme: scheme).background
                }
            case .classic:
                Color(.systemGroupedBackground)
            }
        }
        .ignoresSafeArea()
    }
}

struct PhotoWallpaper: View {
    let image: UIImage
    var dim: Double = 0.3
    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .overlay(Color.black.opacity(dim))
    }
}

/// iLife's animated mesh wallpaper.
struct VividWallpaper: View {
    let theme: VividTheme
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    layers(t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                layers(t: 0)
            }
        }
        .overlay(alignment: .bottom) {
            if theme == .natureGlass || theme == .sunsetDream || theme == .forestMist {
                MountainRidge(tint: theme == .sunsetDream ? .black : Color(red: 0.02, green: 0.08, blue: 0.10))
            }
        }
    }

    private func layers(t: Double) -> some View {
        let d = Float(0.09 * sin(t * 0.25))
        let e = Float(0.06 * cos(t * 0.18))
        return ZStack {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + e, 0], [1, 0],
                [0, 0.5 + d], [0.5 + d, 0.5 - d], [1, 0.5 - e],
                [0, 1], [0.5 - e, 1], [1, 1]
            ], colors: theme.mesh)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Circle().fill(theme.accent.opacity(0.30)).frame(width: w * 0.9)
                    .position(x: w * (0.25 + 0.20 * sin(t * 0.11)), y: h * (0.22 + 0.10 * cos(t * 0.09)))
                    .blur(radius: 90)
                Circle().fill(theme.accent2.opacity(0.25)).frame(width: w * 0.8)
                    .position(x: w * (0.80 + 0.15 * cos(t * 0.08)), y: h * (0.62 + 0.14 * sin(t * 0.07)))
                    .blur(radius: 100)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Layered mountain silhouette, drawn in code.
struct MountainRidge: View {
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: .init(x: 0, y: h * 0.72))
                    p.addLine(to: .init(x: w * 0.18, y: h * 0.55)); p.addLine(to: .init(x: w * 0.32, y: h * 0.66))
                    p.addLine(to: .init(x: w * 0.55, y: h * 0.48)); p.addLine(to: .init(x: w * 0.75, y: h * 0.63))
                    p.addLine(to: .init(x: w, y: h * 0.52)); p.addLine(to: .init(x: w, y: h)); p.addLine(to: .init(x: 0, y: h))
                }.fill(tint.opacity(0.45))
                Path { p in
                    p.move(to: .init(x: 0, y: h * 0.82))
                    p.addLine(to: .init(x: w * 0.25, y: h * 0.70)); p.addLine(to: .init(x: w * 0.45, y: h * 0.80))
                    p.addLine(to: .init(x: w * 0.70, y: h * 0.68)); p.addLine(to: .init(x: w, y: h * 0.78))
                    p.addLine(to: .init(x: w, y: h)); p.addLine(to: .init(x: 0, y: h))
                }.fill(tint.opacity(0.7))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Third Eye skin art (no dimming).
struct SkinArt: View {
    let skin: Skin
    var photoVersion = 0

    var body: some View {
        if skin == .photo, let img = WallpaperStore.image("skin", version: photoVersion) {
            PhotoWallpaper(image: img, dim: 0)
        } else {
            MeshGradient(width: 3, height: 3,
                         points: [[0, 0], [0.5, 0], [1, 0], [0, 0.45], [0.55, 0.5], [1, 0.4], [0, 1], [0.5, 1], [1, 1]],
                         colors: skin.mesh.map { Color(hex: $0) })
        }
    }
}

/// Third Eye's soft backdrop behind glass when no skin is on.
struct AmbientBackdrop: View {
    let base: Color
    let accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let k = scheme == .dark ? 1.0 : 0.75
        let violet = Color(hex: 0x7C6CF0), amber = Color(hex: 0xF2A65A), green = Color(hex: 0x4CB782)
        MeshGradient(width: 3, height: 3,
                     points: [[0, 0], [0.5, 0], [1, 0], [0, 0.45], [0.55, 0.5], [1, 0.4], [0, 1], [0.5, 1], [1, 1]],
                     colors: [base.mix(with: accent, by: 0.42 * k), base.mix(with: violet, by: 0.22 * k), base.mix(with: accent, by: 0.12 * k),
                              base.mix(with: green, by: 0.20 * k), base.mix(with: accent, by: 0.10 * k), base.mix(with: violet, by: 0.34 * k),
                              base.mix(with: violet, by: 0.14 * k), base.mix(with: amber, by: 0.22 * k), base.mix(with: accent, by: 0.36 * k)])
    }
}

// MARK: - Screen, card and row modifiers

extension View {
    /// Standard screen chrome: the look's backdrop behind a list or scroll view.
    func lookScreen() -> some View { modifier(LookScreenModifier()) }

    /// A card: glass in the glass looks, a solid rounded surface otherwise.
    func lookCard(cornerRadius: CGFloat = 20, padding: CGFloat = 16) -> some View {
        modifier(LookCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    /// List / Form rows: frosted glass instead of solid cells in the glass looks.
    func lookRows() -> some View { modifier(LookRowsModifier()) }

    /// Glass for a floating control (composer, buttons), with a solid fallback.
    func lookFloating<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(LookFloatingModifier(shape: shape, interactive: interactive))
    }
}

private struct LookScreenModifier: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.style == .classic {
            content
        } else {
            content
                .scrollContentBackground(.hidden)
                .background { LookBackdrop() }
        }
    }
}

private struct LookCardModifier: ViewModifier {
    @Environment(\.look) private var look
    let cornerRadius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shaped = content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        if look.glassCards {
            shaped.glassEffect(look.glassClear ? .clear : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            shaped
                .background(look.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(look.separator.opacity(0.6), lineWidth: 0.5))
        }
    }
}

private struct LookRowsModifier: ViewModifier {
    @Environment(\.look) private var look
    func body(content: Content) -> some View {
        if look.glassCards {
            content.listRowBackground(
                Rectangle().fill(.ultraThinMaterial).opacity(look.glassClear ? 0.55 : 1)
                    .overlay(Color.white.opacity(look.glassClear ? 0.10 : 0.06))
            )
        } else if look.style == .calm {
            content.listRowBackground(look.surface)
        } else {
            content
        }
    }
}

private struct LookFloatingModifier<S: Shape>: ViewModifier {
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(shape.stroke(look.separator, lineWidth: 0.5))
        } else {
            content.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        }
    }
}
