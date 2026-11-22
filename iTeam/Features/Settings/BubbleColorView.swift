import SwiftUI

/// Settings → Chat bubble: pick my bubble colour, its text colour, and (optionally) the other person's bubble.
struct BubbleColorView: View {
    @Environment(\.look) private var look
    @State private var mine: Int = UserDefaults.standard.object(forKey: "bubble.color") as? Int ?? -1
    @State private var theirs: Int = UserDefaults.standard.object(forKey: "bubble.inColor") as? Int ?? -1
    @State private var text: String = UserDefaults.standard.string(forKey: "bubble.text") ?? "auto"
    @State private var editingTheirs = false
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                preview
                Picker("Bubble", selection: $editingTheirs) { Text("My messages").tag(false); Text("Their messages").tag(true) }
                    .pickerStyle(.segmented)
                LazyVGrid(columns: cols, spacing: 18) {
                    Button { set(-1) } label: {
                        Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 2, dash: [4])).frame(width: 64, height: 64)
                            .overlay(Text("Theme").font(.caption2.bold()))
                            .overlay { if current == -1 { Circle().stroke(Color.primary, lineWidth: 3).padding(-6) } }
                    }
                    ForEach(BubbleColors.all, id: \.self) { c in
                        Button { set(Int(c)) } label: {
                            Circle().fill(Color(hex: c)).frame(width: 64, height: 64)
                                .overlay { if current == Int(c) { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(BubbleColors.isLight(c) ? .black : .white) } }
                                .overlay { if current == Int(c) { Circle().stroke(Color.primary, lineWidth: 3).padding(-6) } }
                        }
                    }
                }
                .buttonStyle(.plain)
                if !editingTheirs {
                    Picker("Text colour", selection: $text) { Text("Automatic").tag("auto"); Text("White").tag("white"); Text("Black").tag("black") }
                        .pickerStyle(.segmented)
                        .onChange(of: text) { _, v in UserDefaults.standard.set(v, forKey: "bubble.text"); refresh() }
                }
                Text("“Theme” uses your Appearance theme's colours. Text colour is chosen automatically for easy reading unless you pick one.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        }
        .lookScreen()
        .navigationTitle("Chat bubble")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var current: Int { editingTheirs ? theirs : mine }

    private var preview: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Hi! Is the site visit still on for today?")
                    .padding(10)
                    .foregroundStyle(look.bubbleInText)
                    .background(theirs >= 0 ? AnyShapeStyle(Color(hex: UInt32(theirs))) : AnyShapeStyle(look.bubbleIn), in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 40)
            }
            HStack {
                Spacer(minLength: 40)
                Text("Yes — see you at 4 PM 👍")
                    .padding(10)
                    .foregroundStyle(look.bubbleOutText)
                    .background(look.bubbleOut, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding().lookCard()
    }

    private func set(_ v: Int) {
        Haptics.tap()
        if editingTheirs {
            theirs = v
            if v < 0 { UserDefaults.standard.removeObject(forKey: "bubble.inColor") } else { UserDefaults.standard.set(v, forKey: "bubble.inColor") }
        } else {
            mine = v
            if v < 0 { UserDefaults.standard.removeObject(forKey: "bubble.color") } else { UserDefaults.standard.set(v, forKey: "bubble.color") }
        }
        refresh()
    }

    private func refresh() { LookManager.shared.objectWillChange.send() }
}
