import SpriteKit
import UIKit

/// One message between the two phones during a live fight (Game Center match data).
struct FightMsg: Codable {
    /// hi · go · s (state) · a (attack) · h (hit landed) · ko · end
    var t: String
    var x: Double? = nil
    var y: Double? = nil
    var p: String? = nil
    var hp: Double? = nil
    var en: Double? = nil
    var k: String? = nil
    var d: Double? = nil
    var b: Bool? = nil
    var u: String? = nil
    var c: String? = nil
    var n: String? = nil
}

/// A fighter on the stage: sprite + shadow + its own little state machine.
final class FighterNode: SKNode {
    let character: FightCharacter
    let sprite = SKSpriteNode()
    let shadow = SKShapeNode(ellipseOf: CGSize(width: 150, height: 26))
    var hp: CGFloat = 100
    var energy: CGFloat = 0
    var pose = "idle"
    var facingRight = true
    var vy: CGFloat = 0
    var busyUntil: TimeInterval = 0
    var blocking = false
    var ko = false
    private var textures: [String: SKTexture] = [:]
    private let height: CGFloat = 235

    init(_ c: FightCharacter) {
        character = c
        super.init()
        for p in ["idle", "kick", "block", "fist"] {
            if let img = c.image(p) { textures[p] = SKTexture(image: img) }
        }
        shadow.fillColor = UIColor.black.withAlphaComponent(0.18)
        shadow.strokeColor = .clear
        shadow.zPosition = -1
        addChild(shadow)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        addChild(sprite)
        show("idle")
        let breathe = SKAction.sequence([.scaleY(to: 1.03, duration: 0.6), .scaleY(to: 1.0, duration: 0.6)])
        breathe.timingMode = .easeInEaseOut
        sprite.run(.repeatForever(breathe), withKey: "breathe")
    }

    required init?(coder: NSCoder) { fatalError() }

    var airborne: Bool { position.y > FightScene.ground + 1 }

    func show(_ p: String) {
        let key = p == "punch" || p == "hit" || p == "win" || p == "ko" ? "idle" : p
        guard let tex = textures[key] ?? textures["idle"] else { return }
        pose = p
        sprite.texture = tex
        let s = height / tex.size().height
        sprite.size = CGSize(width: tex.size().width * s, height: height)
        orient()
    }

    func orient() {
        // Kick drawings face left (except Chompy); idle/block are front-ish and simply mirror to face the foe.
        var flip: CGFloat = facingRight ? 1 : -1
        if pose == "kick" { flip = (facingRight == character.kickFacesLeft) ? -1 : 1 }
        sprite.xScale = abs(sprite.xScale == 0 ? 1 : sprite.xScale) * flip
        sprite.zRotation = pose == "punch" ? (facingRight ? -0.12 : 0.12) : (pose == "ko" ? (facingRight ? 0.35 : -0.35) : 0)
    }

    func fistTexture() -> SKTexture? { textures["fist"] }
}

/// The 2.5D arena. Each phone is in charge of its own fighter; the other one is either the computer or the friend's phone.
final class FightScene: SKScene {
    enum Mode { case cpu, online }
    static let ground: CGFloat = 120
    static let roundSeconds: TimeInterval = 60

    let mode: Mode
    let me: FighterNode
    let foe: FighterNode
    var left = false, right = false
    var blockHeld = false { didSet { if !me.ko { me.blocking = blockHeld } } }
    /// Online: send a message to the other phone.
    var send: ((FightMsg, Bool) -> Void)?
    /// HUD + result callbacks for SwiftUI.
    var onEnd: ((_ iWon: Bool?) -> Void)?
    var onHaptic: ((Bool) -> Void)?
    /// My energy 0…100 for the Special button.
    var onEnergy: ((CGFloat) -> Void)?
    private var lastEnergy: CGFloat = -1
    let arena: FightArena
    let backdrop: UIImage?
    /// Everything that shakes (stage + fighters); the HUD stays still.
    let world = SKNode()
    private var combo = 0
    private var lastHitAt: TimeInterval = 0
    private var guardUntil: TimeInterval = 0

    private(set) var started = false
    private(set) var finished = false
    private var startTime: TimeInterval = 0
    private var last: TimeInterval = 0
    private var lastSent: TimeInterval = 0
    private var cpuNext: TimeInterval = 0
    private var cpuBlockUntil: TimeInterval = 0
    private var remoteTarget = CGPoint(x: 760, y: FightScene.ground)
    private var now: TimeInterval = 0

    private let meBar = SKShapeNode(), foeBar = SKShapeNode(), meEn = SKShapeNode(), foeEn = SKShapeNode()
    private let timerLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let banner = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    let foeName: String

