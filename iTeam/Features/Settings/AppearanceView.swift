import SwiftUI
import PhotosUI

/// Pick one of three looks, then fine-tune it.
struct AppearanceView: View {
    @EnvironmentObject var looks: LookManager
    @Environment(\.look) private var look
    @State private var photo: PhotosPickerItem?
    @State private var skinPhoto: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Style").font(.headline)
                ForEach(Array(UIStyle.allCases.enumerated()), id: \.element.id) { i, s in
                    styleCard(s).appear(i)
                }

                switch looks.style {
                case .vivid: vividOptions
                case .calm: calmOptions
                case .classic: classicOptions
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .lookScreen()
        .navigationTitle("Appearance")
        .onChange(of: photo) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), WallpaperStore.save(d, key: "app") {
                    looks.vividPhoto = true
                    looks.photoVersion += 1
                }
            }
        }
        .onChange(of: skinPhoto) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), WallpaperStore.save(d, key: "skin") {
                    looks.skin = .photo
                    looks.photoVersion += 1
                }
            }
        }
    }

    private func styleCard(_ s: UIStyle) -> some View {
        let selected = looks.style == s
        return Button {
            Haptics.tap()
            withAnimation(.easeInOut(duration: 0.5)) { looks.style = s }
        } label: {
            HStack(spacing: 14) {
                preview(s)
                    .frame(width: 92, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Label(s.title, systemImage: s.icon).font(.headline)
                    Text(s.subtitle).font(.caption).foregroundStyle(look.textSecondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(selected ? look.accent : look.textSecondary)
            }
            .lookCard()
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(selected ? look.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(PressStyle())
    }

    /// Mini phone preview of each style.
    @ViewBuilder
    private func preview(_ s: UIStyle) -> some View {
        ZStack {
            switch s {
            case .vivid: VividWallpaper(theme: looks.currentVivid, animated: false)
            case .calm: SkinArt(skin: looks.skin == .none ? .aurora : looks.skin)
            case .classic: Color(.systemGroupedBackground)
            }
            VStack(alignment: .leading, spacing: 6) {
                bubble(width: 50, mine: false, s)
                bubble(width: 60, mine: true, s)
                bubble(width: 40, mine: false, s)
            }
            .padding(8)
        }
    }

    private func bubble(width: CGFloat, mine: Bool, _ s: UIStyle) -> some View {
        let fill: AnyShapeStyle
        switch s {
        case .vivid: fill = mine ? AnyShapeStyle(looks.currentVivid.gradient) : AnyShapeStyle(.ultraThinMaterial)
        case .calm: fill = mine ? AnyShapeStyle(Color(hex: 0x3FB4BE)) : AnyShapeStyle(.ultraThinMaterial)
        case .classic: fill = mine ? AnyShapeStyle(looks.pastel.soft) : AnyShapeStyle(Color(.secondarySystemBackground))
        }
        return RoundedRectangle(cornerRadius: 7).fill(fill).frame(width: width, height: 14)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    // MARK: iLife

    private var vividOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $looks.vividAuto.animation(.easeInOut(duration: 0.6))) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Follow the time of day", systemImage: "sun.and.horizon.fill").font(.headline)
                    Text("Fresh in the morning, ocean at midday, sunset in the evening, aurora at night.")
                        .font(.caption).foregroundStyle(look.textSecondary)
                }
            }
            .lookCard()

            Text("iLife themes").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(Array(VividTheme.allCases.enumerated()), id: \.element.id) { i, t in
                    let selected = !looks.vividAuto && looks.vivid == t && !looks.vividPhoto
                    Button {
                        Haptics.tap()
                        withAnimation(.easeInOut(duration: 0.6)) {
                            looks.vividAuto = false
                            looks.vividPhoto = false
                            looks.vivid = t
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            VividWallpaper(theme: t, animated: false)
                                .frame(height: 150)
                                .overlay(alignment: .topTrailing) {
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, t.accent).padding(8)
                                    }
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.subheadline.bold())
                                Text(t.mood).font(.caption2).foregroundStyle(look.textSecondary)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(t.gradient) : AnyShapeStyle(Color.white.opacity(0.15)), lineWidth: selected ? 3 : 1))
                        .shadow(color: selected ? t.accent.opacity(0.5) : .clear, radius: 12)
                    }
                    .buttonStyle(PressStyle())
                    .appear(i)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Your own wallpaper").font(.headline)
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Choose a photo", systemImage: "photo.on.rectangle")
                }
                if looks.vividPhoto {
                    Button("Remove my photo", role: .destructive) {
                        withAnimation { looks.vividPhoto = false }
                        WallpaperStore.remove("app")
                    }
                }
                Text("Colours and buttons still follow the theme you pick above.").font(.caption).foregroundStyle(look.textSecondary)
            }
            .lookCard()
        }
    }

    // MARK: Third Eye

    private var calmOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Theme").font(.headline)
            VStack(spacing: 0) {
                ForEach(CalmTheme.allCases) { t in
                    Button {
                        Haptics.tap()
                        looks.calm = t
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.body.weight(.medium))
                                Text(t.subtitle).font(.caption).foregroundStyle(look.textSecondary)
                            }
                            Spacer()
                            if looks.calm == t { Image(systemName: "checkmark").foregroundStyle(look.accent) }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if t != CalmTheme.allCases.last { Divider() }
                }
            }
            .lookCard()

            Picker("Glass", selection: $looks.glassLook) {
                ForEach(GlassLook.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("Skin").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                skinTile(.none)
                ForEach(Skin.builtIn) { skinTile($0) }
                if WallpaperStore.image("skin", version: looks.photoVersion) != nil { skinTile(.photo) }
            }
            PhotosPicker(selection: $skinPhoto, matching: .images) {
                Label("Use a photo from my library", systemImage: "photo.on.rectangle")
            }
            .lookCard()
            if looks.skin != .none {
                VStack(alignment: .leading) {
                    Text("Dim the wallpaper").font(.headline)
                    HStack {
                        Image(systemName: "sun.max")
                        Slider(value: $looks.skinDim, in: 0...0.7)
                        Image(systemName: "moon.fill")
                    }
                    Text("Like Winamp skins: the wallpaper sits behind every screen and everything on top is glass. A skin switches to the dark look so text stays readable.")
                        .font(.caption).foregroundStyle(look.textSecondary)
                }
                .lookCard()
            }
        }
    }

    private func skinTile(_ s: Skin) -> some View {
        let selected = looks.skin == s
        return Button { Haptics.tap(); looks.skin = s } label: {
            VStack(spacing: 6) {
                ZStack {
                    if s == .none {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground))
                        Image(systemName: "nosign").foregroundStyle(look.textSecondary)
                    } else {
                        SkinArt(skin: s, photoVersion: looks.photoVersion)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.ultraThinMaterial).frame(width: 56, height: 18)
                    }
                }
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? look.accent : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1))
                Text(s.title).font(.caption.weight(selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Classic

    private var classicOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Appearance", selection: $looks.classicAppearance) {
                Text("System").tag(0)
                Text("Light").tag(1)
                Text("Dark").tag(2)
            }
            .pickerStyle(.segmented)

            Text("Pastel colour").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                ForEach(PastelAccent.allCases) { p in
                    Button { Haptics.tap(); looks.pastel = p } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(p.soft)
                                Circle().fill(p.strong).frame(width: 18, height: 18)
                                if looks.pastel == p { Circle().stroke(p.strong, lineWidth: 3) }
                            }
                            .frame(width: 56, height: 56)
                            Text(p.title).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .lookCard()
            Text("The regular iOS look: solid backgrounds, no wallpapers, soft pastel bubbles.")
                .font(.caption).foregroundStyle(look.textSecondary)
        }
    }
}
