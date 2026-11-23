import SwiftUI
import SwiftData
import PhotosUI

/// Transformation journey (from iLife): front, side and back progress photos with before / after compare.
/// Photos are end-to-end encrypted and shared only in this person's chat (e.g. with their trainer).
struct GymTransformationView: View {
    let memberID: String
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @Query private var found: [GymMember]
    @Query private var photos: [GymPhoto]
    @State private var pose = "Front"
    @State private var capture = false
    @State private var compare = false
    @State private var open: GymPhoto?

    init(memberID: String) {
        self.memberID = memberID
        _found = Query(filter: #Predicate<GymMember> { $0.id == memberID })
        _photos = Query(filter: #Predicate<GymPhoto> { $0.memberID == memberID && !$0.deleted }, sort: \GymPhoto.date, order: .reverse)
    }

    private var posePhotos: [GymPhoto] { photos.filter { $0.pose == pose } }
    private var days: Int {
        guard let first = photos.last?.date else { return 0 }
        return (Calendar.current.dateComponents([.day], from: first, to: .now).day ?? 0) + 1
    }
    private var weights: [GymPhoto] { photos.filter { $0.weight > 0 }.sorted { $0.date < $1.date } }

    var body: some View {
        if let m = found.first { content(m) } else { EmptyStateView(icon: "figure.stand", title: "Not found", message: "") }
    }

    private func content(_ m: GymMember) -> some View {
        List {
            Section {
                HStack(spacing: 10) {
                    GymStat(value: "\(photos.count)", label: "Photos", icon: "camera.fill")
                    GymStat(value: "\(days)", label: "Days in", icon: "calendar")
                    GymStat(value: weightChange, label: "Weight change", icon: "scalemass.fill")
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Button { capture = true } label: {
                    Label("Take progress photos", systemImage: "camera.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large).listRowBackground(Color.clear)
            } footer: {
                Text("Same spot, same light, same pose — once a week works well. Photos are end-to-end encrypted and shared only in “\(engine.conversation(m.convID)?.title ?? "this chat")”.")
            }

            Section {
                Picker("Pose", selection: $pose) { ForEach(GymPhoto.poses, id: \.self) { Text($0) } }
                    .pickerStyle(.segmented)
                if posePhotos.count >= 2 {
                    Button { compare = true } label: { Label("Compare before / after", systemImage: "rectangle.split.2x1") }
                }
                if posePhotos.isEmpty {
                    Text("No \(pose.lowercased()) photos yet.").foregroundStyle(look.textSecondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(posePhotos) { p in
                            Button { open = p } label: { tile(p) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: { Text("Journey") }
            .lookRows()

            if weights.count >= 2 {
                Section("Weight") {
                    ForEach(weights.reversed().prefix(10)) { p in
                        HStack { Text(p.date.formatted(date: .abbreviated, time: .omitted)); Spacer(); Text(String(format: "%.1f kg", p.weight)).bold() }
                    }
                }
                .lookRows()
            }
        }
        .listStyle(.insetGrouped)
        .lookScreen()
        .navigationTitle("Transformation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $capture) { NavigationStack { GymPhotoCapture(member: m) } }
        .sheet(isPresented: $compare) {
            NavigationStack { GymCompareView(name: m.name, pose: pose, before: posePhotos.last, after: posePhotos.first, all: Array(posePhotos.reversed())) }
        }
        .sheet(item: $open) { p in NavigationStack { GymPhotoDetail(member: m, photo: p) } }
    }

    private var weightChange: String {
        guard let a = weights.first?.weight, let b = weights.last?.weight, weights.count >= 2 else { return "–" }
        let d = b - a
        return (d > 0 ? "+" : "") + String(format: "%.1f kg", d)
    }

    private func tile(_ p: GymPhoto) -> some View {
        ZStack(alignment: .bottomLeading) {
            GymPhotoImage(ref: p.photo, thumbOnly: true)
                .frame(height: 130).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(p.date.formatted(.dateTime.day().month(.abbreviated)))
                .font(.caption2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule()).padding(5)
        }
    }
}

/// Loads an encrypted photo (thumbnail at once, full image after download).
struct GymPhotoImage: View {
    let ref: AttachmentRef?
    var thumbOnly = false
    var fit = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.2))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else if let t = ref?.thumb, let img = UIImage(data: t) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: fit ? .fit : .fill).blur(radius: thumbOnly ? 0 : 4)
            }
        }
        .task(id: ref?.id) {
            guard !thumbOnly, let ref, let url = try? await Attachments.load(ref) else { return }
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

/// Guided capture: front → side → back, from the camera or the library, plus optional weight.
struct GymPhotoCapture: View {
    let member: GymMember
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var shots: [String: Data] = [:]
    @State private var camera: String?
    @State private var library: String?
    @State private var item: PhotosPickerItem?
    @State private var weight = ""
    @State private var note = ""
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                ForEach(GymPhoto.poses, id: \.self) { pose in
                    HStack(spacing: 12) {
                        Group {
                            if let d = shots[pose], let img = UIImage(data: d) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Image(systemName: pose == "Side" ? "figure.walk" : "figure.stand").font(.title).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.15))
                            }
                        }
                        .frame(width: 64, height: 84).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pose).font(.headline)
                            HStack {
                                Button("Camera", systemImage: "camera") { camera = pose }.buttonStyle(.bordered)
                                Button("Library", systemImage: "photo") { library = pose }.buttonStyle(.bordered)
                            }
                            .font(.caption)
                        }
                    }
                }
            } footer: { Text("Stand in the same place each time, arms relaxed, full body in frame.") }
            AIScanSection(spec: ScanSpec(title: "Scan the InBody / body-composition report", what: "an InBody or body-composition analysis printout",
                                         fields: [.number("weight", "Weight (kg)"), .number("fat", "Body fat %"), .number("muscle", "Skeletal muscle mass (kg)"),
                                                  .number("bmi", "BMI"), .number("visceral", "Visceral fat level"), .number("bmr", "BMR (kcal)"), .number("score", "InBody score")],
                                         hint: "Copy the numbers exactly as printed. Do not interpret them.")) { o in
                if let v = o.number("weight") { weight = String(v) }
                let parts = [("Fat", o.str("fat"), "%"), ("Muscle", o.str("muscle"), " kg"), ("BMI", o.str("bmi"), ""), ("Visceral", o.str("visceral"), ""),
                             ("BMR", o.str("bmr"), " kcal"), ("Score", o.str("score"), "")].compactMap { t in t.1.map { "\(t.0) \($0)\(t.2)" } }
                if !parts.isEmpty { note = "InBody: " + parts.joined(separator: " · ") }
            }
            Section {
                TextField("Weight in kg (optional)", text: $weight).keyboardType(.decimalPad)
                TextField("Note (optional)", text: $note)
            }
        }
        .navigationTitle("Progress photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { save() }.bold().disabled(shots.isEmpty || saving)
            }
        }
        .fullScreenCover(item: Binding(get: { camera.map(PoseBox.init) }, set: { camera = $0?.pose })) { b in
            CameraPicker { img in if let d = img.jpegData(compressionQuality: 0.9) { shots[b.pose] = d } }.ignoresSafeArea()
        }
        .photosPicker(isPresented: Binding(get: { library != nil }, set: { if !$0 { library = nil } }), selection: $item, matching: .images)
        .onChange(of: item) { _, it in
            let pose = library
            Task {
                if let pose, let d = try? await it?.loadTransferable(type: Data.self) { shots[pose] = d }
                item = nil; library = nil
            }
        }
    }

    private func save() {
        saving = true
        let w = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
        for pose in GymPhoto.poses {
            guard let d = shots[pose], let prepared = try? Attachments.prepareImage(d) else { continue }
            engine.saveGymPhoto(member, pose: pose, date: .now, photo: prepared.ref, note: note, weight: w,
                                uploads: [prepared.upload.0: prepared.upload.1])
        }
        Haptics.big()
        dismiss()
    }
}