    init(mode: Mode, mine: FightCharacter, theirs: FightCharacter, myName: String, theirName: String,
         arena: FightArena = .meadow, backdrop: UIImage? = nil) {
        self.mode = mode
        self.arena = arena
        self.backdrop = backdrop
        me = FighterNode(mine)
        foe = FighterNode(theirs)
        foeName = theirName
        super.init(size: CGSize(width: 1000, height: 700))
        scaleMode = .aspectFit
        backgroundColor = UIColor(red: 0.93, green: 0.90, blue: 0.98, alpha: 1)
        addChild(world)
        buildStage()
        me.position = CGPoint(x: 240, y: Self.ground)
        foe.position = CGPoint(x: 760, y: Self.ground)
        remoteTarget = foe.position
        world.addChild(me); world.addChild(foe)
        buildHUD(myName: myName, theirName: theirName)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Stage

    private static func ui(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private func buildStage() {
        if let backdrop {
            // The challenger's own photo as the arena.
            let bg = SKSpriteNode(texture: SKTexture(image: backdrop))
            let s = max(size.width / backdrop.size.width, size.height / backdrop.size.height)
            bg.size = CGSize(width: backdrop.size.width * s, height: backdrop.size.height * s)
            bg.position = CGPoint(x: size.width / 2, y: size.height / 2); bg.zPosition = -20
            world.addChild(bg)
            let floor = SKShapeNode(rect: CGRect(x: -50, y: 0, width: size.width + 100, height: Self.ground))
            floor.fillColor = UIColor.black.withAlphaComponent(0.25); floor.strokeColor = .clear; floor.zPosition = -10
            world.addChild(floor)
            return
        }
        let sky = SKSpriteNode(texture: SKTexture(image: Self.gradient(top: Self.ui(arena.sky.0), bottom: Self.ui(arena.sky.1))))
        sky.size = CGSize(width: size.width + 100, height: size.height + 60); sky.position = CGPoint(x: size.width / 2, y: size.height / 2); sky.zPosition = -20
        world.addChild(sky)
        for (i, c) in [Self.ui(arena.hills.0), Self.ui(arena.hills.1)].enumerated() {
            let hill = SKShapeNode(ellipseOf: CGSize(width: 900, height: arena == .city ? 420 : 260))
            hill.fillColor = c; hill.strokeColor = .clear
            hill.position = CGPoint(x: i == 0 ? 250 : 780, y: Self.ground + 10); hill.zPosition = -15 + CGFloat(i)
            world.addChild(hill)
        }
        if arena == .city {
            for i in 0..<9 {
                let h = CGFloat.random(in: 140...320)
                let b = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 80, height: h), cornerRadius: 4)
                b.fillColor = Self.ui(0x2A3150); b.strokeColor = .clear; b.position = CGPoint(x: CGFloat(i) * 115 - 10, y: Self.ground); b.zPosition = -12
                for w in 0..<Int(h / 40) where Bool.random() {
                    let win = SKShapeNode(rect: CGRect(x: 14 + CGFloat(w % 2) * 30, y: 20 + CGFloat(w) * 36, width: 16, height: 12))
                    win.fillColor = Self.ui(0xFFE08A, 0.9); win.strokeColor = .clear; b.addChild(win)
                }
                world.addChild(b)
            }
        }
        let floor = SKShapeNode(rect: CGRect(x: -50, y: 0, width: size.width + 100, height: Self.ground))
        floor.fillColor = Self.ui(arena.ground); floor.strokeColor = .clear; floor.zPosition = -10
        world.addChild(floor)
        for i in 0..<16 {
            let dot = SKLabelNode(text: arena.sparkle)
            dot.fontSize = CGFloat.random(in: 14...26); dot.fontColor = UIColor.white.withAlphaComponent(0.8)
            dot.position = CGPoint(x: CGFloat(i) * 66 + 20, y: CGFloat.random(in: 400...670)); dot.zPosition = -18
            dot.run(.repeatForever(.sequence([.fadeAlpha(to: 0.2, duration: Double.random(in: 0.8...1.6)), .fadeAlpha(to: 0.9, duration: 1)])))
            if arena == .snow { dot.run(.repeatForever(.sequence([.moveBy(x: 0, y: -400, duration: Double.random(in: 4...7)), .moveBy(x: 0, y: 400, duration: 0)]))) }
            world.addChild(dot)
        }
    }

