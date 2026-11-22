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

    init(mode: Mode, mine: FightCharacter, theirs: FightCharacter, myName: String, theirName: String) {
        self.mode = mode
        me = FighterNode(mine)
        foe = FighterNode(theirs)
        foeName = theirName
        super.init(size: CGSize(width: 1000, height: 700))
        scaleMode = .aspectFit
        backgroundColor = UIColor(red: 0.93, green: 0.90, blue: 0.98, alpha: 1)
        buildStage()
        me.position = CGPoint(x: 240, y: Self.ground)
        foe.position = CGPoint(x: 760, y: Self.ground)
        remoteTarget = foe.position
        addChild(me); addChild(foe)
        buildHUD(myName: myName, theirName: theirName)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Stage

    private func buildStage() {
        let sky = SKSpriteNode(texture: SKTexture(image: Self.gradient(top: UIColor(red: 0.80, green: 0.86, blue: 1.0, alpha: 1),
                                                                         bottom: UIColor(red: 1.0, green: 0.88, blue: 0.93, alpha: 1))))
        sky.size = size; sky.position = CGPoint(x: size.width / 2, y: size.height / 2); sky.zPosition = -20
        addChild(sky)
        for (i, c) in [UIColor(red: 0.74, green: 0.86, blue: 0.74, alpha: 1), UIColor(red: 0.64, green: 0.80, blue: 0.66, alpha: 1)].enumerated() {
            let hill = SKShapeNode(ellipseOf: CGSize(width: 900, height: 260))
            hill.fillColor = c; hill.strokeColor = .clear
            hill.position = CGPoint(x: i == 0 ? 250 : 780, y: Self.ground + 10); hill.zPosition = -15 + CGFloat(i)
            addChild(hill)
        }
        let floor = SKShapeNode(rect: CGRect(x: 0, y: 0, width: size.width, height: Self.ground))
        floor.fillColor = UIColor(red: 0.96, green: 0.86, blue: 0.74, alpha: 1); floor.strokeColor = .clear; floor.zPosition = -10
        addChild(floor)
        for i in 0..<14 {
            let dot = SKShapeNode(circleOfRadius: CGFloat.random(in: 2...5))
            dot.fillColor = UIColor.white.withAlphaComponent(0.7); dot.strokeColor = .clear
            dot.position = CGPoint(x: CGFloat(i) * 75 + 20, y: CGFloat.random(in: 420...660)); dot.zPosition = -18
            dot.run(.repeatForever(.sequence([.fadeAlpha(to: 0.2, duration: Double.random(in: 0.8...1.6)), .fadeAlpha(to: 0.8, duration: 1)])))
            addChild(dot)
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
    }

    // MARK: Start / end

    /// 3-2-1 then fight. Online, both phones call this when the host says "go".
    func begin() {
        guard !started else { return }
        var steps: [SKAction] = []
        for t in ["3", "2", "1", "Fluff!"] {
            steps.append(SKAction.run { [weak self] in self?.setBanner(t) })
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
        if let loser { knockOut(loser) }
        if let winner { winner.show("win"); winner.run(.repeat(.sequence([.moveBy(x: 0, y: 40, duration: 0.18), .moveBy(x: 0, y: -40, duration: 0.18)]), count: 4)) }
        setBanner(iWon == nil ? "Double flop!" : (iWon! ? "You win!" : "\(foeName) wins!"))
        confetti()
        onHaptic?(true)
        run(.wait(forDuration: 2.4)) { [weak self] in self?.onEnd?(iWon) }
    }

    // MARK: Controls (called by the SwiftUI buttons)

    func punch() { attack("punch") }
    func kick() { attack("kick") }
    func special() { guard me.energy >= 100 else { return }; me.energy = 0; attack("special") }
    func jump() {
        guard started, !finished, !me.airborne, !me.ko else { return }
        me.vy = 760
    }

    private func attack(_ kind: String, by f: FighterNode? = nil) {
        let f = f ?? me
        guard started, !finished, !f.ko, now >= f.busyUntil else { return }
        let (windup, total): (TimeInterval, TimeInterval) = kind == "kick" ? (0.18, 0.55) : kind == "special" ? (0.2, 0.7) : (0.1, 0.32)
        f.busyUntil = now + total
        f.blocking = false
        f.show(kind == "kick" ? "kick" : "punch")
        if kind != "kick" { showFist(f, big: kind == "special") }
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
        let range: CGFloat = kind == "kick" ? 215 : kind == "special" ? 2000 : 170
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
        if kind == "punch" && defender.airborne { return }
        land(kind, attacker: attacker, defender: defender)
    }

    private func land(_ kind: String, attacker: FighterNode, defender: FighterNode) {
        guard !finished else { return }
        let base: CGFloat = kind == "kick" ? 11 : kind == "special" ? 20 : 7
        var dmg = base * attacker.character.power
        let blocked = defender.blocking
        if blocked { dmg *= 0.25 / defender.character.guardStrength }
        defender.hp = max(0, defender.hp - dmg)
        defender.energy = min(100, defender.energy + (blocked ? 4 : 8))
        hitEffect(on: defender, blocked: blocked, big: kind != "punch")
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

    private func hitEffect(on f: FighterNode, blocked: Bool, big: Bool) {
        let dir: CGFloat = f.facingRight ? -1 : 1
        f.run(.moveBy(x: (blocked ? 12 : (big ? 46 : 26)) * dir, y: 0, duration: 0.12))
        f.sprite.colorBlendFactor = 0
        f.sprite.color = blocked ? UIColor.cyan : UIColor.white
        f.sprite.run(.sequence([.colorize(withColorBlendFactor: 0.6, duration: 0.03), .colorize(withColorBlendFactor: 0, duration: 0.18)]))
        pop(blocked ? "Blocked!" : ["BONK!", "BOP!", "POW!", "FWUMP!", "BOING!"].randomElement()!, at: f)
        for _ in 0..<(big ? 10 : 6) {
            let star = SKLabelNode(text: ["✦", "★", "✧", "♥"].randomElement()!)
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
            foe.show(k == "kick" ? "kick" : "punch")
            if k != "kick" { showFist(foe, big: k == "special") }
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
        if foe.energy >= 100 && Bool.random() { foe.energy = 0; attack("special", by: foe); return }
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
