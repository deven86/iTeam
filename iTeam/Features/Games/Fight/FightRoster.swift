import SwiftUI
import UIKit

/// The Fluffy Fight cast — original characters drawn by Devendra. Cute knock-outs only: stars and sparkles, never blood.
struct FightCharacter: Identifiable, Hashable {
    let id: String
    let name: String
    let kick: String
    let shield: String
    let punch: String
    /// 0.8…1.2 multipliers.
    let speed: CGFloat
    let power: CGFloat
    let guardStrength: CGFloat
    let tint: UInt32
    /// Super power (special move) and its element sparkle.
    var superPower: FightPower { FightPower.of(id) }
    var element: String {
        switch id {
        case "bee": "🍯"; case "turtle": "🫧"; case "skykit": "⭐"; case "fungi": "🍄"; case "dragon": "💧"; case "fox": "✨"
        case "cosmicbear": "🌌"; case "unicorn": "🌈"; case "lion": "⚙️"; case "tiger": "🔥"; case "gryphon": "🔥"
        case "cow": "🔔"; case "raptor", "trex": "🦴"; case "rhino": "🪨"; case "witch": "🔮"; case "phantasma", "dolly": "👻"
        case "eagle": "🪶"; case "mermaid": "🐚"; case "batcat": "🦇"; case "werewolf": "🌙"; case "cinderwyrm": "🔥"; case "chrono": "⏳"
        default: "🪽"
        }
    }
    /// Most kick and fist drawings face left; Chompy's kick faces right.
    var kickFacesLeft: Bool { !["turtle", "mermaid", "chrono"].contains(id) }

    func image(_ pose: String) -> UIImage? { UIImage(named: "fx_\(id)_\(pose)") }
    var color: Color { Color(hex: tint) }

    static let all: [FightCharacter] = [
        .init(id: "bee", name: "Buzzy Bee", kick: "Pollen-Kick", shield: "Honey-Shield", punch: "Stinger-Buzz", speed: 1.15, power: 0.9, guardStrength: 0.95, tint: 0xF6C744),
        .init(id: "turtle", name: "Chompy Turtle", kick: "Shell-Kick", shield: "Bubble-Shield", punch: "Snapper-Snap", speed: 0.85, power: 1.0, guardStrength: 1.2, tint: 0x7BBF5A),
        .init(id: "skykit", name: "Starry Sky-Kit", kick: "Star-Kick", shield: "Moon-Shield", punch: "Paw-Swipe", speed: 1.1, power: 1.0, guardStrength: 0.95, tint: 0x3D4A9A),
        .init(id: "fungi", name: "Fungi-Sprout", kick: "Spore-Kick", shield: "Moss-Shield", punch: "Root-Fist", speed: 0.95, power: 1.05, guardStrength: 1.05, tint: 0x9CBF6B),
        .init(id: "dragon", name: "Bubble-Dragon", kick: "Bubble-Kick", shield: "Water-Shield", punch: "Tidal-Fist", speed: 1.0, power: 1.1, guardStrength: 0.95, tint: 0x6EB6E8),
        .init(id: "fox", name: "Pixie-Fox", kick: "Pixie-Kick", shield: "Aura-Shield", punch: "Star-Fist", speed: 1.2, power: 0.9, guardStrength: 0.9, tint: 0xE0507F),
        .init(id: "cosmicbear", name: "Cosmic-Bear", kick: "Galaxy-Kick", shield: "Nebula-Shield", punch: "Comet-Fist", speed: 0.9, power: 1.15, guardStrength: 1.0, tint: 0x5A6BC9),
        .init(id: "unicorn", name: "Woolly Unicorn", kick: "Prance-Kick", shield: "Magic-Shield", punch: "Hoof-Puff", speed: 1.1, power: 0.95, guardStrength: 1.0, tint: 0xE9C9A8),
        .init(id: "lion", name: "Cog-Lion", kick: "Roar-Pounce", shield: "Gear-Shield", punch: "Smirk-Puff", speed: 0.9, power: 1.2, guardStrength: 1.0, tint: 0xB88A4A),
        .init(id: "tiger", name: "Cog-Tiger", kick: "Stripe-Pounce", shield: "Gear-Shield", punch: "Smirk-Puff", speed: 1.0, power: 1.15, guardStrength: 0.95, tint: 0xE08A2E),
        .init(id: "gryphon", name: "Gryphon-Bear", kick: "Flame-Flight", shield: "Inferno-Shield", punch: "Smirk-Puff", speed: 1.05, power: 1.1, guardStrength: 0.9, tint: 0xD9572B),
        .init(id: "angelbear", name: "Halo Bear", kick: "Halo-Flight", shield: "Halo-Shield", punch: "Cloud-Puff", speed: 1.0, power: 0.95, guardStrength: 1.15, tint: 0xEADFC8),
        // Arcane Mythos & friends (Devendra's sheets, Nov 2026)
        .init(id: "cow", name: "Moo-Moo Cow", kick: "Arcane-Moo", shield: "Aegis-Bell", punch: "Terra-Graze", speed: 0.95, power: 1.0, guardStrength: 1.1, tint: 0xE8A0B4),
        .init(id: "raptor", name: "Chibi Raptor", kick: "Arcane-Pounce", shield: "Aegis-Claw", punch: "Terra-Swipe", speed: 1.2, power: 0.95, guardStrength: 0.9, tint: 0x3B4FB0),
        .init(id: "trex", name: "Chibi T-Rex", kick: "Arcane-Roar", shield: "Fossil-Ward", punch: "Cretaceous-Stomp", speed: 0.9, power: 1.2, guardStrength: 1.0, tint: 0x3F6B3A),
        .init(id: "rhino", name: "Chibi Rhino", kick: "Comet-Horn", shield: "Aegis-Rock", punch: "Terra-Stomp", speed: 0.85, power: 1.15, guardStrength: 1.2, tint: 0x6B6575),
        .init(id: "witch", name: "Astra the Witch", kick: "Arcane-Weave", shield: "Arcane-Zen", punch: "Astra-Flight", speed: 1.05, power: 1.05, guardStrength: 0.9, tint: 0x5B3FA0),
        .init(id: "phantasma", name: "Phantasma", kick: "Boo!", shield: "Ethereal-Zen", punch: "Phase-Shift", speed: 1.15, power: 0.9, guardStrength: 1.0, tint: 0xB9C6F0),
        .init(id: "dolly", name: "Ghost Doll", kick: "Spectral Float", shield: "Ecto-Calm", punch: "Possession Rush", speed: 1.1, power: 1.0, guardStrength: 0.95, tint: 0x9AA8BF),
        .init(id: "eagle", name: "Aethon the Eagle", kick: "Aethon-Dive", shield: "Wing-Guard", punch: "Talon-Strike", speed: 1.2, power: 1.0, guardStrength: 0.85, tint: 0xC8902E),
        .init(id: "mermaid", name: "Starry Mermaid", kick: "Aqua-Smash", shield: "Faerie-Shield", punch: "Aqua-Volute", speed: 1.0, power: 0.95, guardStrength: 1.1, tint: 0x6CC5D9),
        .init(id: "batcat", name: "Chibi Vampire", kick: "Stardust-Kick", shield: "Vamp-Shield", punch: "Sanguine-Flight", speed: 1.15, power: 1.0, guardStrength: 0.9, tint: 0x2A2540),
        .init(id: "werewolf", name: "Chibi Werewolf", kick: "Stardust-Kick", shield: "Fenrir-Shield", punch: "Fenrir-Swipe", speed: 1.05, power: 1.1, guardStrength: 0.95, tint: 0x2F4A9A),
        .init(id: "cinderwyrm", name: "Cinder-Wyrm", kick: "Stardust-Kick", shield: "Wyrm-Shield", punch: "Ember-Swipe", speed: 1.0, power: 1.15, guardStrength: 0.95, tint: 0xB0222E),
        .init(id: "chrono", name: "Chrono-Weaver", kick: "Chrono-Shift", shield: "Inferno-Shield", punch: "Wind-up Punch", speed: 0.9, power: 1.2, guardStrength: 1.1, tint: 0x8A6A35),
    ]

