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
    /// Most kick and fist drawings face left; Chompy's kick faces right.
    var kickFacesLeft: Bool { id != "turtle" }

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
    ]

    static func find(_ id: String) -> FightCharacter { all.first { $0.id == id } ?? all[0] }

    static var favourite: String {
        get { UserDefaults.standard.string(forKey: "fight.fav") ?? "bee" }
        set { UserDefaults.standard.set(newValue, forKey: "fight.fav") }
    }
}
