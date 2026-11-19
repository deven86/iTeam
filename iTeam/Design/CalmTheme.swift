import SwiftUI

// The Third Eye look: calm, low-glare palettes, solid or Liquid Glass cards,
// and Winamp-style skins (a wallpaper behind every screen, glass on top).
// Colours are copied from Third Eye so both apps feel like one family.

enum CalmTheme: String, CaseIterable, Identifiable {
    case liquidGlass, calmLight, calmDark, oledNight, paper, highContrast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .calmLight: "Calm Light"
        case .calmDark: "Calm Dark"
        case .oledNight: "OLED Night"
        case .paper: "Paper"
        case .highContrast: "High Contrast"
        }
    }

    var subtitle: String {
        switch self {
        case .liquidGlass: "System look · follows light/dark"
        case .calmLight: "Off-white, slate text, soft colours"
        case .calmDark: "Deep grey instead of black, low glare"
        case .oledNight: "True black for night use"
        case .paper: "Warm, low-blue tones for long reading"
        case .highContrast: "Maximum legibility"
        }
    }

    /// nil = follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .liquidGlass: nil
        case .calmLight, .paper, .highContrast: .light
        case .calmDark, .oledNight: .dark
        }
    }

    var allowsGlass: Bool { self != .highContrast }

    func palette(systemScheme: ColorScheme) -> CalmPalette {
        var p: CalmPalette
        switch self {
        case .liquidGlass:
            p = systemScheme == .dark ? .darkBase : .lightBase
            p.background = Color(.systemGroupedBackground)
            p.surface = Color(.secondarySystemGroupedBackground)
            p.textSecondary = .secondary
        case .calmLight: p = .lightBase
        case .calmDark: p = .darkBase
        case .oledNight:
            p = .darkBase
            p.background = .black
            p.surface = Color(hex: 0x111214)
            p.textPrimary = Color(hex: 0xD6D9DD)
        case .paper:
            p = .lightBase
            p.background = Color(hex: 0xF4EEE3)
            p.surface = Color(hex: 0xFBF7F0)
            p.textPrimary = Color(hex: 0x3B3226)
            p.textSecondary = Color(hex: 0x7A6E5E)
            p.accent = Color(hex: 0x8A5A2B)
            p.separator = Color(hex: 0xE2D8C6)
        case .highContrast:
            p = .lightBase
            p.background = .white
            p.surface = .white
            p.textPrimary = .black
            p.textSecondary = Color(hex: 0x333333)
            p.accent = Color(hex: 0x00515A)
            p.separator = .black
        }
        return p
    }
}

struct CalmPalette {
    var background: Color
    var surface: Color
    var textPrimary: Color
    var textSecondary: Color
    var accent: Color
    var success: Color
    var danger: Color
    var warning: Color
    var separator: Color

    static let lightBase = CalmPalette(
        background: Color(hex: 0xF7F7F5), surface: .white,
        textPrimary: Color(hex: 0x1B2430), textSecondary: Color(hex: 0x5B6573),
        accent: Color(hex: 0x0E7C86), success: Color(hex: 0x2E9E6B), danger: Color(hex: 0xD9534F),
        warning: Color(hex: 0xB4541E), separator: Color(hex: 0xE3E6EA))

    static let darkBase = CalmPalette(
        background: Color(hex: 0x121417), surface: Color(hex: 0x1B1E23),
        textPrimary: Color(hex: 0xE4E7EB), textSecondary: Color(hex: 0x9AA3AE),
        accent: Color(hex: 0x3FB4BE), success: Color(hex: 0x4CB782), danger: Color(hex: 0xE06C66),
        warning: Color(hex: 0xE09A5B), separator: Color(hex: 0x2A2E35))
}

/// Winamp-style skins from Third Eye.
enum Skin: String, CaseIterable, Identifiable {
    case none, aurora, ocean, sunset, nebula, forest, graphite, classic, photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Off"
        case .aurora: "Aurora"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        case .nebula: "Nebula"
        case .forest: "Forest"
        case .graphite: "Graphite"
        case .classic: "Classic Amp"
        case .photo: "My photo"
        }
    }

    var mesh: [UInt32] {
        switch self {
        case .aurora: [0x06142E, 0x0B3B5C, 0x0E2A47, 0x0E7C86, 0x1F9E78, 0x3B2C7A, 0x071A33, 0x2A5C8F, 0x5B2E8C]
        case .ocean: [0x021428, 0x053A66, 0x0A2647, 0x0B5C8F, 0x1D7FB8, 0x0E4F7A, 0x031B33, 0x0A3D66, 0x02223F]
        case .sunset: [0x2B0F3A, 0x7A1F4F, 0x3D1250, 0xC2410C, 0xE0626A, 0x8C2B6B, 0x3A0D2E, 0xB4541E, 0x4A1240]
        case .nebula: [0x0D0726, 0x3A0F6B, 0x150A3D, 0x6B21A8, 0xC2378C, 0x2E1A7A, 0x0A0520, 0x4C1D95, 0x1E0B45]
        case .forest: [0x05170F, 0x0F3D2A, 0x0A2419, 0x1F6B45, 0x3E8E5A, 0x174D33, 0x041209, 0x245C3C, 0x0B2A1C]
        case .graphite: [0x101114, 0x2A2D33, 0x16181C, 0x3A3F47, 0x555B66, 0x2B2F36, 0x0C0D10, 0x23262B, 0x15171A]
        case .classic: [0x0B0C10, 0x1D2128, 0x101216, 0x22303A, 0x2F7D32, 0x1F2A30, 0x08090C, 0x3A4049, 0x111316]
        case .none, .photo: Array(repeating: 0x101114, count: 9)
        }
    }

    static let builtIn: [Skin] = [.aurora, .ocean, .sunset, .nebula, .forest, .graphite, .classic]
}

/// How much of the Third Eye look is glass.
enum GlassLook: String, CaseIterable, Identifiable {
    case off, frosted, clear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off (solid cards)"
        case .frosted: "Frosted glass"
        case .clear: "Clear glass"
        }
    }
}

/// The plain, regular iOS look with a soft pastel accent.
enum PastelAccent: String, CaseIterable, Identifiable {
    case sky, mint, peach, lavender, rose, lemon, sage, coral

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Soft colour used for bubbles and chips.
    var soft: Color {
        switch self {
        case .sky: Color(hex: 0xBFE3FF)
        case .mint: Color(hex: 0xBFF0DC)
        case .peach: Color(hex: 0xFFD9C2)
        case .lavender: Color(hex: 0xDCD3FF)
        case .rose: Color(hex: 0xFFCFDD)
        case .lemon: Color(hex: 0xFFF1B3)
        case .sage: Color(hex: 0xD3E6C8)
        case .coral: Color(hex: 0xFFC4BC)
        }
    }

    /// Stronger version of the same hue for buttons, icons and links (readable on white).
    var strong: Color {
        switch self {
        case .sky: Color(hex: 0x2F7FD0)
        case .mint: Color(hex: 0x1E9A6E)
        case .peach: Color(hex: 0xD2692E)
        case .lavender: Color(hex: 0x6F5BD6)
        case .rose: Color(hex: 0xD04B78)
        case .lemon: Color(hex: 0xA88400)
        case .sage: Color(hex: 0x4E8A3A)
        case .coral: Color(hex: 0xD2503F)
        }
    }

    /// Bubble colour in dark mode: the soft hue, darkened.
    var softDark: Color { strong.opacity(0.45) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