    static func find(_ id: String) -> FightCharacter { all.first { $0.id == id } ?? all[0] }

    static var favourite: String {
        get { UserDefaults.standard.string(forKey: "fight.fav") ?? "bee" }
        set { UserDefaults.standard.set(newValue, forKey: "fight.fav") }
    }
}

/// Four kinds of super power, so characters play differently.
enum FightPower: String {
    /// Flying fist across the stage (jump to dodge).
    case blast
    /// Ground shockwave: hits anyone standing nearby (jump to dodge).
    case quake
    /// Teleport behind the foe and strike (block to defend).
    case dash
    /// Restore 25 fluff and a shining guard for 3 seconds.
    case heal

    static func of(_ id: String) -> FightPower {
        switch id {
        case "bee", "fox", "skykit", "raptor", "dolly", "eagle", "batcat": .dash
        case "turtle", "lion", "cosmicbear", "cow", "trex", "rhino": .quake
        case "angelbear", "unicorn", "fungi", "phantasma", "mermaid": .heal
        default: .blast
        }
    }
    var title: String {
        switch self { case .blast: "Flying Fist"; case .quake: "Ground Quake"; case .dash: "Shadow Dash"; case .heal: "Healing Glow" }
    }
}

/// Where the fight happens. The challenger picks it (or their own photo).
enum FightArena: String, CaseIterable, Identifiable {
    case meadow, beach, space, candy, snow, city
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var sky: (UInt32, UInt32) {
        switch self {
        case .meadow: (0xCCDBFF, 0xFFE0EC)
        case .beach: (0x7FD3F7, 0xFFF1C9)
        case .space: (0x0B1033, 0x3A1C71)
        case .candy: (0xFFC2E2, 0xFFF0B3)
        case .snow: (0xBFD9F2, 0xF4FAFF)
        case .city: (0x1E2A4A, 0xF29E6D)
        }
    }
    var ground: UInt32 {
        switch self {
        case .meadow: 0xF5DBBD; case .beach: 0xF2D59C; case .space: 0x4B3F72; case .candy: 0xF7A8C8; case .snow: 0xFFFFFF; case .city: 0x5B5F6B
        }
    }
    var hills: (UInt32, UInt32) {
        switch self {
        case .meadow: (0xBCDDBD, 0xA3CCA8); case .beach: (0x4FB3D9, 0x2E8FB8); case .space: (0x6A5ACD, 0x483D8B)
        case .candy: (0xFF9ECF, 0xC39BFF); case .snow: (0xDDEBF7, 0xC9DDF0); case .city: (0x2B3350, 0x3C4566)
        }
    }
    var sparkle: String {
        switch self { case .meadow: "✿"; case .beach: "☀︎"; case .space: "✦"; case .candy: "🍬"; case .snow: "❄︎"; case .city: "✧" }
    }
}
