import SwiftUI
import AVFoundation

/// Game sounds (original, generated for iTeam) — respect the silent switch and the in-game sound toggle.
@MainActor
enum GameSound {
    private static var players: [String: AVAudioPlayer] = [:]
    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "game.sound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "game.sound") }
    }

    static func play(_ name: String, volume: Float = 1) {
        guard on else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        if players[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            players[name] = try? AVAudioPlayer(contentsOf: url)
            players[name]?.prepareToPlay()
        }
        guard let p = players[name] else { return }
        p.volume = volume
        p.currentTime = 0
        p.play()
    }
}

/// A winner's blast: fireworks and confetti over any game screen.
struct WinnerBlast: View {
    let title: String
    @State private var go = false
    private let colors: [Color] = [.pink, .yellow, .orange, .purple, .mint, .cyan, .red]

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<4, id: \.self) { burst in
                    let cx = g.size.width * [0.25, 0.75, 0.5, 0.35][burst]
                    let cy = g.size.height * [0.3, 0.25, 0.45, 0.6][burst]
                    ForEach(0..<18, id: \.self) { i in
                        let a = Double(i) / 18 * 2 * .pi
                        Circle().fill(colors[(i + burst) % colors.count])
                            .frame(width: 9, height: 9)
                            .position(x: cx + (go ? cos(a) * 120 : 0), y: cy + (go ? sin(a) * 120 + 40 : 0))
                            .opacity(go ? 0 : 1)
                            .animation(.easeOut(duration: 1.3).delay(Double(burst) * 0.35), value: go)
                    }
                }
                ForEach(0..<40, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(colors[i % colors.count])
                        .frame(width: 8, height: 14)
                        .rotationEffect(.degrees(go ? Double(i * 47) : 0))
                        .position(x: CGFloat((i * 53) % Int(max(g.size.width, 1))), y: go ? g.size.height + 30 : -30)
                        .animation(.easeIn(duration: Double(2 + (i % 5)) * 0.5).delay(Double(i % 7) * 0.08), value: go)
                }
                Text(title)
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .scaleEffect(go ? 1 : 0.2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.5), value: go)
                    .position(x: g.size.width / 2, y: g.size.height * 0.4)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            go = true
            GameSound.play("fx_blast")
            Task { try? await Task.sleep(for: .milliseconds(400)); GameSound.play("fx_win") }
        }
    }
}
