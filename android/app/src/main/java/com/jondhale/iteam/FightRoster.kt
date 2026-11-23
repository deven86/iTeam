package com.jondhale.iteam

// Generated from the iPhone roster.
data class Fighter(val id: String, val name: String, val kick: String, val shield: String, val punch: String, val speed: Float, val power: Float, val guard: Float, val tint: Long) {
    val kickFacesLeft get() = id !in listOf("turtle", "mermaid", "chrono")
}

val fighters = listOf(
    Fighter("bee", "Buzzy Bee", "Pollen-Kick", "Honey-Shield", "Stinger-Buzz", 1.15f, 0.9f, 0.95f, 0xFFF6C744),
    Fighter("turtle", "Chompy Turtle", "Shell-Kick", "Bubble-Shield", "Snapper-Snap", 0.85f, 1.0f, 1.2f, 0xFF7BBF5A),
    Fighter("skykit", "Starry Sky-Kit", "Star-Kick", "Moon-Shield", "Paw-Swipe", 1.1f, 1.0f, 0.95f, 0xFF3D4A9A),
    Fighter("fungi", "Fungi-Sprout", "Spore-Kick", "Moss-Shield", "Root-Fist", 0.95f, 1.05f, 1.05f, 0xFF9CBF6B),
    Fighter("dragon", "Bubble-Dragon", "Bubble-Kick", "Water-Shield", "Tidal-Fist", 1.0f, 1.1f, 0.95f, 0xFF6EB6E8),
    Fighter("fox", "Pixie-Fox", "Pixie-Kick", "Aura-Shield", "Star-Fist", 1.2f, 0.9f, 0.9f, 0xFFE0507F),
    Fighter("cosmicbear", "Cosmic-Bear", "Galaxy-Kick", "Nebula-Shield", "Comet-Fist", 0.9f, 1.15f, 1.0f, 0xFF5A6BC9),
    Fighter("unicorn", "Woolly Unicorn", "Prance-Kick", "Magic-Shield", "Hoof-Puff", 1.1f, 0.95f, 1.0f, 0xFFE9C9A8),
    Fighter("lion", "Cog-Lion", "Roar-Pounce", "Gear-Shield", "Smirk-Puff", 0.9f, 1.2f, 1.0f, 0xFFB88A4A),
    Fighter("tiger", "Cog-Tiger", "Stripe-Pounce", "Gear-Shield", "Smirk-Puff", 1.0f, 1.15f, 0.95f, 0xFFE08A2E),
    Fighter("gryphon", "Gryphon-Bear", "Flame-Flight", "Inferno-Shield", "Smirk-Puff", 1.05f, 1.1f, 0.9f, 0xFFD9572B),
    Fighter("angelbear", "Halo Bear", "Halo-Flight", "Halo-Shield", "Cloud-Puff", 1.0f, 0.95f, 1.15f, 0xFFEADFC8),
    Fighter("cow", "Moo-Moo Cow", "Arcane-Moo", "Aegis-Bell", "Terra-Graze", 0.95f, 1.0f, 1.1f, 0xFFE8A0B4),
    Fighter("raptor", "Chibi Raptor", "Arcane-Pounce", "Aegis-Claw", "Terra-Swipe", 1.2f, 0.95f, 0.9f, 0xFF3B4FB0),
    Fighter("trex", "Chibi T-Rex", "Arcane-Roar", "Fossil-Ward", "Cretaceous-Stomp", 0.9f, 1.2f, 1.0f, 0xFF3F6B3A),
    Fighter("rhino", "Chibi Rhino", "Comet-Horn", "Aegis-Rock", "Terra-Stomp", 0.85f, 1.15f, 1.2f, 0xFF6B6575),
    Fighter("witch", "Astra the Witch", "Arcane-Weave", "Arcane-Zen", "Astra-Flight", 1.05f, 1.05f, 0.9f, 0xFF5B3FA0),
    Fighter("phantasma", "Phantasma", "Boo!", "Ethereal-Zen", "Phase-Shift", 1.15f, 0.9f, 1.0f, 0xFFB9C6F0),
    Fighter("dolly", "Ghost Doll", "Spectral Float", "Ecto-Calm", "Possession Rush", 1.1f, 1.0f, 0.95f, 0xFF9AA8BF),
    Fighter("eagle", "Aethon the Eagle", "Aethon-Dive", "Wing-Guard", "Talon-Strike", 1.2f, 1.0f, 0.85f, 0xFFC8902E),
    Fighter("mermaid", "Starry Mermaid", "Aqua-Smash", "Faerie-Shield", "Aqua-Volute", 1.0f, 0.95f, 1.1f, 0xFF6CC5D9),
    Fighter("batcat", "Chibi Vampire", "Stardust-Kick", "Vamp-Shield", "Sanguine-Flight", 1.15f, 1.0f, 0.9f, 0xFF2A2540),
    Fighter("werewolf", "Chibi Werewolf", "Stardust-Kick", "Fenrir-Shield", "Fenrir-Swipe", 1.05f, 1.1f, 0.95f, 0xFF2F4A9A),
    Fighter("cinderwyrm", "Cinder-Wyrm", "Stardust-Kick", "Wyrm-Shield", "Ember-Swipe", 1.0f, 1.15f, 0.95f, 0xFFB0222E),
    Fighter("chrono", "Chrono-Weaver", "Chrono-Shift", "Inferno-Shield", "Wind-up Punch", 0.9f, 1.2f, 1.1f, 0xFF8A6A35)
)