private struct PoseBox: Identifiable { let pose: String; var id: String { pose } }

/// Before / after: side by side, or a drag-to-reveal slider. Share as one image.
struct GymCompareView: View {
    let name: String
    let pose: String
    @State var before: GymPhoto?
    @State var after: GymPhoto?
    let all: [GymPhoto]
    @Environment(\.dismiss) private var dismiss
    @State private var slider = false
    @State private var split: CGFloat = 0.5
    @State private var shareImage: UIImage?

    var body: some View {
        VStack(spacing: 12) {
            Picker("Style", selection: $slider) { Text("Side by side").tag(false); Text("Slider").tag(true) }
                .pickerStyle(.segmented).padding(.horizontal)
            board.padding(.horizontal)
            HStack {
                picker("Before", selection: $before)
                Spacer()
                picker("After", selection: $after)
            }
            .padding(.horizontal)
            Spacer()
        }
        .navigationTitle("\(pose) · before / after")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                if let shareImage {
                    ShareLink(item: Image(uiImage: shareImage), preview: SharePreview("\(name) transformation", image: Image(uiImage: shareImage)))
                } else {
                    Button("Prepare share", systemImage: "square.and.arrow.up") { render() }
                }
            }
        }
    }

    @ViewBuilder private var board: some View {
        if slider {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    GymPhotoImage(ref: after?.photo, fit: false).frame(width: g.size.width, height: g.size.height).clipped()
                    GymPhotoImage(ref: before?.photo, fit: false).frame(width: g.size.width, height: g.size.height).clipped()
                        .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * split) }
                    Rectangle().fill(.white).frame(width: 3).offset(x: g.size.width * split - 1.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(1, max(0, $0.location.x / g.size.width)) })
            }
            .aspectRatio(3 / 4, contentMode: .fit)
        } else {
            HStack(spacing: 6) {
                half(before, "Before")
                half(after, "After")
            }
        }
    }

    private func half(_ p: GymPhoto?, _ label: String) -> some View {
        VStack(spacing: 4) {
            GymPhotoImage(ref: p?.photo).aspectRatio(3 / 4, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
            Text("\(label) · \(p?.date.formatted(date: .abbreviated, time: .omitted) ?? "–")\(p.map { $0.weight > 0 ? String(format: " · %.1f kg", $0.weight) : "" } ?? "")")
                .font(.caption.bold())
        }
    }

    private func picker(_ title: String, selection: Binding<GymPhoto?>) -> some View {
        Menu {
            ForEach(all) { p in Button(p.date.formatted(date: .abbreviated, time: .omitted)) { selection.wrappedValue = p; shareImage = nil } }
        } label: { Label(title, systemImage: "calendar") }
        .buttonStyle(.bordered)
    }

    /// Renders the two full photos with dates into one shareable image.
    private func render() {
        Task {
            var imgs: [UIImage] = []
            for p in [before, after] {
                if let ref = p?.photo, let url = try? await Attachments.load(ref), let img = UIImage(contentsOfFile: url.path) { imgs.append(img) }
            }
            guard imgs.count == 2 else { return }
            let h: CGFloat = 1200, pad: CGFloat = 24
            let ws = imgs.map { $0.size.width * h / $0.size.height }
            let size = CGSize(width: ws[0] + ws[1] + pad * 3, height: h + pad * 2 + 70)
            let r = UIGraphicsImageRenderer(size: size)
            shareImage = r.image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                imgs[0].draw(in: CGRect(x: pad, y: pad, width: ws[0], height: h))
                imgs[1].draw(in: CGRect(x: pad * 2 + ws[0], y: pad, width: ws[1], height: h))
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.darkGray]
                let a = "Before · \(before?.date.formatted(date: .abbreviated, time: .omitted) ?? "")" as NSString
                let b = "After · \(after?.date.formatted(date: .abbreviated, time: .omitted) ?? "")" as NSString
                a.draw(at: CGPoint(x: pad, y: h + pad + 16), withAttributes: attrs)
                b.draw(at: CGPoint(x: pad * 2 + ws[0], y: h + pad + 16), withAttributes: attrs)
            }
        }
    }
}

struct GymPhotoDetail: View {
    let member: GymMember
    let photo: GymPhoto
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            GymPhotoImage(ref: photo.photo, fit: true).clipShape(RoundedRectangle(cornerRadius: 16)).padding()
            Text("\(photo.pose) · \(photo.date.formatted(date: .long, time: .omitted))\(photo.weight > 0 ? String(format: " · %.1f kg", photo.weight) : "")")
                .font(.subheadline.bold())
            if !photo.note.isEmpty { Text(photo.note).font(.footnote).foregroundStyle(.secondary) }
            Text("Added by \(photo.by == engine.me ? "you" : engine.name(of: photo.by))").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .navigationTitle("Progress photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            if photo.by == engine.me || member.createdBy == engine.me, let ref = photo.photo {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        engine.saveGymPhoto(member, id: photo.id, pose: photo.pose, date: photo.date, photo: ref, note: photo.note,
                                            weight: photo.weight, deleted: true)
                        dismiss()
                    }
                }
            }
        }
    }
}
