import SwiftUI

/// Pick a relation — family, Client, Team member… — or choose Custom… and type your own.
struct RelationPicker: View {
    @Binding var relation: String
    var title = "Relation"
    @State private var custom = false

    var body: some View {
        Group {
            Picker(title, selection: Binding(get: { custom ? Relations.custom : relation },
                                             set: { v in
                                                 if v == Relations.custom { custom = true; if Relations.all.contains(relation) { relation = "" } }
                                                 else { custom = false; relation = v }
                                             })) {
                Text("Not set").tag("")
                ForEach(Relations.all, id: \.self) { Text($0).tag($0) }
                Text(Relations.custom).tag(Relations.custom)
            }
            if custom {
                TextField("Custom relation (e.g. Coach, Neighbour)", text: $relation)
            }
        }
        .onAppear { custom = !relation.isEmpty && !Relations.all.contains(relation) }
    }
}