    private static func gradient(top: UIColor, bottom: UIColor) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 256))
        return r.image { ctx in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        }
    }

    private func buildHUD(myName: String, theirName: String) {
        for (i, bar) in [meBar, foeBar].enumerated() {
            let frame = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 380, height: 26), cornerRadius: 13)
            frame.fillColor = UIColor.white.withAlphaComponent(0.7); frame.strokeColor = UIColor.black.withAlphaComponent(0.15)
            frame.position = CGPoint(x: i == 0 ? 30 : size.width - 410, y: size.height - 60); frame.zPosition = 50
            addChild(frame)
            bar.zPosition = 51; bar.position = frame.position; addChild(bar)
            let en = i == 0 ? meEn : foeEn
            en.zPosition = 51; en.position = CGPoint(x: frame.position.x, y: frame.position.y - 18); addChild(en)
            let name = SKLabelNode(fontNamed: "AvenirNext-Bold")
            name.text = i == 0 ? "\(myName) · \(me.character.name)" : "\(theirName) · \(foe.character.name)"
            name.fontSize = 20; name.fontColor = UIColor(white: 0.25, alpha: 1)
            name.horizontalAlignmentMode = i == 0 ? .left : .right
            name.position = CGPoint(x: i == 0 ? 34 : size.width - 34, y: size.height - 26); name.zPosition = 52
            addChild(name)
        }
        timerLabel.fontSize = 40; timerLabel.fontColor = UIColor(red: 0.35, green: 0.25, blue: 0.55, alpha: 1)
        timerLabel.position = CGPoint(x: size.width / 2, y: size.height - 72); timerLabel.zPosition = 52
        addChild(timerLabel)
        banner.fontSize = 84; banner.fontColor = .white; banner.zPosition = 80
        banner.position = CGPoint(x: size.width / 2, y: size.height / 2)
        let shadow = SKLabelNode(fontNamed: "AvenirNext-Heavy"); shadow.fontSize = 84; shadow.fontColor = UIColor(red: 0.45, green: 0.3, blue: 0.7, alpha: 0.8)
        shadow.position = CGPoint(x: 4, y: -4); shadow.zPosition = -1; shadow.name = "shadow"
        banner.addChild(shadow)
        addChild(banner)
        refreshHUD()
    }

    private func setBanner(_ text: String) {
        banner.text = text
        (banner.childNode(withName: "shadow") as? SKLabelNode)?.text = text
        banner.setScale(0.3); banner.alpha = 1
        banner.run(.sequence([.scale(to: 1.1, duration: 0.18), .scale(to: 1, duration: 0.1)]))
    }

    private func refreshHUD() {
        func fill(_ node: SKShapeNode, _ v: CGFloat, width: CGFloat, height: CGFloat, color: UIColor, rightAligned: Bool) {
            let w = max(0, min(1, v)) * width
            node.path = CGPath(roundedRect: CGRect(x: rightAligned ? width - w : 0, y: 0, width: max(w, 0.1), height: height),
                               cornerWidth: min(height / 2, w / 2), cornerHeight: min(height / 2, w / 2), transform: nil)
            node.fillColor = color; node.strokeColor = .clear
        }
        let pink = UIColor(red: 1.0, green: 0.55, blue: 0.70, alpha: 1)
        fill(meBar, me.hp / 100, width: 380, height: 26, color: pink, rightAligned: false)
        fill(foeBar, foe.hp / 100, width: 380, height: 26, color: pink, rightAligned: true)
        let gold = UIColor(red: 1.0, green: 0.80, blue: 0.30, alpha: 1)
        fill(meEn, me.energy / 100, width: 380, height: 10, color: me.energy >= 100 ? .systemPurple : gold, rightAligned: false)
        fill(foeEn, foe.energy / 100, width: 380, height: 10, color: foe.energy >= 100 ? .systemPurple : gold, rightAligned: true)
        if started && !finished {
            timerLabel.text = "\(max(0, Int(ceil(Self.roundSeconds - (now - startTime)))))"
        }
        if abs(me.energy - lastEnergy) >= 1 { lastEnergy = me.energy; onEnergy?(me.energy) }
    }

    // MARK: Start / end

    /// 3-2-1 then fight. Online, both phones call this when the host says "go".
    private var counting = false
    func begin() {
        guard !started, !counting else { return }
        counting = true
        var steps: [SKAction] = []
        for t in ["3", "2", "1", "Fluff!"] {
            steps.append(SKAction.run { [weak self] in self?.setBanner(t); GameSound.play(t == "Fluff!" ? "fx_go" : "fx_beep") })
            steps.append(SKAction.wait(forDuration: 0.7))
        }
        run(.sequence(steps + [.run { [weak self] in
            guard let self else { return }
            self.started = true; self.startTime = self.now
            self.banner.run(.fadeOut(withDuration: 0.3))
        }]))
    }

    private func finish(iWon: Bool?) {
        guard !finished else { return }
        finished = true
        let winner = iWon == true ? me : (iWon == false ? foe : nil)
        let loser = iWon == true ? foe : (iWon == false ? me : nil)
        if let loser { knockOut(loser); shake(26) }
        GameSound.play("fx_ko")
        run(.wait(forDuration: 0.6)) { GameSound.play(iWon == false ? "fx_lose" : "fx_win") }
        speed = 0.5
        run(.wait(forDuration: 0.5)) { [weak self] in self?.speed = 1 }
        if let winner { winner.show("win"); winner.run(.repeat(.sequence([.moveBy(x: 0, y: 40, duration: 0.18), .moveBy(x: 0, y: -40, duration: 0.18)]), count: 4)) }
        setBanner(iWon == nil ? "Double flop!" : (iWon! ? "You win!" : "\(foeName) wins!"))
        confetti()
        onHaptic?(true)
        run(.wait(forDuration: 2.4)) { [weak self] in self?.onEnd?(iWon) }
    }

    // MARK: Controls (called by the SwiftUI buttons)

    func punch() { attack("punch") }
    func kick() { attack("kick") }
    func special() { guard me.energy >= 100, started, !finished, !me.ko else { return }; me.energy = 0; usePower(me) }
    func jump() {
        guard started, !finished, !me.airborne, !me.ko else { return }
        me.vy = 760
        GameSound.play("fx_jump", volume: 0.6)
    }

    /// The character's super power.
    private func usePower(_ f: FighterNode) {
        GameSound.play("fx_special")
        powerBanner(for: f.character.superPower.title, at: f)
        switch f.character.superPower {
        case .blast: attack("special", by: f)
        case .quake: attack("quake", by: f)
        case .dash: attack("dash", by: f)
        case .heal:
            f.hp = min(100, f.hp + 25)
            if f === me { guardUntil = now + 3; if mode == .online { send?(FightMsg(t: "fx", k: "heal"), true); sendState(force: true) } }
            healGlow(f)
        }
    }

    private func powerBanner(for text: String, at f: FighterNode) {
        let l = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        l.text = "\(f.character.element) \(text)!"; l.fontSize = 34; l.fontColor = .white
        l.position = CGPoint(x: f.position.x, y: f.position.y + 300); l.zPosition = 60; l.setScale(0.3)
        let back = SKShapeNode(rectOf: CGSize(width: l.frame.width / 0.3 + 30, height: 50), cornerRadius: 25)
        back.fillColor = UIColor.systemPurple.withAlphaComponent(0.85); back.strokeColor = .clear; back.zPosition = -1; back.position = CGPoint(x: 0, y: 12)
        l.addChild(back)
        addChild(l)
        l.run(.sequence([.scale(to: 1, duration: 0.15), .wait(forDuration: 0.6), .fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    private func healGlow(_ f: FighterNode) {
        let ring = SKShapeNode(circleOfRadius: 120)
        ring.strokeColor = UIColor.systemGreen.withAlphaComponent(0.8); ring.lineWidth = 10; ring.glowWidth = 12
        ring.position = CGPoint(x: 0, y: 120); ring.zPosition = 6
        f.addChild(ring)
        ring.run(.sequence([.group([.scale(to: 1.4, duration: 0.8), .fadeOut(withDuration: 0.8)]), .removeFromParent()]))
        for _ in 0..<12 {
            let h = SKLabelNode(text: ["💚", "✚", "✨"].randomElement()!); h.fontSize = 28
            h.position = CGPoint(x: CGFloat.random(in: -70...70), y: CGFloat.random(in: 20...200)); h.zPosition = 7
            f.addChild(h)
            h.run(.sequence([.group([.moveBy(x: 0, y: 90, duration: 0.9), .fadeOut(withDuration: 0.9)]), .removeFromParent()]))
        }
    }

    private func shake(_ amount: CGFloat) {
        var steps: [SKAction] = []
        for i in 0..<6 {
            let d = amount * (1 - CGFloat(i) / 6)
            steps.append(.moveBy(x: CGFloat.random(in: -d...d), y: CGFloat.random(in: -d...d) / 2, duration: 0.03))
        }
        steps.append(.move(to: .zero, duration: 0.04))
        world.removeAction(forKey: "shake")
        world.run(.sequence(steps), withKey: "shake")
    }

    private func attack(_ kind: String, by f: FighterNode? = nil) {
        let f = f ?? me
        guard started, !finished, !f.ko, now >= f.busyUntil else { return }
        let (windup, total): (TimeInterval, TimeInterval) = switch kind {
        case "kick": (0.18, 0.55)
        case "special": (0.2, 0.7)
        case "quake": (0.35, 0.8)
        case "dash": (0.25, 0.6)
        default: (0.1, 0.32)
        }
        f.busyUntil = now + total
        f.blocking = false
        f.show(kind == "kick" || kind == "dash" ? "kick" : "punch")
        if kind == "punch" || kind == "special" { showFist(f, big: kind == "special") }
        if kind == "punch" { GameSound.play("fx_punch", volume: 0.7) } else if kind == "kick" { GameSound.play("fx_kick", volume: 0.8) }
        if kind == "quake" {
            f.run(.sequence([.moveBy(x: 0, y: 120, duration: 0.15), .moveBy(x: 0, y: -120, duration: 0.15)]))
            run(.wait(forDuration: 0.3)) { [weak self, weak f] in if let f { self?.quakeWave(f) } }
        }
        if kind == "dash" {
            // Vanish in a puff, reappear behind the foe.
            let other = f === me ? foe : me
            let behind = other.position.x + (f.position.x < other.position.x ? 110 : -110)
            puff(at: f.position, element: f.character.element)
            f.position.x = min(max(behind, 90), size.width - 90)
            f.facingRight = f.position.x < other.position.x
            f.orient()
            puff(at: f.position, element: f.character.element)
        }
        let dir: CGFloat = f.facingRight ? 1 : -1
        f.sprite.run(.sequence([.moveBy(x: 14 * dir, y: 0, duration: windup), .moveBy(x: -14 * dir, y: 0, duration: 0.15)]))
        run(.wait(forDuration: windup)) { [weak self, weak f] in
            guard let self, let f, !self.finished else { return }
            if f === self.me {
                if self.mode == .online {
                    self.send?(FightMsg(t: "a", x: Double(f.position.x), y: Double(f.position.y), k: kind, b: f.facingRight), true)
                } else {
                    self.resolve(kind, attacker: f, attackerX: f.position.x, facingRight: f.facingRight, defender: self.foe)
                }
            } else {
                self.resolve(kind, attacker: f, attackerX: f.position.x, facingRight: f.facingRight, defender: self.me)
            }
        }
        run(.wait(forDuration: total)) { [weak f] in
            guard let f, !f.ko, f.pose == "kick" || f.pose == "punch" else { return }
            f.show(f.blocking ? "block" : "idle")
        }
    }

    private func showFist(_ f: FighterNode, big: Bool) {
        guard let tex = f.fistTexture() else { return }
        let fist = SKSpriteNode(texture: tex)
        let h: CGFloat = big ? 140 : 90
        fist.size = CGSize(width: tex.size().width * h / tex.size().height, height: h)
        let dir: CGFloat = f.facingRight ? 1 : -1
        fist.xScale = (f.facingRight == f.character.kickFacesLeft) ? -1 : 1
        fist.position = CGPoint(x: f.position.x + 70 * dir, y: f.position.y + 120)
        fist.zPosition = 30; fist.setScale(0.4)
        addChild(fist)
        if big {
            fist.run(.sequence([.scale(to: 1, duration: 0.15), .moveBy(x: 900 * dir, y: 0, duration: 1.0), .removeFromParent()]))
            fist.run(.repeatForever(.rotate(byAngle: -0.4 * dir, duration: 0.15)))
        } else {
            fist.run(.sequence([.group([.scale(to: 1, duration: 0.1), .moveBy(x: 60 * dir, y: 0, duration: 0.1)]), .fadeOut(withDuration: 0.15), .removeFromParent()]))
        }
    }

    /// Does the attack land? Decided on the defender's phone (or locally against the computer).
    private func resolve(_ kind: String, attacker: FighterNode, attackerX: CGFloat, facingRight: Bool, defender: FighterNode) {
        guard !defender.ko else { return }
        let dx = defender.position.x - attackerX
        let facing = facingRight ? dx > 0 : dx < 0
        let range: CGFloat = switch kind { case "kick": 215; case "special", "dash": 2000; case "quake": 460; default: 170 }
        guard facing, abs(dx) <= range else { return }
        if kind == "special" {
            // The flying fist takes a moment to arrive; jumping over it dodges.
            let delay = TimeInterval(abs(dx) / 900)
            run(.wait(forDuration: delay)) { [weak self] in
                guard let self, !defender.airborne else { self?.pop("Dodged!", at: defender); return }
                self.land(kind, attacker: attacker, defender: defender)
            }
            return
        }
        if (kind == "punch" || kind == "quake") && defender.airborne { pop("Dodged!", at: defender); return }
        land(kind, attacker: attacker, defender: defender)
    }

    private func land(_ kind: String, attacker: FighterNode, defender: FighterNode) {
        guard !finished else { return }
        let base: CGFloat = switch kind { case "kick": 11; case "special", "dash": 20; case "quake": 17; default: 7 }
        var dmg = base * attacker.character.power
        let blocked = defender.blocking
        if blocked { dmg *= 0.25 / defender.character.guardStrength }
        if defender === me && now < guardUntil { dmg *= 0.5 }
        defender.hp = max(0, defender.hp - dmg)
        defender.energy = min(100, defender.energy + (blocked ? 4 : 8))
        hitEffect(on: defender, blocked: blocked, big: kind != "punch", element: attacker.character.element)
        if kind != "punch" { shake(blocked ? 6 : 14) }
        if defender !== me { countCombo() }
        if defender === me {
            onHaptic?(kind != "punch")
            if mode == .online {
                send?(FightMsg(t: "h", d: Double(dmg), b: blocked), true)
                sendState(force: true)
                if me.hp <= 0 { send?(FightMsg(t: "ko"), true); finish(iWon: false) }
            } else if me.hp <= 0 { finish(iWon: false) }
        } else {
            attacker.energy = min(100, attacker.energy + (blocked ? 5 : 15))
            if mode == .cpu && foe.hp <= 0 { finish(iWon: true) }
        }
    }

    // MARK: Effects (no blood — stars, sparkles and "BONK!")

    private func countCombo() {
        combo = now - lastHitAt < 1.3 ? combo + 1 : 1
        lastHitAt = now
        guard combo >= 2 else { return }
        let l = SKLabelNode(fontNamed: "AvenirNext-HeavyItalic")
        l.text = "×\(combo) Combo!"; l.fontSize = 44; l.fontColor = UIColor.systemOrange
        l.position = CGPoint(x: size.width / 2, y: size.height - 150); l.zPosition = 70; l.setScale(0.4)
        addChild(l)
        l.run(.sequence([.scale(to: 1.15, duration: 0.12), .scale(to: 1, duration: 0.08), .wait(forDuration: 0.5), .fadeOut(withDuration: 0.2), .removeFromParent()]))
    }

    private func puff(at p: CGPoint, element: String) {
        for i in 0..<10 {
            let c = SKLabelNode(text: i % 3 == 0 ? element : "☁︎")
            c.fontSize = CGFloat.random(in: 26...44); c.fontColor = .white
            c.position = CGPoint(x: p.x + CGFloat.random(in: -50...50), y: p.y + CGFloat.random(in: 20...200)); c.zPosition = 40
            addChild(c)
            c.run(.sequence([.group([.scale(to: 1.6, duration: 0.4), .fadeOut(withDuration: 0.4)]), .removeFromParent()]))
        }
    }

    private func quakeWave(_ f: FighterNode) {
        shake(20)
        for dir in [-1.0, 1.0] {
            for i in 0..<6 {
                let r = SKLabelNode(text: i % 2 == 0 ? f.character.element : "💥")
                r.fontSize = 40; r.position = CGPoint(x: f.position.x, y: Self.ground + 10); r.zPosition = 30
                addChild(r)
                r.run(.sequence([.wait(forDuration: Double(i) * 0.05),
                                 .group([.moveBy(x: CGFloat(dir) * 460, y: 0, duration: 0.5), .fadeOut(withDuration: 0.5)]), .removeFromParent()]))
            }
        }
    }

    private func hitEffect(on f: FighterNode, blocked: Bool, big: Bool, element: String = "✦") {
        let dir: CGFloat = f.facingRight ? -1 : 1
        f.run(.moveBy(x: (blocked ? 12 : (big ? 46 : 26)) * dir, y: 0, duration: 0.12))
        f.sprite.colorBlendFactor = 0
        f.sprite.color = blocked ? UIColor.cyan : UIColor.white
        f.sprite.run(.sequence([.colorize(withColorBlendFactor: 0.6, duration: 0.03), .colorize(withColorBlendFactor: 0, duration: 0.18)]))
        pop(blocked ? "Blocked!" : ["BONK!", "BOP!", "POW!", "FWUMP!", "BOING!"].randomElement()!, at: f)
        GameSound.play(blocked ? "fx_block" : "fx_hit", volume: big ? 1 : 0.7)
        for _ in 0..<(big ? 10 : 6) {
            let star = SKLabelNode(text: [element, "★", "✧", "♥", element].randomElement()!)
            star.fontSize = CGFloat.random(in: 22...40)
            star.fontColor = [UIColor.systemYellow, .systemPink, .systemPurple, .systemTeal].randomElement()!
            star.position = CGPoint(x: f.position.x, y: f.position.y + 140); star.zPosition = 40
            addChild(star)
            let a = CGFloat.random(in: 0...(2 * .pi)), d = CGFloat.random(in: 60...140)
            star.run(.sequence([.group([.moveBy(x: cos(a) * d, y: sin(a) * d, duration: 0.45), .fadeOut(withDuration: 0.45), .scale(to: 0.4, duration: 0.45)]), .removeFromParent()]))
        }
    }

    private func pop(_ text: String, at f: FighterNode) {
        let l = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        l.text = text; l.fontSize = 38; l.fontColor = UIColor(red: 0.55, green: 0.3, blue: 0.85, alpha: 1)
        l.position = CGPoint(x: f.position.x, y: f.position.y + 260); l.zPosition = 45; l.setScale(0.5)
        addChild(l)
        l.run(.sequence([.group([.scale(to: 1, duration: 0.12), .moveBy(x: 0, y: 30, duration: 0.5)]), .fadeOut(withDuration: 0.2), .removeFromParent()]))
    }

    private func knockOut(_ f: FighterNode) {
        f.ko = true
        f.show("ko")
        f.sprite.removeAction(forKey: "breathe")
        f.sprite.run(.fadeAlpha(to: 0.85, duration: 0.3))
        // A poof cloud and dizzy stars circling the head.
        for i in 0..<8 {
            let puff = SKShapeNode(circleOfRadius: CGFloat.random(in: 18...34))
            puff.fillColor = UIColor.white.withAlphaComponent(0.85); puff.strokeColor = .clear; puff.zPosition = 35
            puff.position = CGPoint(x: f.position.x + CGFloat(i - 4) * 22, y: f.position.y + CGFloat.random(in: 10...60))
            addChild(puff)
            puff.run(.sequence([.group([.scale(to: 1.8, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
        }
        let ring = SKNode(); ring.position = CGPoint(x: 0, y: 250); ring.zPosition = 5
        for i in 0..<3 {
            let s = SKLabelNode(text: "★"); s.fontSize = 30; s.fontColor = .systemYellow
            let a = CGFloat(i) * 2 * .pi / 3
            s.position = CGPoint(x: cos(a) * 46, y: sin(a) * 14)
            ring.addChild(s)
        }
        f.addChild(ring)
        ring.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 1.2)))
    }

    private func confetti() {
        for _ in 0..<40 {
            let c = SKShapeNode(rectOf: CGSize(width: 10, height: 16), cornerRadius: 3)
            c.fillColor = [UIColor.systemPink, .systemYellow, .systemTeal, .systemPurple, .systemOrange].randomElement()!; c.strokeColor = .clear
            c.position = CGPoint(x: CGFloat.random(in: 0...size.width), y: size.height + 20); c.zPosition = 70
            addChild(c)
            c.run(.sequence([.group([.moveBy(x: CGFloat.random(in: -80...80), y: -size.height - 60, duration: Double.random(in: 1.6...2.6)),
                                     .rotate(byAngle: CGFloat.random(in: -6...6), duration: 2)]), .removeFromParent()]))
        }
    }

    // MARK: Online messages

    func receive(_ m: FightMsg) {
        switch m.t {
        case "s":
            if let x = m.x, let y = m.y { remoteTarget = CGPoint(x: size.width - x, y: y) }
            if let hp = m.hp { foe.hp = CGFloat(hp) }
            if let en = m.en { foe.energy = CGFloat(en) }
            if let p = m.p, p != foe.pose, !foe.ko, p != "punch" || foe.pose != "punch" {
                foe.blocking = p == "block"
                if p == "kick" || p == "block" || p == "idle" { foe.show(p) }
            }
        case "a":
            guard let x = m.x, let k = m.k else { return }
            let ax = size.width - CGFloat(x)
            // Mirrored stage: their "facing right" is facing left here.
            let fr = !(m.b ?? true)
            foe.facingRight = fr
            foe.show(k == "kick" || k == "dash" ? "kick" : "punch")
            if k == "punch" || k == "special" { showFist(foe, big: k == "special") }
            if k == "quake" { quakeWave(foe) }
            if k == "dash" { puff(at: CGPoint(x: ax, y: FightScene.ground), element: foe.character.element) }
            if k == "special" || k == "quake" || k == "dash" { GameSound.play("fx_special"); powerBanner(for: foe.character.superPower.title, at: foe) }
            run(.wait(forDuration: k == "kick" ? 0.4 : 0.25)) { [weak self] in
                guard let self, !self.foe.ko, self.foe.pose == "kick" || self.foe.pose == "punch" else { return }
                self.foe.show(self.foe.blocking ? "block" : "idle")
            }
            resolve(k, attacker: foe, attackerX: ax, facingRight: fr, defender: me)
        case "h":
            // My attack landed on their phone.
            let blocked = m.b ?? false
            me.energy = min(100, me.energy + (blocked ? 5 : 15))
            hitEffect(on: foe, blocked: blocked, big: (m.d ?? 0) > 9)
        case "fx":
            if m.k == "heal" { healGlow(foe); powerBanner(for: foe.character.superPower.title, at: foe); GameSound.play("fx_special") }
        case "ko":
            foe.hp = 0
            finish(iWon: true)
        case "end":
            // Host's verdict when time runs out: u = "host", "guest" or "draw" seen from the host.
            finish(iWon: m.u == "draw" ? nil : (m.u == "you"))
        default: break
        }
    }

    /// Host only: decide when time runs out.
    var isHost = false

    private func sendState(force: Bool = false) {
        guard mode == .online, force || now - lastSent > 1.0 / 15 else { return }
        lastSent = now
        send?(FightMsg(t: "s", x: Double(me.position.x), y: Double(me.position.y), p: me.blocking && me.pose != "kick" ? "block" : me.pose,
                       hp: Double(me.hp), en: Double(me.energy)), false)
    }

    // MARK: Loop

    override func update(_ currentTime: TimeInterval) {
        let dt = last == 0 ? 1.0 / 60 : min(currentTime - last, 1.0 / 20)
        last = currentTime
        now = currentTime
        defer { refreshHUD() }
        // Face each other.
        if !me.ko { me.facingRight = me.position.x < foe.position.x; me.orient() }
        if !foe.ko && mode == .cpu { foe.facingRight = foe.position.x < me.position.x; foe.orient() }
        if mode == .online && !foe.ko { foe.facingRight = foe.position.x < me.position.x; foe.orient() }
        guard started, !finished else { return }

        step(me, dt: dt, moveLeft: left, moveRight: right)
        if mode == .cpu { cpuThink(); step(foe, dt: dt, moveLeft: cpuMove < 0, moveRight: cpuMove > 0) }
        else {
            foe.position.x += (remoteTarget.x - foe.position.x) * min(1, CGFloat(dt) * 12)
            foe.position.y += (remoteTarget.y - foe.position.y) * min(1, CGFloat(dt) * 12)
            foe.shadow.position = CGPoint(x: 0, y: Self.ground - foe.position.y)
        }
        if me.blocking && me.pose == "idle" { me.show("block") }
        if !me.blocking && me.pose == "block" { me.show("idle") }
        sendState()

        if now - startTime >= Self.roundSeconds {
            if mode == .cpu {
                finish(iWon: me.hp == foe.hp ? nil : me.hp > foe.hp)
            } else if isHost {
                let verdict = me.hp == foe.hp ? "draw" : (me.hp > foe.hp ? "me" : "you")
                send?(FightMsg(t: "end", u: verdict), true)
                finish(iWon: verdict == "draw" ? nil : verdict == "me")
            }
        }
    }

    private func step(_ f: FighterNode, dt: TimeInterval, moveLeft: Bool, moveRight: Bool) {
        guard !f.ko else { return }
        let canMove = now >= f.busyUntil && !f.blocking
        if canMove {
            let v = (moveRight ? 1 : 0) - (moveLeft ? 1 : 0)
            f.position.x += CGFloat(v) * 300 * f.character.speed * CGFloat(dt)
        }
        f.vy -= 2000 * CGFloat(dt)
        f.position.y = max(Self.ground, f.position.y + f.vy * CGFloat(dt))
        if f.position.y <= Self.ground { f.vy = 0 }
        // Stay on stage and don't walk through each other.
        let other = f === me ? foe : me
        f.position.x = min(max(f.position.x, 90), size.width - 90)
        if abs(f.position.x - other.position.x) < 110 && !f.airborne && !other.airborne {
            f.position.x = other.position.x + (f.position.x < other.position.x ? -110 : 110)
            f.position.x = min(max(f.position.x, 90), size.width - 90)
        }
        f.shadow.position = CGPoint(x: 0, y: Self.ground - f.position.y)
        f.shadow.setScale(max(0.5, 1 - (f.position.y - Self.ground) / 400))
    }

    // MARK: Computer opponent

    private var cpuMove = 0

    private func cpuThink() {
        guard now >= cpuNext, !foe.ko else { return }
        cpuNext = now + Double.random(in: 0.22...0.45)
        let dist = abs(foe.position.x - me.position.x)
        foe.blocking = now < cpuBlockUntil
        if foe.energy >= 100 && Bool.random() { foe.energy = 0; usePower(foe); return }
        // React to my attacks sometimes.
        if (me.pose == "kick" || me.pose == "punch") && dist < 230 && Double.random(in: 0...1) < 0.35 {
            cpuBlockUntil = now + 0.5; foe.blocking = true; foe.show("block"); cpuMove = 0; return
        }
        if dist > 190 { cpuMove = foe.position.x < me.position.x ? 1 : -1; if foe.pose == "block" { foe.show("idle") }; return }
        cpuMove = 0
        switch Double.random(in: 0...1) {
        case ..<0.38: attack("punch", by: foe)
        case ..<0.62: attack("kick", by: foe)
        case ..<0.72: if !foe.airborne { foe.vy = 760 }
        case ..<0.84: cpuMove = foe.position.x < me.position.x ? -1 : 1
        default: cpuBlockUntil = now + 0.6; foe.blocking = true; foe.show("block")
        }
    }
}
